-- =====================================================================
-- Ferramentas MCP do estoque: registrar_compra, movimentar_estoque,
-- ver_estoque e salvar_material (com kit). Cada uma é uma transação:
-- erro = nada gravado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Linhas de kit também não se apagam: tirar uma linha marca removido_em
-- (e voltar com ela limpa a marca).
-- ---------------------------------------------------------------------
alter table public.estoque_kit_itens add column if not exists removido_em timestamptz;
comment on column public.estoque_kit_itens.removido_em is 'Linha tirada do kit (fica no histórico). Só valem as linhas com removido_em vazio.';
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'estoque_kit_itens_sem_exclusao'
                    and tgrelid = 'public.estoque_kit_itens'::regclass) then
    create trigger estoque_kit_itens_sem_exclusao before delete on public.estoque_kit_itens
      for each statement execute function public.estoque_bloquear_exclusao();
  end if;
end
$$;

create or replace function public.estoque_baixa_kit(
  p_kit uuid,
  p_materiais jsonb,
  p_contexto text,
  p_contexto2 text,
  p_data date,
  p_atendimento uuid,
  p_item uuid,
  p_paciente uuid)
returns int
language plpgsql
set search_path = ''
as $$
declare
  k record;
  v_mat uuid;
  v_grupo text;
  v_ids uuid[];
  v_grupos text[];
  v_n int := 0;
begin
  select coalesce(array_agg(c.material_id), '{}'), coalesce(array_agg(c.grupo) filter (where c.grupo is not null), '{}')
    into v_ids, v_grupos
    from public.estoque_citados(p_materiais) c;
  for k in select ki.material_id, ki.grupo, ki.quantidade from public.estoque_kit_itens ki
            where ki.kit_id = p_kit and ki.removido_em is null
  loop
    v_mat := coalesce(k.material_id, public.estoque_material_do_grupo(k.grupo, p_contexto, p_contexto2));
    continue when v_mat is null;
    select grupo into v_grupo from public.estoque_materiais where id = v_mat and ativo;
    continue when not found;
    continue when v_mat = any(v_ids) or (v_grupo is not null and v_grupo = any(v_grupos));
    perform public.estoque_saida(v_mat, k.quantidade, 'uso_atendimento', p_data, p_atendimento, p_item, p_paciente, null);
    v_n := v_n + 1;
  end loop;
  return v_n;
end
$$;

create or replace function public.custo_materiais_detalhe(p_procedimento_id uuid, p_incluir_base boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with k as (
    select id, anestesia_tubetes from public.estoque_kits
     where ativo and ((p_procedimento_id is not null and procedimento_id = p_procedimento_id)
                      or (p_incluir_base and base))),
  l as (
    select ki.quantidade q, coalesce(ki.material_id, public.estoque_material_do_grupo(ki.grupo)) mid, ki.grupo
      from public.estoque_kit_itens ki join k on k.id = ki.kit_id
     where ki.removido_em is null
    union all
    select k.anestesia_tubetes, public.estoque_anestesico_padrao(), null from k where k.anestesia_tubetes > 0
    union all
    select 1, (select id from public.estoque_materiais where codigo = 'agulha_curta_30g'), null
      from k where k.anestesia_tubetes > 0),
  d as (
    select m.nome, m.codigo, l.grupo, sum(l.q) q, m.unidade_uso, m.unidade_compra, m.fator, m.custo_medio
      from l join public.estoque_materiais m on m.id = l.mid
     group by m.id, l.grupo)
  select jsonb_build_object(
    'custo_total', coalesce(round(sum(d.q * coalesce(d.custo_medio, 0)), 2), 0),
    'itens', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'material', d.nome, 'codigo', d.codigo, 'grupo', d.grupo,
        'quantidade', public.estoque_qtd(d.unidade_uso, d.unidade_compra, d.fator, d.q),
        'custo', round(d.q * d.custo_medio, 2))) order by d.q * coalesce(d.custo_medio, 0) desc, d.nome), '[]'::jsonb),
    'sem_custo', coalesce(jsonb_agg(d.nome order by d.nome) filter (where d.custo_medio is null), '[]'::jsonb))
  from d
$$;

-- ---------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------

-- Número vindo do JSON (aceita "2,5" e "R$ 180").
create or replace function public.estoque_numero(p jsonb, p_campo text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p) = 'number' then
    return (p #>> '{}')::numeric;
  end if;
  if jsonb_typeof(p) = 'string' then
    begin
      return replace(regexp_replace(btrim(p #>> '{}'), '^R\$\s*', ''), ',', '.')::numeric;
    exception when others then
      null;
    end;
  end if;
  raise exception '% "%" inválido: use só o número (ex.: 180 ou 2,5).', p_campo, p #>> '{}';
end
$$;

-- Validade: AAAA-MM-DD, AAAA-MM ou MM/AAAA (mês e ano valem até o fim do mês).
create or replace function public.estoque_validade(p text, p_campo text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := nullif(btrim(p), '');
begin
  if v is null then
    return null;
  end if;
  if v ~ '^\d{4}-\d{1,2}$' then
    return (to_date(v || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date;
  end if;
  if v ~ '^\d{1,2}/\d{4}$' then
    return (to_date('01/' || v, 'DD/MM/YYYY') + interval '1 month' - interval '1 day')::date;
  end if;
  return public.ler_data(v, p_campo);
end
$$;

-- Preço unitário pequeno com mais casas (R$ 0,0072 por gota).
create or replace function public.estoque_preco(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p is null then null
    when p >= 1 then public.estoque_reais(p)
    else 'R$ ' || replace(rtrim(rtrim(round(p, 4)::text, '0'), '.'), '.', ',') end
$$;

create or replace function public.estoque_lote(p_material uuid, p_lote text, p_validade date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_lote text := nullif(btrim(p_lote), '');
  v_id uuid;
begin
  if v_lote is null and p_validade is null then
    return null;
  end if;
  select id into v_id from public.estoque_lotes
   where material_id = p_material
     and coalesce(public.normalizar(lote), '') = coalesce(public.normalizar(v_lote), '')
     and coalesce(validade, 'infinity'::date) = coalesce(p_validade, 'infinity'::date);
  if v_id is null then
    insert into public.estoque_lotes (material_id, lote, validade) values (p_material, v_lote, p_validade)
    returning id into v_id;
  end if;
  return v_id;
end
$$;

-- Material pelo texto, ou erro com os nomes parecidos.
create or replace function public.estoque_material_ou_erro(p_texto text)
returns public.estoque_materiais
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid := public.estoque_achar_material(p_texto);
  v public.estoque_materiais;
  v_sug text[];
begin
  if coalesce(btrim(p_texto), '') = '' then
    raise exception 'Informe o material.';
  end if;
  if v_id is null then
    v_sug := public.estoque_sugestoes(p_texto);
    raise exception using
      message = format('Material "%s" não encontrado no estoque%s.', p_texto,
                       case when cardinality(v_sug) > 0 then '. Parecidos: ' || array_to_string(v_sug, '; ') else '' end),
      hint = 'Use um dos nomes do cadastro. Se for material novo, cadastre antes com salvar_material.';
  end if;
  select * into v from public.estoque_materiais where id = v_id;
  return v;
end
$$;

create or replace function public.estoque_achar_procedimento(p_texto text)
returns public.procedimentos
language plpgsql
stable
set search_path = ''
as $$
declare
  v public.procedimentos;
begin
  select * into v from public.procedimentos
   where codigo = public.codigo_de(p_texto)
      or public.normalizar(nome) = public.normalizar(p_texto)
      or public.normalizar(p_texto) = any(sinonimos)
   order by (codigo = public.codigo_de(p_texto)) desc, ativo desc
   limit 1;
  if v.id is null then
    raise exception using
      message = format('Procedimento "%s" não está no catálogo.', p_texto),
      hint = 'Use o procedimento_codigo de listar_procedimentos (ex.: resina_2_faces), ou atendimento_base para o kit de todo atendimento.';
  end if;
  return v;
end
$$;

create or replace function public.estoque_material_json(m public.estoque_materiais)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'codigo', m.codigo,
    'nome', m.nome,
    'categoria', m.categoria,
    'grupo', m.grupo,
    'padrao_do_grupo', case when m.padrao_do_grupo then true end,
    'embalagem', format('1 %s = %s %s', m.unidade_compra, public.estoque_num(m.fator),
                        public.estoque_plural(m.unidade_uso, m.fator)),
    'unidade_compra', m.unidade_compra,
    'unidade_uso', m.unidade_uso,
    'fator', m.fator,
    'saldo', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, public.estoque_saldo(m.id)),
    'saldo_registrado', public.estoque_acompanhado(m.id),
    'estoque_minimo', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, m.estoque_minimo),
    'prazo_entrega_dias', m.prazo_entrega_dias,
    'custo_medio', case when m.custo_medio is not null then
      format('%s por %s (%s por %s)', public.estoque_preco(m.custo_medio), m.unidade_uso,
             public.estoque_reais(m.custo_medio * m.fator), m.unidade_compra) end,
    'controla_validade', m.controla_validade,
    'sinonimos', m.sinonimos,
    'variantes', nullif(m.variantes, '{}'),
    'ativo', m.ativo,
    'observacao', m.observacao))
$$;

create or replace function public.estoque_compra_json(p_compra uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', c.id,
    'data', c.data,
    'fornecedor', f.nome,
    'nota_fiscal', c.nota_fiscal,
    'valor_itens', c.valor_itens,
    'frete', nullif(c.frete, 0),
    'desconto', nullif(c.desconto, 0),
    'valor_total', c.valor_total,
    'forma_pagamento', c.forma_pagamento,
    'cancelada_em', c.cancelada_em,
    'motivo_cancelamento', c.motivo_cancelamento,
    'itens', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'material', m.nome,
                'quantidade', public.estoque_num(i.quantidade_informada) || ' '
                              || public.estoque_plural(i.unidade_informada, i.quantidade_informada),
                'entrou', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, i.quantidade_uso),
                'preco_total', i.preco_total,
                'custo_por_' || public.codigo_de(m.unidade_compra), round(i.custo_unitario_uso * m.fator, 2),
                'lote', l.lote,
                'validade', l.validade)) order by i.ordem)
                from public.estoque_compra_itens i
                join public.estoque_materiais m on m.id = i.material_id
                left join public.estoque_lotes l on l.id = i.lote_id
               where i.compra_id = c.id)))
  from public.estoque_compras c
  left join public.estoque_fornecedores f on f.id = c.fornecedor_id
 where c.id = p_compra
