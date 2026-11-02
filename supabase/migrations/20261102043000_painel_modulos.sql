-- Integração dos módulos: ficha do paciente com orçamentos, documentos e
-- financeiro; compra de material vira despesa; atendimento traz avisos do
-- estoque; painel do iPad com estoque, financeiro do mês e orçamentos a
-- acompanhar; chaves estrangeiras de orçamento no financeiro.

-- ------------------------------------------------------------------
-- Chaves estrangeiras que esperavam o módulo de documentos
-- ------------------------------------------------------------------
alter table public.acordos_pagamento
  add constraint acordos_pagamento_orcamento_id_fkey
  foreign key (orcamento_id) references public.orcamentos (id);
alter table public.recebimentos
  add constraint recebimentos_orcamento_id_fkey
  foreign key (orcamento_id) references public.orcamentos (id);

-- ------------------------------------------------------------------
-- Rótulos curtos
-- ------------------------------------------------------------------
create or replace function public.rotulo_forma_pagamento(p_forma text, p_parcelas int default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_forma
    when 'pix' then 'Pix' when 'dinheiro' then 'Dinheiro' when 'debito' then 'Débito'
    when 'credito' then 'Crédito' || case when p_parcelas > 1 then ' ' || p_parcelas || 'x' else '' end
    when 'transferencia' then 'Transferência' when 'boleto' then 'Boleto' when 'cheque' then 'Cheque'
    else initcap(replace(coalesce(p_forma, ''), '_', ' ')) end
$$;

create or replace function public.nome_do_mes(p_mes date)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto',
                'setembro', 'outubro', 'novembro', 'dezembro'])[extract(month from p_mes)::int]
         || ' de ' || extract(year from p_mes)::int
$$;

-- ------------------------------------------------------------------
-- Orçamento resumido (lista do paciente, iPad e ficha do Claude)
-- ------------------------------------------------------------------
create or replace function public.orcamento_resumo(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', j ->> 'id',
    'numero', (j ->> 'numero')::int,
    'versao', (j ->> 'versao')::int,
    'titulo', j ->> 'rotulo' || coalesce(' · ' || (j ->> 'titulo'), ''),
    'data', j -> 'emitido_em',
    'status', j ->> 'status_texto',
    'situacao', j ->> 'status',
    'valor', j -> 'total',
    'opcoes', case when jsonb_array_length(j -> 'opcoes') > 1 then (
                select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                         'alternativa', o ->> 'alternativa', 'total', o -> 'total')))
                  from jsonb_array_elements(j -> 'opcoes') o) end,
    'validade', j -> 'validade',
    'dias_para_vencer', j -> 'dias_para_vencer',
    'apresentado_em', j -> 'apresentado_em',
    'aprovado_em', j -> 'aprovado_em',
    'forma', j ->> 'forma_escolhida',
    'proximo_contato', j -> 'acompanhamento' -> 'proximo_contato',
    'contato_em_atraso', case when (j -> 'acompanhamento' ->> 'em_atraso')::boolean then true end,
    'itens', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'descricao', i ->> 'descricao', 'local', i ->> 'local', 'alternativa', i ->> 'alternativa',
                       'valor', i -> 'valor_total', 'status', i ->> 'status',
                       'conta', case when not (i ->> 'conta')::boolean then false end)))
                from jsonb_array_elements(j -> 'itens') i),
    'arquivo', (public.documento_arquivo(p_id) ->> 'caminho')))
  from (select public.orcamento_json(p_id) j) x
  where j is not null
$$;

-- Orçamentos do paciente (sem versões substituídas), mais recentes primeiro.
create or replace function public.orcamentos_do_paciente(p_paciente uuid, p_so_abertos boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.orcamento_resumo(o.id) order by o.criado_em desc), '[]'::jsonb)
    from public.orcamentos o
   where o.paciente_id = p_paciente
     and o.status <> 'substituido'
     and (not p_so_abertos or o.status in ('rascunho', 'apresentado', 'aprovado', 'parcial'))
$$;

