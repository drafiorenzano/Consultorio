-- =====================================================================
-- Site do consultório: lançar pelo site (recebimento, despesa, estoque).
--
-- O site grava pelas MESMAS funções do conector (mcp_registrar_pagamento,
-- mcp_registrar_despesa, mcp_movimentar_estoque): mesmas validações, mesma
-- auditoria, nada se apaga (corrige-se com estorno). A solicitação fica
-- marcada com cliente = 'site' e o usuário da conta do site.
-- =====================================================================

-- A solicitação e a auditoria sabem quando o pedido veio do site.
create or replace function public.iniciar_solicitacao(
  p_ferramenta text,
  p_argumentos jsonb,
  p_texto_original text,
  p_cliente text default 'mcp')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.solicitacoes (ferramenta, argumentos, texto_original, cliente, usuario)
  values (p_ferramenta, coalesce(p_argumentos, '{}'::jsonb),
          nullif(btrim(p_texto_original), ''),
          coalesce(nullif(current_setting('app.cliente', true), ''), p_cliente, 'mcp'),
          coalesce(auth.uid(), nullif(current_setting('app.usuario', true), '')::uuid))
  returning id into v_id;
  perform set_config('app.solicitacao_id', v_id::text, true);
  return v_id;
end
$$;

create or replace function public.registrar_auditoria()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_antes jsonb;
  v_depois jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_antes := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_depois := to_jsonb(new); end if;
  insert into public.auditoria (solicitacao_id, tabela, operacao, registro_id, antes, depois, usuario)
  values (nullif(current_setting('app.solicitacao_id', true), '')::uuid,
          tg_table_name, tg_op,
          coalesce(v_depois ->> 'id', v_antes ->> 'id', v_depois ->> 'codigo', v_antes ->> 'codigo'),
          v_antes, v_depois,
          coalesce(auth.uid()::text, nullif(current_setting('app.usuario', true), ''), current_user));
  return null;
end
$$;

-- Só os campos que cada formulário do site pode mandar.
create or replace function public.painel_campos(p_dados jsonb, p_campos text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
    from jsonb_each(coalesce(p_dados, '{}'::jsonb)) e(k, v)
   where k = any (p_campos) and v <> 'null'::jsonb
$$;

-- Gravação pelo site: confere a sessão (e registra o acesso) e chama a
-- mesma função do conector. Erro de validação desfaz tudo e volta como erro.
create or replace function public.painel_gravar(p_usuario uuid, p_sessao uuid, p_acao text, p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_texto text := left(coalesce(nullif(btrim(p_dados ->> 'texto_original'), ''), 'Lançado pelo site'), 500);
  v_mov jsonb;
begin
  if p_acao not in ('pagamento', 'estornar_pagamento', 'despesa', 'estornar_despesa', 'estoque') then
    raise exception 'Lançamento "%" desconhecido.', p_acao;
  end if;
  if not public.painel_autorizar(p_usuario, p_sessao, 'gravar:' || p_acao, null) then
    return jsonb_build_object('status', 'sessao_expirada');
  end if;
  perform set_config('app.cliente', 'site', true);
  perform set_config('app.usuario', p_usuario::text, true);

  if p_acao = 'pagamento' then
    return public.mcp_registrar_pagamento(
      jsonb_build_object('acao', 'pagamento') || public.painel_campos(p_dados, array[
        'paciente_id', 'valor', 'forma', 'data', 'parcelas_cartao', 'descricao', 'orcamento_id',
        'confirmar_duplicado', 'quitar_parcela']),
      v_texto);
  elsif p_acao = 'estornar_pagamento' then
    return public.mcp_registrar_pagamento(
      jsonb_build_object('acao', 'estornar') || public.painel_campos(p_dados, array['recebimento_id', 'motivo']),
      v_texto);
  elsif p_acao = 'despesa' then
    return public.mcp_registrar_despesa(
      jsonb_build_object('acao', 'registrar') || public.painel_campos(p_dados, array[
        'valor', 'categoria', 'data', 'descricao', 'fornecedor', 'forma', 'competencia', 'paciente_id',
        'confirmar_duplicada']),
      v_texto);
  elsif p_acao = 'estornar_despesa' then
    return public.mcp_registrar_despesa(
      jsonb_build_object('acao', 'estornar') || public.painel_campos(p_dados, array['despesa_id', 'motivo']),
      v_texto);
  end if;

  -- estoque: um movimento por vez (uso, perda, vencido, contagem, entrada)
  v_mov := public.painel_campos(p_dados, array['tipo', 'material', 'quantidade', 'unidade', 'motivo', 'preco_unitario']);
  if coalesce(v_mov ->> 'tipo', '') not in ('uso', 'perda', 'vencido', 'contagem', 'entrada') then
    raise exception 'Escolha o tipo: uso, perda, vencido, contagem ou entrada.';
  end if;
  return public.mcp_movimentar_estoque(
    jsonb_strip_nulls(jsonb_build_object('data', p_dados ->> 'data', 'movimentos', jsonb_build_array(v_mov))),
    v_texto);
end
$$;

-- ---------------------------------------------------------------------
-- Leituras que o site precisa para lançar e estornar
-- ---------------------------------------------------------------------

-- Financeiro: as listas do mês passam a trazer id e número (para estornar),
-- e os pagamentos das clínicas onde ela atende (sem paciente) entram na lista.
create or replace function public.painel_financeiro_extra(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with mes as (
    select public.fin_mes(p_params ->> 'mes') ini,
           (public.fin_mes(p_params ->> 'mes') + interval '1 month')::date fim
  )
  select jsonb_build_object(
    'historico', (
      select jsonb_agg(public.fin_totais_mes(m::date) order by m)
        from mes, generate_series(date_trunc('month', mes.ini) - interval '11 months',
                                  date_trunc('month', mes.ini), interval '1 month') m),
    'recibos_a_emitir', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', p.nome, 'paciente_id', p.id, 'data', r.data_pagamento,
               'forma', public.rotulo_forma_pagamento(r.forma, r.parcelas_cartao), 'valor', r.valor_bruto,
               'status', case x.s when 'cancelar' then 'cancelar recibo' else 'a emitir' end))
             order by r.data_pagamento, r.numero), '[]'::jsonb)
        from public.recebimentos r
        join public.pacientes p on p.id = r.paciente_id
        cross join lateral (select public.recibo_situacao(r.id) ->> 'situacao' s) x
       where r.estorna_id is null and r.regime_fiscal = 'pf' and x.s in ('pendente', 'cancelar')),
    'recebimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', x.id,
               'numero', x.numero,
               -- pagamento de clínica (sem paciente): mostra o nome da clínica
               'titulo', coalesce(p.nome, to_jsonb(x) ->> 'clinica', 'Clínica'),
               'paciente_id', p.id,
               'clinica', case when p.id is null then true end,
               'descricao', x.descricao,
               'data', x.data_pagamento,
               'forma', public.rotulo_forma_pagamento(x.forma, x.parcelas_cartao),
               'valor', x.valor_bruto,
               'status', case when exists (select 1 from public.recebimentos e where e.estorna_id = x.id)
                              then 'estornado' end)) order by x.data_pagamento desc, x.numero desc), '[]'::jsonb)
        from mes, public.recebimentos x left join public.pacientes p on p.id = x.paciente_id
       where x.data_pagamento >= mes.ini and x.data_pagamento < mes.fim and x.estorna_id is null),
    'despesas', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', d.id,
               'numero', d.numero,
               'titulo', d.descricao,
               'data', d.data,
               'forma', public.fin_rotulo_categoria(d.categoria),
               'valor', d.valor,
               'automatica', case when d.origem in ('compra', 'reserva_sala') then true end,
               'status', case when exists (select 1 from public.despesas e where e.estorna_id = d.id)
                              then 'estornada' end)) order by d.data desc, d.numero desc), '[]'::jsonb)
        from mes, public.despesas d
       where d.data >= mes.ini and d.data < mes.fim and d.estorna_id is null))
  from mes
