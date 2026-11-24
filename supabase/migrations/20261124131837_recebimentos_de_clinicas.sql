-- =====================================================================
-- Recebimentos de clínicas.
--
-- A Dra. também atende em clínicas de outros dentistas (Tanaka, semanal;
-- Giusti, mensal), que pagam a ela direto. Esses pagamentos entram em
-- recebimentos sem paciente, com o nome da clínica em "clinica":
--   - não têm recibo do Receita Saúde (quem paga é pessoa jurídica);
--   - entram no total do mês, separados em de_pacientes e de_clinicas;
--   - vão no pacote do contador (coluna Pagador = clínica).
-- Pelo conector: registrar_pagamento sem paciente_id e com pagador.nome =
-- nome da clínica (ou "clinica"). Nome parecido com um já usado ("Clínica
-- Tanaka" e "Tanaka") fica com o nome já usado.
-- =====================================================================

alter table public.recebimentos alter column paciente_id drop not null;
alter table public.recebimentos add column clinica text
  check (clinica is null or length(btrim(clinica)) >= 3);
alter table public.recebimentos add constraint recebimentos_paciente_ou_clinica
  check ((paciente_id is null) <> (clinica is null));
comment on column public.recebimentos.clinica is
  'Clínica que pagou (pagamento pelo trabalho da Dra. em outra clínica). Preenchido só quando não há paciente.';
create index recebimentos_clinica_idx on public.recebimentos (clinica, data_pagamento) where clinica is not null;

create or replace function public.recibo_situacao(p_recebimento uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  r public.recebimentos;
  e public.recibos_receita_saude;
  v_estornado boolean;
begin
  select * into r from public.recebimentos where id = p_recebimento;
  if not found then return null; end if;
  if r.estorna_id is not null then
    return jsonb_build_object('situacao', 'nao_se_aplica');
  end if;
  if r.regime_fiscal = 'pj' then
    return jsonb_build_object('situacao', 'nfse_contador');
  end if;
  if r.paciente_id is null then
    -- Pagamento de clínica (pessoa jurídica): não tem recibo do Receita Saúde.
    return jsonb_build_object('situacao', 'nao_se_aplica', 'motivo', 'pagamento de clínica');
  end if;
  v_estornado := exists (select 1 from public.recebimentos x where x.estorna_id = r.id);
  select * into e from public.recibos_receita_saude
   where recebimento_id = r.id order by registrado_em desc limit 1;
  if e.id is null then
    return jsonb_build_object('situacao', case when v_estornado then 'nao_se_aplica' else 'pendente' end);
  end if;
  if e.situacao = 'emitido' then
    return jsonb_strip_nulls(jsonb_build_object(
      'situacao', case when v_estornado then 'cancelar' else 'emitido' end,
      'codigo', e.codigo, 'data_emissao', e.data_emissao));
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'situacao', case when v_estornado then 'cancelado' else 'pendente' end,
    'codigo_cancelado', e.codigo));
end
$$;

create or replace function public.recebimento_json(r public.recebimentos)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', r.id,
    'numero', r.numero,
    'data_pagamento', r.data_pagamento,
    'paciente', (select jsonb_build_object('id', p.id, 'nome', p.nome) from public.pacientes p where p.id = r.paciente_id),
    'clinica', r.clinica,
    'pagador', jsonb_build_object('nome', r.pagador_nome, 'cpf', r.pagador_cpf, 'e_o_paciente', r.pagador_e_paciente),
    'valor_bruto', r.valor_bruto,
    'forma', r.forma,
    'parcelas_cartao', case when r.parcelas_cartao > 1 then r.parcelas_cartao end,
    'taxa_percentual', r.taxa_percentual,
    'taxa', r.taxa_valor,
    'valor_liquido', r.valor_liquido,
    'data_credito_prevista', r.data_credito_prevista,
    'descricao', r.descricao,
    'parcela', (select format('%s/%s do acordo nº %s', pp.numero, pp.total, a.numero)
                  from public.parcelas_previstas pp join public.acordos_pagamento a on a.id = pp.acordo_id
                 where pp.id = r.parcela_id),
    'atendimento_id', r.atendimento_id,
    'orcamento_id', r.orcamento_id,
    'regime_fiscal', r.regime_fiscal,
    'estorno_de', (select o.numero from public.recebimentos o where o.id = r.estorna_id),
    'motivo_estorno', r.motivo_estorno,
    'estornado_por', (select e.numero from public.recebimentos e where e.estorna_id = r.id limit 1),
    'recibo', public.recibo_situacao(r.id)))
