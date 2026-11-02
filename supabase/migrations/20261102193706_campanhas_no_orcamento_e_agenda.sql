-- Campanhas no orçamento, na agenda, no catálogo e imposto no financeiro.

-- ---------------------------------------------------------------------
-- Orçamento: preços da campanha do dia (ou da que a Dra. disser)
-- ---------------------------------------------------------------------

create or replace function public.mcp_montar_orcamento(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conf public.configuracao;
  v_cfg public.documentos_config;
  v_pac public.pacientes;
  v_aberto public.orcamentos;
  v_separado boolean := coalesce((p_dados ->> 'separado')::boolean, false);
  v_do_odonto boolean := coalesce((p_dados ->> 'incluir_odontograma')::boolean, true);
  v_apresentar boolean := coalesce((p_dados ->> 'apresentar')::boolean, false);
  v_valores jsonb;
  v_itens jsonb := '[]';
  v_livres jsonb := '[]';
  v_avisos text[] := '{}';
  v_marca public.odontograma;
  v_num_outro int;
  v_proc_id uuid;
  v_novo jsonb;
  v_velho jsonb;
  v_item jsonb;
  v_dentes smallint[];
  v_dente smallint;
  v_idx int;
  v_faltando jsonb;
  v_validade numeric;
  v_desc record;
  v_id uuid;
  v_numero int;
  v_versao int := 1;
  v_alts int;
  v_camp public.campanhas;
  v_camp_ref text := public.normalizar(nullif(btrim(p_dados ->> 'campanha'), ''));
begin
  perform public.iniciar_solicitacao('montar_orcamento', p_dados, p_texto_original);
  select * into v_conf from public.configuracao;
  select * into v_cfg from public.documentos_config;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_valores := public.orcamento_mapa_valores(p_dados -> 'valores');

  -- Preços de campanha: os da campanha pedida; sem pedido, os da versão em aberto
  -- ou os da campanha de hoje. "nenhuma" usa só os preços normais.
  if v_camp_ref in ('nenhuma', 'nenhum', 'sem campanha', 'sem', 'normal', 'normais', 'preco normal',
                    'precos normais', 'tabela normal', 'nao') then
    null;
  elsif v_camp_ref is not null and v_camp_ref <> '' then
    v_camp := public.campanha_localizar(p_dados ->> 'campanha');
    if v_camp.cancelada_em is not null then
      raise exception 'A campanha "%" foi cancelada.', v_camp.nome;
    end if;
  else
    if not v_separado then
      select c.* into v_camp
        from public.orcamentos o join public.campanhas c on c.id = o.campanha_id
       where o.paciente_id = v_pac.id and o.status in ('rascunho', 'apresentado') and c.cancelada_em is null
       order by o.criado_em desc limit 1;
    end if;
    if v_camp.id is null then
      v_camp := public.campanha_na_data(public.hoje());
    end if;
  end if;
  if v_camp.id is not null then
    v_valores := public.campanha_mapa_precos(v_camp.id) || v_valores;
    v_avisos := v_avisos || format(
      'Preços da %s (%s) onde a campanha tem preço; o resto pelo preço normal. Para usar só os preços normais, chame de novo com campanha "nenhuma".',
      v_camp.nome, public.campanha_periodo(v_camp));
  end if;

  if p_dados ? 'itens' and jsonb_typeof(p_dados -> 'itens') <> 'array' then
    raise exception 'itens deve ser uma lista.';
  end if;

  -- 1) Planos do odontograma
  if v_do_odonto then
    for v_marca in
      select a.* from public.odontograma_ativas(v_pac.id) a
       where a.camada = 'planejado' order by a.dente, a.registrado_em
    loop
      select o.numero into v_num_outro
        from public.orcamento_itens i join public.orcamentos o on o.id = i.orcamento_id
       where i.marca_id = v_marca.id and i.status in ('aprovado', 'realizado')
         and o.status in ('aprovado', 'parcial', 'concluido')
       limit 1;
      if found then
        v_avisos := v_avisos || format('Dente %s (%s): já aprovado no orçamento nº %s, ficou de fora.',
                                       v_marca.dente, v_marca.condicao, v_num_outro);
        continue;
      end if;
      v_proc_id := v_marca.procedimento_id;
      if v_proc_id is null then
        select e.proc_id into v_proc_id
          from public.escolher_procedimento(null, null, v_marca.condicao, v_marca.dente, length(v_marca.faces)) e;
      end if;
      if v_proc_id is null then
        v_livres := v_livres || jsonb_build_array(jsonb_build_object(
          'marca_id', v_marca.id, 'dente', v_marca.dente, 'condicao', v_marca.condicao));
        continue;
      end if;
      v_novo := public.orcamento_novo_item(
        jsonb_build_object('procedimento_codigo', (select codigo from public.procedimentos where id = v_proc_id),
                           'faces', v_marca.faces),
        v_marca.dente, v_valores);
      v_itens := v_itens || jsonb_build_array(v_novo || jsonb_build_object(
        'marca_id', v_marca.id, 'condicao', v_marca.condicao, 'origem', 'odontograma'));
    end loop;
  end if;

  -- 2) Itens ditados (podem ajustar os do odontograma: valor, alternativa, fase...)
  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'itens', '[]')) loop
    if v_item ? 'dentes' and jsonb_typeof(v_item -> 'dentes') = 'array' and jsonb_array_length(v_item -> 'dentes') > 0 then
      v_dentes := array(select public.ler_dente(x) from jsonb_array_elements_text(v_item -> 'dentes') x);
    else
      v_dentes := array[public.ler_dente(v_item ->> 'dente')];
    end if;
    foreach v_dente in array v_dentes loop
      v_novo := public.orcamento_novo_item(v_item - 'dentes', v_dente, v_valores);
      v_idx := null;
      if v_dente is not null then
        select (t.ord - 1)::int into v_idx
          from jsonb_array_elements(v_itens) with ordinality t(x, ord)
         where t.x ->> 'origem' = 'odontograma' and not coalesce((t.x ->> 'ditado')::boolean, false)
           and (t.x ->> 'dente')::smallint = v_dente
           and (t.x ->> 'procedimento_id' = v_novo ->> 'procedimento_id'
                or t.x ->> 'familia' = v_novo ->> 'familia'
                or t.x ->> 'condicao' = v_novo ->> 'condicao')
         order by t.ord limit 1;
      end if;
      if v_idx is not null then
        v_velho := v_itens -> v_idx;
        if v_novo ->> 'faces' is null and v_velho ->> 'faces' is not null then
          v_novo := public.orcamento_novo_item((v_item - 'dentes') || jsonb_build_object('faces', v_velho ->> 'faces'),
                                               v_dente, v_valores);
        end if;
        v_itens := jsonb_set(v_itens, array[v_idx::text], v_novo || jsonb_build_object(
          'marca_id', v_velho -> 'marca_id', 'origem', 'odontograma', 'ditado', true));
      else
        -- plano do odontograma sem procedimento definido (ex.: coroa): liga pelo dente e condição
        if v_dente is not null and v_novo ->> 'condicao' is not null then
          select (t.ord - 1)::int into v_idx
            from jsonb_array_elements(v_livres) with ordinality t(x, ord)
           where (t.x ->> 'dente')::smallint = v_dente and t.x ->> 'condicao' = v_novo ->> 'condicao'
           order by t.ord limit 1;
          if v_idx is not null then
            v_novo := v_novo || jsonb_build_object('marca_id', v_livres -> v_idx -> 'marca_id');
            v_livres := v_livres - v_idx;
          end if;
        end if;
        v_itens := v_itens || jsonb_build_array(v_novo || jsonb_build_object('origem', 'ditado'));
      end if;
    end loop;
  end loop;

  for v_item in select * from jsonb_array_elements(v_livres) loop
    v_avisos := v_avisos || format(
      'Dente %s: o plano "%s" do odontograma não tem procedimento definido no catálogo e ficou de fora. Diga qual em itens (com o dente) para entrar.',
      v_item ->> 'dente', v_item ->> 'condicao');
  end loop;
  select v_avisos || coalesce(array_agg(a), '{}') into v_avisos
    from jsonb_array_elements(v_itens) x, jsonb_array_elements_text(x -> 'avisos') a;

  if jsonb_array_length(v_itens) = 0 then
    raise exception 'Nada para orçar: % não tem planos no odontograma e nenhum item foi ditado.', v_pac.nome;
  end if;

  v_faltando := public.orcamento_faltando_valor(v_itens);
  if v_faltando is not null then
    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'valor_necessario',
      'mensagem', 'Nada foi gravado. Há procedimentos sem preço no catálogo: pergunte o valor à Dra. e chame de novo com valores [{procedimento_codigo, valor}] (ou valor no item). Não invente valores; a faixa de mercado é só referência.',
      'faltando', v_faltando,
      'itens_previstos', jsonb_array_length(v_itens),
      'avisos', to_jsonb(v_avisos)));
  end if;

  select count(distinct x ->> 'alternativa') into v_alts
    from jsonb_array_elements(v_itens) x where x ->> 'alternativa' is not null;
  if v_alts = 1 then
    v_avisos := array_append(v_avisos, 'Só há uma alternativa marcada: as alternativas servem para comparar opções (A e B).'::text);
  end if;

  v_validade := coalesce(public.documentos_ler_numero(p_dados ->> 'validade_dias', 'Validade (dias)'),
                         v_cfg.orcamento_validade_dias);
  if v_validade <> trunc(v_validade) or v_validade not between 1 and 180 then
    raise exception 'Validade de % dias fora do esperado (1 a 180).', v_validade;
  end if;
  select * into v_desc from public.orcamento_desconto(p_dados);

  -- 3) Versão nova do orçamento em aberto, ou orçamento novo
  select * into v_aberto from public.orcamentos
   where paciente_id = v_pac.id and status in ('rascunho', 'apresentado')
   order by criado_em desc limit 1;
  if found and not v_separado then
    v_numero := v_aberto.numero;
    select max(versao) + 1 into v_versao from public.orcamentos where numero = v_aberto.numero;
  else
    -- número seguinte (sem sequência: tentativa desfeita não gasta número)
    perform pg_advisory_xact_lock(hashtext('public.orcamentos.numero'));
    select coalesce(max(numero), 0) + 1 into v_numero from public.orcamentos;
    if v_aberto.id is not null then
      v_avisos := v_avisos || format('O orçamento nº %s continua em aberto; este é separado.', v_aberto.numero);
    end if;
  end if;

  insert into public.orcamentos (
    numero, versao, paciente_id, status, titulo, validade, desconto_tipo, desconto_valor, pagamento,
    observacoes, substitui_id, apresentado_em, profissional, cro, solicitacao_id, campanha_id)
  values (
    v_numero, v_versao, v_pac.id, case when v_apresentar then 'apresentado' else 'rascunho' end,
    coalesce(nullif(btrim(p_dados ->> 'titulo'), ''), 'Plano de tratamento'),
    public.hoje() + v_validade::int, v_desc.tipo, coalesce(v_desc.valor, 0),
    public.orcamento_condicoes(to_jsonb(v_cfg) - 'id' - 'atualizado_em' - 'orcamento_validade_dias' - 'acompanhamento_dias',
                               p_dados -> 'pagamento'),
    concat_ws(' ', nullif(btrim(p_dados ->> 'observacoes'), ''),
              case when v_camp.id is not null then format('Valores da %s (%s).', v_camp.nome, public.campanha_periodo(v_camp)) end),
    case when v_versao > 1 then v_aberto.id end,
    case when v_apresentar then public.hoje() end,
    v_conf.dentista_nome, v_conf.cro,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid,
    v_camp.id)
  returning id into v_id;

  insert into public.orcamento_itens (
    orcamento_id, ordem, procedimento_id, descricao, explicacao, dente, faces, regiao, quantidade,
    valor_unitario, fase, alternativa, marca_id, observacao)
  select v_id,
         row_number() over (order by (x ->> 'fase')::int, coalesce(x ->> 'alternativa', ''),
                                     (x ->> 'dente')::int nulls last, t.ord),
         (x ->> 'procedimento_id')::uuid, x ->> 'descricao', x ->> 'explicacao', (x ->> 'dente')::smallint,
         x ->> 'faces', x ->> 'regiao', (x ->> 'quantidade')::int, (x ->> 'valor_unitario')::numeric,
         (x ->> 'fase')::smallint, x ->> 'alternativa', (x ->> 'marca_id')::uuid, x ->> 'observacao'
    from jsonb_array_elements(v_itens) with ordinality t(x, ord);

  if v_versao > 1 then
    update public.orcamentos set status = 'substituido' where id = v_aberto.id;
    v_avisos := v_avisos || format('O orçamento nº %s versão %s foi substituído por esta versão %s.',
                                   v_numero, v_aberto.versao, v_versao);
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'orcamento', public.orcamento_json(v_id),
    'documento', public.orcamento_documento(v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;
create or replace function public.mcp_alterar_orcamento(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  o public.orcamentos;
  v_cfg public.documentos_config;
  v_acao text := public.normalizar(p_dados ->> 'acao');
  v_status text;
  v_avisos text[] := '{}';
  v_doc boolean := false;
  v_data date;
  v_alt text := nullif(upper(btrim(p_dados ->> 'alternativa')), '');
  v_ordens int[];
  v_alts text[];
  v_aprov_alts text[];
  v_total boolean;
  v_alvo uuid;
  v_valores jsonb;
  v_item jsonb;
  v_novos jsonb := '[]';
  v_novo jsonb;
  v_dentes smallint[];
  v_dente smallint;
  v_faltando jsonb;
  v_desc record;
  v_validade numeric;
  v_dur int;
  v_max int;
  v_n int;
  v_marca uuid;
begin
  perform public.iniciar_solicitacao('alterar_orcamento', p_dados, p_texto_original);
  select * into v_cfg from public.documentos_config;
  if v_acao is null or v_acao not in ('apresentar', 'aprovar', 'recusar', 'acompanhamento', 'editar') then
    raise exception 'Ação "%" inválida: use apresentar, aprovar, recusar, acompanhamento ou editar.', p_dados ->> 'acao';
  end if;
  o := public.orcamento_localizar(p_dados);
  v_status := case when o.status = 'apresentado' and o.validade < public.hoje() then 'expirado' else o.status end;
  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data (%) está no futuro.', v_data;
  end if;

  if v_acao = 'apresentar' then
    if o.status <> 'rascunho' then
      raise exception 'O orçamento nº % não é rascunho (está %).', o.numero, lower(public.orcamento_status_texto(v_status));
    end if;
    v_dur := o.validade - (o.criado_em at time zone public.fuso())::date;
    update public.orcamentos
       set status = 'apresentado', apresentado_em = v_data, validade = v_data + greatest(v_dur, 1)
     where id = o.id;
    v_doc := true;

  elsif v_acao = 'aprovar' then
    if o.status not in ('rascunho', 'apresentado', 'recusado') then
      raise exception 'O orçamento nº % já está %.', o.numero, lower(public.orcamento_status_texto(v_status));
    end if;
    if v_status = 'expirado' then
      v_avisos := v_avisos || format('Aprovado depois da validade (vencia em %s): os valores foram mantidos.',
                                     to_char(o.validade, 'DD/MM/YYYY'));
    elsif o.status = 'recusado' then
      v_avisos := array_append(v_avisos, 'O orçamento estava recusado e foi aprovado agora.'::text);
    end if;
    if v_alt is not null and v_alt not in ('A', 'B', 'C', 'D') then
      raise exception 'Alternativa "%" inválida.', p_dados ->> 'alternativa';
    end if;
    if p_dados ? 'itens' and jsonb_typeof(p_dados -> 'itens') = 'array' and jsonb_array_length(p_dados -> 'itens') > 0 then
      v_ordens := array(select (x)::int from jsonb_array_elements_text(p_dados -> 'itens') x);
      if exists (select 1 from unnest(v_ordens) n
                  where not exists (select 1 from public.orcamento_itens i
                                     where i.orcamento_id = o.id and i.ordem = n and i.status <> 'cancelado')) then
        raise exception 'Itens que não existem neste orçamento: %. Veja a numeração (ordem) dos itens.',
          (select string_agg(n::text, ', ') from unnest(v_ordens) n
            where not exists (select 1 from public.orcamento_itens i
                               where i.orcamento_id = o.id and i.ordem = n and i.status <> 'cancelado'));
      end if;
    end if;
    select coalesce(array_agg(distinct alternativa), '{}') into v_alts
      from public.orcamento_itens where orcamento_id = o.id and alternativa is not null and status <> 'cancelado';
    if cardinality(v_alts) >= 2 and v_alt is null and v_ordens is null then
      raise exception 'Este orçamento tem alternativas (%): diga qual foi escolhida (alternativa) ou quais itens (itens).',
        array_to_string(v_alts, ', ');
    end if;
    if v_alt is not null and not v_alt = any (v_alts) then
      raise exception 'A alternativa % não existe neste orçamento.', v_alt;
    end if;

    update public.orcamento_itens i
       set status = case
             when i.status = 'realizado' then 'realizado'
             when (v_ordens is not null and i.ordem = any (v_ordens))
               or (v_ordens is null and (i.alternativa is null or i.alternativa = v_alt or cardinality(v_alts) < 2))
               then 'aprovado'
             else 'recusado' end
     where i.orcamento_id = o.id and i.status <> 'cancelado';

    select coalesce(array_agg(distinct alternativa), '{}') into v_aprov_alts
      from public.orcamento_itens where orcamento_id = o.id and alternativa is not null and status in ('aprovado', 'realizado');
    select not exists (
             select 1 from public.orcamento_itens i
              where i.orcamento_id = o.id and i.status = 'recusado'
                and (i.alternativa is null or i.alternativa = any (v_aprov_alts)))
           and cardinality(v_aprov_alts) <= 1
      into v_total;
    if not exists (select 1 from public.orcamento_itens where orcamento_id = o.id and status in ('aprovado', 'realizado')) then
      raise exception 'Nenhum item ficou aprovado. Para recusar o orçamento, use acao recusar.';
    end if;
    update public.orcamentos
       set status = case when v_total then 'aprovado' else 'parcial' end,
           aprovacao = case when v_total then 'total' else 'parcial' end,
           aprovado_em = v_data, apresentado_em = coalesce(apresentado_em, v_data),
           forma_escolhida = coalesce(nullif(btrim(p_dados ->> 'forma_pagamento'), ''), forma_escolhida),
           recusado_em = null, motivo_recusa = null
     where id = o.id;
    perform public.orcamento_atualizar_status(o.id);
    v_doc := true;

  elsif v_acao = 'recusar' then
    if o.status not in ('rascunho', 'apresentado') then
      raise exception 'O orçamento nº % está % e não pode ser recusado.', o.numero, lower(public.orcamento_status_texto(v_status));
    end if;
    update public.orcamentos
       set status = 'recusado', recusado_em = v_data, motivo_recusa = nullif(btrim(p_dados ->> 'motivo'), ''),
           apresentado_em = coalesce(apresentado_em, v_data)
     where id = o.id;

  elsif v_acao = 'acompanhamento' then
    if coalesce(btrim(p_dados ->> 'nota'), '') = '' then
      raise exception 'Escreva o que foi conversado no contato (nota).';
    end if;
    if v_status not in ('apresentado', 'expirado') then
      v_avisos := v_avisos || format('O orçamento está %s; o contato foi anotado mesmo assim.',
                                     lower(public.orcamento_status_texto(v_status)));
    end if;
    update public.orcamentos
       set acompanhamentos = acompanhamentos || jsonb_build_array(jsonb_build_object('data', v_data, 'nota', btrim(p_dados ->> 'nota')))
     where id = o.id;

  elsif v_acao = 'editar' then
    if o.status not in ('rascunho', 'apresentado') then
      raise exception 'O orçamento nº % já está % e não pode ser editado. Para um plano novo, use montar_orcamento com separado.',
        o.numero, lower(public.orcamento_status_texto(v_status));
    end if;
    -- itens novos primeiro: se faltar valor, nada muda
    -- item novo num orçamento de campanha leva o preço da campanha
    v_valores := public.campanha_mapa_precos(o.campanha_id) || public.orcamento_mapa_valores(p_dados -> 'valores');
    for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'adicionar', '[]')) loop
      if v_item ? 'dentes' and jsonb_typeof(v_item -> 'dentes') = 'array' and jsonb_array_length(v_item -> 'dentes') > 0 then
        v_dentes := array(select public.ler_dente(x) from jsonb_array_elements_text(v_item -> 'dentes') x);
      else
        v_dentes := array[public.ler_dente(v_item ->> 'dente')];
      end if;
      foreach v_dente in array v_dentes loop
        v_novo := public.orcamento_novo_item(v_item - 'dentes', v_dente, v_valores);
        -- liga ao plano do odontograma do mesmo dente e condição
        v_marca := null;
        if v_dente is not null and v_novo ->> 'condicao' is not null then
          select a.id into v_marca from public.odontograma_ativas(o.paciente_id) a
           where a.camada = 'planejado' and a.dente = v_dente and a.condicao = v_novo ->> 'condicao'
           order by a.registrado_em desc limit 1;
        end if;
        v_novos := v_novos || jsonb_build_array(v_novo || jsonb_build_object('marca_id', v_marca));
      end loop;
    end loop;
    v_faltando := public.orcamento_faltando_valor(v_novos);
    if v_faltando is not null then
      return jsonb_build_object(
        'status', 'valor_necessario',
        'mensagem', 'Nada foi alterado. Há procedimentos sem preço: pergunte o valor à Dra. e chame de novo com valores [{procedimento_codigo, valor}].',
        'faltando', v_faltando);
    end if;
    select v_avisos || coalesce(array_agg(a), '{}') into v_avisos
      from jsonb_array_elements(v_novos) x, jsonb_array_elements_text(x -> 'avisos') a;

    if o.status = 'rascunho' then
      v_alvo := o.id;
    else
      -- apresentado: a mudança vira versão nova, apresentada de novo
      v_dur := o.validade - coalesce(o.apresentado_em, (o.criado_em at time zone public.fuso())::date);
      insert into public.orcamentos (
        numero, versao, paciente_id, status, titulo, validade, desconto_tipo, desconto_valor, pagamento,
        observacoes, substitui_id, apresentado_em, profissional, cro, solicitacao_id, campanha_id)
      select o.numero, (select max(versao) + 1 from public.orcamentos where numero = o.numero), o.paciente_id,
             'apresentado', o.titulo, public.hoje() + greatest(v_dur, 1), o.desconto_tipo, o.desconto_valor,
             o.pagamento, o.observacoes, o.id, public.hoje(), o.profissional, o.cro,
             nullif(current_setting('app.solicitacao_id', true), '')::uuid, o.campanha_id
      returning id into v_alvo;
      insert into public.orcamento_itens (
        orcamento_id, ordem, procedimento_id, descricao, explicacao, dente, faces, regiao, quantidade,
        valor_unitario, fase, alternativa, status, marca_id, realizado_em, realizado_marca_id,
        atendimento_item_id, observacao)
      select v_alvo, i.ordem, i.procedimento_id, i.descricao, i.explicacao, i.dente, i.faces, i.regiao, i.quantidade,
             i.valor_unitario, i.fase, i.alternativa,
             case when i.status = 'realizado' then 'realizado' else 'incluido' end,
             i.marca_id, i.realizado_em, i.realizado_marca_id, i.atendimento_item_id, i.observacao
        from public.orcamento_itens i
       where i.orcamento_id = o.id and i.status <> 'cancelado';
      update public.orcamentos set status = 'substituido' where id = o.id;
      v_avisos := v_avisos || format('Como já tinha sido apresentado, virou a versão %s do orçamento nº %s.',
                                     (select versao from public.orcamentos where id = v_alvo), o.numero);
    end if;

    -- remover
    if p_dados ? 'remover' then
      v_ordens := array(select (x)::int from jsonb_array_elements_text(p_dados -> 'remover') x);
      update public.orcamento_itens set status = 'cancelado'
       where orcamento_id = v_alvo and ordem = any (v_ordens) and status <> 'realizado';
      get diagnostics v_n = row_count;
      if v_n < cardinality(v_ordens) then
        v_avisos := array_append(v_avisos, 'Algum item de remover não existe ou já foi realizado: confira a numeração.'::text);
      end if;
    end if;

    -- alterar
    for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'alterar', '[]')) loop
      if not exists (select 1 from public.orcamento_itens
                      where orcamento_id = v_alvo and ordem = (v_item ->> 'ordem')::int and status <> 'cancelado') then
        raise exception 'Item % não existe neste orçamento.', v_item ->> 'ordem';
      end if;
      if (v_item ->> 'alternativa') is not null and upper(btrim(v_item ->> 'alternativa')) not in ('A', 'B', 'C', 'D', '') then
        raise exception 'Alternativa "%" inválida.', v_item ->> 'alternativa';
      end if;
      update public.orcamento_itens i
         set valor_unitario = coalesce(public.documentos_ler_numero(v_item ->> 'valor', 'Valor'), i.valor_unitario),
             quantidade = coalesce(public.documentos_ler_numero(v_item ->> 'quantidade', 'Quantidade')::int, i.quantidade),
             fase = coalesce(public.documentos_ler_numero(v_item ->> 'fase', 'Fase')::smallint, i.fase),
             alternativa = case when v_item ? 'alternativa' then nullif(upper(btrim(v_item ->> 'alternativa')), '')
                                else i.alternativa end,
             explicacao = coalesce(nullif(btrim(v_item ->> 'explicacao'), ''), i.explicacao),
             descricao = coalesce(nullif(btrim(v_item ->> 'descricao'), ''), i.descricao),
             observacao = case when v_item ? 'observacao' then nullif(btrim(v_item ->> 'observacao'), '')
                               else i.observacao end
       where i.orcamento_id = v_alvo and i.ordem = (v_item ->> 'ordem')::int;
    end loop;

    -- adicionar
    select coalesce(max(ordem), 0) into v_max from public.orcamento_itens where orcamento_id = v_alvo;
    insert into public.orcamento_itens (
      orcamento_id, ordem, procedimento_id, descricao, explicacao, dente, faces, regiao, quantidade,
      valor_unitario, fase, alternativa, marca_id, observacao)
    select v_alvo, v_max + t.ord::int, (x ->> 'procedimento_id')::uuid, x ->> 'descricao', x ->> 'explicacao',
           (x ->> 'dente')::smallint, x ->> 'faces', x ->> 'regiao', (x ->> 'quantidade')::int,
           (x ->> 'valor_unitario')::numeric, (x ->> 'fase')::smallint, x ->> 'alternativa',
           (x ->> 'marca_id')::uuid, x ->> 'observacao'
      from jsonb_array_elements(v_novos) with ordinality t(x, ord);

    -- cabeçalho do orçamento
    if p_dados ? 'desconto_percentual' or p_dados ? 'desconto_valor' or coalesce((p_dados ->> 'sem_desconto')::boolean, false) then
      if coalesce((p_dados ->> 'sem_desconto')::boolean, false) then
        update public.orcamentos set desconto_tipo = null, desconto_valor = 0 where id = v_alvo;
      else
        select * into v_desc from public.orcamento_desconto(p_dados);
        update public.orcamentos set desconto_tipo = v_desc.tipo, desconto_valor = coalesce(v_desc.valor, 0)
         where id = v_alvo;
      end if;
    end if;
    if p_dados ? 'validade_dias' then
      v_validade := public.documentos_ler_numero(p_dados ->> 'validade_dias', 'Validade (dias)');
      if v_validade is null or v_validade <> trunc(v_validade) or v_validade not between 1 and 180 then
        raise exception 'Validade de % dias fora do esperado (1 a 180).', p_dados ->> 'validade_dias';
      end if;
      update public.orcamentos
         set validade = coalesce(apresentado_em, (criado_em at time zone public.fuso())::date) + v_validade::int
       where id = v_alvo;
    end if;
    update public.orcamentos
       set pagamento = public.orcamento_condicoes(pagamento, p_dados -> 'pagamento'),
           titulo = coalesce(nullif(btrim(p_dados ->> 'titulo'), ''), titulo),
           observacoes = case when p_dados ? 'observacoes' then nullif(btrim(p_dados ->> 'observacoes'), '')
                              else observacoes end
     where id = v_alvo;

    if not exists (select 1 from public.orcamento_itens where orcamento_id = v_alvo and status <> 'cancelado') then
      raise exception 'O orçamento ficaria sem itens. Para desistir dele, use acao recusar.';
    end if;
    o.id := v_alvo;
    v_doc := true;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'acao', v_acao,
    'orcamento', public.orcamento_json(o.id),
    'documento', case when v_doc then public.orcamento_documento(o.id) end,
    'avisos', to_jsonb(v_avisos)));