$$;

-- Atividade: marca o que foi lançado pelo site (e não pelo Claude).
create or replace function public.painel_atividade(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with s as (
    select s.*
      from public.solicitacoes s
     where (nullif(p_params ->> 'antes', '') is null or s.criado_em < (p_params ->> 'antes')::timestamptz)
       and (not coalesce((p_params ->> 'so_mudancas')::boolean, false)
            or exists (select 1 from public.auditoria a where a.solicitacao_id = s.id))
     order by s.criado_em desc
     limit 80
  )
  select jsonb_build_object(
    'total', (select count(*) from public.solicitacoes),
    'itens', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'ferramenta', s.ferramenta,
      'texto', s.texto_original,
      'em', s.criado_em,
      'data', (s.criado_em at time zone public.fuso())::date,
      'hora', to_char(s.criado_em at time zone public.fuso(), 'HH24:MI'),
      'ok', s.sucesso,
      'erro', s.erro,
      'pelo_site', case when s.cliente = 'site' then true end,
      'mudancas', nullif(a.n, 0),
      'tabelas', a.tabelas,
      'pacientes', pa.lista)) order by s.criado_em desc), '[]'::jsonb))
    from s
    left join lateral (
      select count(*) n, jsonb_agg(distinct au.tabela) filter (where au.tabela is not null) tabelas
        from public.auditoria au where au.solicitacao_id = s.id) a on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome) order by p.nome) lista
        from public.pacientes p
       where p.id in (
         select case when au.tabela = 'pacientes' then au.registro_id
                     else coalesce(au.depois ->> 'paciente_id', au.antes ->> 'paciente_id') end::uuid
           from public.auditoria au
          where au.solicitacao_id = s.id
            and coalesce(case when au.tabela = 'pacientes' then au.registro_id end,
                         au.depois ->> 'paciente_id', au.antes ->> 'paciente_id')
                ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) pa on true
$$;

-- Estoque: a lista de materiais com as unidades (para o formulário).
create or replace function public.painel_estoque_materiais()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('materiais', coalesce(jsonb_agg(jsonb_build_object(
           'nome', m.nome, 'unidade_uso', m.unidade_uso, 'unidade_compra', m.unidade_compra, 'fator', m.fator)
           order by public.normalizar(m.nome)), '[]'::jsonb))
    from public.estoque_materiais m
   where m.ativo
$$;

create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio() || public.painel_inicio_extra()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params)
    when 'financeiro' then public.painel_financeiro(p_params) || public.painel_financeiro_extra(p_params)
    when 'estoque' then public.painel_estoque(p_params) || public.painel_estoque_extra(p_params)
                        || public.painel_estoque_materiais()
    when 'orcamentos' then public.painel_orcamentos(p_params)
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_configuracoes()
    else null
  end;
end
$$;

revoke execute on function
  public.painel_campos(jsonb, text[]), public.painel_gravar(uuid, uuid, text, jsonb),
  public.painel_financeiro_extra(jsonb), public.painel_estoque_materiais(), public.painel(text, jsonb),
  public.painel_atividade(jsonb)
  from public, anon, authenticated;
grant execute on function
  public.painel_campos(jsonb, text[]), public.painel_gravar(uuid, uuid, text, jsonb),
  public.painel_financeiro_extra(jsonb), public.painel_estoque_materiais(), public.painel(text, jsonb),
  public.painel_atividade(jsonb)
  to service_role;