$$;

create or replace function public.estoque_kit_json(p_kit uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'kit', k.nome,
    'procedimento_codigo', coalesce(p.codigo, case when k.base then 'atendimento_base' end),
    'ativo', k.ativo,
    'anestesia_tubetes_estimativa', nullif(k.anestesia_tubetes, 0),
    'itens', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'material', coalesce(m.nome, 'grupo ' || ki.grupo || ' (cor/tamanho pelo atendimento; padrão: '
                                             || coalesce(pm.nome, '?') || ')'),
                'quantidade', public.estoque_qtd(coalesce(m.unidade_uso, pm.unidade_uso), coalesce(m.unidade_compra, pm.unidade_compra),
                                                 coalesce(m.fator, pm.fator), ki.quantidade)))
                order by coalesce(m.nome, pm.nome)), '[]'::jsonb)
                from public.estoque_kit_itens ki
                left join public.estoque_materiais m on m.id = ki.material_id
                left join public.estoque_materiais pm on pm.id = public.estoque_material_do_grupo(ki.grupo)
               where ki.kit_id = k.id and ki.removido_em is null),
    'custo_estimado', case when k.ativo then
      (public.custo_materiais_detalhe(k.procedimento_id, k.base) - 'itens') end))
  from public.estoque_kits k
  left join public.procedimentos p on p.id = k.procedimento_id
 where k.id = p_kit
$$;