end
$$;
create or replace function public.orcamento_json(p_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  o public.orcamentos;
  v_cfg public.documentos_config;
  v_status text;
  v_alts text[];
  v_alt text;
  v_opcoes jsonb := '[]';
  v_itens jsonb;
  v_fases jsonb;
  v_alternativas jsonb;
  v_acomp jsonb;
  v_datas date[];
  v_feitos int;
  v_prox date;
  v_ant public.orcamentos;
begin
  select * into o from public.orcamentos where id = p_id;
  if not found then
    return null;
  end if;
  select * into v_cfg from public.documentos_config;
  v_status := case when o.status = 'apresentado' and o.validade < public.hoje() then 'expirado' else o.status end;

  select coalesce(array_agg(distinct i.alternativa order by i.alternativa), '{}') into v_alts
    from public.orcamento_itens i
   where i.orcamento_id = p_id and i.alternativa is not null and public.orcamento_item_conta(o.status, i.status);

  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'ordem', i.ordem,
           'descricao', i.descricao,
           'explicacao', i.explicacao,
           'local', public.orcamento_local(i.dente, i.faces, i.regiao),
           'dente', i.dente,
           'faces', i.faces,
           'regiao', i.regiao,
           'quantidade', i.quantidade,
           'valor_unitario', i.valor_unitario,
           'valor_total', i.quantidade * i.valor_unitario,
           'fase', i.fase,
           'alternativa', i.alternativa,
           'status', i.status,
           'conta', public.orcamento_item_conta(o.status, i.status),
           'procedimento_codigo', p.codigo,
           'do_odontograma', case when i.marca_id is not null then true end,
           'realizado_em', i.realizado_em,
           'observacao', i.observacao)) order by i.fase, i.alternativa nulls first, i.ordem)
    into v_itens
    from public.orcamento_itens i
    left join public.procedimentos p on p.id = i.procedimento_id
   where i.orcamento_id = p_id and i.status <> 'cancelado';

  -- Fases: com alternativas em aberto, só os itens comuns; as opções vêm à parte.
  select jsonb_agg(jsonb_build_object('fase', f.fase, 'nome', public.orcamento_fase_nome(f.fase),
                                      'subtotal', f.subtotal) order by f.fase)
    into v_fases
    from (select i.fase, sum(i.quantidade * i.valor_unitario) as subtotal
            from public.orcamento_itens i
           where i.orcamento_id = p_id and public.orcamento_item_conta(o.status, i.status)
             and (cardinality(v_alts) <= 1 or i.alternativa is null)
           group by i.fase) f;

  if cardinality(v_alts) <= 1 then
    v_opcoes := jsonb_build_array(public.orcamento_opcao(o, null,
      (select sum(i.quantidade * i.valor_unitario) from public.orcamento_itens i
        where i.orcamento_id = p_id and public.orcamento_item_conta(o.status, i.status))));
  else
    select jsonb_agg(jsonb_build_object('alternativa', a.alternativa, 'subtotal', a.subtotal) order by a.alternativa)
      into v_alternativas
      from (select i.alternativa, sum(i.quantidade * i.valor_unitario) as subtotal
              from public.orcamento_itens i
             where i.orcamento_id = p_id and i.alternativa is not null
               and public.orcamento_item_conta(o.status, i.status)
             group by i.alternativa) a;
    foreach v_alt in array v_alts loop
      v_opcoes := v_opcoes || jsonb_build_array(public.orcamento_opcao(o, v_alt,
        (select sum(i.quantidade * i.valor_unitario) from public.orcamento_itens i
          where i.orcamento_id = p_id and public.orcamento_item_conta(o.status, i.status)
            and (i.alternativa is null or i.alternativa = v_alt))));
    end loop;
  end if;

  if v_status in ('apresentado', 'expirado') and o.apresentado_em is not null then
    v_datas := array(select o.apresentado_em + d from unnest(v_cfg.acompanhamento_dias) d order by d);
    v_feitos := jsonb_array_length(o.acompanhamentos);
    v_prox := case when v_feitos < cardinality(v_datas) then v_datas[v_feitos + 1] end;
    v_acomp := jsonb_strip_nulls(jsonb_build_object(
      'proximo_contato', v_prox,
      'em_atraso', case when v_prox is not null then v_prox <= public.hoje() end,
      'roteiro', to_jsonb(v_datas),
      'contatos', case when v_feitos > 0 then o.acompanhamentos end));
  elsif jsonb_array_length(o.acompanhamentos) > 0 then
    v_acomp := jsonb_build_object('contatos', o.acompanhamentos);
  end if;

  if o.substitui_id is not null then
    select * into v_ant from public.orcamentos where id = o.substitui_id;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'id', o.id,
    'numero', o.numero,
    'versao', o.versao,
    'rotulo', 'Orçamento nº ' || o.numero || case when o.versao > 1 then ' (versão ' || o.versao || ')' else '' end,
    'titulo', o.titulo,
    'status', v_status,
    'status_texto', public.orcamento_status_texto(v_status),
    'emitido_em', (o.criado_em at time zone public.fuso())::date,
    'validade', o.validade,
    'dias_para_vencer', case when v_status in ('rascunho', 'apresentado') then o.validade - public.hoje() end,
    'paciente', public.documentos_paciente(o.paciente_id),
    'cabecalho', public.documentos_cabecalho(),
    'profissional', o.profissional,
    'cro', o.cro,
    'itens', coalesce(v_itens, '[]'),
    'fases', coalesce(v_fases, '[]'),
    'alternativas', v_alternativas,
    'opcoes', v_opcoes,
    'total', case when jsonb_array_length(v_opcoes) = 1 then v_opcoes -> 0 -> 'total' end,
    'desconto', case when o.desconto_tipo is not null then
                  jsonb_build_object('tipo', o.desconto_tipo, 'valor', o.desconto_valor) end,
    'condicoes', o.pagamento,
    'apresentado_em', o.apresentado_em,
    'aprovacao', o.aprovacao,
    'aprovado_em', o.aprovado_em,
    'forma_escolhida', o.forma_escolhida,
    'recusado_em', o.recusado_em,
    'motivo_recusa', o.motivo_recusa,
    'concluido_em', o.concluido_em,
    'acompanhamento', v_acomp,
    'campanha', (select jsonb_build_object('nome', c.nome, 'periodo', public.campanha_periodo(c), 'local', coalesce(c.local, c.cidade))
                   from public.campanhas c where c.id = o.campanha_id),
    'observacoes', o.observacoes,
    'substitui', case when v_ant.id is not null then
                   jsonb_build_object('numero', v_ant.numero, 'versao', v_ant.versao) end));