-- Documentos gerados do paciente (PDFs), mais recentes primeiro.
create or replace function public.documentos_do_paciente(p_paciente uuid, p_limite int default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'titulo', d.titulo,
           'tipo', d.tipo,
           'data', (d.gerado_em at time zone public.fuso())::date,
           'arquivo', d.caminho)) order by d.gerado_em desc), '[]'::jsonb)
    from (select * from public.documentos where paciente_id = p_paciente
           order by gerado_em desc limit greatest(1, least(coalesce(p_limite, 100), 200))) d
$$;

-- Financeiro do paciente: saldo, parcelas em aberto e pagamentos.
create or replace function public.financeiro_do_paciente(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select public.saldo_paciente(p_paciente) || jsonb_strip_nulls(jsonb_build_object(
    'total_orcado', (select nullif(sum((public.orcamento_json(o.id) ->> 'total')::numeric), 0)
                       from public.orcamentos o
                      where o.paciente_id = p_paciente and o.status in ('aprovado', 'parcial', 'concluido')),
    'recebido', (select coalesce(sum(r.valor_bruto), 0) from public.recebimentos r where r.paciente_id = p_paciente),
    'saldo', (public.saldo_paciente(p_paciente) -> 'a_receber'),
    'recebimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', coalesce(r.descricao, 'Pagamento'),
               'numero', r.numero,
               'data', r.data_pagamento,
               'forma', public.rotulo_forma_pagamento(r.forma, r.parcelas_cartao),
               'valor', r.valor_bruto,
               'status', case when exists (select 1 from public.recebimentos e where e.estorna_id = r.id)
                              then 'estornado' end)) order by r.data_pagamento desc, r.numero desc), '[]'::jsonb)
        from public.recebimentos r
       where r.paciente_id = p_paciente and r.estorna_id is null)))
$$;

-- ------------------------------------------------------------------
-- Ficha do paciente (Claude): mais o que está em aberto nos módulos
-- ------------------------------------------------------------------
create or replace function public.paciente_ficha(p_id uuid, p_qtd_atendimentos int default 10)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', p.id,
    'ficha', p.ficha,
    'nome', p.nome,
    'nome_social', p.nome_social,
    'apelido', p.apelido,
    'data_nascimento', p.data_nascimento,
    'idade', public.idade(p.data_nascimento),
    'sexo', p.sexo,
    'cpf', p.cpf,
    'rg', p.rg,
    'telefone', p.telefone,
    'whatsapp', p.whatsapp,
    'email', p.email,
    'endereco', p.endereco,
    'profissao', p.profissao,
    'estado_civil', p.estado_civil,
    'contato_emergencia', p.contato_emergencia,
    'origem', p.origem,
    'convenio', p.convenio,
    'alertas_saude', p.alertas_saude,
    'observacoes', p.observacoes,
    'consentimento_lgpd_em', p.consentimento_lgpd_em,
    'consentimento_imagem_em', p.consentimento_imagem_em,
    'arquivado_em', p.arquivado_em,
    'cadastrado_em', to_char(p.criado_em at time zone public.fuso(), 'YYYY-MM-DD'),
    'responsaveis', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'nome', r.nome, 'cpf', r.cpf, 'parentesco', r.parentesco,
               'telefone', r.telefone, 'e_pagador', r.e_pagador)) order by r.criado_em)
      from public.responsaveis r where r.paciente_id = p.id),
    'anamnese', public.anamnese_json(p.id),
    'odontograma', nullif(public.odontograma_json(p.id), '[]'::jsonb),
    'proximas_consultas', nullif(public.consultas_do_paciente(p.id) -> 'proximas', '[]'::jsonb),
    'orcamentos_em_aberto', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'numero', x ->> 'numero', 'versao', x -> 'versao', 'status', x ->> 'status', 'total', x -> 'valor',
               'opcoes', x -> 'opcoes', 'validade', x -> 'validade', 'proximo_contato', x -> 'proximo_contato')))
        from jsonb_array_elements(public.orcamentos_do_paciente(p.id, true)) x),
    'financeiro', (select case when (s ->> 'pago_total')::numeric <> 0 or (s ->> 'a_receber')::numeric <> 0
                               then s - 'parcelas_em_aberto'
                                    || jsonb_strip_nulls(jsonb_build_object('parcelas_em_aberto',
                                         nullif(s -> 'parcelas_em_aberto', '[]'::jsonb))) end
                     from (select public.saldo_paciente(p.id) s) z),
    'documentos_recentes', nullif(public.documentos_do_paciente(p.id, 5), '[]'::jsonb),
    'total_atendimentos', (select count(*) from public.atendimentos a where a.paciente_id = p.id),
    'ultimos_atendimentos', (
      select coalesce(jsonb_agg(public.atendimento_json(x.id) order by x.data desc, x.registrado_em desc), '[]'::jsonb)
      from (select a.id, a.data, a.registrado_em
              from public.atendimentos a
             where a.paciente_id = p.id
             order by a.data desc, a.registrado_em desc
             limit greatest(1, least(coalesce(p_qtd_atendimentos, 10), 50))) x)
  ))
  from public.pacientes p
  where p.id = p_id
