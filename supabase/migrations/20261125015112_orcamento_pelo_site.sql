-- =====================================================================
-- Site do consultório: novo orçamento pelo site.
--
-- O site monta o orçamento pela MESMA função do conector
-- (mcp_montar_orcamento): mesmos preços (catálogo e campanha), mesmo número
-- e versão, mesma auditoria, nada se apaga. A solicitação fica marcada como
-- vinda do site. O PDF sai no visual do gerador que a Dra. já usava no site
-- público: o navegador desenha, a API guarda no Storage e registra pela
-- mesma mcp_registrar_documento (que agora anota gerado_por = 'site').
-- =====================================================================

-- O que o formulário precisa: catálogo com preço e fase, campanhas com os
-- preços delas, validade padrão, cabeçalho do PDF e, com paciente, o
-- orçamento em aberto dele (para escolher entre versão nova ou à parte).
create or replace function public.painel_orcamento_novo(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
  v_pac public.pacientes;
  v_aberto jsonb;
begin
  if nullif(p_params ->> 'paciente_id', '') is not null then
    begin
      v_id := (p_params ->> 'paciente_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Paciente inválido.';
    end;
    select * into v_pac from public.pacientes where id = v_id;
    if not found then
      raise exception 'Paciente não encontrado.';
    end if;
    select jsonb_strip_nulls(jsonb_build_object(
             'id', o.id, 'numero', o.numero, 'versao', o.versao, 'status', o.status,
             'status_texto', public.orcamento_status_texto(o.status),
             'emitido_em', (o.criado_em at time zone public.fuso())::date,
             'campanha_id', c.id, 'campanha', c.nome))
      into v_aberto
      from public.orcamentos o
      left join public.campanhas c on c.id = o.campanha_id and c.cancelada_em is null
     where o.paciente_id = v_pac.id and o.status in ('rascunho', 'apresentado')
     order by o.criado_em desc
     limit 1;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'hoje', public.hoje(),
    'validade_dias', (select d.orcamento_validade_dias from public.documentos_config d limit 1),
    'cabecalho', public.documentos_cabecalho(),
    'procedimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'codigo', p.codigo,
               'nome', p.nome,
               'grupo', p.grupo,
               'preco', p.preco,
               'aplica_a', p.aplica_a,
               'fase', public.orcamento_fase_padrao(p.codigo, p.categoria)))
             order by p.ordem, p.nome), '[]'::jsonb)
        from public.procedimentos p
       where p.ativo),
    'campanhas', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', c.id,
               'nome', c.nome,
               'inicio', c.inicio,
               'fim', c.fim,
               'periodo', public.campanha_periodo(c),
               'hoje', case when public.hoje() between c.inicio and c.fim then true end,
               'precos', (select jsonb_object_agg(p.codigo, cp.preco)
                            from public.campanha_precos cp
                            join public.procedimentos p on p.id = cp.procedimento_id
                           where cp.campanha_id = c.id and cp.preco is not null and p.ativo)))
             order by c.inicio), '[]'::jsonb)
        from public.campanhas c
       where c.cancelada_em is null and c.fim >= public.hoje() - 30),
    'paciente', case when v_pac.id is not null then
      jsonb_strip_nulls(jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'aberto', v_aberto)) end));
end
$$;

-- Caminho do PDF de um orçamento no bucket "documentos" (o mesmo formato do conector).
create or replace function public.painel_orcamento_caminho(p_orcamento uuid)
returns text
language sql
volatile
set search_path = ''
as $$
  select public.documentos_caminho(o.paciente_id, 'orcamento', o.numero, case when o.versao > 1 then o.versao end)
    from public.orcamentos o
   where o.id = p_orcamento
$$;