$$;

create or replace function public.fin_totais_mes(p_mes date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with rec as (
    select coalesce(sum(valor_bruto), 0) bruto, coalesce(sum(taxa_valor), 0) taxas,
           coalesce(sum(valor_liquido), 0) liquido,
           coalesce(sum(valor_bruto) filter (where paciente_id is not null), 0) de_pacientes,
           coalesce(sum(valor_bruto) filter (where paciente_id is null), 0) de_clinicas
      from public.recebimentos
     where data_pagamento >= p_mes and data_pagamento < (p_mes + interval '1 month')::date),
  desp as (
    select coalesce(sum(valor), 0) total from public.despesas
     where data >= p_mes and data < (p_mes + interval '1 month')::date)
  select jsonb_build_object('mes', to_char(p_mes, 'YYYY-MM'), 'recebido_bruto', rec.bruto, 'taxas', rec.taxas,
                            'recebido_liquido', rec.liquido, 'recebido_de_pacientes', rec.de_pacientes,
                            'recebido_de_clinicas', rec.de_clinicas, 'despesas', desp.total,
                            'resultado', rec.liquido - desp.total)
    from rec, desp
$$;

create or replace function public.financeiro_resumo_mes(p_mes date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ini date := date_trunc('month', p_mes)::date;
  v_fim date := (date_trunc('month', p_mes) + interval '1 month')::date;
  v_cfg public.configuracao_financeira;
  v_tot jsonb;
  v_formas jsonb;
  v_clinicas jsonb;
  v_qtd int;
  v_areceber jsonb;
  v_cats jsonb;
  v_fixas jsonb;
  v_fixas_valor numeric;
  v_rec_pend int;
  v_rec_pend_valor numeric;
  v_rec_cancelar int;
  v_horas numeric;
  v_sem_hora int;
  v_atend int;
  v_custos_fixos numeric;
  v_avisos text[] := '{}';
begin
  select * into v_cfg from public.configuracao_financeira;
  v_tot := public.fin_totais_mes(v_ini);

  select count(*) into v_qtd from public.recebimentos r
   where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.estorna_id is null
     and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id);

  select coalesce(jsonb_agg(jsonb_build_object('forma', forma, 'bruto', b, 'taxas', t, 'liquido', l) order by b desc), '[]'::jsonb)
    into v_formas
    from (select forma, sum(valor_bruto) b, sum(taxa_valor) t, sum(valor_liquido) l
            from public.recebimentos
           where data_pagamento >= v_ini and data_pagamento < v_fim
           group by forma having sum(valor_bruto) <> 0) x;

  select coalesce(jsonb_agg(jsonb_build_object('clinica', clinica, 'total', b, 'pagamentos', n) order by b desc), '[]'::jsonb)
    into v_clinicas
    from (select r.clinica, sum(r.valor_bruto) b,
                 count(*) filter (where r.estorna_id is null
                                    and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id)) n
            from public.recebimentos r
           where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.paciente_id is null
           group by r.clinica having sum(r.valor_bruto) <> 0) x;

  with abertas as (
    select pp.vencimento, greatest(pp.valor - public.parcela_pago(pp.id), 0) restante
      from public.parcelas_previstas pp join public.acordos_pagamento a on a.id = pp.acordo_id
     where a.cancelado_em is null and pp.cancelada_em is null)
  select jsonb_build_object(
           'vence_no_mes', coalesce(sum(restante) filter (where vencimento >= v_ini and vencimento < v_fim), 0),
           'atrasado_hoje', coalesce(sum(restante) filter (where vencimento < public.hoje()), 0),
           'proximos_30_dias', coalesce(sum(restante) filter (where vencimento >= public.hoje()
                                                                and vencimento < public.hoje() + 30), 0),
           'total_em_aberto', coalesce(sum(restante), 0))
    into v_areceber
    from abertas where restante > 0;

  select coalesce(jsonb_agg(jsonb_build_object('categoria', categoria, 'total', s) order by s desc), '[]'::jsonb)
    into v_cats
    from (select categoria, sum(valor) s from public.despesas
           where data >= v_ini and data < v_fim group by categoria having sum(valor) <> 0) x;

  select coalesce(jsonb_agg(public.despesa_fixa_json(r) order by r.dia), '[]'::jsonb), coalesce(sum(r.valor), 0)
    into v_fixas, v_fixas_valor
    from public.despesas_recorrentes r
   where r.inicio < v_fim and (r.encerrada_em is null or r.encerrada_em >= v_ini)
     and not public.despesa_fixa_lancada(r.id, v_ini);

  select count(*) filter (where s = 'pendente'), coalesce(sum(valor_bruto) filter (where s = 'pendente'), 0),
         count(*) filter (where s = 'cancelar')
    into v_rec_pend, v_rec_pend_valor, v_rec_cancelar
    from (select r.valor_bruto, public.recibo_situacao(r.id) ->> 'situacao' s
            from public.recebimentos r
           where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.estorna_id is null
             and r.regime_fiscal = 'pf') x;

  -- Hora clínica: custos fixos ÷ horas atendidas (versão mais recente de cada atendimento).
  select coalesce(sum(extract(epoch from (a.hora_fim - a.hora_inicio)) / 3600.0)
                    filter (where a.hora_inicio is not null and a.hora_fim is not null), 0),
         count(*) filter (where a.hora_inicio is null or a.hora_fim is null),
         count(*)
    into v_horas, v_sem_hora, v_atend
    from public.atendimentos a
   where a.data >= v_ini and a.data < v_fim
     and not exists (select 1 from public.atendimentos c where c.corrige_atendimento_id = a.id);
  select coalesce(sum(valor), 0) into v_custos_fixos from public.despesas
   where data >= v_ini and data < v_fim and categoria not in ('materiais', 'laboratorio', 'impostos', 'iss');

  if v_cfg.cpf_profissional is null then
    v_avisos := array_append(v_avisos, 'CPF da Dra. não configurado: o lote do Receita Saúde precisa dele (configurar_financeiro).');
  end if;
  if v_rec_pend > 0 then
    v_avisos := array_append(v_avisos, format('%s recibo(s) do Receita Saúde pendente(s) no mês, somando %s.',
                                              v_rec_pend, public.fin_reais(v_rec_pend_valor)));
  end if;
  if v_rec_cancelar > 0 then
    v_avisos := array_append(v_avisos, format('%s recibo(s) emitido(s) de pagamento estornado: cancele no Receita Saúde.', v_rec_cancelar));
  end if;
  if jsonb_array_length(v_fixas) > 0 and v_ini <= public.hoje() then
    v_avisos := array_append(v_avisos, format('%s despesa(s) fixa(s) ainda não lançada(s) no mês (%s): registrar_despesa com acao lancar_fixas.',
                                              jsonb_array_length(v_fixas), public.fin_reais(v_fixas_valor)));
  end if;
  if v_sem_hora > 0 then
    v_avisos := array_append(v_avisos, format('%s atendimento(s) sem horário de início e fim ficaram fora da hora clínica.', v_sem_hora));
  end if;
  if v_cfg.regime = 'pf' and v_cfg.pj_a_partir_de is not null then
    if v_cfg.pj_a_partir_de > v_ini and v_cfg.pj_a_partir_de < v_fim then
      v_avisos := array_append(v_avisos, format('Mês da virada: pagamentos até %s entram como pessoa física (Receita Saúde); a partir de %s, pessoa jurídica (NFS-e pelo contador).',
                                                to_char(v_cfg.pj_a_partir_de - 1, 'DD/MM/YYYY'), to_char(v_cfg.pj_a_partir_de, 'DD/MM/YYYY')));
    elsif v_cfg.pj_a_partir_de between public.hoje() and public.hoje() + 45 then
      v_avisos := array_append(v_avisos, format('A partir de %s os pagamentos passam a ser da pessoa jurídica (NFS-e emitida pelo contador). Até lá, Receita Saúde.',
                                                to_char(v_cfg.pj_a_partir_de, 'DD/MM/YYYY')));
    end if;
  end if;

  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'regime', case when public.regime_fiscal(v_ini) = public.regime_fiscal(v_fim - 1) then public.regime_fiscal(v_ini)
                   else 'pf_e_pj' end,
    'recebido', jsonb_build_object('bruto', v_tot -> 'recebido_bruto', 'taxas', v_tot -> 'taxas',
                                   'liquido', v_tot -> 'recebido_liquido', 'pagamentos', v_qtd, 'por_forma', v_formas,
                                   'de_pacientes', v_tot -> 'recebido_de_pacientes',
                                   'de_clinicas', v_tot -> 'recebido_de_clinicas', 'por_clinica', v_clinicas),
    'a_receber', coalesce(v_areceber, '{}'::jsonb),
    'despesas', jsonb_build_object('total', v_tot -> 'despesas', 'por_categoria', v_cats,
                                   'fixas_nao_lancadas', v_fixas),
    'resultado', v_tot -> 'resultado',
    'mes_anterior', public.fin_totais_mes((v_ini - interval '1 month')::date),
    'recibos_receita_saude', jsonb_build_object('pendentes', v_rec_pend, 'valor_pendente', v_rec_pend_valor,
                                                'a_cancelar', v_rec_cancelar),
    'hora_clinica', jsonb_strip_nulls(jsonb_build_object(
      'custos_fixos', v_custos_fixos,
      'horas_atendidas', round(v_horas, 1),
      'atendimentos', v_atend,
      'valor_hora', case when v_horas > 0 then round(v_custos_fixos / v_horas, 2) end,
      'como_calcula', 'Estimativa: despesas do mês sem materiais, laboratório e impostos, divididas pelas horas atendidas registradas. Com a agenda, passa a usar as horas disponíveis.')),
    'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.fin_estornar_recebimento(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_r public.recebimentos;
  v_e public.recebimentos;
  v_motivo text := nullif(btrim(p_dados ->> 'motivo'), '');
  v_rec jsonb;
  v_data date := public.ler_data(p_dados ->> 'data', 'Data do estorno');
  v_avisos text[] := '{}';
  v_num int := public.fin_inteiro(p_dados ->> 'numero', 'Número do pagamento');
  v_id uuid := public.fin_uuid(p_dados ->> 'recebimento_id', 'recebimento_id');