$$;

-- ------------------------------------------------------------------
-- Estoque: compra vira despesa de materiais
-- ------------------------------------------------------------------
create or replace function public.compra_para_financeiro()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_forn text;
begin
  if new.cancelada_em is not null then
    if tg_op = 'UPDATE' and old.cancelada_em is null then
      perform public.financeiro_estornar_despesa_automatica('compra', new.id,
        coalesce('Compra cancelada: ' || nullif(btrim(new.motivo_cancelamento), ''), 'Compra cancelada.'));
    end if;
    return null;
  end if;
  if tg_op = 'INSERT' then
    select f.nome into v_forn from public.estoque_fornecedores f where f.id = new.fornecedor_id;
    perform public.financeiro_lancar_despesa_automatica('compra', new.id, new.data, 'materiais', new.valor_total,
      'Compra de materiais' || coalesce(' · ' || v_forn, '') || coalesce(' · NF ' || new.nota_fiscal, ''),
      v_forn, null, new.forma_pagamento);
  end if;
  return null;
end
$$;

create trigger estoque_compras_financeiro after insert or update of cancelada_em on public.estoque_compras
  for each row execute function public.compra_para_financeiro();

revoke execute on function public.compra_para_financeiro() from public, anon, authenticated;

-- Compras que já existiam entram no financeiro.
select public.financeiro_lancar_despesa_automatica('compra', c.id, c.data, 'materiais', c.valor_total,
         'Compra de materiais' || coalesce(' · ' || f.nome, '') || coalesce(' · NF ' || c.nota_fiscal, ''),
         f.nome, null, c.forma_pagamento)
  from public.estoque_compras c left join public.estoque_fornecedores f on f.id = c.fornecedor_id
 where c.cancelada_em is null;

-- ------------------------------------------------------------------
-- Painel: estoque
-- ------------------------------------------------------------------
create or replace function public.estoque_situacao(p_saldo numeric, p_minimo numeric, p_acompanhado boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when not p_acompanhado then 'sem_contagem'
              when p_saldo <= 0 then 'zerado'
              when p_minimo > 0 and p_saldo <= p_minimo then 'baixo'
              else 'ok' end
$$;

create or replace function public.estoque_alertas_painel()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'nome', x.nome,
           'quantidade', public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, greatest(x.saldo, 0)),
           'zerado', case when x.saldo <= 0 then true end,
           'mensagem', 'Mínimo: ' || public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.estoque_minimo)))
           order by x.saldo <= 0 desc, x.nome)
    from (select m.*, public.estoque_saldo(m.id) saldo from public.estoque_materiais m
           where m.ativo and public.estoque_acompanhado(m.id)) x
   where x.saldo <= 0 or (x.estoque_minimo > 0 and x.saldo <= x.estoque_minimo)
$$;

