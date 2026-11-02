-- =====================================================================
-- Etapa 4b: financeiro, ferramentas ver_financeiro, marcar_recibos e
-- gerar_pacote_contador (dados do mês e registro do pacote).
-- =====================================================================

-- ---------------------------------------------------------------------
-- ver_financeiro
-- ---------------------------------------------------------------------
create or replace function public.mcp_ver_financeiro(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_visao text := coalesce(nullif(public.normalizar(p_dados ->> 'visao'), ''), 'mes');
  v_mes date;
  v_ini date;
  v_fim date;
  v_pac public.pacientes;
  v_res jsonb;
begin
  perform public.iniciar_solicitacao('ver_financeiro', p_dados, p_texto_original);
  v_mes := public.fin_mes(p_dados ->> 'mes');
  v_ini := v_mes;
  v_fim := (v_mes + interval '1 month')::date;

  if v_visao = 'mes' then
    return jsonb_build_object('status', 'ok', 'visao', 'mes') || public.financeiro_resumo_mes(v_mes);

  elsif v_visao = 'paciente' then
    begin
      select * into strict v_pac from public.pacientes where id = public.fin_uuid(p_dados ->> 'paciente_id', 'paciente_id');
    exception when no_data_found then
      raise exception 'Paciente não encontrado. Use buscar_paciente para obter o id.';
    end;
    return jsonb_build_object(
      'status', 'ok', 'visao', 'paciente',
      'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha,
                                     'cpf_informado', v_pac.cpf is not null),
      'responsaveis', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'nome', r.nome, 'parentesco', r.parentesco,
                                                                     'cpf_informado', r.cpf is not null, 'e_pagador', r.e_pagador))
                                  from public.responsaveis r where r.paciente_id = v_pac.id), '[]'::jsonb),
      'saldo', public.saldo_paciente(v_pac.id),
      'acordos', coalesce((select jsonb_agg(public.acordo_json(a.id) order by a.criado_em desc)
                             from public.acordos_pagamento a where a.paciente_id = v_pac.id), '[]'::jsonb),
      'pagamentos', coalesce((select jsonb_agg(public.recebimento_json(r) order by r.data_pagamento desc, r.numero desc)
                                from public.recebimentos r
                               where r.id in (select x.id from public.recebimentos x where x.paciente_id = v_pac.id
                                               order by x.data_pagamento desc, x.numero desc limit 30)), '[]'::jsonb),
      'custo_laboratorio', (select coalesce(sum(valor), 0) from public.despesas
                             where paciente_id = v_pac.id and categoria = 'laboratorio'));

  elsif v_visao = 'a_receber' then
    select coalesce(jsonb_agg(x.j || jsonb_build_object('paciente', x.pac) order by x.venc), '[]'::jsonb)
      into v_res
      from (select public.parcela_json(pp) j, pp.vencimento venc,
                   jsonb_strip_nulls(jsonb_build_object('id', p.id, 'nome', p.nome, 'telefone', p.telefone)) pac
              from public.parcelas_previstas pp
              join public.acordos_pagamento a on a.id = pp.acordo_id
              join public.pacientes p on p.id = a.paciente_id
             where a.cancelado_em is null and pp.cancelada_em is null
               and pp.valor - public.parcela_pago(pp.id) > 0) x;
    return jsonb_build_object(
      'status', 'ok', 'visao', 'a_receber',
      'total', (select coalesce(sum((j ->> 'restante')::numeric), 0) from jsonb_array_elements(v_res) j),
      'atrasado', (select coalesce(sum((j ->> 'restante')::numeric), 0) from jsonb_array_elements(v_res) j
                    where j ->> 'situacao' = 'atrasada'),
      'parcelas', v_res);

  elsif v_visao = 'inadimplentes' then
    select coalesce(jsonb_agg(x order by (x ->> 'atrasado')::numeric desc), '[]'::jsonb) into v_res
      from (select jsonb_strip_nulls(jsonb_build_object(
                     'paciente', jsonb_build_object('id', p.id, 'nome', p.nome, 'ficha', p.ficha),
                     'telefone', p.telefone,
                     'whatsapp', p.whatsapp,
                     'atrasado', sum(pp.valor - public.parcela_pago(pp.id)),
                     'parcelas_atrasadas', count(*),
                     'vencida_desde', min(pp.vencimento),
                     'dias_de_atraso', public.hoje() - min(pp.vencimento))) x
              from public.parcelas_previstas pp
              join public.acordos_pagamento a on a.id = pp.acordo_id
              join public.pacientes p on p.id = a.paciente_id
             where a.cancelado_em is null and pp.cancelada_em is null and pp.vencimento < public.hoje()
               and pp.valor - public.parcela_pago(pp.id) > 0
             group by p.id) s;
    return jsonb_build_object('status', 'ok', 'visao', 'inadimplentes',
      'total_atrasado', (select coalesce(sum((j ->> 'atrasado')::numeric), 0) from jsonb_array_elements(v_res) j),
      'pacientes', v_res);

  elsif v_visao = 'recibos' then
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'recebimento_id', r.id, 'numero', r.numero, 'data_pagamento', r.data_pagamento,
             'paciente', p.nome, 'pagador', r.pagador_nome, 'valor', r.valor_bruto,
             'situacao', public.recibo_situacao(r.id) ->> 'situacao',
             'codigo', public.recibo_situacao(r.id) ->> 'codigo',
             'falta', nullif(concat_ws(' e ', case when r.pagador_cpf is null then 'CPF do pagador' end,
                                              case when r.beneficiario_cpf is null then 'CPF do paciente' end), '')))
             order by r.data_pagamento, r.numero), '[]'::jsonb)
      into v_res
      from public.recebimentos r join public.pacientes p on p.id = r.paciente_id
     where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.estorna_id is null and r.regime_fiscal = 'pf'
       and public.recibo_situacao(r.id) ->> 'situacao' <> 'nao_se_aplica';
    return jsonb_build_object('status', 'ok', 'visao', 'recibos', 'mes', to_char(v_ini, 'YYYY-MM'),
      'pendentes', (select count(*) from jsonb_array_elements(v_res) j where j ->> 'situacao' = 'pendente'),
      'emitidos', (select count(*) from jsonb_array_elements(v_res) j where j ->> 'situacao' = 'emitido'),
      'a_cancelar', (select count(*) from jsonb_array_elements(v_res) j where j ->> 'situacao' = 'cancelar'),
      'recibos', v_res,
      'como_emitir', 'Gere o pacote do mês (gerar_pacote_contador) e importe o arquivo receita-saude no Carnê-Leão Web, ou emita um a um no app Receita Saúde. Depois, marcar_recibos.');

  elsif v_visao = 'despesas' then
    return jsonb_build_object('status', 'ok', 'visao', 'despesas', 'mes', to_char(v_ini, 'YYYY-MM'),
      'total', (select coalesce(sum(valor), 0) from public.despesas where data >= v_ini and data < v_fim),
      'despesas', coalesce((select jsonb_agg(public.despesa_json(d) order by d.data, d.numero)
                              from public.despesas d where d.data >= v_ini and d.data < v_fim), '[]'::jsonb),
      'fixas', coalesce((select jsonb_agg(public.despesa_fixa_json(r)
                                          || jsonb_build_object('lancada_no_mes', public.despesa_fixa_lancada(r.id, v_ini))
                                          order by r.dia)
                           from public.despesas_recorrentes r
                          where r.inicio < v_fim and (r.encerrada_em is null or r.encerrada_em >= v_ini)), '[]'::jsonb));

  elsif v_visao = 'configuracao' then
    return jsonb_build_object('status', 'ok', 'visao', 'configuracao', 'configuracao', public.fin_config_json());
  end if;

  raise exception 'Visão "%" desconhecida: use mes, paciente, a_receber, inadimplentes, recibos, despesas ou configuracao.',
    p_dados ->> 'visao';