end
$$;

-- ---------------------------------------------------------------------
-- Agenda: dias de campanha (local na confirmação, sem cobrar reserva de sala)
-- ---------------------------------------------------------------------

create or replace function public.link_confirmacao(p_consulta uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select 'https://wa.me/' || (select case when length(d) in (10, 11) then '55' || d else d end
                                from regexp_replace(public.telefone_contato(c.paciente_id), '\D', '', 'g') as d)
         || '?text=' || public.urlencode(format(
           'Olá, %s! Aqui é da %s. Passando para confirmar sua consulta %s, %s, às %s, na %s. Posso confirmar?',
           coalesce(nullif(btrim(p.apelido), ''), split_part(p.nome, ' ', 1)),
           coalesce(cfg.dentista_nome, 'Dra. Andressa'),
           case public.data_local(c.inicio) - public.hoje()
             when 0 then 'hoje' when 1 then 'amanhã'
             else public.dia_semana(public.data_local(c.inicio)) end,
           to_char(c.inicio at time zone public.fuso(), 'DD/MM'),
           public.hora_local(c.inicio),
           coalesce((select coalesce(x.local, x.cidade) from public.campanha_na_data(public.data_local(c.inicio)) x),
                    cfg.endereco, 'clínica')))
    from public.consultas c
    join public.pacientes p on p.id = c.paciente_id
    left join public.configuracao cfg on true
   where c.id = p_consulta
     and public.telefone_contato(c.paciente_id) is not null
$$;
create or replace function public.consulta_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', c.id,
    'data', public.data_local(c.inicio),
    'dia_semana', public.dia_semana(public.data_local(c.inicio)),
    'inicio', public.hora_local(c.inicio),
    'fim', public.hora_local(c.fim),
    'duracao_min', (extract(epoch from c.fim - c.inicio) / 60)::int,
    'status', c.status,
    'paciente', jsonb_strip_nulls(jsonb_build_object(
      'id', p.id, 'nome', p.nome, 'apelido', p.apelido,
      'telefone', public.telefone_contato(p.id),
      'alertas_saude', nullif(p.alertas_saude, '[]'::jsonb),
      'primeira_vez', case when not exists (select 1 from public.atendimentos a where a.paciente_id = p.id)
                           then true end)),
    'motivo', c.motivo,
    'procedimento', pr.codigo,
    'observacao', c.observacao,
    'motivo_status', c.motivo_status,
    'remarcada_de', c.remarcada_de,
    'remarcada_para', c.remarcada_para,
    'atendimento_id', c.atendimento_id,
    'campanha', (select x.nome from public.campanha_na_data(public.data_local(c.inicio)) x),
    'sala_reservada', case when c.status in ('agendada', 'confirmada')
                            and (select x.id from public.campanha_na_data(public.data_local(c.inicio)) x) is null then exists (
      select 1 from public.reservas_sala r
       where r.cancelada_em is null and r.inicio <= c.inicio and r.fim >= c.fim) end))
  from public.consultas c
  join public.pacientes p on p.id = c.paciente_id
  left join public.procedimentos pr on pr.id = c.procedimento_id
  where c.id = p_id