create or replace function public.painel_estoque(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_lista jsonb := public.estoque_lista_compras();
begin
  return jsonb_strip_nulls(jsonb_build_object(
    'sem_contagem', not exists (select 1 from public.estoque_movimentos where tipo in ('compra', 'contagem', 'entrada_avulsa')),
    'resumo', jsonb_build_object(
      'materiais', (select count(*) from public.estoque_materiais where ativo),
      'com_contagem', (select count(*) from public.estoque_materiais m where m.ativo and public.estoque_acompanhado(m.id)),
      'valor_em_estoque', (select round(coalesce(sum(greatest(public.estoque_saldo(m.id), 0) * coalesce(m.custo_medio, 0)), 0), 2)
                             from public.estoque_materiais m where m.ativo),
      'lista_de_compras', jsonb_array_length(v_lista -> 'itens'),
      'total_estimado', v_lista -> 'total_estimado'),
    'itens', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'nome', x.nome,
               'categoria', public.estoque_rotulo_categoria(x.categoria),
               'quantidade', case when x.acompanhado then
                               public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.saldo) end,
               'minimo', case when x.estoque_minimo > 0 then
                           public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.estoque_minimo) end,
               'situacao', public.estoque_situacao(x.saldo, x.estoque_minimo, x.acompanhado),
               'zerado', case when x.acompanhado and x.saldo <= 0 then true end,
               'baixo', case when public.estoque_situacao(x.saldo, x.estoque_minimo, x.acompanhado) = 'baixo' then true end,
               'ultimo_preco', case when x.custo_medio is not null then round(x.custo_medio * x.fator, 2) end,
               'unidade_compra', x.unidade_compra,
               'vence_primeiro', (select min(s.validade) from public.estoque_lotes_saldo(x.id) s where s.saldo > 0)))
             order by x.categoria, x.nome), '[]'::jsonb)
        from (select m.*, public.estoque_saldo(m.id) saldo, public.estoque_acompanhado(m.id) acompanhado
                from public.estoque_materiais m where m.ativo) x),
    'lista_de_compras', nullif(v_lista -> 'itens', '[]'::jsonb),
    'vencendo', (
      select jsonb_agg(jsonb_build_object('nome', m.nome, 'lote', s.lote, 'validade', s.validade,
                                          'quantidade', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, s.saldo))
                       order by s.validade)
        from public.estoque_materiais m cross join lateral public.estoque_lotes_saldo(m.id) s
       where m.ativo and s.saldo > 0 and s.validade <= public.hoje() + 60),
    'ultimas_compras', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', coalesce(f.nome, 'Compra'), 'data', c.data, 'numero', c.nota_fiscal,
               'forma', public.rotulo_forma_pagamento(c.forma_pagamento), 'valor', c.valor_total,
               'status', case when c.cancelada_em is not null then 'cancelada' end)) order by c.data desc, c.registrado_em desc)
        from (select * from public.estoque_compras order by data desc, registrado_em desc limit 15) c
        left join public.estoque_fornecedores f on f.id = c.fornecedor_id)));
end
$$;