-- O registro do PDF sabe se ele saiu do site (visual do gerador antigo) ou do conector.
create or replace function public.mcp_registrar_documento(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tipo text := p_dados ->> 'tipo';
  v_ref uuid;
  v_pac uuid;
  v_sol uuid;
  v_id uuid;
begin
  begin
    v_ref := (p_dados ->> 'referencia_id')::uuid;
    v_sol := nullif(p_dados ->> 'solicitacao_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Identificador inválido no registro do documento.';
  end;
  if v_sol is not null and exists (select 1 from public.solicitacoes where id = v_sol) then
    perform set_config('app.solicitacao_id', v_sol::text, true);
  else
    v_sol := public.iniciar_solicitacao('registrar_documento', p_dados, null);
  end if;
  v_pac := case v_tipo
    when 'orcamento' then (select paciente_id from public.orcamentos where id = v_ref)
    when 'receita' then (select paciente_id from public.receitas where id = v_ref)
    when 'atestado' then (select paciente_id from public.atestados where id = v_ref)
    when 'termo' then (select paciente_id from public.termos_emitidos where id = v_ref and tipo = 'consentimento')
    when 'orientacoes' then (select paciente_id from public.termos_emitidos where id = v_ref and tipo = 'orientacoes')
  end;
  if v_pac is null then
    raise exception 'Documento de origem não encontrado (% %).', v_tipo, v_ref;
  end if;
  if left(p_dados ->> 'caminho', 37) <> v_pac::text || '/' then
    raise exception 'O caminho do arquivo não é da pasta do paciente.';
  end if;
  insert into public.documentos (paciente_id, tipo, referencia_id, titulo, caminho, tamanho_bytes, sha256,
                                 solicitacao_id, gerado_por)
  values (v_pac, v_tipo, v_ref, coalesce(nullif(btrim(p_dados ->> 'titulo'), ''), v_tipo), p_dados ->> 'caminho',
          (p_dados ->> 'tamanho_bytes')::int, lower(p_dados ->> 'sha256'), v_sol,
          case when current_setting('app.cliente', true) = 'site' then 'site' else 'mcp' end)
  returning id into v_id;
  return jsonb_build_object('status', 'ok', 'documento_id', v_id);
end
$$;

-- O site grava orçamentos pela mesma regra (painel_gravar, tipos "orcamento" e "orcamento_pdf").
create or replace function public.painel_gravar(p_usuario uuid, p_sessao uuid, p_acao text, p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_texto text := left(coalesce(nullif(btrim(p_dados ->> 'texto_original'), ''), 'Lançado pelo site'), 500);
  v_mov jsonb;
  v_orc public.orcamentos;
  v_orc_id uuid;
begin
  if p_acao not in ('pagamento', 'estornar_pagamento', 'despesa', 'estornar_despesa', 'estoque', 'anexo',
                    'retirar_anexo', 'orcamento', 'orcamento_pdf') then
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
  elsif p_acao = 'anexo' then
    return public.mcp_registrar_anexo(
      jsonb_build_object('acao', 'registrar') || public.painel_campos(p_dados, array[
        'anexo_id', 'paciente_id', 'tipo', 'titulo', 'data_documento', 'observacao', 'caminho', 'nome_arquivo',
        'tipo_arquivo', 'tamanho_bytes']),
      v_texto);
  elsif p_acao = 'retirar_anexo' then
    return public.mcp_registrar_anexo(
      jsonb_build_object('acao', 'retirar') || public.painel_campos(p_dados, array['anexo_id', 'motivo']),
      v_texto);
  elsif p_acao = 'orcamento' then
    -- No site, o orçamento tem só o que ela pôs no formulário (o plano do
    -- odontograma entra só se o site pedir).
    return public.mcp_montar_orcamento(
      jsonb_build_object('incluir_odontograma', false) || public.painel_campos(p_dados, array[
        'paciente_id', 'itens', 'incluir_odontograma', 'valores', 'validade_dias', 'desconto_percentual',
        'desconto_valor', 'pagamento', 'titulo', 'observacoes', 'apresentar', 'separado', 'campanha']),
      v_texto);
  elsif p_acao = 'orcamento_pdf' then
    -- PDF que o navegador desenhou e a API já guardou no Storage.
    begin
      v_orc_id := (p_dados ->> 'orcamento_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Orçamento inválido.';
    end;
    select * into v_orc from public.orcamentos where id = v_orc_id;
    if not found then
      raise exception 'Orçamento não encontrado.';
    end if;
    if coalesce(p_dados ->> 'caminho', '') !~ ('^' || v_orc.paciente_id::text || '/orcamento-' || v_orc.numero ||
         case when v_orc.versao > 1 then '-v' || v_orc.versao else '' end ||
         '-[0-9]{8}-[0-9]{6}-[0-9a-f]{4}[.]pdf$') then
      raise exception 'Arquivo do orçamento inválido.';
    end if;
    return public.mcp_registrar_documento(jsonb_build_object(
      'tipo', 'orcamento',
      'referencia_id', v_orc.id,
      'caminho', p_dados ->> 'caminho',
      'titulo', 'Orçamento nº ' || v_orc.numero || case when v_orc.versao > 1 then ' v' || v_orc.versao else '' end,
      'tamanho_bytes', p_dados -> 'tamanho_bytes',
      'sha256', p_dados ->> 'sha256',
      'solicitacao_id', v_orc.solicitacao_id));
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

create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio() || public.painel_inicio_extra() || public.painel_inicio_afazer()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params) || public.painel_paciente_anexos(p_params)
    when 'financeiro' then public.painel_financeiro(p_params) || public.painel_financeiro_extra(p_params)
    when 'estoque' then public.painel_estoque(p_params) || public.painel_estoque_extra(p_params)
                        || public.painel_estoque_materiais()
    when 'orcamentos' then public.painel_orcamentos(p_params)
    when 'orcamento_novo' then public.painel_orcamento_novo(p_params)
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_configuracoes()
    else null
  end;
end
$$;

revoke execute on function
  public.painel_orcamento_novo(jsonb), public.painel_orcamento_caminho(uuid), public.mcp_registrar_documento(jsonb),
  public.painel_gravar(uuid, uuid, text, jsonb), public.painel(text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.painel_orcamento_novo(jsonb), public.painel_orcamento_caminho(uuid), public.mcp_registrar_documento(jsonb),
  public.painel_gravar(uuid, uuid, text, jsonb), public.painel(text, jsonb)
  to service_role;