$$;
create or replace function public.consulta_avisos(p_id uuid)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  c public.consultas;
  v_avisos text[] := '{}';
  v_outra record;
  v_camp public.campanhas;
begin
  select * into c from public.consultas where id = p_id;
  if c.status not in ('agendada', 'confirmada') then return v_avisos; end if;
  v_camp := public.campanha_na_data(public.data_local(c.inicio));
  if v_camp.id is not null then
    v_avisos := array_append(v_avisos, format('Dia da %s%s: a confirmação leva o local da campanha.',
      v_camp.nome, ' (' || coalesce(v_camp.local, v_camp.cidade) || ')'));
  elsif not exists (select 1 from public.reservas_sala r
                  where r.cancelada_em is null and r.inicio <= c.inicio and r.fim >= c.fim) then
    v_avisos := array_append(v_avisos, format(
      'A sala ainda não está reservada para %s (%s), das %s às %s. Se já reservou, registre com reservar_sala.',
      to_char(c.inicio at time zone public.fuso(), 'DD/MM'), public.dia_semana(public.data_local(c.inicio)),
      public.hora_local(c.inicio), public.hora_local(c.fim)));
  end if;
  select o.inicio into v_outra from public.consultas o
   where o.paciente_id = c.paciente_id and o.id <> c.id
     and o.status in ('agendada', 'confirmada') and o.inicio > now()
   order by o.inicio limit 1;
  if found then
    v_avisos := array_append(v_avisos, format('O paciente já tem outra consulta marcada em %s às %s.',
      to_char(v_outra.inicio at time zone public.fuso(), 'DD/MM'), public.hora_local(v_outra.inicio)));
  end if;
  if extract(hour from c.inicio at time zone public.fuso()) < 7
     or (c.fim at time zone public.fuso())::time > time '22:00'
     or public.data_local(c.fim) <> public.data_local(c.inicio) then
    v_avisos := array_append(v_avisos, 'Horário fora do comum: confirme com a Dra.');
  end if;
  if extract(isodow from public.data_local(c.inicio)) = 7 then
    v_avisos := array_append(v_avisos, 'A consulta cai num domingo.');
  end if;
  if public.telefone_contato(c.paciente_id) is null then
    v_avisos := array_append(v_avisos, 'Sem telefone na ficha: não dá para mandar a confirmação por WhatsApp.');
  end if;
  return v_avisos;
