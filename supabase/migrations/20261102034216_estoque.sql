-- =====================================================================
-- Estoque (etapa 4a): materiais, fornecedores, compras, lotes com
-- validade, movimentos (só inclusão), kits por procedimento e baixa
-- automática a partir do prontuário.
--
-- Quantidades de estoque ficam sempre na unidade de uso do material
-- (tubete, par, g, gota...). Uma unidade de compra (caixa, seringa...)
-- vale `fator` unidades de uso. O custo médio é por unidade de uso.
-- Nada se apaga: um engano se corrige com um movimento novo (estorno,
-- contagem); compras só podem ser canceladas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Palavras, unidades e números
-- ---------------------------------------------------------------------

-- Raiz simples de uma palavra já normalizada: singular e plural caem juntos.
create or replace function public.estoque_raiz(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when p is null then null
    when length(p) > 4 and p ~ 'oes$' then regexp_replace(p, 'oes$', 'ao')
    when length(p) > 3 and p ~ 'eis$' then regexp_replace(p, 'eis$', 'el')
    when length(p) > 4 and p ~ 'ais$' then regexp_replace(p, 'ais$', 'al')
    when length(p) > 4 and p ~ '[rz]es$' then regexp_replace(p, 'es$', '')
    when length(p) > 3 and p ~ '[^s]s$' then left(p, -1)
    else p end
$$;

-- Palavras de busca (raízes, sem conectivos).
create or replace function public.estoque_palavras(p text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(array_agg(distinct public.estoque_raiz(w)), '{}')
    from regexp_split_to_table(public.normalizar(p), '[^a-z0-9]+') w
   where w <> ''
     and w not in ('de', 'da', 'do', 'das', 'dos', 'com', 'para', 'a', 'o', 'e', 'em', 'no', 'na',
                   'um', 'uma', 'tamanho', 'cor', 'tipo', 'marca')
$$;

-- Frase normalizada palavra por palavra pela raiz (para achar variantes
-- como "luva m" ou "a2" dentro de um texto).
create or replace function public.estoque_frase_raiz(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(string_agg(public.estoque_raiz(w), ' ' order by n), '')
    from regexp_split_to_table(public.normalizar(p), '[^a-z0-9]+') with ordinality as t(w, n)
   where w <> ''
$$;

-- Unidade falada → forma canônica (caixas, cx → caixa; gramas → g).
create or replace function public.estoque_unidade(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(case w
    when 'cx' then 'caixa' when 'caixinha' then 'caixa'
    when 'pct' then 'pacote' when 'pc' then 'pacote' when 'saco' then 'pacote' when 'saquinho' then 'pacote'
    when 'un' then 'unidade' when 'und' then 'unidade' when 'unid' then 'unidade' when 'peca' then 'unidade'
    when 'gr' then 'g' when 'grama' then 'g'
    when 'mililitro' then 'ml'
    when 'l' then 'litro' when 'lt' then 'litro'
    when 'tb' then 'tubete' when 'carpule' then 'tubete'
    when 'fr' then 'frasco' when 'vidro' then 'frasco'
    when 'centimetro' then 'cm'
    when 'aplicacao' then 'aplicacao' when 'porcao' then 'porcao'
    else w end, '')
  from (select public.estoque_frase_raiz(p)) as t(w)
$$;

create or replace function public.estoque_plural(p_unidade text, p_qtd numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_unidade is null then ''
    when p_qtd is not null and p_qtd <> 0 and abs(p_qtd) < 2 then p_unidade
    when p_unidade in ('g', 'ml', 'mg', 'cm', 'kg') then p_unidade
    when p_unidade ~ 'ão$' then regexp_replace(p_unidade, 'ão$', 'ões')
    when p_unidade ~ '[rz]$' then p_unidade || 'es'
    when p_unidade ~ '[sx]$' then p_unidade
    else p_unidade || 's' end
$$;

-- 2.5 → "2,5"; 3.00 → "3".
create or replace function public.estoque_num(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p is null then null
    when round(p, 2) = trunc(round(p, 2)) then trunc(round(p, 2))::text
    else replace(rtrim(round(p, 2)::text, '0'), '.', ',') end
$$;

create or replace function public.estoque_reais(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p is null then null
    else 'R$ ' || translate(to_char(round(p, 2), 'FM999G999G990D00'), ',.', '.,') end
$$;

-- "100 tubetes (2 caixas)".
create or replace function public.estoque_qtd(p_uso text, p_compra text, p_fator numeric, p_q numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select public.estoque_num(p_q) || ' ' || public.estoque_plural(p_uso, p_q)
    || case when p_fator <> 1 and p_compra is distinct from p_uso and abs(p_q / p_fator) >= 0.1
            then ' (' || public.estoque_num(round(p_q / p_fator, 1)) || ' '
                 || public.estoque_plural(p_compra, round(p_q / p_fator, 1)) || ')'
            else '' end
$$;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
create table public.estoque_materiais (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome text not null check (length(btrim(nome)) >= 2),
  categoria text not null check (categoria in (
    'anestesico', 'agulha', 'epi', 'descartavel', 'dentistica', 'endodontia', 'cirurgia', 'periodontia',
    'protese', 'implante', 'esterilizacao', 'clareamento', 'profilaxia', 'antissepsia', 'radiologia',
    'instrumental', 'outros')),
  grupo text check (grupo ~ '^[a-z][a-z0-9_]*$'),
  padrao_do_grupo boolean not null default false,
  variantes text[] not null default '{}',
  unidade_compra text not null check (length(btrim(unidade_compra)) >= 1),
  unidade_uso text not null check (length(btrim(unidade_uso)) >= 1),
  fator numeric not null check (fator > 0),
  estoque_minimo numeric not null default 0 check (estoque_minimo >= 0),
  prazo_entrega_dias int not null default 5 check (prazo_entrega_dias between 0 and 90),
  custo_medio numeric check (custo_medio >= 0),
  controla_validade boolean not null default false,
  sinonimos text[] not null default '{}',
  observacao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (not padrao_do_grupo or grupo is not null)
);
comment on table public.estoque_materiais is 'Materiais de consumo. Saldo e custo médio na unidade de uso; 1 unidade de compra = fator unidades de uso.';
comment on column public.estoque_materiais.grupo is 'Materiais intercambiáveis (ex.: resina_composta, luva_procedimento). Kits podem pedir o grupo; a variante sai do contexto do atendimento ou do padrão do grupo.';
comment on column public.estoque_materiais.variantes is 'Palavras que escolhem este material dentro do grupo (ex.: "a2", "luva m"), já na forma de estoque_frase_raiz.';
comment on column public.estoque_materiais.estoque_minimo is 'Estoque de segurança, na unidade de uso. Entra no ponto de pedido.';
comment on column public.estoque_materiais.sinonimos is 'Formas faladas, normalizadas.';
create unique index estoque_materiais_nome_idx on public.estoque_materiais (public.normalizar(nome));
create unique index estoque_materiais_padrao_idx on public.estoque_materiais (grupo) where padrao_do_grupo;

create table public.estoque_fornecedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(btrim(nome)) >= 2),
  cnpj text,
  telefone text,
  site text,
  observacao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index estoque_fornecedores_nome_idx on public.estoque_fornecedores (public.normalizar(nome));

create table public.estoque_compras (
  id uuid primary key default gen_random_uuid(),
  fornecedor_id uuid references public.estoque_fornecedores (id),
  data date not null,
  nota_fiscal text,
  valor_itens numeric(12, 2) not null default 0 check (valor_itens >= 0),
  frete numeric(12, 2) not null default 0 check (frete >= 0),
  desconto numeric(12, 2) not null default 0 check (desconto >= 0),
  valor_total numeric(12, 2) not null check (valor_total >= 0),
  forma_pagamento text,
  observacao text,
  cancelada_em timestamptz,
  motivo_cancelamento text,
  solicitacao_id uuid references public.solicitacoes (id)
    default nullif(current_setting('app.solicitacao_id', true), '')::uuid,
  registrado_em timestamptz not null default now(),
  check ((cancelada_em is null) = (motivo_cancelamento is null))
);
comment on table public.estoque_compras is 'Compras de material. Não se alteram: só podem ser canceladas (com motivo), o que estorna a entrada no estoque.';
create index estoque_compras_data_idx on public.estoque_compras (data desc);

create table public.estoque_lotes (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.estoque_materiais (id),
  lote text,
  validade date,
  criado_em timestamptz not null default now(),
  check (lote is not null or validade is not null)
);
create unique index estoque_lotes_unico_idx
  on public.estoque_lotes (material_id, coalesce(public.normalizar(lote), ''), coalesce(validade, 'infinity'::date));

create table public.estoque_compra_itens (
  id uuid primary key default gen_random_uuid(),
  compra_id uuid not null references public.estoque_compras (id),
  ordem int not null,
  material_id uuid not null references public.estoque_materiais (id),
  quantidade_informada numeric not null check (quantidade_informada > 0),
  unidade_informada text not null,
  quantidade_uso numeric not null check (quantidade_uso > 0),
  preco_total numeric(12, 2) check (preco_total >= 0),
  custo_unitario_uso numeric check (custo_unitario_uso >= 0),
  lote_id uuid references public.estoque_lotes (id),
  registrado_em timestamptz not null default now(),
  unique (compra_id, ordem)
);
comment on column public.estoque_compra_itens.custo_unitario_uso is 'Custo por unidade de uso, já com frete e desconto da compra rateados.';
create index estoque_compra_itens_material_idx on public.estoque_compra_itens (material_id);

create table public.estoque_movimentos (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.estoque_materiais (id),
  lote_id uuid references public.estoque_lotes (id),
  tipo text not null check (tipo in ('compra', 'uso_atendimento', 'uso_avulso', 'contagem', 'perda', 'vencido',
                                     'entrada_avulsa', 'estorno')),
  quantidade numeric not null check (quantidade <> 0),
  custo_unitario numeric check (custo_unitario >= 0),
  data date not null default public.hoje(),
  compra_item_id uuid references public.estoque_compra_itens (id),
  atendimento_id uuid references public.atendimentos (id),
  atendimento_item_id uuid references public.atendimento_itens (id),
  paciente_id uuid references public.pacientes (id),
  estorna_id uuid unique references public.estoque_movimentos (id),
  motivo text,
  solicitacao_id uuid references public.solicitacoes (id)
    default nullif(current_setting('app.solicitacao_id', true), '')::uuid,
  registrado_em timestamptz not null default now(),
  check ((tipo = 'estorno') = (estorna_id is not null)),
  check (tipo not in ('compra', 'entrada_avulsa') or quantidade > 0),
  check (tipo not in ('uso_atendimento', 'uso_avulso', 'perda', 'vencido') or quantidade < 0)
);
comment on table public.estoque_movimentos is 'Entradas (+) e saídas (−) na unidade de uso. Só inclusão: corrige-se com estorno ou contagem. Sem lote = saldo sem lote conhecido.';
create index estoque_movimentos_material_idx on public.estoque_movimentos (material_id, data);
create index estoque_movimentos_lote_idx on public.estoque_movimentos (lote_id) where lote_id is not null;
create index estoque_movimentos_atendimento_idx on public.estoque_movimentos (atendimento_id) where atendimento_id is not null;
create index estoque_movimentos_compra_item_idx on public.estoque_movimentos (compra_item_id) where compra_item_id is not null;

create table public.estoque_kits (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome text not null,
  procedimento_id uuid unique references public.procedimentos (id),
  base boolean not null default false,
  anestesia_tubetes numeric not null default 0 check (anestesia_tubetes >= 0),
  ativo boolean not null default true,
  observacao text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (not (base and procedimento_id is not null))
);
comment on table public.estoque_kits is 'Material gasto por procedimento do catálogo (e o kit base de biossegurança, somado a todo atendimento).';
comment on column public.estoque_kits.anestesia_tubetes is 'Tubetes típicos, só para a estimativa de custo. A baixa real do anestésico vem da anestesia registrada no atendimento.';
create unique index estoque_kits_base_idx on public.estoque_kits (base) where base;

create table public.estoque_kit_itens (
  id uuid primary key default gen_random_uuid(),
  kit_id uuid not null references public.estoque_kits (id),
  material_id uuid references public.estoque_materiais (id),
  grupo text,
  quantidade numeric not null check (quantidade > 0),
  observacao text,
  criado_em timestamptz not null default now(),
  check ((material_id is null) <> (grupo is null))
);
comment on column public.estoque_kit_itens.quantidade is 'Na unidade de uso do material.';
create unique index estoque_kit_itens_unico_idx
  on public.estoque_kit_itens (kit_id, coalesce(material_id::text, 'grupo:' || grupo));

-- ---------------------------------------------------------------------
-- Gatilhos: auditoria, só inclusão, compras só canceláveis
-- ---------------------------------------------------------------------
create or replace function public.estoque_compra_so_cancelamento()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.cancelada_em is not null
     or (to_jsonb(new) - 'cancelada_em' - 'motivo_cancelamento')
        is distinct from (to_jsonb(old) - 'cancelada_em' - 'motivo_cancelamento') then
    raise exception using
      message = 'Compras não se alteram nem se apagam: só podem ser canceladas uma vez, com motivo.',
      hint = 'Cancele com movimentar_estoque (tipo cancelar_compra) e registre a compra certa de novo.';
  end if;
  return new;
end
$$;

create or replace function public.estoque_bloquear_exclusao()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = format('Cadastros do estoque (%s) não se apagam.', tg_table_name),
    hint = 'Para tirar de uso, marque ativo = false com salvar_material.';
end
$$;

create or replace function public.estoque_so_inclusao()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = format('A tabela %s só aceita inclusões: este registro não pode ser alterado nem apagado.', tg_table_name),
    hint = 'Para corrigir o estoque, registre um movimento novo (desfazer, contagem ou cancelar_compra).';
end
$$;

create trigger estoque_materiais_atualizado_em before update on public.estoque_materiais
  for each row execute function public.tocar_atualizado_em();
create trigger estoque_materiais_sem_exclusao before delete or truncate on public.estoque_materiais
  for each statement execute function public.estoque_bloquear_exclusao();
create trigger estoque_materiais_auditoria after insert or update on public.estoque_materiais
  for each row execute function public.registrar_auditoria();

create trigger estoque_fornecedores_atualizado_em before update on public.estoque_fornecedores
  for each row execute function public.tocar_atualizado_em();
create trigger estoque_fornecedores_sem_exclusao before delete or truncate on public.estoque_fornecedores
  for each statement execute function public.estoque_bloquear_exclusao();
create trigger estoque_fornecedores_auditoria after insert or update on public.estoque_fornecedores
  for each row execute function public.registrar_auditoria();

create trigger estoque_compras_so_cancelamento before update or delete on public.estoque_compras
  for each row execute function public.estoque_compra_so_cancelamento();
create trigger estoque_compras_sem_truncate before truncate on public.estoque_compras
  for each statement execute function public.estoque_so_inclusao();
create trigger estoque_compras_auditoria after insert or update on public.estoque_compras
  for each row execute function public.registrar_auditoria();

create trigger estoque_compra_itens_so_inclusao before update or delete on public.estoque_compra_itens
  for each row execute function public.estoque_so_inclusao();
create trigger estoque_compra_itens_sem_truncate before truncate on public.estoque_compra_itens
  for each statement execute function public.estoque_so_inclusao();
create trigger estoque_compra_itens_auditoria after insert on public.estoque_compra_itens
  for each row execute function public.registrar_auditoria();

create trigger estoque_lotes_so_inclusao before update or delete on public.estoque_lotes
  for each row execute function public.estoque_so_inclusao();
create trigger estoque_lotes_sem_truncate before truncate on public.estoque_lotes
  for each statement execute function public.estoque_so_inclusao();
create trigger estoque_lotes_auditoria after insert on public.estoque_lotes
  for each row execute function public.registrar_auditoria();

create trigger estoque_movimentos_so_inclusao before update or delete on public.estoque_movimentos
  for each row execute function public.estoque_so_inclusao();
create trigger estoque_movimentos_sem_truncate before truncate on public.estoque_movimentos
  for each statement execute function public.estoque_so_inclusao();
create trigger estoque_movimentos_auditoria after insert on public.estoque_movimentos
  for each row execute function public.registrar_auditoria();

create trigger estoque_kits_atualizado_em before update on public.estoque_kits
  for each row execute function public.tocar_atualizado_em();
create trigger estoque_kits_sem_exclusao before delete or truncate on public.estoque_kits
  for each statement execute function public.estoque_bloquear_exclusao();
create trigger estoque_kits_auditoria after insert or update on public.estoque_kits
  for each row execute function public.registrar_auditoria();

-- Itens de kit são configuração: podem ser trocados e removidos (fica na auditoria).
create trigger estoque_kit_itens_sem_truncate before truncate on public.estoque_kit_itens
  for each statement execute function public.estoque_so_inclusao();
create trigger estoque_kit_itens_auditoria after insert or update or delete on public.estoque_kit_itens
  for each row execute function public.registrar_auditoria();

-- ---------------------------------------------------------------------
-- Achar material pelo que a Dra. disse
-- ---------------------------------------------------------------------
create or replace function public.estoque_palavras_material(m public.estoque_materiais)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select public.estoque_palavras(m.nome || ' ' || replace(m.codigo, '_', ' ') || ' '
                                 || array_to_string(m.sinonimos, ' ') || ' ' || array_to_string(m.variantes, ' '))
$$;

-- Devolve o material ou null (não achou ou ficou ambíguo).
-- Ordem: código, nome ou sinônimo exatos; depois todas as palavras ditas
-- dentro do nome/sinônimos. Se sobrar mais de um do mesmo grupo, vale o
-- padrão do grupo.
create or replace function public.estoque_achar_material(p_texto text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_norm text := public.normalizar(p_texto);
  v_raiz text := public.estoque_frase_raiz(p_texto);
  v_q text[] := public.estoque_palavras(p_texto);
  v_ids uuid[];
  v_grupos int;
begin
  if v_norm = '' then
    return null;
  end if;
  select array_agg(m.id) into v_ids
    from public.estoque_materiais m
   where m.ativo
     and (m.codigo = public.codigo_de(p_texto)
          or public.normalizar(m.nome) = v_norm
          or v_norm = any(m.sinonimos)
          or v_raiz = any(array(select public.estoque_frase_raiz(s) from unnest(m.sinonimos) s)));
  if coalesce(cardinality(v_ids), 0) = 0 and cardinality(v_q) > 0 then
    select array_agg(m.id) into v_ids
      from public.estoque_materiais m
     where m.ativo and v_q <@ public.estoque_palavras_material(m);
  end if;
  if coalesce(cardinality(v_ids), 0) = 0 then
    return null;
  end if;
  if cardinality(v_ids) = 1 then
    return v_ids[1];
  end if;
  select count(distinct coalesce(grupo, id::text)) into v_grupos
    from public.estoque_materiais where id = any(v_ids);
  if v_grupos = 1 then
    return (select id from public.estoque_materiais where id = any(v_ids)
             order by padrao_do_grupo desc, nome limit 1);
  end if;
  return null;
end
$$;

-- Nomes parecidos, para a mensagem de erro.
create or replace function public.estoque_sugestoes(p_texto text, p_limite int default 5)
returns text[]
language sql
stable
set search_path = ''
as $$
  with q as (select unnest(public.estoque_palavras(p_texto)) w),
  m as (select nome, public.estoque_palavras_material(x) p from public.estoque_materiais x where x.ativo),
  s as (
    select m.nome,
           (select count(*) from q
             where exists (select 1 from unnest(m.p) y
                            where y = q.w
                               or (length(q.w) >= 3 and length(y) >= 3 and (y like q.w || '%' or q.w like y || '%')))) pontos
      from m)
  select coalesce((array_agg(nome order by pontos desc, nome) filter (where pontos > 0))[1:p_limite], '{}')
    from s
$$;

-- Maior variante do material que aparece no texto (null se nenhuma).
create or replace function public.estoque_variante(p_variantes text[], p_contexto text)
returns int
language sql
immutable
set search_path = ''
as $$
  select max(length(v)) from unnest(p_variantes) v
   where v <> '' and p_contexto is not null
     and (' ' || public.estoque_frase_raiz(p_contexto) || ' ') like ('% ' || v || ' %')
$$;

-- Material de um grupo: o que o contexto cita (primeiro o principal), senão o padrão.
create or replace function public.estoque_material_do_grupo(p_grupo text, p_contexto text default null,
                                                            p_contexto2 text default null)
returns uuid
language sql
stable
set search_path = ''
as $$
  select id from public.estoque_materiais
   where grupo = p_grupo and ativo
   order by public.estoque_variante(variantes, p_contexto) desc nulls last,
            public.estoque_variante(variantes, p_contexto2) desc nulls last,
            padrao_do_grupo desc, nome
   limit 1
$$;

-- Material citado no atendimento ({material, detalhe}): tenta com o
-- detalhe (cor, tamanho), depois só o nome, e escolhe a variante do grupo.
create or replace function public.estoque_material_citado(p_material text, p_detalhe text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
  v_grupo text;
begin
  v_id := public.estoque_achar_material(concat_ws(' ', p_material, p_detalhe));
  if v_id is null then
    v_id := public.estoque_achar_material(p_material);
  end if;
  if v_id is not null then
    select grupo into v_grupo from public.estoque_materiais where id = v_id;
    if v_grupo is not null then
      v_id := coalesce(public.estoque_material_do_grupo(v_grupo, concat_ws(' ', p_material, p_detalhe)), v_id);
    end if;
  end if;
  return v_id;
end
$$;

-- Anestésico registrado ({anestesico, vasoconstritor}) → material.
create or replace function public.estoque_material_anestesico(p_anestesico text, p_vaso text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := public.normalizar(concat_ws(' ', p_anestesico, p_vaso));
  v_droga text := substring(v from '(articaina|lidocaina|mepivacaina|prilocaina|bupivacaina|benzocaina)');
  v_id uuid;
begin
  if v_droga is null then
    return public.estoque_achar_material(p_anestesico);
  end if;
  select id into v_id
    from public.estoque_materiais
   where ativo and categoria = 'anestesico'
     and public.normalizar(nome || ' ' || array_to_string(sinonimos, ' ')) like '%' || v_droga || '%'
   order by case
              when v ~ '\msem\M' then (codigo ~ 'sem_vaso')::int
              when v ~ 'felipressina' then (codigo ~ 'felipressina')::int
              when v ~ '(epinefrina|adrenalina)' then (codigo ~ 'epinefrina')::int
              else (codigo !~ 'sem_vaso')::int end desc,
            case when v ~ '200' then (codigo ~ '200')::int else 0 end desc,
            nome
   limit 1;
  return v_id;
end
$$;

-- Quantidade dita (na unidade dita) → unidade de uso.
create or replace function public.estoque_para_uso(m public.estoque_materiais, p_qtd numeric, p_unidade text,
                                                   p_padrao text default 'uso')
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_u text := public.estoque_unidade(p_unidade);
begin
  if p_qtd is null then
    raise exception 'Informe a quantidade de %.', m.nome;
  end if;
  if v_u is null then
    return case when p_padrao = 'compra' then p_qtd * m.fator else p_qtd end;
  end if;
  if v_u = public.estoque_unidade(m.unidade_uso) then
    return p_qtd;
  end if;
  if v_u = public.estoque_unidade(m.unidade_compra) then
    return p_qtd * m.fator;
  end if;
  raise exception 'Unidade "%" não serve para %: use % (1 % = % %) ou %.',
    p_unidade, m.nome, m.unidade_compra, m.unidade_compra, public.estoque_num(m.fator),
    public.estoque_plural(m.unidade_uso, m.fator), m.unidade_uso;
end
$$;

-- ---------------------------------------------------------------------
-- Saldos e movimentos
-- ---------------------------------------------------------------------
create or replace function public.estoque_saldo(p_material uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(quantidade), 0) from public.estoque_movimentos where material_id = p_material
$$;

create or replace function public.estoque_lotes_saldo(p_material uuid)
returns table (lote_id uuid, lote text, validade date, saldo numeric, criado_em timestamptz)
language sql
stable
set search_path = ''
as $$
  select l.id, l.lote, l.validade, coalesce(sum(m.quantidade), 0), l.criado_em
    from public.estoque_lotes l
    left join public.estoque_movimentos m on m.lote_id = l.id
   where l.material_id = p_material
   group by l.id
$$;

-- Material já tem saldo registrado (compra, contagem ou entrada)?
create or replace function public.estoque_acompanhado(p_material uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.estoque_movimentos
                  where material_id = p_material and tipo in ('compra', 'contagem', 'entrada_avulsa'))
$$;

-- Saída (quantidade positiva, na unidade de uso). Sem lote informado, sai
-- pelo lote que vence primeiro (FEFO); o uso não pega lote vencido. O que
-- faltar sai do saldo sem lote, que pode ficar negativo (sinal de que é
-- hora de contar). Custo = custo médio atual. Devolve o custo da saída.
create or replace function public.estoque_saida(
  p_material uuid,
  p_qtd numeric,
  p_tipo text,
  p_data date default null,
  p_atendimento_id uuid default null,
  p_item_id uuid default null,
  p_paciente_id uuid default null,
  p_motivo text default null,
  p_lote_id uuid default null)
returns numeric
language plpgsql
set search_path = ''
as $$
declare
  v_cm numeric;
  v_rest numeric := p_qtd;
  v_q numeric;
  v_data date := coalesce(p_data, public.hoje());
  l record;
begin
  if p_qtd is null or p_qtd <= 0 then
    return 0;
  end if;
  select custo_medio into v_cm from public.estoque_materiais where id = p_material for update;
  if not found then
    raise exception 'Material não encontrado.';
  end if;
  if p_lote_id is null then
    for l in
      select s.lote_id, s.saldo from public.estoque_lotes_saldo(p_material) s
       where s.saldo > 0
         and (p_tipo not in ('uso_atendimento', 'uso_avulso') or s.validade is null or s.validade >= v_data)
       order by s.validade nulls last, s.criado_em
    loop
      v_q := least(v_rest, l.saldo);
      insert into public.estoque_movimentos (material_id, lote_id, tipo, quantidade, custo_unitario, data,
                                             atendimento_id, atendimento_item_id, paciente_id, motivo)
      values (p_material, l.lote_id, p_tipo, -v_q, v_cm, v_data, p_atendimento_id, p_item_id, p_paciente_id, p_motivo);
      v_rest := v_rest - v_q;
      exit when v_rest <= 0;
    end loop;
  end if;
  if v_rest > 0 then
    insert into public.estoque_movimentos (material_id, lote_id, tipo, quantidade, custo_unitario, data,
                                           atendimento_id, atendimento_item_id, paciente_id, motivo)
    values (p_material, p_lote_id, p_tipo, -v_rest, v_cm, v_data, p_atendimento_id, p_item_id, p_paciente_id, p_motivo);
  end if;
  return round(p_qtd * v_cm, 2);
end
$$;

-- Entrada (quantidade positiva, unidade de uso). Com custo, recalcula o
-- custo médio ponderado; sem custo, mantém o atual.
create or replace function public.estoque_entrada(
  p_material uuid,
  p_qtd numeric,
  p_custo numeric,
  p_lote_id uuid,
  p_tipo text,
  p_compra_item_id uuid default null,
  p_data date default null,
  p_motivo text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_m public.estoque_materiais;
  v_saldo numeric;
  v_novo numeric;
begin
  select * into v_m from public.estoque_materiais where id = p_material for update;
  if not found then
    raise exception 'Material não encontrado.';
  end if;
  if p_custo is not null then
    v_saldo := public.estoque_saldo(p_material);
    v_novo := case when v_saldo <= 0 or v_m.custo_medio is null then p_custo
                   else (v_saldo * v_m.custo_medio + p_qtd * p_custo) / (v_saldo + p_qtd) end;
    v_novo := round(v_novo, 6);
    if v_novo is distinct from v_m.custo_medio then
      update public.estoque_materiais set custo_medio = v_novo where id = p_material;
    end if;
  end if;
  insert into public.estoque_movimentos (material_id, lote_id, tipo, quantidade, custo_unitario, data,
                                         compra_item_id, motivo)
  values (p_material, p_lote_id, p_tipo, p_qtd, coalesce(p_custo, v_m.custo_medio), coalesce(p_data, public.hoje()),
          p_compra_item_id, p_motivo);
end
$$;

-- Desfaz um movimento com outro de sinal contrário. Desfazer uma entrada
-- com custo tira o efeito dela do custo médio.
create or replace function public.estoque_estornar(p_movimento uuid, p_motivo text)
returns public.estoque_movimentos
language plpgsql
set search_path = ''
as $$
declare
  v public.estoque_movimentos;
  v_m public.estoque_materiais;
  v_saldo numeric;
  v_novo numeric;
  v_r public.estoque_movimentos;
begin
  select * into v from public.estoque_movimentos where id = p_movimento;
  if not found then
    raise exception 'Movimento % não encontrado.', p_movimento;
  end if;
  if v.tipo = 'estorno' then
    raise exception 'Esse movimento já é um estorno; para voltar atrás, registre um movimento novo.';
  end if;
  if exists (select 1 from public.estoque_movimentos where estorna_id = v.id) then
    raise exception 'Esse movimento já foi desfeito.';
  end if;
  select * into v_m from public.estoque_materiais where id = v.material_id for update;
  if v.quantidade > 0 and v.custo_unitario is not null and v_m.custo_medio is not null then
    v_saldo := public.estoque_saldo(v.material_id);
    if v_saldo - v.quantidade > 0 then
      v_novo := round((v_saldo * v_m.custo_medio - v.quantidade * v.custo_unitario) / (v_saldo - v.quantidade), 6);
      if v_novo > 0 and v_novo is distinct from v_m.custo_medio then
        update public.estoque_materiais set custo_medio = v_novo where id = v.material_id;
      end if;
    end if;
  end if;
  insert into public.estoque_movimentos (material_id, lote_id, tipo, quantidade, custo_unitario, data,
                                         compra_item_id, atendimento_id, atendimento_item_id, paciente_id,
                                         estorna_id, motivo)
  values (v.material_id, v.lote_id, 'estorno', -v.quantidade, v.custo_unitario, v.data,
          v.compra_item_id, v.atendimento_id, v.atendimento_item_id, v.paciente_id, v.id, p_motivo)
  returning * into v_r;
  return v_r;
end
$$;

create or replace function public.estoque_estornar_atendimento(p_atendimento uuid, p_motivo text)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select m.id from public.estoque_movimentos m
     where m.atendimento_id = p_atendimento and m.tipo = 'uso_atendimento'
       and not exists (select 1 from public.estoque_movimentos e where e.estorna_id = m.id)
     order by m.registrado_em, m.id
  loop
    perform public.estoque_estornar(v_id, p_motivo);
    v_n := v_n + 1;
  end loop;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------
-- Baixa automática a partir do prontuário
-- ---------------------------------------------------------------------

-- Materiais citados com quantidade numérica em atendimentos.materiais.
create or replace function public.estoque_citados(p_materiais jsonb)
returns table (material_id uuid, grupo text, categoria text, quantidade numeric, unidade text)
language sql
stable
set search_path = ''
as $$
  select m.id, m.grupo, m.categoria, c.q, c.u
    from (select case when jsonb_typeof(x -> 'quantidade') = 'number' then (x ->> 'quantidade')::numeric end q,
                 x ->> 'unidade' u,
                 public.estoque_material_citado(x ->> 'material', x ->> 'detalhe') mid
            from jsonb_array_elements(case when jsonb_typeof(p_materiais) = 'array' then p_materiais
                                           else '[]'::jsonb end) x) c
    join public.estoque_materiais m on m.id = c.mid
   where c.q > 0
$$;

create or replace function public.estoque_texto_materiais(p_materiais jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select string_agg(concat_ws(' ', x ->> 'material', x ->> 'detalhe'), ' ; ')
    from jsonb_array_elements(case when jsonb_typeof(p_materiais) = 'array' then p_materiais
                                   else '[]'::jsonb end) x
$$;

-- Baixa as linhas de um kit, menos o que foi citado com quantidade no
-- atendimento (o citado vale mais que o kit).
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
  for k in select ki.material_id, ki.grupo, ki.quantidade from public.estoque_kit_itens ki where ki.kit_id = p_kit
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

-- Depois de gravar um atendimento: desfaz a baixa do atendimento
-- corrigido, baixa o kit base, a anestesia (tubetes + agulha) e os
-- materiais citados com quantidade. Nunca impede o registro clínico: se
-- algo der errado no estoque, só fica um aviso no log.
create or replace function public.estoque_baixa_atendimento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_m public.estoque_materiais;
  v_ctx text;
  v_tem_agulha boolean;
  v_tem_anestesia boolean;
  v_tub numeric;
  v_mat uuid;
  v_kit uuid;
  a jsonb;
  c record;
begin
  begin
    if new.corrige_atendimento_id is not null then
      for v_id in
        select new.corrige_atendimento_id
        union
        select x.id from public.atendimentos x
         where x.corrige_atendimento_id = new.corrige_atendimento_id and x.id <> new.id
      loop
        perform public.estoque_estornar_atendimento(v_id, 'Correção do atendimento: ' || coalesce(new.motivo_correcao, ''));
      end loop;
    end if;

    v_tem_anestesia := jsonb_array_length(new.anestesia) > 0;
    v_tem_agulha := exists (select 1 from public.estoque_citados(new.materiais) x where x.categoria = 'agulha');

    -- Materiais citados com quantidade (anestésico citado conta pela anestesia)
    for c in select * from public.estoque_citados(new.materiais) loop
      continue when c.categoria = 'anestesico' and v_tem_anestesia;
      select * into v_m from public.estoque_materiais where id = c.material_id;
      begin
        perform public.estoque_saida(c.material_id, public.estoque_para_uso(v_m, c.quantidade, c.unidade, 'uso'),
                                     'uso_atendimento', new.data, new.id, null, new.paciente_id, null);
      exception when others then
        raise warning 'Estoque: material citado "%" sem baixa: %', v_m.nome, sqlerrm;
      end;
    end loop;

    -- Anestesia: tubetes (1 se não disse) e uma agulha por anestesia injetável
    for a in select * from jsonb_array_elements(new.anestesia) loop
      v_tub := case when jsonb_typeof(a -> 'tubetes') = 'number' then (a ->> 'tubetes')::numeric else 1 end;
      continue when v_tub <= 0;
      v_mat := public.estoque_material_anestesico(a ->> 'anestesico', a ->> 'vasoconstritor');
      v_m := null;
      if v_mat is not null then
        select * into v_m from public.estoque_materiais where id = v_mat;
        perform public.estoque_saida(v_mat, case when public.estoque_unidade(v_m.unidade_uso) = 'tubete' then v_tub else 1 end,
                                     'uso_atendimento', new.data, new.id, null, new.paciente_id, null);
      end if;
      if not v_tem_agulha
         and public.normalizar(a ->> 'anestesico') !~ '(topic|benzocaina|pomada|spray)'
         and (v_m.id is null or public.estoque_unidade(v_m.unidade_uso) = 'tubete') then
        select id into v_mat from public.estoque_materiais
         where ativo and codigo = case
           when public.normalizar(a ->> 'tecnica') ~ '(alveolar|bloqueio|pterig|spix|mandibular|troncular|infraorbit|tuber|regional)'
             then 'agulha_longa_27g' else 'agulha_curta_30g' end;
        if found then
          perform public.estoque_saida(v_mat, 1, 'uso_atendimento', new.data, new.id, null, new.paciente_id, null);
        end if;
      end if;
    end loop;

    -- Kit base de biossegurança
    select id into v_kit from public.estoque_kits where base and ativo;
    if v_kit is not null then
      v_ctx := public.estoque_texto_materiais(new.materiais);
      perform public.estoque_baixa_kit(v_kit, new.materiais, v_ctx, new.evolucao, new.data, new.id, null, new.paciente_id);
    end if;
  exception when others then
    raise warning 'Estoque: baixa automática do atendimento % não foi feita: %', new.id, sqlerrm;
  end;
  return null;
end
$$;

-- Depois de gravar um procedimento concluído do catálogo: baixa o kit dele.
create or replace function public.estoque_baixa_item()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_a public.atendimentos;
  v_kit uuid;
begin
  if new.procedimento_id is null or new.etapa <> 'concluido' then
    return null;
  end if;
  begin
    select id into v_kit from public.estoque_kits where procedimento_id = new.procedimento_id and ativo;
    if v_kit is not null then
      select * into v_a from public.atendimentos where id = new.atendimento_id;
      perform public.estoque_baixa_kit(
        v_kit, v_a.materiais,
        concat_ws(' ; ', new.observacao, public.estoque_texto_materiais(v_a.materiais)),
        v_a.evolucao,
        v_a.data, v_a.id, new.id, v_a.paciente_id);
    end if;
  exception when others then
    raise warning 'Estoque: baixa do procedimento "%" não foi feita: %', new.procedimento, sqlerrm;
  end;
  return null;
end
$$;

create trigger estoque_baixa after insert on public.atendimentos
  for each row execute function public.estoque_baixa_atendimento();
create trigger estoque_baixa after insert on public.atendimento_itens
  for each row execute function public.estoque_baixa_item();

-- ---------------------------------------------------------------------
-- Consultas reutilizáveis (financeiro, avisos)
-- ---------------------------------------------------------------------

-- Consumo médio por dia (uso em atendimento e avulso, menos estornos).
-- Janela: últimos p_dias, mas pelo menos 14 dias desde o início do estoque.
create or replace function public.estoque_consumo_diario(p_material uuid, p_dias int default 60)
returns numeric
language sql
stable
set search_path = ''
as $$
  with j as (
    select least(p_dias, greatest(14, public.hoje() - coalesce((select min(data) from public.estoque_movimentos),
                                                               public.hoje()) + 1)) dias)
  select greatest(0, -coalesce(sum(m.quantidade), 0)) / (select dias from j)
    from public.estoque_movimentos m
    left join public.estoque_movimentos o on o.id = m.estorna_id
   where m.material_id = p_material
     and m.data > public.hoje() - (select dias from j)
     and (m.tipo in ('uso_atendimento', 'uso_avulso')
          or (m.tipo = 'estorno' and o.tipo in ('uso_atendimento', 'uso_avulso')))
$$;

-- Ponto de pedido = consumo diário × prazo de entrega + estoque mínimo.
create or replace function public.estoque_ponto_pedido(m public.estoque_materiais)
returns numeric
language sql
stable
set search_path = ''
as $$
  select ceil(public.estoque_consumo_diario(m.id) * m.prazo_entrega_dias) + m.estoque_minimo
$$;

-- Anestésico mais usado nos últimos 90 dias (para estimar custo).
create or replace function public.estoque_anestesico_padrao()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select m.material_id from public.estoque_movimentos m
       join public.estoque_materiais x on x.id = m.material_id and x.categoria = 'anestesico'
      where m.tipo = 'uso_atendimento' and m.data > public.hoje() - 90
      group by m.material_id order by sum(m.quantidade) asc limit 1),
    (select id from public.estoque_materiais where codigo = 'articaina_4_epinefrina_100'))
$$;

-- Custo estimado de materiais de um procedimento (kit + anestesia típica),
-- pelo custo médio atual. Com p_incluir_base, soma o kit base do
-- atendimento. Material ainda sem custo conta zero e aparece em sem_custo.
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

create or replace function public.custo_materiais(p_procedimento_id uuid, p_incluir_base boolean default false)
returns numeric
language sql
stable
set search_path = ''
as $$
  select (public.custo_materiais_detalhe(p_procedimento_id, p_incluir_base) ->> 'custo_total')::numeric
$$;

-- Custo real de material baixado num atendimento (já líquido de estornos).
create or replace function public.custo_materiais_atendimento(p_atendimento_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(round(-sum(quantidade * coalesce(custo_unitario, 0)), 2), 0)
    from public.estoque_movimentos where atendimento_id = p_atendimento_id
$$;

-- Lista de compras sugerida: materiais acompanhados no ponto de pedido ou
-- abaixo. Quantidade = até o ponto de pedido + 30 dias de consumo (sem
-- consumo, 2× o mínimo), arredondada para a unidade de compra.
create or replace function public.estoque_lista_compras()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with b as (
    select m.*, public.estoque_saldo(m.id) saldo, public.estoque_consumo_diario(m.id) consumo
      from public.estoque_materiais m
     where m.ativo and public.estoque_acompanhado(m.id)),
  c as (
    select b.*, ceil(b.consumo * b.prazo_entrega_dias) + b.estoque_minimo ponto,
           case when b.consumo > 0 then ceil(b.consumo * b.prazo_entrega_dias) + b.estoque_minimo + ceil(b.consumo * 30)
                else 2 * b.estoque_minimo end alvo
      from b),
  s as (
    select c.*, greatest(1, ceil((c.alvo - c.saldo) / c.fator)) comprar, u.preco, u.fornecedor
      from c
      left join lateral (
        select round(i.custo_unitario_uso * c.fator, 2) preco, f.nome fornecedor
          from public.estoque_compra_itens i
          join public.estoque_compras co on co.id = i.compra_id and co.cancelada_em is null
          left join public.estoque_fornecedores f on f.id = co.fornecedor_id
         where i.material_id = c.id and i.custo_unitario_uso is not null
         order by co.data desc, i.registrado_em desc
         limit 1) u on true
     where c.saldo < 0 or (c.saldo <= c.ponto and (c.consumo > 0 or c.estoque_minimo > 0)))
  select jsonb_build_object(
    'itens', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'material', s.nome, 'codigo', s.codigo,
        'saldo', public.estoque_qtd(s.unidade_uso, s.unidade_compra, s.fator, s.saldo),
        'ponto_de_pedido', public.estoque_qtd(s.unidade_uso, s.unidade_compra, s.fator, s.ponto),
        'comprar', public.estoque_num(s.comprar) || ' ' || public.estoque_plural(s.unidade_compra, s.comprar),
        'comprar_quantidade', s.comprar,
        'unidade_compra', s.unidade_compra,
        'dura_dias', case when s.consumo > 0 then floor(greatest(s.saldo, 0) / s.consumo) end,
        'ultimo_preco', s.preco,
        'ultimo_fornecedor', s.fornecedor,
        'valor_estimado', round(s.comprar * s.preco, 2),
        'motivo', case when s.saldo < 0 then 'saldo negativo: conte o que tem'
                       when s.saldo <= s.estoque_minimo then 'abaixo do mínimo'
                       else 'acaba antes da próxima entrega' end))
      order by s.fornecedor nulls last, s.saldo / nullif(s.ponto, 0) nulls first, s.nome), '[]'::jsonb),
    'total_estimado', coalesce(round(sum(s.comprar * s.preco), 2), 0),
    'itens_sem_preco', count(*) filter (where s.preco is null))
  from s
$$;

-- Avisos de estoque: saldo negativo, abaixo do mínimo ou no ponto de
-- pedido (só materiais com saldo registrado) e, com p_validade, lotes
-- vencidos ou vencendo em 30 dias. p_materiais limita aos materiais dados.
create or replace function public.estoque_avisos(p_materiais uuid[] default null, p_validade boolean default true)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_avisos text[] := '{}';
  r record;
  v_ponto numeric;
  v_consumo numeric;
  v_sem text[];
begin
  for r in
    select m.*, public.estoque_saldo(m.id) saldo
      from public.estoque_materiais m
     where m.ativo and (p_materiais is null or m.id = any(p_materiais)) and public.estoque_acompanhado(m.id)
     order by m.nome
  loop
    v_consumo := public.estoque_consumo_diario(r.id);
    v_ponto := ceil(v_consumo * r.prazo_entrega_dias) + r.estoque_minimo;
    if r.saldo < 0 then
      v_avisos := v_avisos || format('%s: saldo negativo (%s). Saiu mais do que entrou: faça uma contagem.',
                                     r.nome, public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.saldo));
    elsif r.estoque_minimo > 0 and r.saldo <= r.estoque_minimo then
      v_avisos := v_avisos || format('%s: restam %s (mínimo %s).', r.nome,
                                     public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.saldo),
                                     public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.estoque_minimo));
    elsif v_consumo > 0 and r.saldo <= v_ponto then
      v_avisos := v_avisos || format('%s: restam %s, dá para uns %s dias; a entrega leva %s.', r.nome,
                                     public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.saldo),
                                     floor(r.saldo / v_consumo), r.prazo_entrega_dias);
    end if;
  end loop;

  if p_validade then
    for r in
      select m.nome, m.unidade_uso, m.unidade_compra, m.fator, s.lote, s.validade, s.saldo
        from public.estoque_materiais m
        cross join lateral public.estoque_lotes_saldo(m.id) s
       where m.ativo and (p_materiais is null or m.id = any(p_materiais))
         and s.saldo > 0 and s.validade <= public.hoje() + 30
       order by s.validade, m.nome
    loop
      v_avisos := v_avisos || case
        when r.validade < public.hoje() then
          format('%s%s venceu em %s e ainda tem %s: se foi descartado, registre como vencido.', r.nome,
                 coalesce(' (lote ' || r.lote || ')', ''), to_char(r.validade, 'DD/MM/YYYY'),
                 public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.saldo))
        else
          format('%s%s vence em %s (%s): use primeiro.', r.nome, coalesce(' (lote ' || r.lote || ')', ''),
                 to_char(r.validade, 'DD/MM/YYYY'), public.estoque_qtd(r.unidade_uso, r.unidade_compra, r.fator, r.saldo))
        end;
    end loop;
  end if;

  if p_materiais is null then
    select array_agg(m.nome order by m.nome) into v_sem
      from public.estoque_materiais m
     where m.ativo and not public.estoque_acompanhado(m.id)
       and exists (select 1 from public.estoque_movimentos x where x.material_id = m.id);
    if cardinality(v_sem) > 0 then
      v_avisos := v_avisos || format('%s material(is) com uso registrado ainda sem contagem inicial (%s%s): '
                                     'conte e registre com movimentar_estoque, tipo contagem.',
                                     cardinality(v_sem), array_to_string(v_sem[1:5], ', '),
                                     case when cardinality(v_sem) > 5 then '...' else '' end);
    end if;
  end if;
  return v_avisos;
end
$$;

-- Avisos de estoque dos materiais que um atendimento acabou de baixar
-- (para devolver junto com o registro do atendimento).
create or replace function public.estoque_avisos_atendimento(p_atendimento_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select public.estoque_avisos(
    coalesce((select array_agg(distinct material_id) from public.estoque_movimentos
               where atendimento_id = p_atendimento_id), '{}'),
    false)
$$;

-- ---------------------------------------------------------------------
-- Permissões: só o service_role (servidor MCP)
-- ---------------------------------------------------------------------
alter table public.estoque_materiais enable row level security;
alter table public.estoque_fornecedores enable row level security;
alter table public.estoque_compras enable row level security;
alter table public.estoque_compra_itens enable row level security;
alter table public.estoque_lotes enable row level security;
alter table public.estoque_movimentos enable row level security;
alter table public.estoque_kits enable row level security;
alter table public.estoque_kit_itens enable row level security;

revoke all on table
  public.estoque_materiais, public.estoque_fornecedores, public.estoque_compras, public.estoque_compra_itens,
  public.estoque_lotes, public.estoque_movimentos, public.estoque_kits, public.estoque_kit_itens
  from anon, authenticated;

revoke execute on function
  public.estoque_bloquear_exclusao(),
  public.estoque_so_inclusao(),
  public.estoque_raiz(text),
  public.estoque_palavras(text),
  public.estoque_frase_raiz(text),
  public.estoque_unidade(text),
  public.estoque_plural(text, numeric),
  public.estoque_num(numeric),
  public.estoque_reais(numeric),
  public.estoque_qtd(text, text, numeric, numeric),
  public.estoque_compra_so_cancelamento(),
  public.estoque_palavras_material(public.estoque_materiais),
  public.estoque_achar_material(text),
  public.estoque_sugestoes(text, int),
  public.estoque_variante(text[], text),
  public.estoque_material_do_grupo(text, text, text),
  public.estoque_material_citado(text, text),
  public.estoque_material_anestesico(text, text),
  public.estoque_para_uso(public.estoque_materiais, numeric, text, text),
  public.estoque_saldo(uuid),
  public.estoque_lotes_saldo(uuid),
  public.estoque_acompanhado(uuid),
  public.estoque_saida(uuid, numeric, text, date, uuid, uuid, uuid, text, uuid),
  public.estoque_entrada(uuid, numeric, numeric, uuid, text, uuid, date, text),
  public.estoque_estornar(uuid, text),
  public.estoque_estornar_atendimento(uuid, text),
  public.estoque_citados(jsonb),
  public.estoque_texto_materiais(jsonb),
  public.estoque_baixa_kit(uuid, jsonb, text, text, date, uuid, uuid, uuid),
  public.estoque_baixa_atendimento(),
  public.estoque_baixa_item(),
  public.estoque_consumo_diario(uuid, int),
  public.estoque_ponto_pedido(public.estoque_materiais),
  public.estoque_anestesico_padrao(),
  public.custo_materiais_detalhe(uuid, boolean),
  public.custo_materiais(uuid, boolean),
  public.custo_materiais_atendimento(uuid),
  public.estoque_lista_compras(),
  public.estoque_avisos(uuid[], boolean),
  public.estoque_avisos_atendimento(uuid)
  from public, anon, authenticated;

grant execute on function
  public.estoque_bloquear_exclusao(),
  public.estoque_so_inclusao(),
  public.estoque_raiz(text),
  public.estoque_palavras(text),
  public.estoque_frase_raiz(text),
  public.estoque_unidade(text),
  public.estoque_plural(text, numeric),
  public.estoque_num(numeric),
  public.estoque_reais(numeric),
  public.estoque_qtd(text, text, numeric, numeric),
  public.estoque_compra_so_cancelamento(),
  public.estoque_palavras_material(public.estoque_materiais),
  public.estoque_achar_material(text),
  public.estoque_sugestoes(text, int),
  public.estoque_variante(text[], text),
  public.estoque_material_do_grupo(text, text, text),
  public.estoque_material_citado(text, text),
  public.estoque_material_anestesico(text, text),
  public.estoque_para_uso(public.estoque_materiais, numeric, text, text),
  public.estoque_saldo(uuid),
  public.estoque_lotes_saldo(uuid),
  public.estoque_acompanhado(uuid),
  public.estoque_saida(uuid, numeric, text, date, uuid, uuid, uuid, text, uuid),
  public.estoque_entrada(uuid, numeric, numeric, uuid, text, uuid, date, text),
  public.estoque_estornar(uuid, text),
  public.estoque_estornar_atendimento(uuid, text),
  public.estoque_citados(jsonb),
  public.estoque_texto_materiais(jsonb),
  public.estoque_baixa_kit(uuid, jsonb, text, text, date, uuid, uuid, uuid),
  public.estoque_baixa_atendimento(),
  public.estoque_baixa_item(),
  public.estoque_consumo_diario(uuid, int),
  public.estoque_ponto_pedido(public.estoque_materiais),
  public.estoque_anestesico_padrao(),
  public.custo_materiais_detalhe(uuid, boolean),
  public.custo_materiais(uuid, boolean),
  public.custo_materiais_atendimento(uuid),
  public.estoque_lista_compras(),
  public.estoque_avisos(uuid[], boolean),
  public.estoque_avisos_atendimento(uuid)
  to service_role;