-- Fornecedor pelo nome dito ("Cremer" acha "Dental Cremer"); cria se não existe.
create or replace function public.estoque_fornecedor(p_nome text, out p_id uuid, out p_novo boolean)
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
  v_nomes text[];
  v_nome text := nullif(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')), '');
begin
  p_novo := false;
  if v_nome is null then
    return;
  end if;
  select id into p_id from public.estoque_fornecedores where public.normalizar(nome) = public.normalizar(v_nome);
  if p_id is not null then
    return;
  end if;
  select array_agg(id), array_agg(nome order by nome) into v_ids, v_nomes
    from public.estoque_fornecedores f
   where cardinality(public.estoque_palavras(v_nome)) > 0
     and (public.estoque_palavras(v_nome) <@ public.estoque_palavras(f.nome)
          or public.estoque_palavras(f.nome) <@ public.estoque_palavras(v_nome));
  if cardinality(v_ids) = 1 then
    p_id := v_ids[1];
    return;
  end if;
  if cardinality(v_ids) > 1 then
    raise exception 'Fornecedor "%" pode ser: %. Diga qual.', v_nome, array_to_string(v_nomes, ', ');
  end if;
  insert into public.estoque_fornecedores (nome) values (v_nome) returning id into p_id;
  p_novo := true;
end
$$;

-- ---------------------------------------------------------------------
-- registrar_compra
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_compra(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_data date;
  v_itens jsonb := coalesce(p_dados -> 'itens', '[]'::jsonb);
  v_item jsonb;
  v_linha jsonb;
  v_linhas jsonb := '[]'::jsonb;
  v_m public.estoque_materiais;
  v_mid uuid;
  v_faltam text[] := '{}';
  v_sug text[];
  v_avisos text[] := '{}';
  v_q numeric;
  v_qu numeric;
  v_pu numeric;
  v_pt numeric;
  v_val date;
  v_soma numeric := 0;
  v_com_preco int := 0;
  v_frete numeric;
  v_desc numeric;
  v_total_inf numeric;
  v_total numeric;
  v_rateio numeric := 1;
  v_forma text := nullif(replace(public.normalizar(p_dados ->> 'forma_pagamento'), ' ', '_'), '');
  v_forn uuid;
  v_forn_novo boolean;
  v_compra uuid;
  v_ci uuid;
  v_lote uuid;
  v_custo numeric;
  v_ult numeric;
  v_ord int := 0;
  v_ids uuid[] := '{}';
begin
  perform public.iniciar_solicitacao('registrar_compra', p_dados, p_texto_original);

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data da compra'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data da compra (%) está no futuro.', to_char(v_data, 'DD/MM/YYYY');
  end if;
  if jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then
    raise exception 'Informe os itens da compra: material, quantidade, unidade e preço (unitário ou total).';
  end if;
  v_frete := coalesce(public.estoque_numero(p_dados -> 'frete', 'Frete'), 0);
  v_desc := coalesce(public.estoque_numero(p_dados -> 'desconto', 'Desconto'), 0);
  v_total_inf := public.estoque_numero(p_dados -> 'valor_total', 'Valor total');
  if v_frete < 0 or v_desc < 0 or v_total_inf < 0 then
    raise exception 'Frete, desconto e total não podem ser negativos.';
  end if;
  if v_forma is not null then
    v_forma := case
      when v_forma ~ 'parcel' then 'credito_parcelado'
      when v_forma ~ 'credito' or v_forma = 'cartao' then 'credito_vista'
      when v_forma ~ 'debito' then 'debito'
      when v_forma ~ 'pix' then 'pix'
      when v_forma ~ 'boleto' then 'boleto'
      when v_forma ~ 'dinheiro|especie' then 'dinheiro'
      when v_forma ~ 'transfer|ted|doc' then 'transferencia'
      else v_forma end;
    if v_forma not in ('pix', 'dinheiro', 'debito', 'credito_vista', 'credito_parcelado', 'boleto', 'transferencia') then
      raise exception 'Forma de pagamento "%" inválida: use pix, dinheiro, debito, credito_vista, credito_parcelado, boleto ou transferencia.',
        p_dados ->> 'forma_pagamento';
    end if;
  end if;

  -- 1ª passada: acha todos os materiais e confere quantidades e preços
  for v_item in select * from jsonb_array_elements(v_itens) loop
    v_ord := v_ord + 1;
    v_mid := public.estoque_achar_material(v_item ->> 'material');
    if v_mid is null then
      v_sug := public.estoque_sugestoes(v_item ->> 'material');
      v_faltam := v_faltam || format('"%s"%s', coalesce(v_item ->> 'material', '?'),
                                     case when cardinality(v_sug) > 0
                                          then ' (parecidos: ' || array_to_string(v_sug, '; ') || ')' else '' end);
      continue;
    end if;
    select * into v_m from public.estoque_materiais where id = v_mid;
    v_q := public.estoque_numero(v_item -> 'quantidade', format('Quantidade de %s', v_m.nome));
    if v_q is null or v_q <= 0 then
      raise exception 'Informe a quantidade comprada de % (maior que zero).', v_m.nome;
    end if;
    v_qu := public.estoque_para_uso(v_m, v_q, v_item ->> 'unidade', 'compra');
    v_pu := public.estoque_numero(v_item -> 'preco_unitario', format('Preço unitário de %s', v_m.nome));
    v_pt := public.estoque_numero(v_item -> 'preco_total', format('Preço total de %s', v_m.nome));
    if v_pu < 0 or v_pt < 0 then
      raise exception 'Preço de % não pode ser negativo.', v_m.nome;
    end if;
    if v_pt is not null and v_pu is not null and abs(v_pt - v_pu * v_q) > 0.05 then
      v_avisos := v_avisos || format('%s: o total (%s) não bate com %s × %s; ficou o total.', v_m.nome,
                                     public.estoque_reais(v_pt), public.estoque_num(v_q), public.estoque_reais(v_pu));
    end if;
    v_pt := coalesce(v_pt, round(v_pu * v_q, 2));
    v_val := public.estoque_validade(v_item ->> 'validade', format('Validade de %s', v_m.nome));
    if v_val is not null and v_val < v_data then
      raise exception 'A validade de % (%) é anterior à compra: confira.', v_m.nome, to_char(v_val, 'DD/MM/YYYY');
    end if;
    v_linhas := v_linhas || jsonb_build_object(
      'mid', v_mid, 'q', v_q, 'u', coalesce(nullif(btrim(v_item ->> 'unidade'), ''), v_m.unidade_compra),
      'qu', v_qu, 'pt', v_pt, 'val', v_val, 'lote', nullif(btrim(v_item ->> 'lote'), ''), 'ordem', v_ord);
    v_soma := v_soma + coalesce(v_pt, 0);
    if v_pt is not null then
      v_com_preco := v_com_preco + 1;
    end if;
  end loop;
  if cardinality(v_faltam) > 0 then
    raise exception using
      message = format('Material não encontrado no estoque: %s. Nada foi gravado da compra.', array_to_string(v_faltam, '; ')),
      hint = 'Use os nomes do cadastro, ou cadastre o material novo com salvar_material (categoria, unidade de compra, unidade de uso e fator) e registre a compra de novo.';
  end if;

  -- Um item só, sem preço, e o total da nota informado: o item vale o total.
  if v_com_preco = 0 and v_total_inf is not null and jsonb_array_length(v_linhas) = 1 then
    v_pt := v_total_inf - v_frete + v_desc;
    v_linhas := jsonb_build_array(jsonb_set(v_linhas -> 0, '{pt}', to_jsonb(v_pt)));
    v_soma := v_pt;
    v_com_preco := 1;
  end if;
  v_total := v_soma + v_frete - v_desc;
  if v_total < 0 then
    raise exception 'O desconto (%) é maior que o valor dos itens.', public.estoque_reais(v_desc);
  end if;
  if v_total_inf is not null and v_com_preco > 0 and abs(v_total_inf - v_total) > 0.05 then
    v_avisos := v_avisos || format('O total informado (%s) não bate com a soma dos itens + frete − desconto (%s): confira a nota.',
                                   public.estoque_reais(v_total_inf), public.estoque_reais(v_total));
  end if;
  if v_soma > 0 and (v_frete > 0 or v_desc > 0) then
    v_rateio := (v_soma + v_frete - v_desc) / v_soma;
    v_avisos := array_append(v_avisos, 'Frete e desconto foram rateados no custo dos itens.'::text);
  end if;

  select f.p_id, f.p_novo into v_forn, v_forn_novo from public.estoque_fornecedor(p_dados ->> 'fornecedor') f;
  if v_forn_novo then
    v_avisos := v_avisos || format('Fornecedor novo cadastrado: %s.', btrim(p_dados ->> 'fornecedor'));
  elsif v_forn is null then
    v_avisos := array_append(v_avisos, 'Compra sem fornecedor.'::text);
  end if;

  insert into public.estoque_compras (fornecedor_id, data, nota_fiscal, valor_itens, frete, desconto, valor_total,
                                      forma_pagamento, observacao)
  values (v_forn, v_data, nullif(btrim(p_dados ->> 'nota_fiscal'), ''), round(v_soma, 2), v_frete, v_desc,
          round(coalesce(v_total_inf, v_total), 2), v_forma, nullif(btrim(p_dados ->> 'observacao'), ''))
  returning id into v_compra;

  -- 2ª passada: grava itens, lotes e entradas
  for v_linha in select * from jsonb_array_elements(v_linhas) loop
    select * into v_m from public.estoque_materiais where id = (v_linha ->> 'mid')::uuid;
    v_val := (v_linha ->> 'val')::date;
    v_lote := public.estoque_lote(v_m.id, v_linha ->> 'lote', v_val);
    v_custo := case when v_linha ->> 'pt' is not null
                    then round((v_linha ->> 'pt')::numeric * v_rateio / (v_linha ->> 'qu')::numeric, 6) end;

    select i.custo_unitario_uso into v_ult
      from public.estoque_compra_itens i
      join public.estoque_compras c on c.id = i.compra_id and c.cancelada_em is null
     where i.material_id = v_m.id and i.custo_unitario_uso is not null
     order by c.data desc, i.registrado_em desc
     limit 1;
    v_ult := coalesce(v_ult, v_m.custo_medio);
    if v_custo is not null and v_ult > 0 and v_custo > v_ult * 1.2 then
      v_avisos := v_avisos || format('%s: %s por %s, %s%% acima do custo anterior (%s).', v_m.nome,
                                     public.estoque_reais(v_custo * v_m.fator), v_m.unidade_compra,
                                     round((v_custo / v_ult - 1) * 100), public.estoque_reais(v_ult * v_m.fator));
    end if;
    if v_custo is null then
      v_avisos := v_avisos || format('%s sem preço: o custo médio não mudou.', v_m.nome);
    end if;
    if v_m.controla_validade and v_val is null then
      v_avisos := v_avisos || format('%s sem validade: informe para o sistema avisar antes de vencer.', v_m.nome);
    elsif v_val < public.hoje() + 60 then
      v_avisos := v_avisos || format('%s vence em %s (menos de 60 dias).', v_m.nome, to_char(v_val, 'DD/MM/YYYY'));
    end if;

    insert into public.estoque_compra_itens (compra_id, ordem, material_id, quantidade_informada, unidade_informada,
                                             quantidade_uso, preco_total, custo_unitario_uso, lote_id)
    values (v_compra, (v_linha ->> 'ordem')::int, v_m.id, (v_linha ->> 'q')::numeric, v_linha ->> 'u',
            (v_linha ->> 'qu')::numeric, (v_linha ->> 'pt')::numeric, v_custo, v_lote)
    returning id into v_ci;
    perform public.estoque_entrada(v_m.id, (v_linha ->> 'qu')::numeric, v_custo, v_lote, 'compra', v_ci, v_data, null);
    v_ids := v_ids || v_m.id;
  end loop;

  return jsonb_build_object(
    'status', 'registrada',
    'compra', public.estoque_compra_json(v_compra),
    'estoque', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'material', m.nome,
                  'saldo', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, public.estoque_saldo(m.id)),
                  'custo_medio', public.estoque_reais(m.custo_medio * m.fator) || ' por ' || m.unidade_compra))
                  order by m.nome)
                  from public.estoque_materiais m where m.id = any(v_ids)),
    'avisos', to_jsonb(v_avisos || public.estoque_avisos(v_ids, false)));
end
$$;