end
$$;
create or replace function public.agenda_dia_json(p_data date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'data', p_data,
    'dia_semana', public.dia_semana(p_data),
    'reservas_sala', (select jsonb_agg(public.reserva_json(r) order by r.inicio)
                        from public.reservas_sala r
                       where r.cancelada_em is null and public.data_local(r.inicio) = p_data),
    'consultas', (select jsonb_agg(public.consulta_json(c.id) order by c.inicio)
                    from public.consultas c
                   where public.data_local(c.inicio) = p_data
                     and c.status not in ('remarcada')),
    'horarios_livres', nullif(public.horarios_livres(p_data), '[]'::jsonb),
    'campanha', (select public.campanha_json(x) from public.campanha_na_data(p_data) x where x.id is not null),
    'mensagem', case when (select x.id from public.campanha_na_data(p_data) x) is null and not exists (select 1 from public.reservas_sala r
                                       where r.cancelada_em is null and public.data_local(r.inicio) = p_data)
                     then 'Sem reserva de sala neste dia.' end))
$$;

-- ---------------------------------------------------------------------
-- Catálogo: preço da campanha de hoje ao lado do normal
-- ---------------------------------------------------------------------

create or replace function public.mcp_listar_procedimentos(
  p_busca text default null,
  p_categoria text default null,
  p_incluir_inativos boolean default false,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_t text := nullif(public.normalizar(p_busca), '');
  v_lista jsonb;
  v_camp public.campanhas := public.campanha_na_data(public.hoje());
begin
  perform public.iniciar_solicitacao('listar_procedimentos',
    jsonb_strip_nulls(jsonb_build_object('busca', p_busca, 'categoria', p_categoria,
                                         'incluir_inativos', p_incluir_inativos)),
    p_texto_original);

  select coalesce(jsonb_agg(public.procedimento_json(p)
                            || case when cp.preco is not null then jsonb_build_object('preco_campanha', cp.preco) else '{}'::jsonb end
                            order by p.ordem, p.nome), '[]'::jsonb)
    into v_lista
    from public.procedimentos p
    left join public.campanha_precos cp on cp.campanha_id = v_camp.id and cp.procedimento_id = p.id
   where (coalesce(p_incluir_inativos, false) or p.ativo)
     and (p_categoria is null or p.categoria = public.normalizar(p_categoria))
     and (v_t is null
          or public.normalizar(p.nome) like '%' || v_t || '%'
          or p.codigo like '%' || replace(v_t, ' ', '_') || '%'
          or public.normalizar(p.grupo) like '%' || v_t || '%'
          or exists (select 1 from unnest(p.sinonimos) s where s like '%' || v_t || '%'));

  return jsonb_strip_nulls(jsonb_build_object(
    'campanha_hoje', case when v_camp.id is not null then
      format('%s (%s): preco_campanha vale nos orçamentos de hoje.', v_camp.nome, public.campanha_periodo(v_camp)) end,
    'total', jsonb_array_length(v_lista),
    'procedimentos', v_lista,
    'mensagem', case when jsonb_array_length(v_lista) = 0
                     then format('Nada no catálogo para "%s". Para incluir, use salvar_procedimento.', p_busca) end));
end
$$;

-- ---------------------------------------------------------------------
-- Financeiro: imposto da calculadora
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
    'imposto_percentual', c.imposto_percentual,
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
  if p_dados ? 'imposto_percentual' then
    v_new.imposto_percentual := public.fin_valor(p_dados ->> 'imposto_percentual', 'Imposto');
    if v_new.imposto_percentual is null or v_new.imposto_percentual < 0 or v_new.imposto_percentual > 50 then
      raise exception 'Imposto: percentual de 0 a 50 (ex.: 6).';
    end if;
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
         cnpj = v_new.cnpj, observacoes = v_new.observacoes, taxas = v_new.taxas,
         imposto_percentual = v_new.imposto_percentual
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