create or replace function public.estoque_rotulo_categoria(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p
    when 'agulha' then 'Agulhas' when 'anestesico' then 'Anestésicos' when 'antissepsia' then 'Antissepsia'
    when 'cirurgia' then 'Cirurgia' when 'clareamento' then 'Clareamento' when 'dentistica' then 'Dentística'
    when 'descartavel' then 'Descartáveis' when 'endodontia' then 'Endodontia' when 'epi' then 'EPI'
    when 'esterilizacao' then 'Esterilização' when 'profilaxia' then 'Profilaxia' when 'protese' then 'Prótese'
    when 'radiologia' then 'Radiologia' else initcap(coalesce(p, 'Outros')) end
$$;

-- ------------------------------------------------------------------
-- Painel: ficha do paciente com as abas dos módulos
-- ------------------------------------------------------------------
create or replace function public.painel_paciente(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
  v jsonb;
begin
  begin
    v_id := (p_params ->> 'id')::uuid;
  exception when invalid_text_representation then
    raise exception 'Paciente inválido.';
  end;
  v := public.paciente_ficha(v_id, 50);
  if v is null then raise exception 'Paciente não encontrado.'; end if;
  return (v - 'proximas_consultas' - 'orcamentos_em_aberto' - 'financeiro' - 'documentos_recentes')
         || jsonb_build_object(
              'consultas', public.consultas_do_paciente(v_id),
              'orcamentos', public.orcamentos_do_paciente(v_id),
              'documentos', public.documentos_do_paciente(v_id),
              'financeiro', public.financeiro_do_paciente(v_id));
end
$$;

-- ------------------------------------------------------------------
-- Painel: financeiro do mês
-- ------------------------------------------------------------------
create or replace function public.painel_financeiro(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_mes date := public.fin_mes(p_params ->> 'mes');
  v_fim date := (v_mes + interval '1 month')::date;
  r jsonb := public.financeiro_resumo_mes(v_mes);
begin
  return jsonb_strip_nulls(jsonb_build_object(
    'mes', to_char(v_mes, 'YYYY-MM'),
    'periodo', public.nome_do_mes(v_mes),
    'anterior', to_char(v_mes - interval '1 month', 'YYYY-MM'),
    'proximo', to_char(v_mes + interval '1 month', 'YYYY-MM'),
    'resumo', jsonb_strip_nulls(jsonb_build_object(
      'recebido', r -> 'recebido' -> 'bruto',
      'taxas', r -> 'recebido' -> 'taxas',
      'liquido', r -> 'recebido' -> 'liquido',
      'a_receber', r -> 'a_receber' -> 'total_em_aberto',
      'atrasado', nullif((r -> 'a_receber' ->> 'atrasado_hoje')::numeric, 0),
      'despesas', r -> 'despesas' -> 'total',
      'resultado', r -> 'resultado')),
    'por_forma', (select jsonb_agg(jsonb_build_object(
                           'titulo', public.rotulo_forma_pagamento(f ->> 'forma'), 'valor', f -> 'bruto'))
                    from jsonb_array_elements(r -> 'recebido' -> 'por_forma') f),
    'por_categoria', (select jsonb_agg(jsonb_build_object(
                               'titulo', public.fin_rotulo_categoria(c ->> 'categoria'), 'valor', c -> 'total'))
                        from jsonb_array_elements(r -> 'despesas' -> 'por_categoria') c),
    'hora_clinica', r -> 'hora_clinica' -> 'valor_hora',
    'recibos_pendentes', nullif((r -> 'recibos_receita_saude' ->> 'pendentes')::int, 0),
    'avisos', nullif(r -> 'avisos', '[]'::jsonb),
    'recebimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', p.nome,
               'paciente_id', p.id,
               'descricao', x.descricao,
               'data', x.data_pagamento,
               'forma', public.rotulo_forma_pagamento(x.forma, x.parcelas_cartao),
               'valor', x.valor_bruto,
               'status', case when exists (select 1 from public.recebimentos e where e.estorna_id = x.id)
                              then 'estornado' end)) order by x.data_pagamento desc, x.numero desc), '[]'::jsonb)
        from public.recebimentos x join public.pacientes p on p.id = x.paciente_id
       where x.data_pagamento >= v_mes and x.data_pagamento < v_fim and x.estorna_id is null),
    'despesas', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', d.descricao,
               'data', d.data,
               'forma', public.fin_rotulo_categoria(d.categoria),
               'valor', d.valor,
               'status', case when exists (select 1 from public.despesas e where e.estorna_id = d.id)
                              then 'estornada' end)) order by d.data desc, d.numero desc), '[]'::jsonb)
        from public.despesas d
       where d.data >= v_mes and d.data < v_fim and d.estorna_id is null),
    'parcelas_a_receber', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', p.nome, 'paciente_id', p.id, 'descricao', j ->> 'descricao',
               'numero', j ->> 'parcela', 'data', j -> 'vencimento', 'valor', j -> 'restante',
               'status', j ->> 'situacao')) order by pp.vencimento)
        from public.parcelas_previstas pp
        join public.acordos_pagamento a on a.id = pp.acordo_id and a.cancelado_em is null
        join public.pacientes p on p.id = a.paciente_id
        cross join lateral (select public.parcela_json(pp) j) z
       where pp.cancelada_em is null and pp.vencimento < v_fim
         and (j ->> 'restante')::numeric > 0)));
