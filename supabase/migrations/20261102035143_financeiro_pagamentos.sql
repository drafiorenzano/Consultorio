-- =====================================================================
-- Etapa 4b: financeiro, ferramenta registrar_pagamento
-- (pagamento, combinar, estornar, cancelar_acordo).
-- =====================================================================

-- ---------------------------------------------------------------------
-- registrar_pagamento
-- ---------------------------------------------------------------------
create or replace function public.fin_pagamento(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pac public.pacientes;
  v_valor numeric;
  v_data date;
  v_parc int;
  v_forma text;
  v_taxa_pct numeric;
  v_taxa numeric;
  v_credito date;
  v_calc record;
  v_pag jsonb := case when jsonb_typeof(p_dados -> 'pagador') = 'object' then p_dados -> 'pagador' end;
  v_resp public.responsaveis;
  v_pag_nome text;
  v_pag_cpf text;
  v_pag_e_pac boolean;
  v_benef text;
  v_atend uuid;
  v_atend_data date;
  v_orc uuid;
  v_desc text := nullif(btrim(p_dados ->> 'descricao'), '');
  v_quitar boolean := coalesce((p_dados ->> 'quitar_parcela')::boolean, true);
  v_parcela_pedida uuid;
  v_alvos uuid[] := '{}';
  v_pid uuid;
  v_parcela public.parcelas_previstas;
  v_acordo public.acordos_pagamento;
  v_restante numeric;
  v_aloc numeric;
  v_partes jsonb := '[]'::jsonb;
  v_parte jsonb;
  v_i int := 0;
  v_n int;
  v_taxa_rest numeric;
  v_taxa_parte numeric;
  v_regime text;
  v_ids uuid[] := '{}';
  v_id uuid;
  v_dup jsonb;
  v_avisos text[] := '{}';
  v_pj jsonb;
begin
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');

  v_valor := public.fin_valor(p_dados ->> 'valor', 'Valor');
  if v_valor is null or v_valor <= 0 then
    raise exception 'Informe o valor pago, em reais, maior que zero.';
  end if;

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data do pagamento'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data do pagamento (%) está no futuro. Para combinar pagamentos futuros, use acao = combinar.',
      to_char(v_data, 'DD/MM/YYYY');
  end if;
  if v_data < public.hoje() - 30 then
    v_avisos := array_append(v_avisos, format('Pagamento retroativo: de %s, registrado em %s.',
                                              to_char(v_data, 'DD/MM/YYYY'), to_char(public.hoje(), 'DD/MM/YYYY')));
  end if;

  -- Forma e parcelas no cartão
  v_parc := coalesce(public.fin_inteiro(p_dados ->> 'parcelas_cartao', 'Parcelas no cartão'), 1);
  v_forma := public.ler_forma_pagamento(p_dados ->> 'forma', v_parc);
  if v_forma is null then
    raise exception 'Informe a forma de pagamento (pix, dinheiro, debito, credito_vista, credito_parcelado, boleto ou transferencia).';
  end if;
  if v_forma = 'credito_vista' and v_parc > 1 then v_forma := 'credito_parcelado'; end if;
  if v_forma = 'credito_parcelado' and v_parc < 2 then
    raise exception 'Crédito parcelado: diga em quantas vezes no cartão (parcelas_cartao de 2 a 24).';
  end if;
  if v_forma <> 'credito_parcelado' and v_parc > 1 then
    raise exception 'parcelas_cartao só vale para crédito parcelado. Para dividir em vários pagamentos (ex.: 3x no Pix), use acao = combinar.';
  end if;
  if v_parc < 1 or v_parc > 24 then
    raise exception 'Parcelas no cartão: de 1 a 24.';
  end if;

  -- Taxa: informada (R$ ou %) ou a da configuração
  select * into v_calc from public.calcular_taxa_pagamento(v_forma, v_parc, v_valor, v_data);
  v_credito := v_calc.data_credito;
  if nullif(p_dados ->> 'taxa', '') is not null then
    v_taxa := public.fin_valor(p_dados ->> 'taxa', 'Taxa');
    if v_taxa < 0 or v_taxa >= v_valor then
      raise exception 'Taxa de % inválida para um pagamento de %.', public.fin_reais(v_taxa), public.fin_reais(v_valor);
    end if;
    v_taxa_pct := round(v_taxa / v_valor * 100, 3);
    if v_taxa_pct > 30 then
      raise exception 'Taxa de % é mais de 30%% do pagamento: confira o valor.', public.fin_reais(v_taxa);
    end if;
  elsif nullif(p_dados ->> 'taxa_percentual', '') is not null then
    v_taxa_pct := round((p_dados ->> 'taxa_percentual')::numeric, 3);
    if v_taxa_pct < 0 or v_taxa_pct > 30 then
      raise exception '%', format('Taxa de %s%% fora do esperado (de 0 a 30%%).', v_taxa_pct);
    end if;
    v_taxa := round(v_valor * v_taxa_pct / 100, 2);
  else
    v_taxa_pct := v_calc.percentual;
    v_taxa := v_calc.taxa;
  end if;

  -- Pagador: responsável, outra pessoa ou o próprio paciente
  if v_pag is not null and nullif(v_pag ->> 'responsavel_id', '') is not null then
    select * into v_resp from public.responsaveis
     where id = public.fin_uuid(v_pag ->> 'responsavel_id', 'responsavel_id') and paciente_id = v_pac.id;
    if not found then
      raise exception 'Responsável não encontrado neste paciente. Veja os responsáveis na ficha (buscar_paciente).';
    end if;
    v_pag_nome := v_resp.nome; v_pag_cpf := v_resp.cpf; v_pag_e_pac := false;
  elsif v_pag is not null and nullif(btrim(v_pag ->> 'nome'), '') is not null then
    v_pag_nome := btrim(v_pag ->> 'nome');
    v_pag_cpf := nullif(public.somente_digitos(v_pag ->> 'cpf'), '');
    if v_pag_cpf is not null and not public.cpf_valido(v_pag_cpf) then
      raise exception 'CPF do pagador (%) inválido. Confira os números.', v_pag ->> 'cpf';
    end if;
    if public.normalizar(v_pag_nome) = public.normalizar(v_pac.nome) then
      v_pag_e_pac := true; v_pag_nome := v_pac.nome; v_pag_cpf := coalesce(v_pag_cpf, v_pac.cpf);
    else
      v_pag_e_pac := false;
      select * into v_resp from public.responsaveis r
       where r.paciente_id = v_pac.id
         and (public.normalizar(r.nome) = public.normalizar(v_pag_nome)
              or public.normalizar(r.nome) like public.normalizar(v_pag_nome) || ' %')
       order by (public.normalizar(r.nome) = public.normalizar(v_pag_nome)) desc, r.criado_em
       limit 1;
      if found then
        v_pag_nome := v_resp.nome; v_pag_cpf := coalesce(v_pag_cpf, v_resp.cpf);
      end if;
    end if;
    if length(v_pag_nome) < 3 then
      raise exception 'Nome do pagador muito curto: diga o nome completo de quem pagou.';
    end if;
  elsif coalesce((v_pag ->> 'e_o_paciente')::boolean, false) then
    v_pag_nome := v_pac.nome; v_pag_cpf := v_pac.cpf; v_pag_e_pac := true;
  else
    select * into v_resp from public.responsaveis r
     where r.paciente_id = v_pac.id and r.e_pagador order by r.criado_em limit 1;
    if found then
      v_pag_nome := v_resp.nome; v_pag_cpf := v_resp.cpf; v_pag_e_pac := false;
      v_avisos := array_append(v_avisos, format('Pagador: %s (responsável). Se quem pagou foi outra pessoa, estorne e registre com o pagador certo.', v_resp.nome));
    else
      v_pag_nome := v_pac.nome; v_pag_cpf := v_pac.cpf; v_pag_e_pac := true;
      if public.idade(v_pac.data_nascimento) < 18 then
        v_avisos := array_append(v_avisos, format('%s é menor de idade e não tem responsável cadastrado: o recibo deve sair no nome e CPF de quem pagou. Cadastre o responsável com atualizar_paciente.', v_pac.nome));
      end if;
    end if;
  end if;
  v_benef := coalesce(v_pac.cpf, case when v_pag_e_pac then v_pag_cpf end);

  -- Referências
  v_atend := public.fin_uuid(p_dados ->> 'atendimento_id', 'atendimento_id');
  if v_atend is not null then
    select a.data into v_atend_data from public.atendimentos a where a.id = v_atend and a.paciente_id = v_pac.id;
    if not found then
      raise exception 'Atendimento não encontrado neste paciente.';
    end if;
  end if;
  v_orc := public.fin_uuid(p_dados ->> 'orcamento_id', 'orcamento_id');

  -- Pagamento repetido?
  if not coalesce((p_dados ->> 'confirmar_duplicado')::boolean, false) then
    select jsonb_agg(public.recebimento_json(r)) into v_dup
      from public.recebimentos r
     where r.paciente_id = v_pac.id and r.data_pagamento = v_data and r.estorna_id is null
       and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id)
       and r.forma = v_forma
       and (r.valor_bruto = v_valor
            or (select sum(x.valor_bruto) from public.recebimentos x
                 where x.solicitacao_id = r.solicitacao_id and x.estorna_id is null) = v_valor);
    if v_dup is not null then
      return jsonb_build_object(
        'status', 'confirmacao_necessaria',
        'mensagem', 'Já existe pagamento igual deste paciente nesta data. Pergunte à Dra. se é outro pagamento; se for, chame de novo com confirmar_duplicado = true.',
        'parecidos', v_dup);
    end if;
  end if;

  -- Parcelas a quitar: a pedida primeiro, depois as em aberto mais antigas
  v_parcela_pedida := public.fin_uuid(p_dados ->> 'parcela_id', 'parcela_id');
  if v_parcela_pedida is not null then
    select pp.* into v_parcela from public.parcelas_previstas pp
      join public.acordos_pagamento a on a.id = pp.acordo_id
     where pp.id = v_parcela_pedida and a.paciente_id = v_pac.id;
    if not found then
      raise exception 'Parcela não encontrada neste paciente. Veja as parcelas com ver_financeiro (visao paciente).';
    end if;
    if (public.parcela_json(v_parcela) ->> 'restante')::numeric <= 0 then
      raise exception 'A parcela %/% já está %.', v_parcela.numero, v_parcela.total, public.parcela_json(v_parcela) ->> 'situacao';
    end if;
    v_alvos := array[v_parcela_pedida];
  end if;
  if v_quitar or v_parcela_pedida is not null then
    v_alvos := v_alvos || coalesce((
      select array_agg(pp.id order by pp.vencimento, a.numero, pp.numero)
        from public.parcelas_previstas pp join public.acordos_pagamento a on a.id = pp.acordo_id
       where a.paciente_id = v_pac.id and a.cancelado_em is null and pp.cancelada_em is null
         and pp.id is distinct from v_parcela_pedida
         and (v_parcela_pedida is null or pp.acordo_id = v_parcela.acordo_id)
         and pp.valor - public.parcela_pago(pp.id) > 0), '{}');
  end if;

  v_restante := v_valor;
  foreach v_pid in array v_alvos loop
    exit when v_restante <= 0;
    select * into v_parcela from public.parcelas_previstas where id = v_pid;
    v_aloc := least(v_restante, v_parcela.valor - public.parcela_pago(v_pid));
    v_partes := v_partes || jsonb_build_array(jsonb_build_object('parcela_id', v_pid, 'valor', v_aloc));
    v_restante := v_restante - v_aloc;
  end loop;
  if v_restante > 0 then
    v_partes := v_partes || jsonb_build_array(jsonb_build_object('parcela_id', null, 'valor', v_restante));
    if jsonb_array_length(v_partes) > 1 then
      v_avisos := array_append(v_avisos, format('%s a mais que as parcelas em aberto: lançado como pagamento avulso.', public.fin_reais(v_restante)));
    end if;
  end if;

  -- Um recebimento por parcela (um recibo por parcela, na data do pagamento)
  v_regime := public.regime_fiscal(v_data);
  v_n := jsonb_array_length(v_partes);
  v_taxa_rest := v_taxa;
  for v_parte in select * from jsonb_array_elements(v_partes) loop
    v_i := v_i + 1;
    v_aloc := (v_parte ->> 'valor')::numeric;
    v_taxa_parte := case when v_i = v_n then v_taxa_rest else round(v_taxa * v_aloc / v_valor, 2) end;
    v_taxa_rest := v_taxa_rest - v_taxa_parte;
    v_pid := (v_parte ->> 'parcela_id')::uuid;
    v_acordo := null;
    if v_pid is not null then
      select a.* into v_acordo from public.acordos_pagamento a
        join public.parcelas_previstas pp on pp.acordo_id = a.id where pp.id = v_pid;
    end if;
    insert into public.recebimentos (
      paciente_id, data_pagamento, valor_bruto, forma, parcelas_cartao, taxa_percentual, taxa_valor, valor_liquido,
      data_credito_prevista, pagador_nome, pagador_cpf, pagador_e_paciente, beneficiario_cpf, descricao,
      atendimento_id, orcamento_id, parcela_id, regime_fiscal, solicitacao_id)
    values (
      v_pac.id, v_data, v_aloc, v_forma, v_parc, v_taxa_pct, v_taxa_parte, v_aloc - v_taxa_parte,
      v_credito, v_pag_nome, v_pag_cpf, v_pag_e_pac, v_benef,
      coalesce(v_desc, v_acordo.descricao, 'Tratamento odontológico'),
      v_atend, coalesce(v_orc, v_acordo.orcamento_id), v_pid, v_regime, public.fin_solicitacao())
    returning id into v_id;
    v_ids := v_ids || v_id;
    if v_pid is not null then
      select * into v_parcela from public.parcelas_previstas where id = v_pid;
      v_pj := public.parcela_json(v_parcela);
      v_avisos := array_append(v_avisos, case when v_pj ->> 'situacao' = 'quitada'
        then format('Parcela %s do acordo nº %s (%s) quitada.', v_pj ->> 'parcela', v_acordo.numero, v_acordo.descricao)
        else format('Parcela %s do acordo nº %s (%s) paga em parte: faltam %s.', v_pj ->> 'parcela', v_acordo.numero,
                    v_acordo.descricao, public.fin_reais((v_pj ->> 'restante')::numeric)) end);
    end if;
  end loop;
  if v_n > 1 then
    v_avisos := array_append(v_avisos, format('O pagamento cobriu %s parcelas: foi dividido em %s lançamentos (um recibo por parcela).', v_n, v_n));
  end if;

  -- Fiscal
  if v_regime = 'pf' then
    if v_pag_cpf is null then
      v_avisos := array_append(v_avisos, format('Falta o CPF de quem pagou (%s): sem ele o recibo do Receita Saúde não sai. %s',
        v_pag_nome, case when v_pag_e_pac then 'Cadastre com atualizar_paciente.' else 'Cadastre o CPF do responsável na ficha.' end));
    end if;
    if v_benef is null and not v_pag_e_pac then
      v_avisos := array_append(v_avisos, format('Falta o CPF do paciente %s (beneficiário do recibo do Receita Saúde).', v_pac.nome));
    end if;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'recebimentos', (select jsonb_agg(public.recebimento_json(r) order by r.numero) from public.recebimentos r where r.id = any (v_ids)),
    'total', v_valor,
    'taxa', v_taxa,
    'liquido', v_valor - v_taxa,
    'fiscal', case v_regime
      when 'pf' then 'Recibo do Receita Saúde pendente: entra no lote do mês (gerar_pacote_contador) ou é emitido no app; depois, marcar_recibos.'
      else 'Pessoa jurídica: a nota fiscal (NFS-e) é emitida pelo contador.' end,
    'saldo', public.saldo_paciente(v_pac.id),
    'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.fin_combinar(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pac public.pacientes;
  v_total numeric;
  v_n int;
  v_entrada numeric;
  v_data_entrada date;
  v_forma text;
  v_desc text := coalesce(nullif(btrim(p_dados ->> 'descricao'), ''), 'Tratamento odontológico');
  v_orc uuid;
  v_dia int;
  v_primeiro date;
  v_resto numeric;
  v_base numeric;
  v_valor numeric;
  v_acordo uuid;
  v_k int := 0;
  v_tot_parc int;
  v_i int;
  v_venc date;
  v_avisos text[] := '{}';
  v_outros jsonb;