end
$$;

-- ---------------------------------------------------------------------
-- marcar_recibos
-- ---------------------------------------------------------------------
create or replace function public.mcp_marcar_recibos(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_sit text := coalesce(nullif(public.normalizar(p_dados ->> 'situacao'), ''), 'emitido');
  v_data date := coalesce(public.ler_data(p_dados ->> 'data_emissao', 'Data de emissão'), public.hoje());
  v_obs text := nullif(btrim(p_dados ->> 'observacao'), '');
  v_alvos jsonb := '[]'::jsonb;
  v_item jsonb;
  v_r public.recebimentos;
  v_atual jsonb;
  v_codigo text;
  v_marcados jsonb := '[]'::jsonb;
  v_avisos text[] := '{}';
  v_mes date;
  v_lote jsonb;
  v_lote_em timestamptz;
begin
  perform public.iniciar_solicitacao('marcar_recibos', p_dados, p_texto_original);
  if v_sit not in ('emitido', 'cancelado') then
    raise exception 'Situação "%" inválida: use emitido ou cancelado.', p_dados ->> 'situacao';
  end if;
  if v_data > public.hoje() then
    raise exception 'A data de emissão está no futuro.';
  end if;

  if jsonb_typeof(p_dados -> 'itens') = 'array' and jsonb_array_length(p_dados -> 'itens') > 0 then
    v_alvos := p_dados -> 'itens';
  elsif jsonb_typeof(p_dados -> 'numeros') = 'array' and jsonb_array_length(p_dados -> 'numeros') > 0 then
    select jsonb_agg(jsonb_build_object('numero', n)) into v_alvos from jsonb_array_elements(p_dados -> 'numeros') n;
  elsif coalesce((p_dados ->> 'todos_pendentes')::boolean, false) then
    if v_sit <> 'emitido' then
      raise exception 'todos_pendentes só vale para marcar como emitido.';
    end if;
    v_mes := public.fin_mes(p_dados ->> 'mes');
    -- Com pacote gerado, marca só o que foi no último arquivo do mês.
    select pc.resumo -> 'lote_receita_saude', pc.gerado_em into v_lote, v_lote_em
      from public.pacotes_contador pc where pc.competencia = v_mes order by pc.gerado_em desc limit 1;
    if jsonb_typeof(v_lote) <> 'array' then v_lote := null; end if;
    select coalesce(jsonb_agg(jsonb_build_object('recebimento_id', r.id) order by r.numero), '[]'::jsonb) into v_alvos
      from public.recebimentos r
     where r.data_pagamento >= v_mes and r.data_pagamento < (v_mes + interval '1 month')::date
       and r.estorna_id is null and r.regime_fiscal = 'pf'
       and r.pagador_cpf is not null and r.beneficiario_cpf is not null
       and public.recibo_situacao(r.id) ->> 'situacao' = 'pendente'
       and (v_lote is null or v_lote ? r.id::text);
    if v_lote is not null then
      v_avisos := array_append(v_avisos, format('Marcados os recibos que foram no arquivo do pacote gerado em %s.',
        to_char(v_lote_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI')));
    end if;
    if jsonb_array_length(v_alvos) = 0 then
      return jsonb_build_object('status', 'sem_mudanca', 'mensagem',
        format('Nenhum recibo pendente (com os CPFs completos) em %s.', to_char(v_mes, 'MM/YYYY')));
    end if;
  else
    raise exception 'Diga quais pagamentos (numeros ou itens) ou o mês do lote (mes e todos_pendentes = true).';
  end if;

  for v_item in select * from jsonb_array_elements(v_alvos) loop
    select * into v_r from public.recebimentos
     where id = public.fin_uuid(v_item ->> 'recebimento_id', 'recebimento_id')
        or numero = public.fin_inteiro(v_item ->> 'numero', 'Número do pagamento')
     limit 1;
    if not found then
      raise exception 'Pagamento % não encontrado.', coalesce('nº ' || (v_item ->> 'numero'), v_item ->> 'recebimento_id');
    end if;
    if v_r.estorna_id is not null then
      raise exception 'O lançamento nº % é um estorno: não tem recibo.', v_r.numero;
    end if;
    if v_r.regime_fiscal = 'pj' then
      raise exception 'O pagamento nº % é da fase PJ: a nota fiscal é emitida pelo contador.', v_r.numero;
    end if;
    v_atual := public.recibo_situacao(v_r.id);
    v_codigo := coalesce(nullif(btrim(v_item ->> 'codigo'), ''), case when v_sit = 'cancelado' then v_atual ->> 'codigo' end);
    if v_sit = 'emitido' and v_atual ->> 'situacao' in ('emitido', 'cancelar') then
      v_avisos := array_append(v_avisos, format('O recibo do pagamento nº %s já estava emitido.', v_r.numero));
      continue;
    end if;
    if v_sit = 'emitido' and v_atual ->> 'situacao' = 'nao_se_aplica' then
      v_avisos := array_append(v_avisos, format('O pagamento nº %s foi estornado: não precisa de recibo.', v_r.numero));
      continue;
    end if;
    if v_sit = 'cancelado' and v_atual ->> 'situacao' not in ('emitido', 'cancelar') then
      v_avisos := array_append(v_avisos, format('O pagamento nº %s não tem recibo emitido para cancelar.', v_r.numero));
      continue;
    end if;
    insert into public.recibos_receita_saude (recebimento_id, situacao, codigo, data_emissao, observacao,
                                               solicitacao_id, registrado_em)
    values (v_r.id, v_sit, v_codigo, v_data, v_obs, public.fin_solicitacao(), clock_timestamp());
    if v_sit = 'cancelado' and v_atual ->> 'situacao' = 'emitido' then
      v_avisos := array_append(v_avisos, format('O pagamento nº %s continua valendo: o recibo volta para pendente (emita um novo com os dados certos).', v_r.numero));
    end if;
    v_marcados := v_marcados || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'numero', v_r.numero, 'data_pagamento', v_r.data_pagamento, 'pagador', v_r.pagador_nome,
      'valor', v_r.valor_bruto, 'situacao', v_sit, 'codigo', v_codigo)));
  end loop;

  return jsonb_build_object(
    'status', case when jsonb_array_length(v_marcados) = 0 then 'sem_mudanca' else 'ok' end,
    'marcados', v_marcados,
    'quantidade', jsonb_array_length(v_marcados),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- gerar_pacote_contador: dados do mês (o servidor monta os CSVs) e registro
-- ---------------------------------------------------------------------
create or replace function public.fin_descricao_recibo(r public.recebimentos)
returns text
language sql
stable
set search_path = ''
as $$
  select left(concat_ws(' - ',
                coalesce(nullif(btrim(r.descricao), ''), 'Tratamento odontologico'),
                (select format('parcela %s/%s', pp.numero, pp.total) from public.parcelas_previstas pp
                  where pp.id = r.parcela_id and pp.total > 1),
                (select 'atendimento em ' || to_char(a.data, 'DD/MM/YYYY') from public.atendimentos a
                  where a.id = r.atendimento_id and a.data <> r.data_pagamento)), 255)
$$;

create or replace function public.mcp_pacote_contador(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_mes date;
  v_fim date;
  v_cfg public.configuracao_financeira;
  v_clin public.configuracao;
  v_rs jsonb;
  v_rec jsonb;
  v_desp jsonb;
  v_problemas text[] := '{}';
  v_x record;
begin
  perform public.iniciar_solicitacao('gerar_pacote_contador', p_dados, p_texto_original);
  v_mes := case when nullif(btrim(p_dados ->> 'mes'), '') is null
                then (date_trunc('month', public.hoje()) - interval '1 month')::date
                else public.fin_mes(p_dados ->> 'mes') end;
  v_fim := (v_mes + interval '1 month')::date;
  if v_mes > date_trunc('month', public.hoje())::date then
    raise exception 'O mês % ainda não começou.', to_char(v_mes, 'MM/YYYY');
  end if;
  select * into v_cfg from public.configuracao_financeira;
  select * into v_clin from public.configuracao;

  -- Linhas do lote do Receita Saúde: pessoa física, pendentes, com os dois CPFs.
  select coalesce(jsonb_agg(jsonb_build_object(
           'recebimento_id', r.id, 'numero', r.numero, 'data_pagamento', r.data_pagamento, 'valor', r.valor_bruto,
           'descricao', public.fin_descricao_recibo(r), 'cpf_pagador', r.pagador_cpf,
           'cpf_beneficiario', r.beneficiario_cpf) order by r.data_pagamento, r.numero), '[]'::jsonb)
    into v_rs
    from public.recebimentos r
   where r.data_pagamento >= v_mes and r.data_pagamento < v_fim and r.estorna_id is null and r.regime_fiscal = 'pf'
     and r.pagador_cpf is not null and r.beneficiario_cpf is not null
     and public.recibo_situacao(r.id) ->> 'situacao' = 'pendente';

  -- Todos os pagamentos do mês (com estornos), no layout completo.
  select coalesce(jsonb_agg(jsonb_build_object(
           'numero', r.numero,
           'data_pagamento', r.data_pagamento,
           'data_atendimento', (select a.data from public.atendimentos a where a.id = r.atendimento_id),
           'paciente', p.nome,
           'paciente_cpf', coalesce(r.beneficiario_cpf, p.cpf),
           'pagador', r.pagador_nome,
           'pagador_cpf', r.pagador_cpf,
           'descricao', r.descricao,
           'forma', r.forma,
           'parcela', (select format('%s/%s', pp.numero, pp.total) from public.parcelas_previstas pp where pp.id = r.parcela_id),
           'parcelas_cartao', r.parcelas_cartao,
           'valor_bruto', r.valor_bruto,
           'taxa', r.taxa_valor,
           'valor_liquido', r.valor_liquido,
           'data_credito_prevista', r.data_credito_prevista,
           'regime', r.regime_fiscal,
           'recibo', public.recibo_situacao(r.id) ->> 'situacao',
           'recibo_codigo', public.recibo_situacao(r.id) ->> 'codigo',
           'estorno_de', (select o.numero from public.recebimentos o where o.id = r.estorna_id),
           'motivo_estorno', r.motivo_estorno) order by r.data_pagamento, r.numero), '[]'::jsonb)
    into v_rec
    from public.recebimentos r join public.pacientes p on p.id = r.paciente_id
   where r.data_pagamento >= v_mes and r.data_pagamento < v_fim;

  select coalesce(jsonb_agg(jsonb_build_object(
           'numero', d.numero,
           'data', d.data,
           'competencia', to_char(d.competencia, 'YYYY-MM'),
           'categoria', d.categoria,
           'descricao', d.descricao,
           'fornecedor', d.fornecedor,
           'fornecedor_documento', d.fornecedor_documento,
           'valor', d.valor,
           'forma', d.forma,
           'paciente', (select p.nome from public.pacientes p where p.id = d.paciente_id),
           'comprovante', d.comprovante,
           'origem', d.origem,
           'estorno_de', (select o.numero from public.despesas o where o.id = d.estorna_id),
           'motivo_estorno', d.motivo_estorno) order by d.data, d.numero), '[]'::jsonb)
    into v_desp
    from public.despesas d
   where d.data >= v_mes and d.data < v_fim;

  if v_cfg.cpf_profissional is null and jsonb_array_length(v_rs) > 0 then
    v_problemas := array_append(v_problemas, 'Falta o CPF da Dra. (configurar_financeiro): sem ele o arquivo do Receita Saúde não é aceito.');
  end if;
  for v_x in
    select r.numero, r.pagador_nome, r.valor_bruto, r.pagador_cpf, r.beneficiario_cpf
      from public.recebimentos r
     where r.data_pagamento >= v_mes and r.data_pagamento < v_fim and r.estorna_id is null and r.regime_fiscal = 'pf'
       and (r.pagador_cpf is null or r.beneficiario_cpf is null)
       and public.recibo_situacao(r.id) ->> 'situacao' = 'pendente'
     order by r.numero
  loop
    v_problemas := array_append(v_problemas, format('Pagamento nº %s (%s, %s) ficou fora do lote: falta %s.',
      v_x.numero, v_x.pagador_nome, public.fin_reais(v_x.valor_bruto),
      concat_ws(' e ', case when v_x.pagador_cpf is null then 'o CPF do pagador' end,
                       case when v_x.beneficiario_cpf is null then 'o CPF do paciente' end)));
  end loop;
  for v_x in
    select r.numero from public.recebimentos r
     where r.data_pagamento >= v_mes and r.data_pagamento < v_fim and r.estorna_id is null
       and public.recibo_situacao(r.id) ->> 'situacao' = 'cancelar'
  loop
    v_problemas := array_append(v_problemas, format('O recibo do pagamento nº %s foi emitido, mas o pagamento foi estornado: cancele no Receita Saúde.', v_x.numero));
  end loop;
  if exists (select 1 from public.recebimentos r where r.data_pagamento >= v_mes and r.data_pagamento < v_fim
                                                    and r.regime_fiscal = 'pj') then
    v_problemas := array_append(v_problemas, 'Há pagamentos da fase PJ no mês: não entram no Receita Saúde; o contador emite as NFS-e.');
  end if;
  if exists (select 1 from public.despesas d where d.data >= v_mes and d.data < v_fim and d.estorna_id is null
                                                and d.comprovante is null) then
    v_problemas := array_append(v_problemas, format('%s despesa(s) sem comprovante anotado.',
      (select count(*) from public.despesas d where d.data >= v_mes and d.data < v_fim and d.estorna_id is null
                                              and d.comprovante is null)));
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'mes', to_char(v_mes, 'YYYY-MM'),
    'profissional', jsonb_strip_nulls(jsonb_build_object(
      'nome', v_clin.dentista_nome, 'cro', v_clin.cro, 'cpf', v_cfg.cpf_profissional,
      'registro', v_cfg.registro_profissional, 'codigo_ocupacao', v_cfg.codigo_ocupacao)),
    'receita_saude', v_rs,
    'recebimentos', v_rec,
    'despesas', v_desp,
    'resumo', public.financeiro_resumo_mes(v_mes),
    'problemas', to_jsonb(v_problemas));
end
$$;

create or replace function public.mcp_registrar_pacote_contador(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_mes date := public.fin_mes(p_dados ->> 'mes');
  v_id uuid;
begin
  perform public.iniciar_solicitacao('gerar_pacote_contador', p_dados - 'resumo', p_texto_original);
  if jsonb_typeof(p_dados -> 'arquivos') <> 'array' then
    raise exception 'Pacote sem a lista de arquivos.';
  end if;
  insert into public.pacotes_contador (competencia, arquivos, resumo, solicitacao_id, gerado_em)
  values (v_mes, p_dados -> 'arquivos', coalesce(p_dados -> 'resumo', '{}'::jsonb), public.fin_solicitacao(),
          clock_timestamp())
  returning id into v_id;
  return jsonb_build_object('status', 'ok', 'pacote_id', v_id, 'mes', to_char(v_mes, 'YYYY-MM'));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.mcp_ver_financeiro(jsonb, text),
  public.mcp_marcar_recibos(jsonb, text),
  public.fin_descricao_recibo(public.recebimentos),
  public.mcp_pacote_contador(jsonb, text),
  public.mcp_registrar_pacote_contador(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.mcp_ver_financeiro(jsonb, text),
  public.mcp_marcar_recibos(jsonb, text),
  public.fin_descricao_recibo(public.recebimentos),
  public.mcp_pacote_contador(jsonb, text),
  public.mcp_registrar_pacote_contador(jsonb, text)
  to service_role;