end
$$;

-- ------------------------------------------------------------------
-- Painel: início com financeiro do mês e orçamentos a acompanhar
-- ------------------------------------------------------------------
create or replace function public.painel_inicio()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'hoje', public.hoje(),
    'dia_semana', public.dia_semana(public.hoje()),
    'agora', public.hora_local(now()),
    'configuracao', public.painel_configuracao(),
    'agenda_hoje', public.agenda_dia_json(public.hoje()),
    'agenda_amanha', public.agenda_dia_json(public.hoje() + 1),
    'pendentes_de_confirmacao', public.pendentes_confirmacao(public.hoje(), public.hoje() + 7),
    'retornos_sem_consulta', public.retornos_sem_consulta(public.hoje() + 14),
    'orcamentos_acompanhar', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'paciente', p.nome, 'paciente_id', p.id, 'telefone', public.telefone_contato(p.id),
               'titulo', x ->> 'titulo', 'valor', x -> 'valor', 'opcoes', x -> 'opcoes',
               'proximo_contato', x -> 'proximo_contato', 'validade', x -> 'validade',
               'em_atraso', x -> 'contato_em_atraso')) order by x ->> 'proximo_contato')
        from public.orcamentos o
        join public.pacientes p on p.id = o.paciente_id and p.arquivado_em is null
        cross join lateral (select public.orcamento_resumo(o.id) x) z
       where o.status = 'apresentado'
         and (x ->> 'proximo_contato')::date <= public.hoje() + 3),
    'estoque_alertas', public.estoque_alertas_painel(),
    'financeiro_mes', (
      select jsonb_build_object(
               'recebido', f -> 'recebido' -> 'bruto',
               'a_receber', f -> 'a_receber' -> 'vence_no_mes',
               'despesas', f -> 'despesas' -> 'total',
               'resultado', f -> 'resultado')
        from (select public.financeiro_resumo_mes(public.hoje()) f) z),
    'numeros', jsonb_build_object(
      'pacientes', (select count(*) from public.pacientes where arquivado_em is null),
      'consultas_semana', (select count(*) from public.consultas c
                            where c.status in ('agendada', 'confirmada', 'realizada')
                              and public.data_local(c.inicio)
                                  between public.hoje() - (extract(isodow from public.hoje())::int - 1)
                                      and public.hoje() + (7 - extract(isodow from public.hoje())::int)),
      'atendimentos_mes', (select count(*) from public.atendimentos a
                            where a.corrige_atendimento_id is null
                              and date_trunc('month', a.data) = date_trunc('month', public.hoje())))))
$$;

-- ------------------------------------------------------------------
-- Painel: ações
-- ------------------------------------------------------------------
create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params)
    when 'financeiro' then public.painel_financeiro(p_params)
    when 'estoque' then public.painel_estoque(p_params)
    else null
  end;
end
$$;

revoke execute on function
  public.rotulo_forma_pagamento(text, int),
  public.nome_do_mes(date),
  public.orcamento_resumo(uuid),
  public.orcamentos_do_paciente(uuid, boolean),
  public.documentos_do_paciente(uuid, int),
  public.financeiro_do_paciente(uuid),
  public.painel_financeiro(jsonb),
  public.estoque_situacao(numeric, numeric, boolean),
  public.estoque_alertas_painel(),
  public.painel_estoque(jsonb),
  public.estoque_rotulo_categoria(text)
  from public, anon, authenticated;
grant execute on function
  public.rotulo_forma_pagamento(text, int),
  public.nome_do_mes(date),
  public.orcamento_resumo(uuid),
  public.orcamentos_do_paciente(uuid, boolean),
  public.documentos_do_paciente(uuid, int),
  public.financeiro_do_paciente(uuid),
  public.painel_financeiro(jsonb),
  public.estoque_situacao(numeric, numeric, boolean),
  public.estoque_alertas_painel(),
  public.painel_estoque(jsonb),
  public.estoque_rotulo_categoria(text)
  to service_role;