begin
  if v_id is null and v_num is null then
    raise exception 'Diga qual pagamento estornar (recebimento_id ou numero).';
  end if;
  select * into v_r from public.recebimentos where id = v_id or numero = v_num limit 1;
  if not found then
    raise exception 'Pagamento não encontrado. Veja os pagamentos com ver_financeiro (visao paciente).';
  end if;
  if v_r.estorna_id is not null then
    raise exception 'O lançamento nº % já é um estorno.', v_r.numero;
  end if;
  if exists (select 1 from public.recebimentos x where x.estorna_id = v_r.id) then
    raise exception 'O pagamento nº % já foi estornado.', v_r.numero;
  end if;
  if v_motivo is null or length(v_motivo) < 3 then
    raise exception 'Diga o motivo do estorno (ex.: valor errado, paciente errado, pagamento devolvido).';
  end if;
  if v_data is not null and v_data > public.hoje() then
    raise exception 'A data do estorno está no futuro.';
  end if;
  v_rec := public.recibo_situacao(v_r.id);

  insert into public.recebimentos (
    paciente_id, clinica, data_pagamento, valor_bruto, forma, parcelas_cartao, taxa_percentual, taxa_valor, valor_liquido,
    data_credito_prevista, pagador_nome, pagador_cpf, pagador_e_paciente, beneficiario_cpf, descricao,
    atendimento_id, orcamento_id, parcela_id, regime_fiscal, estorna_id, motivo_estorno, solicitacao_id)
  values (
    v_r.paciente_id, v_r.clinica, coalesce(v_data, v_r.data_pagamento), -v_r.valor_bruto, v_r.forma, v_r.parcelas_cartao,
    v_r.taxa_percentual, -v_r.taxa_valor, -v_r.valor_liquido, v_r.data_credito_prevista, v_r.pagador_nome,
    v_r.pagador_cpf, v_r.pagador_e_paciente, v_r.beneficiario_cpf, format('Estorno do pagamento nº %s', v_r.numero),
    v_r.atendimento_id, v_r.orcamento_id, v_r.parcela_id, v_r.regime_fiscal, v_r.id, v_motivo, public.fin_solicitacao())
  returning * into v_e;

  if v_rec ->> 'situacao' = 'emitido' then
    v_avisos := array_append(v_avisos, format('O recibo do Receita Saúde%s já foi emitido: cancele no app Receita Saúde (até 10 dias da emissão) e depois marque com marcar_recibos (situacao cancelado).',
      coalesce(' nº ' || (v_rec ->> 'codigo'), '')));
  end if;
  if exists (select 1 from public.pacotes_contador pc where pc.competencia = date_trunc('month', v_e.data_pagamento)::date) then
    v_avisos := array_append(v_avisos, format('O pacote do contador de %s já foi gerado: gere de novo e avise o contador.',
      to_char(v_e.data_pagamento, 'MM/YYYY')));
  end if;
  if v_r.parcela_id is not null then
    v_avisos := array_append(v_avisos, 'A parcela ligada a este pagamento volta a ficar em aberto.');
  end if;
  v_avisos := array_append(v_avisos, 'Se o certo era outro valor, pagador ou forma, registre agora o pagamento correto.');

  return jsonb_build_object(
    'status', 'ok',
    'estorno', public.recebimento_json(v_e),
    'original', public.recebimento_json(v_r),
    'saldo', case when v_r.paciente_id is not null then public.saldo_paciente(v_r.paciente_id) end,
    'avisos', to_jsonb(v_avisos));