-- ---------------------------------------------------------------------
-- movimentar_estoque
-- ---------------------------------------------------------------------
create or replace function public.mcp_movimentar_estoque(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_data date;
  v_movs jsonb := coalesce(p_dados -> 'movimentos', '[]'::jsonb);
  v jsonb;
  v_tipo text;
  v_motivo text;
  v_m public.estoque_materiais;
  v_q numeric;
  v_qu numeric;
  v_pu numeric;
  v_pt numeric;
  v_custo numeric;
  v_saldo numeric;
  v_delta numeric;
  v_lote_txt text;
  v_val date;
  v_lote_id uuid;
  v_pac uuid;
  v_uuid uuid;
  v_r public.estoque_movimentos;
  v_c public.estoque_compras;
  v_n int;
  v_res jsonb := '[]'::jsonb;
  v_avisos text[] := '{}';
  v_ids uuid[] := '{}';
  v_lotes text;
begin
  perform public.iniciar_solicitacao('movimentar_estoque', p_dados, p_texto_original);

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data (%) está no futuro.', to_char(v_data, 'DD/MM/YYYY');
  end if;
  if jsonb_typeof(v_movs) <> 'array' or jsonb_array_length(v_movs) = 0 then
    raise exception 'Informe os movimentos: material, tipo (uso, perda, vencido, contagem, entrada, desfazer, cancelar_compra) e quantidade.';
  end if;

  for v in select * from jsonb_array_elements(v_movs) loop
    v_tipo := coalesce(nullif(replace(public.normalizar(v ->> 'tipo'), ' ', '_'), ''), 'uso');
    v_motivo := nullif(btrim(v ->> 'motivo'), '');
    if v_tipo not in ('uso', 'perda', 'vencido', 'contagem', 'entrada', 'desfazer', 'cancelar_compra') then
      raise exception 'Tipo "%" inválido: use uso, perda, vencido, contagem, entrada, desfazer ou cancelar_compra.', v ->> 'tipo';
    end if;

    -- Desfazer um movimento
    if v_tipo = 'desfazer' then
      if v_motivo is null then
        raise exception 'Para desfazer um movimento, diga o motivo.';
      end if;
      begin
        v_uuid := (v ->> 'movimento_id')::uuid;
      exception when others then
        v_uuid := null;
      end;
      if v_uuid is null then
        raise exception 'Informe o movimento_id (aparece em ver_estoque, visão material).';
      end if;
      select * into v_r from public.estoque_movimentos where id = v_uuid;
      if v_r.tipo = 'compra' then
        raise exception 'Esse movimento é de uma compra: para desfazer, cancele a compra (cancelar_compra com o compra_id).';
      end if;
      v_r := public.estoque_estornar(v_uuid, v_motivo);
      select * into v_m from public.estoque_materiais where id = v_r.material_id;
      v_res := v_res || jsonb_build_object(
        'tipo', 'desfazer', 'material', v_m.nome,
        'quantidade', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, v_r.quantidade),
        'saldo', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, public.estoque_saldo(v_m.id)));
      v_ids := v_ids || v_m.id;
      continue;
    end if;

    -- Cancelar uma compra inteira
    if v_tipo = 'cancelar_compra' then
      if v_motivo is null then
        raise exception 'Para cancelar uma compra, diga o motivo.';
      end if;
      begin
        v_uuid := (v ->> 'compra_id')::uuid;
      exception when others then
        v_uuid := null;
      end;
      select * into v_c from public.estoque_compras where id = v_uuid for update;
      if v_c.id is null then
        raise exception 'Compra não encontrada: informe o compra_id (aparece em ver_estoque, visão compras_recentes).';
      end if;
      if v_c.cancelada_em is not null then
        raise exception 'Essa compra já foi cancelada em %.', to_char(v_c.cancelada_em at time zone public.fuso(), 'DD/MM/YYYY');
      end if;
      v_n := 0;
      for v_r in
        select m.* from public.estoque_movimentos m
          join public.estoque_compra_itens i on i.id = m.compra_item_id
         where i.compra_id = v_c.id and m.tipo = 'compra'
           and not exists (select 1 from public.estoque_movimentos e where e.estorna_id = m.id)
      loop
        perform public.estoque_estornar(v_r.id, 'Compra cancelada: ' || v_motivo);
        v_ids := v_ids || v_r.material_id;
        v_n := v_n + 1;
      end loop;
      update public.estoque_compras set cancelada_em = now(), motivo_cancelamento = v_motivo where id = v_c.id;
      v_res := v_res || jsonb_build_object('tipo', 'cancelar_compra', 'compra', public.estoque_compra_json(v_c.id),
                                           'itens_estornados', v_n);
      if exists (select 1 from public.estoque_compra_itens i
                  cross join lateral public.estoque_lotes_saldo(i.material_id) s
                  where i.compra_id = v_c.id and s.lote_id = i.lote_id and s.saldo < 0) then
        v_avisos := array_append(v_avisos, 'Parte do material dessa compra já tinha sido usada: confira o saldo com uma contagem.'::text);
      end if;
      continue;
    end if;

    -- Os demais precisam do material e da quantidade
    v_m := public.estoque_material_ou_erro(v ->> 'material');
    v_q := public.estoque_numero(v -> 'quantidade', format('Quantidade de %s', v_m.nome));
    if v_q is null then
      raise exception 'Informe a quantidade de %.', v_m.nome;
    end if;
    if v_q < 0 or (v_q = 0 and v_tipo <> 'contagem') then
      raise exception 'A quantidade de % deve ser maior que zero%.', v_m.nome,
        case when v_tipo = 'contagem' then ' (ou zero, se acabou)' else '' end;
    end if;
    v_qu := public.estoque_para_uso(v_m, v_q, v ->> 'unidade', 'uso');

    -- Lote: entrada e contagem criam; os outros precisam achar
    v_lote_txt := nullif(btrim(v ->> 'lote'), '');
    v_val := public.estoque_validade(v ->> 'validade', 'Validade');
    v_lote_id := null;
    if v_lote_txt is not null or v_val is not null then
      if v_tipo in ('entrada', 'contagem') then
        v_lote_id := public.estoque_lote(v_m.id, v_lote_txt, v_val);
      else
        select l.id into v_lote_id from public.estoque_lotes l
         where l.material_id = v_m.id
           and (v_lote_txt is null or public.normalizar(l.lote) = public.normalizar(v_lote_txt))
           and (v_val is null or l.validade = v_val)
         order by l.validade nulls last
         limit 1;
        if v_lote_id is null then
          select string_agg(coalesce(s.lote, 'sem número') || coalesce(' val. ' || to_char(s.validade, 'DD/MM/YYYY'), '')
                            || ': ' || public.estoque_num(s.saldo), '; ' order by s.validade)
            into v_lotes
            from public.estoque_lotes_saldo(v_m.id) s where s.saldo > 0;
          raise exception 'Lote de % não encontrado.%', v_m.nome,
            coalesce(' Lotes com saldo: ' || v_lotes || '.', ' Não há lotes com saldo.');
        end if;
      end if;
    end if;

    -- Preço (entrada e contagem): unitário na unidade dita, ou total
    v_custo := null;
    if v_tipo in ('entrada', 'contagem') then
      v_pu := public.estoque_numero(v -> 'preco_unitario', 'Preço unitário');
      v_pt := public.estoque_numero(v -> 'preco_total', 'Preço total');
      if v_pt is not null and v_qu > 0 then
        v_custo := round(v_pt / v_qu, 6);
      elsif v_pu is not null and v_qu > 0 then
        v_custo := round(v_pu * v_q / v_qu, 6);
      end if;
    end if;

    v_pac := null;
    if v_tipo = 'uso' and nullif(btrim(v ->> 'paciente_id'), '') is not null then
      v_pac := (public.obter_paciente_ativo(v ->> 'paciente_id')).id;
    end if;

    v_delta := null;
    if v_tipo = 'uso' then
      perform public.estoque_saida(v_m.id, v_qu, 'uso_avulso', v_data, null, null, v_pac, v_motivo, v_lote_id);
    elsif v_tipo in ('perda', 'vencido') then
      perform public.estoque_saida(v_m.id, v_qu, v_tipo, v_data, null, null, null, v_motivo, v_lote_id);
    elsif v_tipo = 'entrada' then
      perform public.estoque_entrada(v_m.id, v_qu, v_custo, v_lote_id, 'entrada_avulsa', null, v_data, v_motivo);
    else
      v_saldo := case when v_lote_id is not null
                      then (select coalesce(sum(quantidade), 0) from public.estoque_movimentos where lote_id = v_lote_id)
                      else public.estoque_saldo(v_m.id) end;
      v_delta := v_qu - v_saldo;
      if v_delta > 0 then
        perform public.estoque_entrada(v_m.id, v_delta, v_custo, v_lote_id, 'contagem', null, v_data,
                                       coalesce(v_motivo, 'Contagem'));
      elsif v_delta < 0 then
        perform public.estoque_saida(v_m.id, -v_delta, 'contagem', v_data, null, null, null,
                                     coalesce(v_motivo, 'Contagem'), v_lote_id);
      else
        v_avisos := v_avisos || format('%s: a contagem bateu com o sistema.', v_m.nome);
      end if;
      if v_custo is not null and (v_delta <= 0 or v_m.custo_medio is null) then
        update public.estoque_materiais set custo_medio = v_custo where id = v_m.id and custo_medio is null;
      end if;
    end if;

    v_ids := v_ids || v_m.id;
    v_res := v_res || jsonb_strip_nulls(jsonb_build_object(
      'tipo', v_tipo,
      'material', v_m.nome,
      'quantidade', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, v_qu),
      'ajuste', case when v_delta is not null and v_delta <> 0 then
                  case when v_delta > 0 then '+' else '' end
                  || public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, v_delta) end,
      'saldo', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, public.estoque_saldo(v_m.id))));
  end loop;

  return jsonb_build_object(
    'status', 'registrado',
    'movimentos', v_res,
    'avisos', to_jsonb(v_avisos || public.estoque_avisos(v_ids, true)));
