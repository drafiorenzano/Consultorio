-- =====================================================================
-- Etapa 4b: financeiro, ferramentas registrar_despesa (registrar,
-- lancar_fixas, alterar_fixa, encerrar_fixa, estornar) e configurar_financeiro.
-- =====================================================================

-- ---------------------------------------------------------------------
-- registrar_despesa
-- ---------------------------------------------------------------------
create or replace function public.fin_despesa_registrar(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_valor numeric := public.fin_valor(p_dados ->> 'valor', 'Valor');
  v_cat text := public.ler_categoria_despesa(p_dados ->> 'categoria');
  v_data date := coalesce(public.ler_data(p_dados ->> 'data', 'Data da despesa'), public.hoje());
  v_comp date;
  v_desc text := nullif(btrim(p_dados ->> 'descricao'), '');
  v_forn text := nullif(btrim(p_dados ->> 'fornecedor'), '');
  v_doc text := nullif(public.somente_digitos(p_dados ->> 'fornecedor_documento'), '');
  v_forma text := public.ler_forma_pagamento(p_dados ->> 'forma', null);
  v_pac uuid := public.fin_uuid(p_dados ->> 'paciente_id', 'paciente_id');
  v_pac_nome text;
  v_comprovante text := nullif(btrim(p_dados ->> 'comprovante'), '');
  v_rec jsonb := p_dados -> 'recorrente';
  v_dia int;
  v_fixa public.despesas_recorrentes;
  v_d public.despesas;
  v_dup jsonb;
  v_avisos text[] := '{}';
begin
  if v_valor is null or v_valor <= 0 then
    raise exception 'Informe o valor da despesa, em reais, maior que zero.';
  end if;
  if v_cat is null then
    raise exception 'Informe a categoria da despesa (aluguel_sala, materiais, laboratorio, cro, contador, inss, impostos, iss, seguro, software, manutencao, marketing ou outros).';
  end if;
  if v_data > public.hoje() then
    raise exception 'A data da despesa (%) está no futuro. Registre quando for paga; conta fixa: cadastre com recorrente e lance no mês com lancar_fixas.',
      to_char(v_data, 'DD/MM/YYYY');
  end if;
  v_comp := case when nullif(btrim(p_dados ->> 'competencia'), '') is not null
                 then public.fin_mes(p_dados ->> 'competencia') else date_trunc('month', v_data)::date end;
  if v_doc is not null and not (public.cpf_valido(v_doc) or public.cnpj_valido(v_doc)) then
    raise exception 'CPF/CNPJ do fornecedor (%) inválido. Confira os números.', p_dados ->> 'fornecedor_documento';
  end if;
  if v_pac is not null then
    select nome into v_pac_nome from public.pacientes where id = v_pac;
    if not found then
      raise exception 'Paciente não encontrado. Use buscar_paciente para obter o id.';
    end if;
  end if;
  if v_cat = 'laboratorio' and v_pac is null then
    v_avisos := array_append(v_avisos, 'Despesa de laboratório sem paciente: diga de qual paciente é, para o custo do tratamento.');
  end if;

  if not coalesce((p_dados ->> 'confirmar_duplicada')::boolean, false) then
    select jsonb_agg(public.despesa_json(d)) into v_dup from public.despesas d
     where d.categoria = v_cat and d.valor = v_valor and abs(d.data - v_data) <= 3 and public.despesa_vigente(d.id);
    if v_dup is not null then
      return jsonb_build_object(
        'status', 'confirmacao_necessaria',
        'mensagem', 'Já existe despesa igual (mesma categoria e valor) em data próxima. Pergunte à Dra. se é outra; se for, chame de novo com confirmar_duplicada = true.',
        'parecidas', v_dup);
    end if;
  end if;

  -- Despesa fixa: cadastra e lança a deste mês
  if v_rec is not null and (jsonb_typeof(v_rec) = 'object' or v_rec = 'true'::jsonb) then
    v_dia := coalesce(public.fin_inteiro(v_rec ->> 'dia', 'Dia da despesa fixa'), extract(day from v_data)::int);
    if v_dia < 1 or v_dia > 31 then
      raise exception 'Dia da despesa fixa: de 1 a 31.';
    end if;
    if exists (select 1 from public.despesas_recorrentes r
                where r.categoria = v_cat and r.encerrada_em is null
                  and public.normalizar(r.descricao) = public.normalizar(coalesce(v_desc, public.fin_rotulo_categoria(v_cat)))) then
      raise exception 'Já existe despesa fixa "%" ativa. Para mudar valor ou dia, use acao alterar_fixa.',
        coalesce(v_desc, public.fin_rotulo_categoria(v_cat));
    end if;
    insert into public.despesas_recorrentes (descricao, categoria, fornecedor, fornecedor_documento, valor, dia, forma,
                                             inicio, solicitacao_id)
    values (coalesce(v_desc, public.fin_rotulo_categoria(v_cat)), v_cat, v_forn, v_doc, v_valor, v_dia, v_forma,
            v_comp, public.fin_solicitacao())
    returning * into v_fixa;
  elsif v_rec is not null and v_rec <> 'false'::jsonb and v_rec <> 'null'::jsonb then
    raise exception 'recorrente: use {"dia": N} (dia do vencimento) ou true.';
  end if;

  insert into public.despesas (data, competencia, categoria, descricao, fornecedor, fornecedor_documento, valor, forma,
                               paciente_id, origem, origem_id, comprovante, solicitacao_id)
  values (v_data, v_comp, v_cat, coalesce(v_desc, public.fin_rotulo_categoria(v_cat)), v_forn, v_doc, v_valor, v_forma,
          v_pac, case when v_fixa.id is null then 'manual' else 'recorrente' end, v_fixa.id, v_comprovante,
          public.fin_solicitacao())
  returning * into v_d;

  if v_comprovante is null then
    v_avisos := array_append(v_avisos, 'Guarde o comprovante (nota ou recibo): o livro-caixa do Carnê-Leão exige.');
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'despesa', public.despesa_json(v_d),
    'despesa_fixa', case when v_fixa.id is not null then public.despesa_fixa_json(v_fixa) end,
    'total_do_mes_na_categoria', (select sum(valor) from public.despesas
                                   where categoria = v_cat and data >= date_trunc('month', v_data)::date
                                     and data < (date_trunc('month', v_data) + interval '1 month')::date),
    'avisos', to_jsonb(v_avisos)));