end
$$;

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
    if v_r.paciente_id is null then
      v_avisos := array_append(v_avisos, format('O pagamento nº %s é da clínica %s: não tem recibo do Receita Saúde.',
                                                v_r.numero, v_r.clinica));
      continue;
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
           'clinica', r.clinica,
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
    from public.recebimentos r left join public.pacientes p on p.id = r.paciente_id
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

-- Pagamento de uma clínica onde a Dra. atende (ex.: Tanaka semanal, Giusti
-- mensal). Sem paciente e sem recibo do Receita Saúde. O nome da clínica vem
-- em clinica ou em pagador.nome; se lembrar uma clínica já usada ("Clínica
-- Tanaka" e "Tanaka"), fica o nome já usado.
create or replace function public.fin_pagamento_clinica(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pedido text := btrim(regexp_replace(coalesce(nullif(btrim(p_dados ->> 'clinica'), ''),
                                                 p_dados -> 'pagador' ->> 'nome', ''), '\s+', ' ', 'g'));
  v_nome text;
  v_valor numeric;
  v_data date;
  v_forma text;
  v_calc record;
  v_taxa numeric;
  v_taxa_pct numeric;
  v_desc text := nullif(btrim(p_dados ->> 'descricao'), '');
  v_regime text;
  v_dup jsonb;
  v_pac text;
  v_r public.recebimentos;
  v_avisos text[] := '{}';
begin
  if length(v_pedido) < 3 then
    raise exception 'Diga o nome da clínica que pagou (pelo menos 3 letras).';
  end if;

  -- Mesmo nome de uma clínica já usada?
  select r.clinica into v_nome
    from public.recebimentos r
   where r.clinica is not null
     and (public.normalizar(r.clinica) = public.normalizar(v_pedido)
          or public.normalizar(v_pedido) like '%' || public.normalizar(r.clinica) || '%'
          or public.normalizar(r.clinica) like '%' || public.normalizar(v_pedido) || '%')
   order by (public.normalizar(r.clinica) = public.normalizar(v_pedido)) desc, r.registrado_em desc
   limit 1;

  if v_nome is null then
    v_nome := v_pedido;
    -- Clínica nova com nome de paciente: pode ter faltado o paciente_id.
    if not coalesce((p_dados ->> 'confirmar_duplicado')::boolean, false) then
      select string_agg(format('%s (ficha %s)', p.nome, p.ficha), ', ') into v_pac
        from public.pacientes p
       where p.arquivado_em is null
         and extensions.similarity(public.normalizar(p.nome), public.normalizar(v_pedido)) >= 0.6;
      if v_pac is not null then
        return jsonb_build_object(
          'status', 'confirmacao_necessaria',
          'mensagem', format('"%s" parece nome de paciente: %s. Se o pagamento é de paciente, chame com o paciente_id. Se é mesmo de uma clínica onde a Dra. atende, chame de novo com confirmar_duplicado = true.', v_pedido, v_pac));
      end if;
    end if;
    v_avisos := array_append(v_avisos, format('Primeiro pagamento da clínica "%s"%s.', v_nome,
      coalesce((select '. Clínicas já usadas: ' || string_agg(distinct r.clinica, ', ')
                  from public.recebimentos r where r.clinica is not null), '')));
  end if;

  v_valor := public.fin_valor(p_dados ->> 'valor', 'Valor');
  if v_valor is null or v_valor <= 0 then
    raise exception 'Informe o valor pago, em reais, maior que zero.';
  end if;

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data do pagamento'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data do pagamento (%) está no futuro.', to_char(v_data, 'DD/MM/YYYY');
  end if;
  if v_data < public.hoje() - 30 then
    v_avisos := array_append(v_avisos, format('Pagamento retroativo: de %s, registrado em %s.',
                                              to_char(v_data, 'DD/MM/YYYY'), to_char(public.hoje(), 'DD/MM/YYYY')));
  end if;

  v_forma := public.ler_forma_pagamento(p_dados ->> 'forma', null);
  if v_forma is null then
    raise exception 'Informe a forma de pagamento (pix, transferencia, dinheiro, boleto, debito ou credito_vista).';
  end if;
  if v_forma = 'credito_parcelado'
     or coalesce(public.fin_inteiro(p_dados ->> 'parcelas_cartao', 'Parcelas no cartão'), 1) > 1 then
    raise exception 'Pagamento de clínica em crédito parcelado não é aceito: registre o valor recebido em cada repasse.';
  end if;

  select * into v_calc from public.calcular_taxa_pagamento(v_forma, 1, v_valor, v_data);
  if nullif(p_dados ->> 'taxa', '') is not null then
    v_taxa := public.fin_valor(p_dados ->> 'taxa', 'Taxa');
    if v_taxa < 0 or v_taxa >= v_valor then
      raise exception 'Taxa de % inválida para um pagamento de %.', public.fin_reais(v_taxa), public.fin_reais(v_valor);
    end if;
    v_taxa_pct := round(v_taxa / v_valor * 100, 3);
    if v_taxa_pct > 30 then
      raise exception 'Taxa de % é mais de 30%% do pagamento: confira o valor.', public.fin_reais(v_taxa);
    end if;
  else
    v_taxa_pct := v_calc.percentual;
    v_taxa := v_calc.taxa;
  end if;

  if not coalesce((p_dados ->> 'confirmar_duplicado')::boolean, false) then
    select jsonb_agg(public.recebimento_json(r)) into v_dup
      from public.recebimentos r
     where r.clinica = v_nome and r.data_pagamento = v_data and r.forma = v_forma and r.valor_bruto = v_valor
       and r.estorna_id is null and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id);
    if v_dup is not null then
      return jsonb_build_object(
        'status', 'confirmacao_necessaria',
        'mensagem', 'Já existe pagamento igual desta clínica nesta data. Pergunte à Dra. se é outro pagamento; se for, chame de novo com confirmar_duplicado = true.',
        'parecidos', v_dup);
    end if;
  end if;

  v_regime := public.regime_fiscal(v_data);
  insert into public.recebimentos (
    paciente_id, clinica, data_pagamento, valor_bruto, forma, parcelas_cartao, taxa_percentual, taxa_valor,
    valor_liquido, data_credito_prevista, pagador_nome, pagador_cpf, pagador_e_paciente, beneficiario_cpf, descricao,
    regime_fiscal, solicitacao_id)
  values (
    null, v_nome, v_data, v_valor, v_forma, 1, v_taxa_pct, v_taxa,
    v_valor - v_taxa, v_calc.data_credito, v_nome, null, false, null,
    coalesce(v_desc, 'Pagamento da clínica ' || v_nome),
    v_regime, public.fin_solicitacao())
  returning * into v_r;

  return jsonb_build_object(
    'status', 'ok',
    'clinica', v_nome,
    'recebimento', public.recebimento_json(v_r),
    'total', v_valor,
    'taxa', v_taxa,
    'liquido', v_valor - v_taxa,
    'recebido_da_clinica_no_mes', (select sum(r.valor_bruto) from public.recebimentos r
                                    where r.clinica = v_nome
                                      and r.data_pagamento >= date_trunc('month', v_data)::date
                                      and r.data_pagamento < (date_trunc('month', v_data) + interval '1 month')::date),
    'fiscal', case v_regime
      when 'pf' then 'Pagamento de clínica: não tem recibo do Receita Saúde. Entra no resumo do mês e no pacote do contador.'
      else 'Pessoa jurídica: a nota fiscal (NFS-e) é emitida pelo contador.' end,
    'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.mcp_registrar_pagamento(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'pagamento');
begin
  perform public.iniciar_solicitacao('registrar_pagamento', p_dados, p_texto_original);
  if v_acao = 'pagamento' then
    -- Sem paciente_id e com o nome de quem pagou (ou clinica): pagamento de uma
    -- clínica onde a Dra. atende (Tanaka, Giusti...), sem recibo do Receita Saúde.
    if nullif(btrim(p_dados ->> 'paciente_id'), '') is not null and nullif(btrim(p_dados ->> 'clinica'), '') is not null then
      raise exception 'Use paciente_id (pagamento de paciente) ou clinica (pagamento de clínica), não os dois.';
    end if;
    if nullif(btrim(p_dados ->> 'paciente_id'), '') is null
       and (nullif(btrim(p_dados ->> 'clinica'), '') is not null
            or (jsonb_typeof(p_dados -> 'pagador') = 'object' and nullif(btrim(p_dados -> 'pagador' ->> 'nome'), '') is not null)) then
      return public.fin_pagamento_clinica(p_dados);
    end if;
    if nullif(btrim(p_dados ->> 'paciente_id'), '') is null then
      raise exception '%', concat('Informe o paciente_id (use buscar_paciente para obter o id). ',
        'Se for pagamento de uma clínica onde a Dra. atende, mande sem paciente_id e com pagador.nome = nome da clínica',
        (select ' (já usadas: ' || string_agg(distinct r.clinica, ', ') || ')' from public.recebimentos r where r.clinica is not null),
        '.');
    end if;
    return public.fin_pagamento(p_dados);
  elsif v_acao = 'combinar' then
    return public.fin_combinar(p_dados);
  elsif v_acao = 'estornar' then
    return public.fin_estornar_recebimento(p_dados);
  elsif v_acao = 'cancelar_acordo' then
    return public.fin_cancelar_acordo(p_dados);
  end if;
  raise exception 'Ação "%" desconhecida: use pagamento, combinar, estornar ou cancelar_acordo.', p_dados ->> 'acao';
end
$$;

revoke execute on function public.fin_pagamento_clinica(jsonb) from public, anon, authenticated;
grant execute on function public.fin_pagamento_clinica(jsonb) to service_role;