end
$$;

-- ---------------------------------------------------------------------
-- ver_estoque
-- ---------------------------------------------------------------------
create or replace function public.mcp_ver_estoque(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_visao text := coalesce(nullif(replace(public.normalizar(p_dados ->> 'visao'), ' ', '_'), ''), 'resumo');
  v_busca text := nullif(btrim(p_dados ->> 'busca'), '');
  v_cat text := nullif(public.normalizar(p_dados ->> 'categoria'), '');
  v_dias int := coalesce(public.estoque_numero(p_dados -> 'dias', 'Dias')::int, 60);
  v_semanas int := least(coalesce(public.estoque_numero(p_dados -> 'semanas', 'Semanas')::int, 4), 26);
  v_m public.estoque_materiais;
  v_proc public.procedimentos;
  v_kit uuid;
  v_q text[];
  v_lista jsonb;
  v_consumo numeric;
begin
  perform public.iniciar_solicitacao('ver_estoque', p_dados, p_texto_original);
  v_q := case when v_busca is not null then public.estoque_palavras(v_busca) end;

  if v_visao = 'resumo' then
    v_lista := public.estoque_lista_compras();
    return jsonb_strip_nulls(jsonb_build_object(
      'visao', 'resumo',
      'materiais_ativos', (select count(*) from public.estoque_materiais where ativo),
      'materiais_com_saldo_registrado', (select count(*) from public.estoque_materiais m
                                          where m.ativo and public.estoque_acompanhado(m.id)),
      'valor_em_estoque', (select public.estoque_reais(coalesce(sum(greatest(public.estoque_saldo(m.id), 0)
                                                                  * coalesce(m.custo_medio, 0)), 0))
                             from public.estoque_materiais m where m.ativo),
      'abaixo_do_minimo', (select jsonb_agg(jsonb_build_object(
                              'material', x.nome,
                              'saldo', public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.saldo),
                              'minimo', public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.estoque_minimo))
                              order by x.nome)
                             from (select m.*, public.estoque_saldo(m.id) saldo from public.estoque_materiais m
                                    where m.ativo and public.estoque_acompanhado(m.id)) x
                            where x.saldo < 0 or (x.estoque_minimo > 0 and x.saldo <= x.estoque_minimo)),
      'lista_de_compras', jsonb_build_object('itens', jsonb_array_length(v_lista -> 'itens'),
                                             'total_estimado', v_lista -> 'total_estimado'),
      'lotes_vencendo_em_60_dias', (select count(*) from public.estoque_materiais m
                                     cross join lateral public.estoque_lotes_saldo(m.id) s
                                    where m.ativo and s.saldo > 0 and s.validade <= public.hoje() + 60),
      'avisos', to_jsonb(public.estoque_avisos()),
      'dica', case when not exists (select 1 from public.estoque_movimentos where tipo in ('compra', 'contagem', 'entrada_avulsa'))
                   then 'Ainda não há saldo registrado: comece pela contagem inicial (movimentar_estoque, tipo contagem), material por material.' end));

  elsif v_visao = 'saldos' then
    return jsonb_build_object('visao', 'saldos', 'materiais', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'codigo', x.codigo,
               'material', x.nome,
               'categoria', x.categoria,
               'saldo', public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.saldo),
               'minimo', public.estoque_qtd(x.unidade_uso, x.unidade_compra, x.fator, x.estoque_minimo),
               'situacao', case when not x.acompanhado then 'sem contagem'
                                when x.saldo < 0 then 'negativo'
                                when x.estoque_minimo > 0 and x.saldo <= x.estoque_minimo then 'abaixo do mínimo'
                                else 'ok' end,
               'custo_medio', public.estoque_reais(x.custo_medio * x.fator) || ' por ' || x.unidade_compra,
               'vence_primeiro', (select min(s.validade) from public.estoque_lotes_saldo(x.id) s where s.saldo > 0)))
             order by x.categoria, x.nome)
        from (select m.*, public.estoque_saldo(m.id) saldo, public.estoque_acompanhado(m.id) acompanhado
                from public.estoque_materiais m
               where (m.ativo or coalesce((p_dados ->> 'incluir_inativos')::boolean, false))
                 and (v_cat is null or m.categoria = v_cat)
                 and (v_q is null or v_q <@ public.estoque_palavras_material(m))) x), '[]'::jsonb));

  elsif v_visao = 'material' then
    if v_busca is null then
      raise exception 'Diga qual material (busca).';
    end if;
    v_m := public.estoque_material_ou_erro(v_busca);
    v_consumo := public.estoque_consumo_diario(v_m.id);
    return jsonb_build_object(
      'visao', 'material',
      'material', public.estoque_material_json(v_m),
      'lotes', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'lote', s.lote, 'validade', s.validade,
                  'saldo', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, s.saldo)))
                  order by s.validade nulls last), '[]'::jsonb)
                  from public.estoque_lotes_saldo(v_m.id) s where s.saldo <> 0),
      'saldo_sem_lote', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator,
                          (select coalesce(sum(quantidade), 0) from public.estoque_movimentos
                            where material_id = v_m.id and lote_id is null)),
      'consumo', jsonb_strip_nulls(jsonb_build_object(
                   'por_semana', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, round(v_consumo * 7, 1)),
                   'ponto_de_pedido', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator,
                                                         public.estoque_ponto_pedido(v_m)),
                   'dura_dias', case when v_consumo > 0 then floor(greatest(public.estoque_saldo(v_m.id), 0) / v_consumo) end)),
      'ultimos_movimentos', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'id', x.id, 'data', x.data, 'tipo', x.tipo,
                  'quantidade', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, x.quantidade),
                  'lote', x.lote, 'paciente', x.paciente, 'motivo', x.motivo,
                  'desfeito', case when x.desfeito then true end)) order by x.registrado_em desc), '[]'::jsonb)
                  from (select mv.id, mv.data, mv.tipo, mv.quantidade, mv.motivo, mv.registrado_em, l.lote, p.nome paciente,
                               exists (select 1 from public.estoque_movimentos e where e.estorna_id = mv.id) desfeito
                          from public.estoque_movimentos mv
                          left join public.estoque_lotes l on l.id = mv.lote_id
                          left join public.pacientes p on p.id = mv.paciente_id
                         where mv.material_id = v_m.id
                         order by mv.registrado_em desc, mv.id
                         limit 20) x),
      'ultimas_compras', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'compra_id', c.id, 'data', c.data, 'fornecedor', f.nome,
                  'quantidade', public.estoque_num(i.quantidade_informada) || ' '
                                || public.estoque_plural(i.unidade_informada, i.quantidade_informada),
                  'preco_por_' || public.codigo_de(v_m.unidade_compra), round(i.custo_unitario_uso * v_m.fator, 2)))
                  order by c.data desc, i.registrado_em desc), '[]'::jsonb)
                  from (select * from public.estoque_compra_itens where material_id = v_m.id
                         order by registrado_em desc limit 5) i
                  join public.estoque_compras c on c.id = i.compra_id and c.cancelada_em is null
                  left join public.estoque_fornecedores f on f.id = c.fornecedor_id),
      'kits', (select coalesce(jsonb_agg(jsonb_build_object(
                  'kit', k.nome,
                  'quantidade', public.estoque_qtd(v_m.unidade_uso, v_m.unidade_compra, v_m.fator, ki.quantidade))
                  order by k.nome), '[]'::jsonb)
                  from public.estoque_kit_itens ki
                  join public.estoque_kits k on k.id = ki.kit_id and k.ativo
                 where ki.removido_em is null
                   and (ki.material_id = v_m.id or (ki.grupo is not null and ki.grupo = v_m.grupo))));

  elsif v_visao = 'lista_compras' then
    v_lista := public.estoque_lista_compras();
    return jsonb_strip_nulls(v_lista || jsonb_build_object(
      'visao', 'lista_compras',
      'sem_contagem', (select nullif(count(*), 0) from public.estoque_materiais m
                        where m.ativo and m.estoque_minimo > 0 and not public.estoque_acompanhado(m.id)),
      'nota', 'Só entram materiais com saldo registrado. Quantidade = até o ponto de pedido + 30 dias de consumo, '
              || 'arredondada para a unidade de compra; o preço é o da última compra.'));

  elsif v_visao = 'compras_recentes' then
    return jsonb_build_object(
      'visao', 'compras_recentes',
      'desde', public.hoje() - v_dias,
      'total_gasto', (select coalesce(sum(valor_total), 0) from public.estoque_compras
                       where cancelada_em is null and data > public.hoje() - v_dias),
      'compras', (select coalesce(jsonb_agg(public.estoque_compra_json(c.id) order by c.data desc, c.registrado_em desc),
                                  '[]'::jsonb)
                    from public.estoque_compras c where c.data > public.hoje() - v_dias));

  elsif v_visao = 'vencimentos' then
    return jsonb_build_object(
      'visao', 'vencimentos',
      'ate', public.hoje() + v_dias,
      'lotes', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'material', m.nome, 'lote', s.lote, 'validade', s.validade,
                  'dias', s.validade - public.hoje(),
                  'situacao', case when s.validade < public.hoje() then 'vencido' else 'vence em breve' end,
                  'saldo', public.estoque_qtd(m.unidade_uso, m.unidade_compra, m.fator, s.saldo)))
                  order by s.validade, m.nome), '[]'::jsonb)
                  from public.estoque_materiais m
                  cross join lateral public.estoque_lotes_saldo(m.id) s
                 where m.ativo and s.saldo > 0 and s.validade <= public.hoje() + v_dias),
      'sem_validade', (select count(*) from public.estoque_materiais m
                        where m.ativo and m.controla_validade and public.estoque_saldo(m.id) > 0
                          and exists (select 1 from public.estoque_movimentos x
                                       where x.material_id = m.id and x.lote_id is null and x.quantidade > 0)));

  elsif v_visao = 'consumo' then
    return jsonb_build_object(
      'visao', 'consumo',
      'semanas', (select coalesce(jsonb_agg(jsonb_build_object(
                    'semana', to_char(w.ini, 'DD/MM') || ' a ' || to_char(w.ini + 6, 'DD/MM'),
                    'atendimentos', (select count(distinct mv.atendimento_id) from public.estoque_movimentos mv
                                      where mv.atendimento_id is not null and mv.data between w.ini and w.ini + 6),
                    'custo', (select coalesce(round(sum(-mv.quantidade * coalesce(mv.custo_unitario, 0)), 2), 0)
                                from public.estoque_movimentos mv
                                left join public.estoque_movimentos o on o.id = mv.estorna_id
                               where mv.data between w.ini and w.ini + 6
                                 and (mv.tipo in ('uso_atendimento', 'uso_avulso')
                                      or (mv.tipo = 'estorno' and o.tipo in ('uso_atendimento', 'uso_avulso')))),
                    'materiais', (select coalesce(jsonb_agg(jsonb_build_object(
                                    'material', u.nome,
                                    'quantidade', public.estoque_qtd(u.unidade_uso, u.unidade_compra, u.fator, u.q),
                                    'custo', u.custo) order by u.custo desc nulls last, u.q desc), '[]'::jsonb)
                                    from (select m.nome, m.unidade_uso, m.unidade_compra, m.fator,
                                                 -sum(mv.quantidade) q,
                                                 round(-sum(mv.quantidade * mv.custo_unitario), 2) custo
                                            from public.estoque_movimentos mv
                                            join public.estoque_materiais m on m.id = mv.material_id
                                            left join public.estoque_movimentos o on o.id = mv.estorna_id
                                           where mv.data between w.ini and w.ini + 6
                                             and (v_q is null or v_q <@ public.estoque_palavras_material(m))
                                             and (mv.tipo in ('uso_atendimento', 'uso_avulso')
                                                  or (mv.tipo = 'estorno' and o.tipo in ('uso_atendimento', 'uso_avulso')))
                                           group by m.id
                                          having sum(mv.quantidade) < 0
                                           order by 6 desc nulls last, 5 desc
                                           limit 15) u)) order by w.ini desc), '[]'::jsonb)
                    from (select (date_trunc('week', public.hoje()::timestamp) - (n * interval '1 week'))::date ini
                            from generate_series(0, v_semanas - 1) n) w));

  elsif v_visao = 'custos' then
    if nullif(btrim(p_dados ->> 'procedimento_codigo'), '') is not null then
      if public.codigo_de(p_dados ->> 'procedimento_codigo') in ('atendimento_base', 'base', 'kit_base') then
        select id into v_kit from public.estoque_kits where base;
        return jsonb_build_object('visao', 'custos', 'kit', public.estoque_kit_json(v_kit),
                                  'detalhe', public.custo_materiais_detalhe(null, true));
      end if;
      v_proc := public.estoque_achar_procedimento(p_dados ->> 'procedimento_codigo');
      select id into v_kit from public.estoque_kits where procedimento_id = v_proc.id;
      return jsonb_strip_nulls(jsonb_build_object(
        'visao', 'custos',
        'procedimento', v_proc.nome,
        'preco', v_proc.preco,
        'kit', case when v_kit is not null then public.estoque_kit_json(v_kit) end,
        'detalhe', public.custo_materiais_detalhe(v_proc.id, false),
        'custo_kit_base', public.custo_materiais(null, true),
        'nota', case when v_kit is null then 'Esse procedimento ainda não tem kit: cadastre com salvar_material (kit).'
                     else 'Estimativa pelo custo médio atual; a anestesia entra pelos tubetes típicos do kit.' end));
    end if;
    return jsonb_build_object(
      'visao', 'custos',
      'custo_kit_base', public.custo_materiais(null, true),
      'procedimentos', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                          'codigo', p.codigo, 'procedimento', p.nome,
                          'custo_materiais', public.custo_materiais(p.id, false),
                          'preco', p.preco,
                          'percentual_do_preco', case when p.preco > 0
                            then round(100 * public.custo_materiais(p.id, false) / p.preco, 1) end))
                          order by p.ordem, p.nome), '[]'::jsonb)
                          from public.estoque_kits k join public.procedimentos p on p.id = k.procedimento_id
                         where k.ativo),
      'nota', 'Custo estimado pelo custo médio atual (material sem compra registrada conta zero), sem o kit base.');
  end if;

  raise exception 'Visão "%" não existe: use resumo, saldos, material, lista_compras, compras_recentes, vencimentos, consumo ou custos.',
    p_dados ->> 'visao';