begin
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_total := public.fin_valor(coalesce(p_dados ->> 'valor_total', p_dados ->> 'valor'), 'Valor total');
  if v_total is null or v_total <= 0 then
    raise exception 'Informe o valor total combinado (valor_total), em reais.';
  end if;
  v_n := coalesce(public.fin_inteiro(p_dados ->> 'parcelas', 'Número de parcelas'), 1);
  if v_n < 1 or v_n > 60 then
    raise exception 'Número de parcelas: de 1 a 60.';
  end if;
  v_entrada := public.fin_valor(p_dados ->> 'entrada', 'Entrada');
  if v_entrada is not null and (v_entrada <= 0 or v_entrada >= v_total) then
    raise exception 'A entrada (%) tem de ser maior que zero e menor que o total (%).',
      public.fin_reais(v_entrada), public.fin_reais(v_total);
  end if;
  v_data_entrada := coalesce(public.ler_data(p_dados ->> 'data_entrada', 'Data da entrada'), public.hoje());
  v_forma := public.ler_forma_pagamento(p_dados ->> 'forma', null);
  v_orc := public.fin_uuid(p_dados ->> 'orcamento_id', 'orcamento_id');
  v_dia := public.fin_inteiro(p_dados ->> 'dia', 'Dia do vencimento');
  if v_dia is not null and (v_dia < 1 or v_dia > 31) then
    raise exception 'Dia do vencimento: de 1 a 31.';
  end if;
  v_primeiro := public.ler_data(p_dados ->> 'primeiro_vencimento', 'Primeiro vencimento');
  if v_primeiro is null then
    if v_dia is not null then
      v_primeiro := public.fin_dia_do_mes(public.hoje(), v_dia);
      if v_primeiro < public.hoje() or (v_entrada is not null and v_primeiro <= v_data_entrada) then
        v_primeiro := public.fin_dia_do_mes((date_trunc('month', public.hoje()) + interval '1 month')::date, v_dia);
      end if;
    elsif v_entrada is not null then
      v_primeiro := (v_data_entrada + interval '1 month')::date;
    else
      v_primeiro := public.hoje();
    end if;
  end if;
  if v_primeiro < public.hoje() - 31 then
    v_avisos := array_append(v_avisos, format('Primeiro vencimento no passado (%s).', to_char(v_primeiro, 'DD/MM/YYYY')));
  end if;
  v_dia := coalesce(v_dia, extract(day from v_primeiro)::int);

  select jsonb_agg(jsonb_build_object('numero', a.numero, 'descricao', a.descricao)) into v_outros
    from public.acordos_pagamento a
   where a.paciente_id = v_pac.id and a.cancelado_em is null
     and exists (select 1 from public.parcelas_previstas pp where pp.acordo_id = a.id and pp.cancelada_em is null
                    and pp.valor - public.parcela_pago(pp.id) > 0);
  if v_outros is not null then
    v_avisos := array_append(v_avisos, format('%s já tem outro acordo em aberto (%s). Se este substitui o anterior, cancele o antigo (acao cancelar_acordo).',
      v_pac.nome, (select string_agg(format('nº %s, %s', x ->> 'numero', x ->> 'descricao'), '; ') from jsonb_array_elements(v_outros) x)));
  end if;

  insert into public.acordos_pagamento (paciente_id, descricao, valor_total, forma_prevista, orcamento_id, solicitacao_id)
  values (v_pac.id, v_desc, v_total, v_forma, v_orc, public.fin_solicitacao())
  returning id into v_acordo;

  v_tot_parc := v_n + case when v_entrada is not null then 1 else 0 end;
  if v_entrada is not null then
    v_k := 1;
    insert into public.parcelas_previstas (acordo_id, numero, total, vencimento, valor)
    values (v_acordo, 1, v_tot_parc, v_data_entrada, v_entrada);
  end if;
  v_resto := v_total - coalesce(v_entrada, 0);
  v_base := trunc(v_resto / v_n, 2);
  for v_i in 0 .. v_n - 1 loop
    v_valor := case when v_i = 0 then v_resto - v_base * (v_n - 1) else v_base end;
    v_venc := public.fin_dia_do_mes((date_trunc('month', v_primeiro) + make_interval(months => v_i))::date, v_dia);
    insert into public.parcelas_previstas (acordo_id, numero, total, vencimento, valor)
    values (v_acordo, v_k + v_i + 1, v_tot_parc, v_venc, v_valor);
  end loop;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'acordo', public.acordo_json(v_acordo),
    'proximo_passo', 'Quando cada parcela for paga, registre com registrar_pagamento: a parcela em aberto mais antiga é quitada sozinha.',
    'saldo', public.saldo_paciente(v_pac.id),
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
    paciente_id, data_pagamento, valor_bruto, forma, parcelas_cartao, taxa_percentual, taxa_valor, valor_liquido,
    data_credito_prevista, pagador_nome, pagador_cpf, pagador_e_paciente, beneficiario_cpf, descricao,
    atendimento_id, orcamento_id, parcela_id, regime_fiscal, estorna_id, motivo_estorno, solicitacao_id)
  values (
    v_r.paciente_id, coalesce(v_data, v_r.data_pagamento), -v_r.valor_bruto, v_r.forma, v_r.parcelas_cartao,
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
    'saldo', public.saldo_paciente(v_r.paciente_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.fin_cancelar_acordo(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_a public.acordos_pagamento;
  v_motivo text := nullif(btrim(p_dados ->> 'motivo'), '');
  v_num int := public.fin_inteiro(p_dados ->> 'acordo', 'Número do acordo');
  v_id uuid := public.fin_uuid(p_dados ->> 'acordo_id', 'acordo_id');
  v_pago numeric;
  v_n int;
  v_avisos text[] := '{}';
begin
  if v_id is null and v_num is null then
    raise exception 'Diga qual acordo cancelar (acordo_id ou acordo = número).';
  end if;
  select * into v_a from public.acordos_pagamento where id = v_id or numero = v_num limit 1;
  if not found then
    raise exception 'Acordo de pagamento não encontrado. Veja com ver_financeiro (visao paciente).';
  end if;
  if v_a.cancelado_em is not null then
    raise exception 'O acordo nº % já estava cancelado.', v_a.numero;
  end if;
  if v_motivo is null or length(v_motivo) < 3 then
    raise exception 'Diga o motivo do cancelamento do acordo.';
  end if;
  update public.acordos_pagamento set cancelado_em = now(), motivo_cancelamento = v_motivo where id = v_a.id;
  update public.parcelas_previstas pp set cancelada_em = now()
   where pp.acordo_id = v_a.id and pp.cancelada_em is null and pp.valor - public.parcela_pago(pp.id) > 0;
  get diagnostics v_n = row_count;
  select coalesce(sum(r.valor_bruto), 0) into v_pago from public.recebimentos r
    join public.parcelas_previstas pp on pp.id = r.parcela_id where pp.acordo_id = v_a.id;
  if v_pago > 0 then
    v_avisos := array_append(v_avisos, format('Os pagamentos já feitos neste acordo (%s) continuam registrados; se houver devolução, estorne.', public.fin_reais(v_pago)));
  end if;
  return jsonb_build_object(
    'status', 'ok',
    'acordo', public.acordo_json(v_a.id),
    'parcelas_canceladas', v_n,
    'saldo', public.saldo_paciente(v_a.paciente_id),
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

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.fin_pagamento(jsonb),
  public.fin_combinar(jsonb),
  public.fin_estornar_recebimento(jsonb),
  public.fin_cancelar_acordo(jsonb),
  public.mcp_registrar_pagamento(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.fin_pagamento(jsonb),
  public.fin_combinar(jsonb),
  public.fin_estornar_recebimento(jsonb),
  public.fin_cancelar_acordo(jsonb),
  public.mcp_registrar_pagamento(jsonb, text)
  to service_role;