end
$$;

create or replace function public.fin_lancar_fixas(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_comp date := public.fin_mes(p_dados ->> 'mes');
  v_fim date := (public.fin_mes(p_dados ->> 'mes') + interval '1 month')::date;
  v_valores jsonb := coalesce(p_dados -> 'valores', '[]'::jsonb);
  v_ids jsonb := p_dados -> 'ids';
  v_r public.despesas_recorrentes;
  v_d public.despesas;
  v_valor numeric;
  v_data date;
  v_lanc jsonb := '[]'::jsonb;
  v_ja jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_futuras boolean := false;
  v_avisos text[] := '{}';
begin
  if v_comp > date_trunc('month', public.hoje())::date then
    raise exception 'Só dá para lançar as fixas do mês atual ou de meses passados.';
  end if;
  if jsonb_typeof(v_valores) <> 'array' then
    raise exception 'valores: use uma lista de {"id": ..., "valor": ...}.';
  end if;
  for v_r in
    select * from public.despesas_recorrentes r
     where r.inicio < v_fim and (r.encerrada_em is null or r.encerrada_em >= v_comp)
     order by r.dia, r.descricao
  loop
    if v_ids is not null and jsonb_typeof(v_ids) = 'array' and not (v_ids ? v_r.id::text) then
      continue;
    end if;
    if public.despesa_fixa_lancada(v_r.id, v_comp) then
      v_ja := v_ja || jsonb_build_array(public.despesa_fixa_json(v_r));
      continue;
    end if;
    v_valor := coalesce((select public.fin_valor(x ->> 'valor', 'Valor') from jsonb_array_elements(v_valores) x
                          where x ->> 'id' = v_r.id::text limit 1), v_r.valor);
    if v_valor <= 0 then continue; end if;
    v_data := public.fin_dia_do_mes(v_comp, v_r.dia);
    if v_data > public.hoje() then v_futuras := true; end if;
    insert into public.despesas (data, competencia, categoria, descricao, fornecedor, fornecedor_documento, valor, forma,
                                 origem, origem_id, solicitacao_id)
    values (v_data, v_comp, v_r.categoria, v_r.descricao, v_r.fornecedor, v_r.fornecedor_documento, v_valor, v_r.forma,
            'recorrente', v_r.id, public.fin_solicitacao())
    returning * into v_d;
    v_lanc := v_lanc || jsonb_build_array(public.despesa_json(v_d));
    v_total := v_total + v_valor;
  end loop;

  if not exists (select 1 from public.despesas_recorrentes) then
    v_avisos := array_append(v_avisos, 'Não há despesas fixas cadastradas. Para cadastrar, registre a despesa com recorrente = {"dia": N}.');
  elsif jsonb_array_length(v_lanc) = 0 then
    v_avisos := array_append(v_avisos, format('Nenhuma despesa fixa pendente em %s.', to_char(v_comp, 'MM/YYYY')));
  end if;
  if v_futuras then
    v_avisos := array_append(v_avisos, 'Algumas foram lançadas com a data de vencimento, ainda à frente. Se alguma for paga em outra data ou valor, estorne e registre de novo.');
  end if;

  return jsonb_build_object(
    'status', case when jsonb_array_length(v_lanc) = 0 then 'sem_mudanca' else 'ok' end,
    'mes', to_char(v_comp, 'YYYY-MM'),
    'lancadas', v_lanc,
    'ja_lancadas', v_ja,
    'total_lancado', v_total,
    'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.fin_alterar_fixa(p_dados jsonb, p_encerrar boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := public.fin_uuid(p_dados ->> 'fixa_id', 'fixa_id');
  v_r public.despesas_recorrentes;
  v_novo public.despesas_recorrentes;
  v_doc text;
  v_data date;
begin
  if v_id is null then
    raise exception 'Diga qual despesa fixa (fixa_id). Veja as fixas com ver_financeiro (visao despesas).';
  end if;
  select * into v_r from public.despesas_recorrentes where id = v_id;
  if not found then
    raise exception 'Despesa fixa não encontrada. Veja as fixas com ver_financeiro (visao despesas).';
  end if;
  if v_r.encerrada_em is not null and v_r.encerrada_em < public.hoje() then
    raise exception 'A despesa fixa "%" já foi encerrada em %.', v_r.descricao, to_char(v_r.encerrada_em, 'DD/MM/YYYY');
  end if;

  if p_encerrar then
    v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data de encerramento'), public.hoje());
    update public.despesas_recorrentes set encerrada_em = v_data where id = v_id returning * into v_novo;
    return jsonb_build_object('status', 'ok', 'despesa_fixa', public.despesa_fixa_json(v_novo),
      'avisos', jsonb_build_array('O que já foi lançado continua; a partir do mês seguinte ao encerramento, ela não é mais lançada.'));
  end if;

  v_novo := v_r;
  if p_dados ? 'valor' then
    v_novo.valor := public.fin_valor(p_dados ->> 'valor', 'Valor');
    if v_novo.valor is null or v_novo.valor <= 0 then raise exception 'Valor da despesa fixa deve ser maior que zero.'; end if;
  end if;
  if p_dados ? 'dia' then
    v_novo.dia := public.fin_inteiro(p_dados ->> 'dia', 'Dia');
    if v_novo.dia is null or v_novo.dia < 1 or v_novo.dia > 31 then raise exception 'Dia: de 1 a 31.'; end if;
  end if;
  if nullif(btrim(p_dados ->> 'descricao'), '') is not null then v_novo.descricao := btrim(p_dados ->> 'descricao'); end if;
  if p_dados ? 'fornecedor' then v_novo.fornecedor := nullif(btrim(p_dados ->> 'fornecedor'), ''); end if;
  if p_dados ? 'fornecedor_documento' then
    v_doc := nullif(public.somente_digitos(p_dados ->> 'fornecedor_documento'), '');
    if v_doc is not null and not (public.cpf_valido(v_doc) or public.cnpj_valido(v_doc)) then
      raise exception 'CPF/CNPJ do fornecedor (%) inválido.', p_dados ->> 'fornecedor_documento';
    end if;
    v_novo.fornecedor_documento := v_doc;
  end if;
  if p_dados ? 'forma' then v_novo.forma := public.ler_forma_pagamento(p_dados ->> 'forma', null); end if;
  if p_dados ? 'categoria' then v_novo.categoria := public.ler_categoria_despesa(p_dados ->> 'categoria'); end if;

  if v_novo is not distinct from v_r then
    return jsonb_build_object('status', 'sem_mudanca', 'despesa_fixa', public.despesa_fixa_json(v_r));
  end if;
  update public.despesas_recorrentes
     set valor = v_novo.valor, dia = v_novo.dia, descricao = v_novo.descricao, fornecedor = v_novo.fornecedor,
         fornecedor_documento = v_novo.fornecedor_documento, forma = v_novo.forma, categoria = v_novo.categoria
   where id = v_id
  returning * into v_novo;
  return jsonb_build_object('status', 'ok', 'despesa_fixa', public.despesa_fixa_json(v_novo),
    'antes', public.despesa_fixa_json(v_r),
    'avisos', jsonb_build_array('Vale para os próximos lançamentos; o que já foi lançado não muda.'));
end
$$;

create or replace function public.fin_despesa_estornar_pedido(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := public.fin_uuid(p_dados ->> 'despesa_id', 'despesa_id');
  v_num int := public.fin_inteiro(p_dados ->> 'numero', 'Número da despesa');
  v_motivo text := nullif(btrim(p_dados ->> 'motivo'), '');
  v_data date := public.ler_data(p_dados ->> 'data', 'Data do estorno');
  v_d public.despesas;
  v_e public.despesas;
  v_avisos text[] := '{}';
begin
  if v_id is null and v_num is null then
    raise exception 'Diga qual despesa estornar (despesa_id ou numero).';
  end if;
  select * into v_d from public.despesas where id = v_id or numero = v_num limit 1;
  if not found then
    raise exception 'Despesa não encontrada. Veja as despesas com ver_financeiro (visao despesas).';
  end if;
  if v_d.origem in ('reserva_sala', 'compra') then
    raise exception 'A despesa nº % veio %: corrija lá, que o financeiro acompanha.', v_d.numero,
      case v_d.origem when 'reserva_sala' then 'da reserva de sala (agenda)' else 'da compra (estoque)' end;
  end if;
  if v_motivo is null or length(v_motivo) < 3 then
    raise exception 'Diga o motivo do estorno (ex.: valor errado, lançada em dobro).';
  end if;
  if v_data is not null and v_data > public.hoje() then
    raise exception 'A data do estorno está no futuro.';
  end if;
  v_e := public.despesa_estornar(v_d.id, v_motivo, v_data);
  if exists (select 1 from public.pacotes_contador pc where pc.competencia = date_trunc('month', v_e.data)::date) then
    v_avisos := array_append(v_avisos, format('O pacote do contador de %s já foi gerado: gere de novo e avise o contador.',
      to_char(v_e.data, 'MM/YYYY')));
  end if;
  if v_d.origem = 'recorrente' then
    v_avisos := array_append(v_avisos, 'Era uma despesa fixa: para lançar de novo a deste mês (com o valor certo), use lancar_fixas com valores.');
  else
    v_avisos := array_append(v_avisos, 'Se o certo era outro valor ou data, registre agora a despesa correta.');
  end if;
  return jsonb_build_object('status', 'ok', 'estorno', public.despesa_json(v_e), 'original', public.despesa_json(v_d),
                            'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.mcp_registrar_despesa(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'registrar');
begin
  perform public.iniciar_solicitacao('registrar_despesa', p_dados, p_texto_original);
  if v_acao = 'registrar' then
    return public.fin_despesa_registrar(p_dados);
  elsif v_acao = 'lancar_fixas' then
    return public.fin_lancar_fixas(p_dados);
  elsif v_acao = 'alterar_fixa' then
    return public.fin_alterar_fixa(p_dados, false);
  elsif v_acao = 'encerrar_fixa' then
    return public.fin_alterar_fixa(p_dados, true);
  elsif v_acao = 'estornar' then
    return public.fin_despesa_estornar_pedido(p_dados);
  end if;
  raise exception 'Ação "%" desconhecida: use registrar, lancar_fixas, alterar_fixa, encerrar_fixa ou estornar.', p_dados ->> 'acao';
end
$$;

-- ---------------------------------------------------------------------
-- configurar_financeiro
-- ---------------------------------------------------------------------
create or replace function public.fin_config_json()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'regime', c.regime,
    'pj_a_partir_de', c.pj_a_partir_de,
    'regime_hoje', public.regime_fiscal(public.hoje()),
    'cpf_profissional', c.cpf_profissional,
    'cnpj', c.cnpj,
    'codigo_ocupacao', c.codigo_ocupacao,
    'registro_profissional', c.registro_profissional,
    'taxas', c.taxas,
    'observacoes', c.observacoes,
    'pendencias', (select jsonb_agg(x) from unnest(array[
        case when c.cpf_profissional is null then 'CPF da Dra. (obrigatório no lote do Receita Saúde)' end,
        case when c.cnpj is null and c.pj_a_partir_de is not null then 'CNPJ (para a fase PJ)' end]) x
       where x is not null)))
    from public.configuracao_financeira c
$$;

create or replace function public.mcp_configurar_financeiro(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old public.configuracao_financeira;
  v_new public.configuracao_financeira;
  v_t text;
  v_forma text;
  v_item record;
  v_campo record;
  v_avisos text[] := '{}';
begin
  perform public.iniciar_solicitacao('configurar_financeiro', p_dados, p_texto_original);
  select * into v_old from public.configuracao_financeira for update;
  if not found then
    raise exception 'Configuração financeira ausente. Avise o Guilherme.';
  end if;
  v_new := v_old;

  if p_dados ? 'cpf_profissional' then
    v_t := nullif(public.somente_digitos(p_dados ->> 'cpf_profissional'), '');
    if v_t is not null and not public.cpf_valido(v_t) then
      raise exception 'CPF da Dra. (%) inválido. Confira os números.', p_dados ->> 'cpf_profissional';
    end if;
    v_new.cpf_profissional := v_t;
  end if;
  if p_dados ? 'registro_profissional' then
    v_t := nullif(btrim(p_dados ->> 'registro_profissional'), '');
    if length(v_t) > 15 then
      raise exception 'Registro profissional com mais de 15 caracteres: o Receita Saúde não aceita.';
    end if;
    v_new.registro_profissional := v_t;
  end if;
  if p_dados ? 'codigo_ocupacao' then
    v_t := btrim(p_dados ->> 'codigo_ocupacao');
    if v_t !~ '^\d{3}$' then
      raise exception 'Código de ocupação deve ter 3 dígitos (226 = odontólogo).';
    end if;
    v_new.codigo_ocupacao := v_t;
  end if;
  if p_dados ? 'regime' then
    v_t := public.normalizar(p_dados ->> 'regime');
    v_new.regime := case when v_t in ('pf', 'pessoa fisica', 'cpf', 'autonoma', 'autonomo') then 'pf'
                         when v_t in ('pj', 'pessoa juridica', 'cnpj', 'empresa') then 'pj' end;
    if v_new.regime is null then
      raise exception 'Regime "%" inválido: use pf (pessoa física) ou pj (pessoa jurídica).', p_dados ->> 'regime';
    end if;
  end if;
  if p_dados ? 'pj_a_partir_de' then
    v_new.pj_a_partir_de := public.ler_data(p_dados ->> 'pj_a_partir_de', 'Data da virada para PJ');
  elsif p_dados ? 'regime' and v_new.regime is distinct from v_old.regime then
    -- "Virei PJ" sem data: a partir de hoje. "Voltei/continuo PF": desfaz a virada já passada.
    if v_new.regime = 'pj' and (v_new.pj_a_partir_de is null or v_new.pj_a_partir_de > public.hoje()) then
      v_new.pj_a_partir_de := public.hoje();
    elsif v_new.regime = 'pf' and v_new.pj_a_partir_de <= public.hoje() then
      v_new.pj_a_partir_de := null;
    end if;
  end if;
  if v_new.pj_a_partir_de is not null then
    v_new.regime := case when public.hoje() >= v_new.pj_a_partir_de then 'pj' else 'pf' end;
  end if;
  if p_dados ? 'cnpj' then
    v_t := nullif(public.somente_digitos(p_dados ->> 'cnpj'), '');
    if v_t is not null and not public.cnpj_valido(v_t) then
      raise exception 'CNPJ (%) inválido. Confira os números.', p_dados ->> 'cnpj';
    end if;
    v_new.cnpj := v_t;
  end if;
  if p_dados ? 'observacoes' then
    v_new.observacoes := nullif(btrim(p_dados ->> 'observacoes'), '');
  end if;
  if p_dados ? 'taxas' then
    if jsonb_typeof(p_dados -> 'taxas') <> 'object' then
      raise exception 'taxas: use {"forma": {"percentual": ..., "dias": ...}}.';
    end if;
    for v_item in select key, value from jsonb_each(p_dados -> 'taxas') loop
      v_forma := public.ler_forma_pagamento(v_item.key, null);
      if jsonb_typeof(v_item.value) <> 'object' then
        raise exception 'Taxa de %: use {"percentual": ..., "fixo": ..., "dias": ...}.', v_forma;
      end if;
      for v_campo in select key, value from jsonb_each(v_item.value) loop
        if v_campo.key not in ('percentual', 'fixo', 'dias', 'adicional_por_parcela', 'por_parcelas') then
          raise exception 'Campo "%" desconhecido na taxa de % (use percentual, fixo, dias, adicional_por_parcela ou por_parcelas).',
            v_campo.key, v_forma;
        end if;
        if v_campo.key = 'por_parcelas' then
          if jsonb_typeof(v_campo.value) <> 'object' or exists (
               select 1 from jsonb_each(v_campo.value) x
                where x.key !~ '^\d{1,2}$' or jsonb_typeof(x.value) <> 'number'
                   or (x.value)::text::numeric < 0 or (x.value)::text::numeric > 30) then
            raise exception 'por_parcelas: use {"2": 4.59, "3": 5.97, ...} (percentual por número de parcelas, de 0 a 30).';
          end if;
        elsif jsonb_typeof(v_campo.value) <> 'number' or (v_campo.value)::text::numeric < 0
              or (v_campo.key in ('percentual', 'adicional_por_parcela') and (v_campo.value)::text::numeric > 30)
              or (v_campo.key = 'dias' and (v_campo.value)::text::numeric > 60) then
          raise exception 'Valor de % na taxa de % inválido.', v_campo.key, v_forma;
        end if;
      end loop;
      v_new.taxas := jsonb_set(v_new.taxas, array[v_forma], coalesce(v_new.taxas -> v_forma, '{}'::jsonb) || v_item.value);
    end loop;
  end if;

  if v_new is not distinct from v_old then
    return jsonb_build_object('status', 'sem_mudanca', 'configuracao', public.fin_config_json());
  end if;
  update public.configuracao_financeira
     set cpf_profissional = v_new.cpf_profissional, registro_profissional = v_new.registro_profissional,
         codigo_ocupacao = v_new.codigo_ocupacao, regime = v_new.regime, pj_a_partir_de = v_new.pj_a_partir_de,
         cnpj = v_new.cnpj, observacoes = v_new.observacoes, taxas = v_new.taxas
   where id;
  if v_new.pj_a_partir_de is distinct from v_old.pj_a_partir_de or v_new.regime is distinct from v_old.regime then
    v_avisos := array_append(v_avisos, case
      when v_new.pj_a_partir_de is null then format('Regime: %s, sem data de virada.', case v_new.regime when 'pj' then 'pessoa jurídica' else 'pessoa física' end)
      else format('Pagamentos até %s: pessoa física (Receita Saúde). A partir de %s: pessoa jurídica (NFS-e pelo contador). Os já registrados não mudam.',
                  to_char(v_new.pj_a_partir_de - 1, 'DD/MM/YYYY'), to_char(v_new.pj_a_partir_de, 'DD/MM/YYYY')) end);
  end if;
  if v_new.taxas is distinct from v_old.taxas then
    v_avisos := array_append(v_avisos, 'As taxas novas valem para os próximos pagamentos; os já registrados não mudam.');
  end if;
  return jsonb_build_object('status', 'ok', 'configuracao', public.fin_config_json(), 'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.fin_despesa_registrar(jsonb),
  public.fin_lancar_fixas(jsonb),
  public.fin_alterar_fixa(jsonb, boolean),
  public.fin_despesa_estornar_pedido(jsonb),
  public.mcp_registrar_despesa(jsonb, text),
  public.fin_config_json(),
  public.mcp_configurar_financeiro(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.fin_despesa_registrar(jsonb),
  public.fin_lancar_fixas(jsonb),
  public.fin_alterar_fixa(jsonb, boolean),
  public.fin_despesa_estornar_pedido(jsonb),
  public.mcp_registrar_despesa(jsonb, text),
  public.fin_config_json(),
  public.mcp_configurar_financeiro(jsonb, text)
  to service_role;