end
$$;

-- ---------------------------------------------------------------------
-- salvar_material (e kit)
-- ---------------------------------------------------------------------
create or replace function public.estoque_salvar_kit(p_kit jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cod text := nullif(btrim(p_kit ->> 'procedimento_codigo'), '');
  v_proc public.procedimentos;
  v_kit public.estoque_kits;
  v_modo text := coalesce(nullif(public.normalizar(p_kit ->> 'modo'), ''), 'acrescentar');
  v_it jsonb;
  v_txt text;
  v_m public.estoque_materiais;
  v_grupo text;
  v_q numeric;
  v_n int;
  v_avisos text[] := '{}';
begin
  if v_cod is null then
    raise exception 'Informe o procedimento do kit (procedimento_codigo), ou atendimento_base para o kit de todo atendimento.';
  end if;
  if v_modo not in ('acrescentar', 'substituir') then
    raise exception 'Modo "%" inválido: use acrescentar ou substituir.', p_kit ->> 'modo';
  end if;
  if public.codigo_de(v_cod) in ('atendimento_base', 'base', 'kit_base') then
    select * into v_kit from public.estoque_kits where base for update;
    if v_kit.id is null then
      insert into public.estoque_kits (codigo, nome, base) values ('atendimento_base', 'Kit base do atendimento (biossegurança)', true)
      returning * into v_kit;
    end if;
  else
    v_proc := public.estoque_achar_procedimento(v_cod);
    select * into v_kit from public.estoque_kits where procedimento_id = v_proc.id for update;
    if v_kit.id is null then
      insert into public.estoque_kits (codigo, nome, procedimento_id)
      values ('kit_' || v_proc.codigo, 'Kit ' || v_proc.nome, v_proc.id)
      returning * into v_kit;
      v_avisos := v_avisos || format('Kit novo para %s.', v_proc.nome);
    end if;
  end if;

  if p_kit ? 'anestesia_tubetes' or p_kit ? 'ativo' then
    update public.estoque_kits set
      anestesia_tubetes = coalesce(public.estoque_numero(p_kit -> 'anestesia_tubetes', 'Tubetes'), anestesia_tubetes),
      ativo = coalesce((p_kit ->> 'ativo')::boolean, ativo)
     where id = v_kit.id;
  end if;

  if v_modo = 'substituir' then
    update public.estoque_kit_itens set removido_em = now() where kit_id = v_kit.id and removido_em is null;
  end if;

  for v_txt in select * from jsonb_array_elements_text(coalesce(p_kit -> 'remover', '[]'::jsonb)) loop
    v_grupo := public.codigo_de(v_txt);
    if not exists (select 1 from public.estoque_materiais where grupo = v_grupo) then
      v_m := public.estoque_material_ou_erro(v_txt);
      v_grupo := v_m.grupo;
    else
      v_m := null;
    end if;
    update public.estoque_kit_itens set removido_em = now()
     where kit_id = v_kit.id and removido_em is null
       and (material_id = v_m.id or (v_grupo is not null and grupo = v_grupo));
    get diagnostics v_n = row_count;
    if v_n = 0 then
      v_avisos := v_avisos || format('"%s" não estava no kit.', v_txt);
    end if;
  end loop;

  for v_it in select * from jsonb_array_elements(coalesce(p_kit -> 'itens', '[]'::jsonb)) loop
    v_txt := v_it ->> 'material';
    v_grupo := public.codigo_de(v_txt);
    if exists (select 1 from public.estoque_materiais where grupo = v_grupo and ativo) then
      select * into v_m from public.estoque_materiais where id = public.estoque_material_do_grupo(v_grupo);
    else
      v_m := public.estoque_material_ou_erro(v_txt);
      v_grupo := case when v_m.grupo is not null and not coalesce((v_it ->> 'fixo')::boolean, false) then v_m.grupo end;
    end if;
    v_q := public.estoque_para_uso(v_m, public.estoque_numero(v_it -> 'quantidade', format('Quantidade de %s', v_m.nome)),
                                   v_it ->> 'unidade', 'uso');
    if v_q <= 0 then
      raise exception 'A quantidade de % no kit deve ser maior que zero (para tirar, use remover).', v_m.nome;
    end if;
    -- Grupo e material do mesmo grupo não convivem no kit: o novo tira o outro.
    if v_grupo is not null then
      update public.estoque_kit_itens set removido_em = now()
       where kit_id = v_kit.id and removido_em is null
         and material_id in (select id from public.estoque_materiais where grupo = v_grupo);
      insert into public.estoque_kit_itens (kit_id, grupo, quantidade, observacao)
      values (v_kit.id, v_grupo, v_q, nullif(btrim(v_it ->> 'observacao'), ''))
      on conflict (kit_id, (coalesce(material_id::text, 'grupo:' || grupo)))
      do update set quantidade = excluded.quantidade, observacao = excluded.observacao, removido_em = null;
    else
      update public.estoque_kit_itens set removido_em = now()
       where kit_id = v_kit.id and removido_em is null and v_m.grupo is not null and grupo = v_m.grupo;
      insert into public.estoque_kit_itens (kit_id, material_id, quantidade, observacao)
      values (v_kit.id, v_m.id, v_q, nullif(btrim(v_it ->> 'observacao'), ''))
      on conflict (kit_id, (coalesce(material_id::text, 'grupo:' || grupo)))
      do update set quantidade = excluded.quantidade, observacao = excluded.observacao, removido_em = null;
    end if;
  end loop;

  return jsonb_build_object('kit', public.estoque_kit_json(v_kit.id), 'avisos', to_jsonb(v_avisos));
end
$$;

create or replace function public.mcp_salvar_material(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old public.estoque_materiais;
  v_novo public.estoque_materiais;
  v_id uuid;
  v_cod text := nullif(public.codigo_de(p_dados ->> 'codigo'), '');
  v_nome text := nullif(btrim(regexp_replace(coalesce(p_dados ->> 'nome', ''), '\s+', ' ', 'g')), '');
  v_cat text := nullif(public.normalizar(p_dados ->> 'categoria'), '');
  v_grupo text := nullif(public.codigo_de(p_dados ->> 'grupo'), '');
  v_uc text := nullif(btrim(lower(p_dados ->> 'unidade_compra')), '');
  v_uu text := nullif(btrim(lower(p_dados ->> 'unidade_uso')), '');
  v_fator numeric := public.estoque_numero(p_dados -> 'fator', 'Fator');
  v_min numeric := public.estoque_numero(p_dados -> 'estoque_minimo', 'Estoque mínimo');
  v_preco numeric := public.estoque_numero(p_dados -> 'preco_unidade_compra', 'Preço');
  v_prazo numeric := public.estoque_numero(p_dados -> 'prazo_entrega_dias', 'Prazo de entrega');
  v_sin_add text[];
  v_sin_rem text[];
  v_var text[];
  v_padrao boolean := (p_dados ->> 'padrao_do_grupo')::boolean;
  v_status text;
  v_avisos text[] := '{}';
  v_kit jsonb;
  v_tem_mov boolean;
  v_n int := 1;
begin
  perform public.iniciar_solicitacao('salvar_material', p_dados, p_texto_original);

  if v_cod is null and v_nome is null and p_dados -> 'kit' is null then
    raise exception 'Informe o material (codigo ou nome) e o que mudar, ou um kit.';
  end if;
  if v_cat is not null and v_cat not in ('anestesico', 'agulha', 'epi', 'descartavel', 'dentistica', 'endodontia', 'cirurgia',
      'periodontia', 'protese', 'implante', 'esterilizacao', 'clareamento', 'profilaxia', 'antissepsia', 'radiologia',
      'instrumental', 'outros') then
    raise exception 'Categoria "%" inválida: use anestesico, agulha, epi, descartavel, dentistica, endodontia, cirurgia, periodontia, protese, implante, esterilizacao, clareamento, profilaxia, antissepsia, radiologia, instrumental ou outros.',
      p_dados ->> 'categoria';
  end if;
  if v_fator is not null and v_fator <= 0 then
    raise exception 'O fator (quantas unidades de uso vêm em cada unidade de compra) deve ser maior que zero.';
  end if;
  if v_min < 0 or v_preco < 0 then
    raise exception 'Mínimo e preço não podem ser negativos.';
  end if;
  if v_prazo is not null and (v_prazo < 0 or v_prazo > 90) then
    raise exception 'Prazo de entrega de % dias fora do esperado (0 a 90).', v_prazo;
  end if;
  v_sin_add := array(select distinct public.normalizar(s) from jsonb_array_elements_text(
                       coalesce(p_dados -> 'sinonimos_adicionar', '[]'::jsonb)) s where public.normalizar(s) <> '');
  v_sin_rem := array(select distinct public.normalizar(s) from jsonb_array_elements_text(
                       coalesce(p_dados -> 'sinonimos_remover', '[]'::jsonb)) s);
  if p_dados ? 'variantes' then
    v_var := array(select distinct public.estoque_frase_raiz(s) from jsonb_array_elements_text(
                     coalesce(p_dados -> 'variantes', '[]'::jsonb)) s where public.estoque_frase_raiz(s) <> '');
  end if;

  if v_cod is not null or v_nome is not null then
    -- Acha o existente: código, nome exato ou (se não for novo) a busca por palavras
    if v_cod is not null then
      select * into v_old from public.estoque_materiais where codigo = v_cod for update;
    end if;
    if v_old.id is null and v_nome is not null then
      select * into v_old from public.estoque_materiais where public.normalizar(nome) = public.normalizar(v_nome) for update;
    end if;
    if v_old.id is null and v_nome is not null and not coalesce((p_dados ->> 'novo')::boolean, false) then
      v_id := public.estoque_achar_material(v_nome);
      if v_id is not null then
        select * into v_old from public.estoque_materiais where id = v_id for update;
      end if;
    end if;

    if v_old.id is not null then
      v_tem_mov := exists (select 1 from public.estoque_movimentos where material_id = v_old.id);
      if v_uu is not null and public.estoque_unidade(v_uu) is distinct from public.estoque_unidade(v_old.unidade_uso)
         and v_tem_mov then
        raise exception 'Não dá para mudar a unidade de uso de % (%) porque já há movimentos nela. Cadastre um material novo e desative este.',
          v_old.nome, v_old.unidade_uso;
      end if;
      if v_fator is not null and v_fator <> v_old.fator and v_tem_mov then
        v_avisos := v_avisos || format('Embalagem de %s mudou para %s por %s: as próximas compras usam o fator novo; o saldo continua em %s.',
                                       v_old.nome, public.estoque_num(v_fator), coalesce(v_uc, v_old.unidade_compra),
                                       public.estoque_plural(v_old.unidade_uso, 2));
      end if;
      v_novo := v_old;
      v_novo.unidade_compra := coalesce(v_uc, v_old.unidade_compra);
      v_novo.unidade_uso := coalesce(v_uu, v_old.unidade_uso);
      v_novo.fator := coalesce(v_fator, v_old.fator);
      v_novo.grupo := case when p_dados ? 'grupo' then v_grupo else v_old.grupo end;
      if coalesce(v_padrao, false) and v_novo.grupo is not null then
        update public.estoque_materiais set padrao_do_grupo = false
         where grupo = v_novo.grupo and padrao_do_grupo and id <> v_old.id;
      end if;
      update public.estoque_materiais set
        nome = case when v_cod is not null and v_nome is not null then v_nome else nome end,
        categoria = coalesce(v_cat, categoria),
        grupo = v_novo.grupo,
        padrao_do_grupo = case when v_novo.grupo is null then false else coalesce(v_padrao, padrao_do_grupo) end,
        variantes = coalesce(v_var, variantes),
        unidade_compra = v_novo.unidade_compra,
        unidade_uso = v_novo.unidade_uso,
        fator = v_novo.fator,
        estoque_minimo = coalesce(case when v_min is not null then
                                    public.estoque_para_uso(v_novo, v_min, p_dados ->> 'estoque_minimo_unidade', 'uso') end,
                                  estoque_minimo),
        prazo_entrega_dias = coalesce(v_prazo::int, prazo_entrega_dias),
        custo_medio = coalesce(round(v_preco / v_novo.fator, 6), custo_medio),
        controla_validade = coalesce((p_dados ->> 'controla_validade')::boolean, controla_validade),
        sinonimos = array(select distinct s from unnest(sinonimos || v_sin_add) s where not (s = any(v_sin_rem))),
        observacao = case when p_dados ? 'observacao' then nullif(btrim(p_dados ->> 'observacao'), '') else observacao end,
        ativo = coalesce((p_dados ->> 'ativo')::boolean, ativo)
       where id = v_old.id;
      v_id := v_old.id;
      v_status := 'atualizado';
      if v_preco is not null then
        v_avisos := v_avisos || format('Custo médio de %s ajustado à mão para %s por %s.', v_old.nome,
                                       public.estoque_reais(v_preco), v_novo.unidade_compra);
      end if;
    else
      if v_nome is null or length(v_nome) < 3 then
        raise exception 'Para cadastrar um material novo, informe o nome.';
      end if;
      if v_cat is null then
        raise exception 'Para cadastrar "%", informe a categoria (ex.: descartavel, dentistica, cirurgia, epi).', v_nome;
      end if;
      if v_uc is null and v_uu is null then
        raise exception 'Para cadastrar "%", informe a unidade de compra (ex.: caixa), a de uso (ex.: unidade) e quantas de uso vêm em cada compra (fator).', v_nome;
      end if;
      v_uc := coalesce(v_uc, v_uu);
      v_uu := coalesce(v_uu, v_uc);
      if v_fator is null and public.estoque_unidade(v_uc) is distinct from public.estoque_unidade(v_uu) then
        raise exception 'Quantas % vêm em cada %? Informe o fator.', public.estoque_plural(v_uu, 2), v_uc;
      end if;
      v_fator := coalesce(v_fator, 1);
      v_cod := coalesce(v_cod, public.codigo_de(v_nome));
      if v_cod !~ '^[a-z]' then
        v_cod := 'm_' || v_cod;
      end if;
      while exists (select 1 from public.estoque_materiais
                     where codigo = v_cod || case when v_n > 1 then '_' || v_n else '' end) loop
        v_n := v_n + 1;
      end loop;
      v_cod := v_cod || case when v_n > 1 then '_' || v_n else '' end;
      if v_grupo is not null and (coalesce(v_padrao, false)
                                  or not exists (select 1 from public.estoque_materiais where grupo = v_grupo and padrao_do_grupo)) then
        update public.estoque_materiais set padrao_do_grupo = false where grupo = v_grupo and padrao_do_grupo;
        v_padrao := true;
      end if;
      v_novo := null;
      v_novo.nome := v_nome;
      v_novo.unidade_compra := v_uc;
      v_novo.unidade_uso := v_uu;
      v_novo.fator := v_fator;
      insert into public.estoque_materiais (codigo, nome, categoria, grupo, padrao_do_grupo, variantes, unidade_compra,
                                            unidade_uso, fator, estoque_minimo, prazo_entrega_dias, custo_medio,
                                            controla_validade, sinonimos, observacao, ativo)
      values (v_cod, v_nome, v_cat, v_grupo, coalesce(v_padrao, false) and v_grupo is not null, coalesce(v_var, '{}'),
              v_uc, v_uu, v_fator,
              coalesce(case when v_min is not null then
                         public.estoque_para_uso(v_novo, v_min, p_dados ->> 'estoque_minimo_unidade', 'uso') end, 0),
              coalesce(v_prazo::int, 5), round(v_preco / v_fator, 6),
              coalesce((p_dados ->> 'controla_validade')::boolean, false),
              array(select distinct s from unnest(v_sin_add || public.normalizar(v_nome)) s where not (s = any(v_sin_rem))),
              nullif(btrim(p_dados ->> 'observacao'), ''), coalesce((p_dados ->> 'ativo')::boolean, true))
      returning id into v_id;
      v_status := 'criado';
      if v_min is null then
        v_avisos := array_append(v_avisos, 'Sem estoque mínimo: não entra nos avisos de estoque baixo até ter um.'::text);
      end if;
    end if;
  end if;

  if p_dados -> 'kit' is not null and jsonb_typeof(p_dados -> 'kit') = 'object' then
    v_kit := public.estoque_salvar_kit(p_dados -> 'kit');
    v_avisos := v_avisos || array(select jsonb_array_elements_text(v_kit -> 'avisos'));
    v_kit := v_kit -> 'kit';
    v_status := coalesce(v_status, 'kit salvo');
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', v_status,
    'material', (select public.estoque_material_json(m) from public.estoque_materiais m where m.id = v_id),
    'antes', case when v_old.id is not null then public.estoque_material_json(v_old) end,
    'kit', v_kit,
    'avisos', to_jsonb(v_avisos)));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.estoque_numero(jsonb, text),
  public.estoque_validade(text, text),
  public.estoque_preco(numeric),
  public.estoque_lote(uuid, text, date),
  public.estoque_material_ou_erro(text),
  public.estoque_achar_procedimento(text),
  public.estoque_material_json(public.estoque_materiais),
  public.estoque_compra_json(uuid),
  public.estoque_kit_json(uuid),
  public.estoque_fornecedor(text),
  public.estoque_salvar_kit(jsonb),
  public.mcp_registrar_compra(jsonb, text),
  public.mcp_movimentar_estoque(jsonb, text),
  public.mcp_ver_estoque(jsonb, text),
  public.mcp_salvar_material(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.estoque_numero(jsonb, text),
  public.estoque_validade(text, text),
  public.estoque_preco(numeric),
  public.estoque_lote(uuid, text, date),
  public.estoque_material_ou_erro(text),
  public.estoque_achar_procedimento(text),
  public.estoque_material_json(public.estoque_materiais),
  public.estoque_compra_json(uuid),
  public.estoque_kit_json(uuid),
  public.estoque_fornecedor(text),
  public.estoque_salvar_kit(jsonb),
  public.mcp_registrar_compra(jsonb, text),
  public.mcp_movimentar_estoque(jsonb, text),
  public.mcp_ver_estoque(jsonb, text),
  public.mcp_salvar_material(jsonb, text)
  to service_role;
