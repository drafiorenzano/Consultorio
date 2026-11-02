-- =====================================================================
-- Etapa 3 (documentos): plano de tratamento / orçamento.
--
-- * orcamentos: número sequencial + versão. Status rascunho, apresentado,
--   aprovado, parcial (aprovação parcial), recusado, concluido e
--   substituido (quando uma versão nova toma o lugar). "expirado" é
--   calculado: apresentado com a validade vencida.
-- * orcamento_itens: procedimento do catálogo (ou texto livre), dente,
--   faces ou região, quantidade, valor unitário congelado, fase 1–7,
--   alternativa (A–D) e status do item.
-- * Gatilhos: a marca "realizado" no odontograma que encerra o plano do
--   item marca o item como realizado; procedimento concluído no
--   atendimento faz o mesmo para itens sem marca no odontograma.
--   Correções (anulação de marca, atendimento corrigido) desfazem.
-- * mcp_montar_orcamento / mcp_alterar_orcamento.
-- =====================================================================

alter table public.documentos_config
  add column desconto_acumula boolean not null default false;
comment on column public.documentos_config.desconto_acumula is
  'Se o desconto à vista se soma a um desconto dado no orçamento (padrão: não).';

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
create table public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  numero int not null,
  versao int not null default 1 check (versao >= 1),
  paciente_id uuid not null references public.pacientes (id),
  status text not null default 'rascunho' check (status in (
    'rascunho', 'apresentado', 'aprovado', 'parcial', 'recusado', 'expirado', 'concluido', 'substituido')),
  titulo text not null default 'Plano de tratamento',
  validade date not null,
  desconto_tipo text check (desconto_tipo in ('percentual', 'valor')),
  desconto_valor numeric(10, 2) not null default 0 check (desconto_valor >= 0),
  pagamento jsonb not null,                   -- condições no momento (cópia de documentos_config + ajustes)
  observacoes text,
  substitui_id uuid references public.orcamentos (id),
  apresentado_em date,
  aprovado_em date,
  aprovacao text check (aprovacao in ('total', 'parcial')),
  forma_escolhida text,
  recusado_em date,
  motivo_recusa text,
  concluido_em date,
  acompanhamentos jsonb not null default '[]' check (jsonb_typeof(acompanhamentos) = 'array'),
  profissional text,
  cro text,
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (numero, versao),
  check (desconto_tipo is not null or desconto_valor = 0),
  check (desconto_tipo is distinct from 'percentual' or desconto_valor <= 100)
);
comment on table public.orcamentos is
  'Planos de tratamento / orçamentos. Uma mudança depois de apresentado vira nova versão (mesmo número).';
create index orcamentos_paciente_idx on public.orcamentos (paciente_id, criado_em desc);
create index orcamentos_status_idx on public.orcamentos (status) where status in ('rascunho', 'apresentado');
create index orcamentos_solicitacao_idx on public.orcamentos (solicitacao_id);

create table public.orcamento_itens (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos (id),
  ordem int not null check (ordem >= 1),
  procedimento_id uuid references public.procedimentos (id),
  descricao text not null check (length(btrim(descricao)) > 0),
  explicacao text,                            -- em linguagem simples, para o paciente
  dente smallint,
  faces text,
  regiao text,
  quantidade int not null default 1 check (quantidade between 1 and 99),
  valor_unitario numeric(10, 2) not null check (valor_unitario >= 0),
  fase smallint not null default 4 check (fase between 1 and 7),
  alternativa text check (alternativa in ('A', 'B', 'C', 'D')),
  status text not null default 'incluido' check (status in ('incluido', 'aprovado', 'recusado', 'realizado', 'cancelado')),
  marca_id uuid references public.odontograma (id),          -- plano no odontograma que originou o item
  realizado_em date,
  realizado_marca_id uuid references public.odontograma (id),
  atendimento_item_id uuid references public.atendimento_itens (id),
  observacao text,
  unique (orcamento_id, ordem)
);
comment on table public.orcamento_itens is 'Itens do orçamento, com valor congelado no momento em que foi montado.';
create index orcamento_itens_marca_idx on public.orcamento_itens (marca_id) where marca_id is not null;
create index orcamento_itens_realizado_marca_idx on public.orcamento_itens (realizado_marca_id)
  where realizado_marca_id is not null;
create index orcamento_itens_atendimento_idx on public.orcamento_itens (atendimento_item_id)
  where atendimento_item_id is not null;

create trigger orcamentos_atualizado_em before update on public.orcamentos
  for each row execute function public.tocar_atualizado_em();
create trigger orcamentos_auditoria after insert or update on public.orcamentos
  for each row execute function public.registrar_auditoria();
create trigger orcamentos_sem_exclusao before delete on public.orcamentos
  for each row execute function public.bloquear_alteracao();
create trigger orcamentos_sem_truncate before truncate on public.orcamentos
  for each statement execute function public.bloquear_alteracao();
create trigger orcamento_itens_auditoria after insert or update on public.orcamento_itens
  for each row execute function public.registrar_auditoria();
create trigger orcamento_itens_sem_exclusao before delete on public.orcamento_itens
  for each row execute function public.bloquear_alteracao();
create trigger orcamento_itens_sem_truncate before truncate on public.orcamento_itens
  for each statement execute function public.bloquear_alteracao();

alter table public.orcamentos enable row level security;
alter table public.orcamento_itens enable row level security;
revoke all on table public.orcamentos, public.orcamento_itens from anon, authenticated;

-- ---------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------
-- Caminho do arquivo com um sufixo curto: dois PDFs do mesmo documento no
-- mesmo segundo não colidem.
create or replace function public.documentos_caminho(p_paciente uuid, p_tipo text, p_numero int, p_versao int default null)
returns text
language sql
volatile
set search_path = ''
as $$
  select p_paciente::text || '/' || p_tipo || '-' || p_numero ||
         coalesce('-v' || p_versao, '') || '-' ||
         to_char(clock_timestamp() at time zone public.fuso(), 'YYYYMMDD-HH24MISS') || '-' ||
         substr(md5(random()::text), 1, 4) || '.pdf'
$$;

create or replace function public.documentos_ler_numero(p_valor text, p_campo text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if nullif(btrim(p_valor), '') is null then
    return null;
  end if;
  return replace(btrim(p_valor), ',', '.')::numeric;
exception when others then
  raise exception '% inválido: "%". Use um número (ex.: 350 ou 350.50).', p_campo, p_valor;
end
$$;

create or replace function public.orcamento_fase_padrao(p_codigo text, p_categoria text)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select (case
    when p_codigo in ('pulpectomia', 'restauracao_provisoria') then 1
    when p_categoria in ('diagnostico', 'prevencao', 'cirurgia') then 1
    when p_categoria = 'periodontia' then 2
    when p_categoria = 'endodontia' then 3
    when p_categoria = 'dentistica' then 4
    when p_categoria in ('protese', 'implante', 'disfuncao') then 5
    when p_categoria = 'estetica' then 6
    else 4 end)::smallint
$$;

create or replace function public.orcamento_fase_nome(p_fase int)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['Urgência e preparo da boca', 'Tratamento da gengiva', 'Tratamento de canal', 'Restaurações',
                'Prótese e implante', 'Estética', 'Manutenção'])[p_fase]
$$;

-- Explicação curta, em linguagem simples, para o paciente.
create or replace function public.explicacao_leiga(p_codigo text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_codigo is null then null
    when p_codigo like 'resina\_%' and p_codigo <> 'resina_indireta_zirconia' then
      'Restauração da cor do dente, para tratar cárie, fratura ou desgaste.'
    when p_codigo like 'exodontia\_siso%' then 'Remoção do dente do siso.'
    when p_codigo = 'exodontia_deciduo' then 'Remoção do dente de leite.'
    when p_codigo like 'exodontia\_%' then 'Remoção do dente.'
    when p_codigo = 'retratamento_canal' then 'Refazer um tratamento de canal antigo que voltou a dar problema.'
    when p_codigo like 'canal\_%' then 'Tratamento do nervo do dente para tirar a dor ou a infecção e manter o dente.'
    when p_codigo = 'pulpectomia' then 'Alívio da dor de dente com a limpeza do nervo (primeira etapa do canal).'
    when p_codigo = 'implante_unitario' then 'Raiz artificial de titânio que substitui o dente perdido.'
    when p_codigo = 'coroa_sobre_implante' then 'Dente de porcelana fixado sobre o implante.'
    when p_codigo = 'protocolo_gm' then 'Dentes fixos sobre implantes para a arcada inteira.'
    when p_codigo = 'coroa_provisoria' then 'Dente provisório enquanto o definitivo fica pronto.'
    when p_codigo like 'coroa\_%' or p_codigo = 'resina_indireta_zirconia' then
      'Peça que cobre e protege o dente inteiro, devolvendo forma e cor.'
    when p_codigo = 'nucleo' then 'Pino que dá sustentação à coroa em dente com canal.'
    when p_codigo = 'consulta_preventiva' then 'Limpeza completa, polimento e flúor.'
    when p_codigo = 'consulta_avaliacao' then 'Exame completo da boca e planejamento do tratamento.'
    when p_codigo = 'urgencia' then 'Atendimento para aliviar a dor ou resolver uma urgência.'
    when p_codigo = 'radiografia_periapical' then 'Radiografia do dente para o diagnóstico.'
    when p_codigo = 'selante' then 'Proteção dos sulcos do dente contra a cárie.'
    when p_codigo = 'restauracao_provisoria' then 'Fechamento provisório do dente até o tratamento definitivo.'
    when p_codigo = 'raspagem_sextante' then 'Limpeza profunda abaixo da gengiva para tratar a inflamação.'
    when p_codigo = 'gengivectomia' then 'Ajuste do contorno da gengiva.'
    when p_codigo = 'frenectomia' then 'Pequena cirurgia no freio do lábio ou da língua.'
    when p_codigo = 'biopsia' then 'Retirada de um pequeno pedaço de tecido para exame.'
    when p_codigo = 'remocao_sutura' then 'Retirada dos pontos.'
    when p_codigo = 'enxerto_osseo' then 'Reconstrução do osso para receber o implante.'
    when p_codigo = 'levantamento_seio' then 'Ganho de osso no fundo da arcada de cima para receber o implante.'
    when p_codigo = 'reabertura_implante' then 'Exposição do implante para começar a parte do dente.'
    when p_codigo = 'protese_parcial_removivel' then 'Prótese de tirar e pôr que repõe alguns dentes.'
    when p_codigo = 'protese_total' then 'Dentadura completa.'
    when p_codigo = 'placa_miorrelaxante' then 'Placa para usar à noite, que protege os dentes do ranger e relaxa a musculatura.'
    when p_codigo like 'clareamento%' then 'Deixa os dentes mais claros com gel clareador.'
  end
$$;

create or replace function public.orcamento_local(p_dente smallint, p_faces text, p_regiao text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_dente is not null then 'Dente ' || p_dente || coalesce(' (' || p_faces || ')', '')
    when p_regiao = 'boca' then 'Boca toda'
    when p_regiao = 'arcada_superior' then 'Arcada superior'
    when p_regiao = 'arcada_inferior' then 'Arcada inferior'
    when p_regiao ~ '^S[1-6]$' then 'Sextante ' || substr(p_regiao, 2)
    when p_regiao ~ '^Q[1-8]$' then 'Quadrante ' || substr(p_regiao, 2)
  end
$$;

create or replace function public.orcamento_status_texto(p_status text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'rascunho' then 'Rascunho'
    when 'apresentado' then 'Em aberto'
    when 'aprovado' then 'Aprovado'
    when 'parcial' then 'Aprovado em parte'
    when 'recusado' then 'Recusado'
    when 'expirado' then 'Vencido'
    when 'concluido' then 'Concluído'
    when 'substituido' then 'Substituído por versão nova'
  end
$$;

-- Condições de pagamento para um total.
create or replace function public.orcamento_pagamento(p_total numeric, p_cfg jsonb, p_tem_desconto boolean)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_acumula boolean := coalesce((p_cfg ->> 'desconto_acumula')::boolean, false);
  v_pct numeric := coalesce((p_cfg ->> 'desconto_a_vista_pct')::numeric, 0);
  v_min numeric := greatest(coalesce((p_cfg ->> 'parcela_minima')::numeric, 100), 1);
  v_cartao_max int := greatest(coalesce((p_cfg ->> 'cartao_parcelas_max')::int, 1), 1);
  v_ent_pct numeric := coalesce((p_cfg ->> 'entrada_pct')::numeric, 0);
  v_ent_max int := greatest(coalesce((p_cfg ->> 'entrada_parcelas_max')::int, 1), 1);
  v_destaque numeric := coalesce((p_cfg ->> 'destaque_parcela_acima')::numeric, 1000);
  v_n int;
  v_m int;
  v_ent numeric;
  v_resto numeric;
  v_entrada jsonb;
begin
  if p_total is null or p_total <= 0 then
    return jsonb_build_object('a_vista', jsonb_build_object('valor', coalesce(p_total, 0), 'desconto_pct', 0));
  end if;
  if p_tem_desconto and not v_acumula then
    v_pct := 0;
  end if;
  v_n := greatest(1, least(v_cartao_max, floor(p_total / v_min)::int));
  if v_ent_pct > 0 and v_ent_pct < 100 and p_total >= 2 * v_min then
    v_ent := round(p_total * v_ent_pct / 100, 2);
    v_resto := p_total - v_ent;
    v_m := greatest(1, least(v_ent_max, floor(v_resto / v_min)::int));
    v_entrada := jsonb_build_object('entrada', v_ent, 'entrada_pct', v_ent_pct, 'parcelas', v_m,
                                    'valor_parcela', round(v_resto / v_m, 2));
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'a_vista', jsonb_build_object('valor', round(p_total * (1 - v_pct / 100), 2), 'desconto_pct', v_pct,
                                  'economia', round(p_total * v_pct / 100, 2)),
    'cartao', jsonb_build_object('parcelas', v_n, 'valor_parcela', round(p_total / v_n, 2)),
    'entrada_mais_parcelas', v_entrada,
    'destacar_parcela', p_total > v_destaque));
end
$$;

-- Itens que contam no total: antes da aprovação, todos menos cancelados e
-- recusados; depois, só os aprovados e realizados.
create or replace function public.orcamento_item_conta(p_status_orcamento text, p_status_item text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case when p_status_orcamento in ('aprovado', 'parcial', 'concluido')
              then p_status_item in ('aprovado', 'realizado')
              else p_status_item not in ('cancelado', 'recusado') end
$$;

create or replace function public.orcamento_opcao(p_orc public.orcamentos, p_alternativa text, p_subtotal numeric)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_sub numeric := coalesce(p_subtotal, 0);
  v_desc numeric;
begin
  v_desc := case p_orc.desconto_tipo
              when 'percentual' then round(v_sub * p_orc.desconto_valor / 100, 2)
              when 'valor' then least(p_orc.desconto_valor, v_sub)
              else 0 end;
  return jsonb_strip_nulls(jsonb_build_object(
    'alternativa', p_alternativa,
    'subtotal', v_sub,
    'desconto', case when v_desc > 0 then v_desc end,
    'total', v_sub - v_desc,
    'pagamento', public.orcamento_pagamento(v_sub - v_desc, p_orc.pagamento, v_desc > 0)));
end
$$;

-- O orçamento inteiro, para a Dra. e para o PDF.
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
    'observacoes', o.observacoes,
    'substitui', case when v_ant.id is not null then
                   jsonb_build_object('numero', v_ant.numero, 'versao', v_ant.versao) end));
end
$$;

-- O que o servidor precisa para gerar o PDF.
create or replace function public.orcamento_documento(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'tipo', 'orcamento',
    'referencia_id', o.id,
    'paciente_id', o.paciente_id,
    'titulo', 'Orçamento nº ' || o.numero || case when o.versao > 1 then ' v' || o.versao else '' end,
    'caminho', public.documentos_caminho(o.paciente_id, 'orcamento', o.numero,
                                         case when o.versao > 1 then o.versao end),
    'solicitacao_id', nullif(current_setting('app.solicitacao_id', true), ''),
    'dados', public.orcamento_json(o.id))
  from public.orcamentos o where o.id = p_id
$$;

-- Monta um item a partir do que a Dra. ditou (ou de um plano do odontograma).
create or replace function public.orcamento_novo_item(p_item jsonb, p_dente smallint, p_valores jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_faces text := public.normalizar_faces(p_dente, p_item ->> 'faces');
  v_regiao text := public.normalizar_regiao(p_item ->> 'regiao');
  v_proc public.procedimentos;
  v_proc_id uuid;
  v_aviso text;
  v_avisos text[] := '{}';
  v_texto text := nullif(btrim(p_item ->> 'procedimento'), '');
  v_qtd numeric;
  v_fase numeric;
  v_alt text := nullif(upper(btrim(p_item ->> 'alternativa')), '');
  v_valor numeric := public.documentos_ler_numero(p_item ->> 'valor', 'Valor');
begin
  if v_faces is not null and p_dente is null then
    raise exception 'Faces informadas sem dente em "%".', coalesce(v_texto, p_item ->> 'procedimento_codigo');
  end if;
  select e.proc_id, e.aviso into v_proc_id, v_aviso
    from public.escolher_procedimento(p_item ->> 'procedimento_codigo', v_texto, null, p_dente, length(v_faces)) e;
  if v_proc_id is not null then
    select * into v_proc from public.procedimentos where id = v_proc_id;
  end if;
  if v_aviso is not null then
    v_avisos := v_avisos || v_aviso;
  end if;
  if v_proc.id is null then
    if v_texto is null then
      raise exception 'Informe o procedimento de cada item (texto ou procedimento_codigo).';
    end if;
    v_avisos := v_avisos || format('"%s" não está no catálogo: entra no orçamento só como texto.', v_texto);
  elsif v_proc.aplica_a in ('dente', 'dente_faces') and p_dente is null then
    v_avisos := v_avisos || format('Faltou o dente em "%s".', v_proc.nome);
  elsif v_proc.aplica_a in ('sextante', 'regiao', 'arcada') and v_regiao is null and p_dente is null then
    v_avisos := v_avisos || format('Faltou a região em "%s" (ex.: arcada_superior, S1, Q2).', v_proc.nome);
  end if;

  v_qtd := coalesce(public.documentos_ler_numero(p_item ->> 'quantidade', 'Quantidade'), 1);
  if v_qtd <> trunc(v_qtd) or v_qtd not between 1 and 99 then
    raise exception 'Quantidade inválida (%): use um número inteiro de 1 a 99.', p_item ->> 'quantidade';
  end if;
  v_fase := coalesce(public.documentos_ler_numero(p_item ->> 'fase', 'Fase'),
                     public.orcamento_fase_padrao(v_proc.codigo, v_proc.categoria));
  if v_fase <> trunc(v_fase) or v_fase not between 1 and 7 then
    raise exception 'Fase % inválida: use de 1 a 7 (1 urgência, 2 gengiva, 3 canal, 4 restaurações, 5 prótese/implante, 6 estética, 7 manutenção).', p_item ->> 'fase';
  end if;
  if v_alt is not null and v_alt not in ('A', 'B', 'C', 'D') then
    raise exception 'Alternativa "%" inválida: use A, B, C ou D.', p_item ->> 'alternativa';
  end if;
  if v_valor is not null and v_valor < 0 then
    raise exception 'Valor negativo em "%".', coalesce(v_proc.nome, v_texto);
  end if;
  if v_valor is null and v_proc.id is not null then
    v_valor := (p_valores ->> v_proc.id::text)::numeric;
  end if;
  if v_valor is null then
    v_valor := v_proc.preco;
  end if;

  return jsonb_build_object(
    'procedimento_id', v_proc.id,
    'codigo', v_proc.codigo,
    'condicao', v_proc.condicao_resultante,
    'familia', v_proc.familia,
    'faixa_mercado', v_proc.faixa_mercado,
    'descricao', coalesce(nullif(btrim(p_item ->> 'descricao'), ''), v_proc.nome, v_texto),
    'explicacao', coalesce(nullif(btrim(p_item ->> 'explicacao'), ''), public.explicacao_leiga(v_proc.codigo)),
    'dente', p_dente,
    'faces', v_faces,
    'regiao', v_regiao,
    'quantidade', v_qtd::int,
    'valor_unitario', v_valor,
    'fase', v_fase::int,
    'alternativa', v_alt,
    'observacao', nullif(btrim(p_item ->> 'observacao'), ''),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- Valores ditados para procedimentos sem preço: {procedimento_id: valor}.
create or replace function public.orcamento_mapa_valores(p_valores jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item jsonb;
  v_proc_id uuid;
  v_valor numeric;
  v_mapa jsonb := '{}';
begin
  if p_valores is null or jsonb_typeof(p_valores) = 'null' then
    return v_mapa;
  end if;
  if jsonb_typeof(p_valores) <> 'array' then
    raise exception 'valores deve ser uma lista de {procedimento_codigo, valor}.';
  end if;
  for v_item in select * from jsonb_array_elements(p_valores) loop
    select e.proc_id into v_proc_id
      from public.escolher_procedimento(v_item ->> 'procedimento_codigo', v_item ->> 'procedimento', null, null, null) e;
    if v_proc_id is null then
      raise exception 'Em valores, "%" não está no catálogo.',
        coalesce(v_item ->> 'procedimento_codigo', v_item ->> 'procedimento');
    end if;
    v_valor := public.documentos_ler_numero(v_item ->> 'valor', 'Valor');
    if v_valor is null or v_valor < 0 then
      raise exception 'Informe o valor de "%".', coalesce(v_item ->> 'procedimento_codigo', v_item ->> 'procedimento');
    end if;
    v_mapa := v_mapa || jsonb_build_object(v_proc_id::text, v_valor);
  end loop;
  return v_mapa;
end
$$;

-- Itens ainda sem valor: devolve a lista para a Dra. responder.
create or replace function public.orcamento_faltando_valor(p_itens jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'procedimento_codigo', f.codigo, 'procedimento', f.descricao, 'faixa_de_mercado', f.faixa,
           'dentes', f.dentes, 'itens', f.n)))
    from (select x ->> 'codigo' as codigo, min(x ->> 'descricao') as descricao, min(x ->> 'faixa_mercado') as faixa,
                 jsonb_agg(x -> 'dente') filter (where x ->> 'dente' is not null) as dentes, count(*) as n
            from jsonb_array_elements(p_itens) x
           where x ->> 'valor_unitario' is null
           group by x ->> 'codigo', case when x ->> 'codigo' is null then x ->> 'descricao' end) f
$$;

-- Condições de pagamento do orçamento: padrão + ajustes ditados.
create or replace function public.orcamento_condicoes(p_base jsonb, p_ajuste jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := p_base;
  k text;
  v_num numeric;
  v_chaves text[] := array['desconto_a_vista_pct', 'cartao_parcelas_max', 'entrada_pct', 'entrada_parcelas_max',
                           'parcela_minima'];
begin
  if p_ajuste is null or jsonb_typeof(p_ajuste) = 'null' then
    return v;
  end if;
  if jsonb_typeof(p_ajuste) <> 'object' then
    raise exception 'pagamento deve ser um objeto (ex.: {"cartao_parcelas_max": 10}).';
  end if;
  for k in select jsonb_object_keys(p_ajuste) loop
    if not k = any (v_chaves) then
      raise exception 'Condição de pagamento "%" desconhecida. Use: %.', k, array_to_string(v_chaves, ', ');
    end if;
    v_num := public.documentos_ler_numero(p_ajuste ->> k, k);
    if v_num is null or v_num < 0
       or (k in ('desconto_a_vista_pct') and v_num > 50)
       or (k = 'entrada_pct' and v_num > 100)
       or (k in ('cartao_parcelas_max', 'entrada_parcelas_max') and (v_num < 1 or v_num > 24 or v_num <> trunc(v_num))) then
      raise exception 'Valor fora do esperado para %: %.', k, p_ajuste ->> k;
    end if;
    v := v || jsonb_build_object(k, v_num);
  end loop;
  return v;
end
$$;

create or replace function public.orcamento_desconto(p_dados jsonb, out tipo text, out valor numeric)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_pct numeric := public.documentos_ler_numero(p_dados ->> 'desconto_percentual', 'Desconto (%)');
  v_rs numeric := public.documentos_ler_numero(p_dados ->> 'desconto_valor', 'Desconto (R$)');
begin
  if v_pct is not null and v_rs is not null then
    raise exception 'Use desconto_percentual ou desconto_valor, não os dois.';
  end if;
  if v_pct is not null then
    if v_pct < 0 or v_pct > 100 then
      raise exception 'Desconto de % %% fora do esperado.', v_pct;
    end if;
    tipo := case when v_pct > 0 then 'percentual' end;
    valor := coalesce(case when v_pct > 0 then v_pct end, 0);
  elsif v_rs is not null then
    if v_rs < 0 then
      raise exception 'Desconto negativo.';
    end if;
    tipo := case when v_rs > 0 then 'valor' end;
    valor := coalesce(case when v_rs > 0 then v_rs end, 0);
  end if;
end
$$;

-- Fecha ou reabre o orçamento conforme os itens realizados.
create or replace function public.orcamento_atualizar_status(p_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  o public.orcamentos;
begin
  select * into o from public.orcamentos where id = p_id;
  if o.status in ('aprovado', 'parcial') then
    if not exists (select 1 from public.orcamento_itens where orcamento_id = p_id and status = 'aprovado')
       and exists (select 1 from public.orcamento_itens where orcamento_id = p_id and status = 'realizado') then
      update public.orcamentos set status = 'concluido', concluido_em = public.hoje() where id = p_id;
    end if;
  elsif o.status = 'concluido' then
    if exists (select 1 from public.orcamento_itens where orcamento_id = p_id and status = 'aprovado') then
      update public.orcamentos
         set status = case o.aprovacao when 'parcial' then 'parcial' else 'aprovado' end, concluido_em = null
       where id = p_id;
    end if;
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Gatilhos: odontograma e atendimentos -> itens realizados
-- ---------------------------------------------------------------------
create or replace function public.orcamento_ao_marcar_odontograma()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if new.acao = 'marcar' and cardinality(new.encerra_ids) > 0 then
    if new.camada = 'planejado' then
      -- replanejamento: o item passa a seguir o plano novo
      update public.orcamento_itens i
         set marca_id = new.id
        from public.odontograma m, public.orcamentos o
       where i.marca_id = m.id and m.id = any (new.encerra_ids)
         and m.camada = 'planejado' and m.condicao = new.condicao
         and o.id = i.orcamento_id and o.status not in ('substituido', 'recusado', 'concluido')
         and i.status in ('incluido', 'aprovado');
    else
      if new.camada = 'realizado' then
        with alvo as (
          update public.orcamento_itens i
             set status = 'realizado', realizado_em = new.data, realizado_marca_id = new.id
            from public.odontograma m, public.orcamentos o
           where i.marca_id = m.id and m.id = any (new.encerra_ids)
             and m.camada = 'planejado' and m.condicao = new.condicao
             and o.id = i.orcamento_id and o.status not in ('substituido', 'recusado')
             and (i.status = 'aprovado' or (i.status = 'incluido' and i.alternativa is null))
          returning i.orcamento_id)
        select array_agg(distinct orcamento_id) into v_ids from alvo;
      end if;
      -- dente que saiu: os outros planos dele no orçamento perdem o sentido
      if new.condicao = 'ausente' then
        with alvo as (
          update public.orcamento_itens i
             set status = 'cancelado',
                 observacao = concat_ws(' ', i.observacao, '(cancelado: dente ausente desde ' || to_char(new.data, 'DD/MM/YYYY') || ')')
            from public.odontograma m, public.orcamentos o
           where i.marca_id = m.id and m.id = any (new.encerra_ids)
             and m.camada = 'planejado' and m.condicao <> 'ausente'
             and o.id = i.orcamento_id and o.status not in ('substituido', 'recusado')
             and i.status in ('incluido', 'aprovado')
          returning i.orcamento_id)
        select array_agg(distinct x) into v_ids
          from (select unnest(v_ids) x union select orcamento_id from alvo) u;
      end if;
    end if;
  elsif new.acao = 'anular' then
    with alvo as (
      update public.orcamento_itens i
         set status = case when o.aprovacao is not null then 'aprovado' else 'incluido' end,
             realizado_em = null, realizado_marca_id = null
        from public.orcamentos o
       where o.id = i.orcamento_id and i.realizado_marca_id = any (new.anula_ids) and i.status = 'realizado'
      returning i.orcamento_id)
    select array_agg(distinct orcamento_id) into v_ids from alvo;
  end if;
  if v_ids is not null then
    perform public.orcamento_atualizar_status(x) from unnest(v_ids) x where x is not null;
  end if;
  return null;
end
$$;

create trigger odontograma_orcamento after insert on public.odontograma
  for each row execute function public.orcamento_ao_marcar_odontograma();

create or replace function public.orcamento_ao_registrar_procedimento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pac uuid;
  v_data date;
  v_familia text;
  v_item uuid;
  v_orc uuid;
begin
  if new.etapa <> 'concluido' or new.procedimento_id is null then
    return null;
  end if;
  select a.paciente_id, a.data into v_pac, v_data from public.atendimentos a where a.id = new.atendimento_id;
  select p.familia into v_familia from public.procedimentos p where p.id = new.procedimento_id;
  -- itens com plano no odontograma são resolvidos pela marca "realizado"
  select i.id, i.orcamento_id into v_item, v_orc
    from public.orcamento_itens i
    join public.orcamentos o on o.id = i.orcamento_id
    left join public.procedimentos p on p.id = i.procedimento_id
   where o.paciente_id = v_pac
     and o.status in ('rascunho', 'apresentado', 'aprovado', 'parcial')
     and i.marca_id is null
     and (i.status = 'aprovado' or (i.status = 'incluido' and i.alternativa is null))
     and (i.procedimento_id = new.procedimento_id or (v_familia is not null and p.familia = v_familia))
     and (i.dente is null or i.dente = new.dente)
     and (i.regiao is null or new.regiao is null or i.regiao = new.regiao)
   order by (i.status = 'aprovado') desc, (i.dente is not distinct from new.dente) desc, o.criado_em, i.ordem
   limit 1;
  if v_item is not null then
    update public.orcamento_itens
       set status = 'realizado', realizado_em = v_data, atendimento_item_id = new.id
     where id = v_item;
    perform public.orcamento_atualizar_status(v_orc);
  end if;
  return null;
end
$$;

create trigger atendimento_itens_orcamento after insert on public.atendimento_itens
  for each row execute function public.orcamento_ao_registrar_procedimento();

create or replace function public.orcamento_ao_corrigir_atendimento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if new.corrige_atendimento_id is null then
    return null;
  end if;
  with alvo as (
    update public.orcamento_itens i
       set status = case when o.aprovacao is not null then 'aprovado' else 'incluido' end,
           realizado_em = null, atendimento_item_id = null
      from public.orcamentos o, public.atendimento_itens ai
     where o.id = i.orcamento_id and ai.id = i.atendimento_item_id
       and ai.atendimento_id = new.corrige_atendimento_id and i.status = 'realizado'
    returning i.orcamento_id)
  select array_agg(distinct orcamento_id) into v_ids from alvo;
  if v_ids is not null then
    perform public.orcamento_atualizar_status(x) from unnest(v_ids) x;
  end if;
  return null;
end
$$;

create trigger atendimentos_orcamento after insert on public.atendimentos
  for each row execute function public.orcamento_ao_corrigir_atendimento();

-- ---------------------------------------------------------------------
-- Ferramenta: montar_orcamento
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
begin
  perform public.iniciar_solicitacao('montar_orcamento', p_dados, p_texto_original);
  select * into v_conf from public.configuracao;
  select * into v_cfg from public.documentos_config;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_valores := public.orcamento_mapa_valores(p_dados -> 'valores');

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
    observacoes, substitui_id, apresentado_em, profissional, cro, solicitacao_id)
  values (
    v_numero, v_versao, v_pac.id, case when v_apresentar then 'apresentado' else 'rascunho' end,
    coalesce(nullif(btrim(p_dados ->> 'titulo'), ''), 'Plano de tratamento'),
    public.hoje() + v_validade::int, v_desc.tipo, coalesce(v_desc.valor, 0),
    public.orcamento_condicoes(to_jsonb(v_cfg) - 'id' - 'atualizado_em' - 'orcamento_validade_dias' - 'acompanhamento_dias',
                               p_dados -> 'pagamento'),
    nullif(btrim(p_dados ->> 'observacoes'), ''),
    case when v_versao > 1 then v_aberto.id end,
    case when v_apresentar then public.hoje() end,
    v_conf.dentista_nome, v_conf.cro,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid)
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

-- ---------------------------------------------------------------------
-- Ferramenta: alterar_orcamento (apresentar, aprovar, recusar,
-- acompanhamento, editar)
-- ---------------------------------------------------------------------
create or replace function public.orcamento_localizar(p_dados jsonb)
returns public.orcamentos
language plpgsql
stable
set search_path = ''
as $$
declare
  o public.orcamentos;
  v_pac public.pacientes;
  v_id uuid;
  v_lista text;
  v_n int;
begin
  if nullif(p_dados ->> 'orcamento_id', '') is not null then
    begin
      v_id := (p_dados ->> 'orcamento_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'orcamento_id inválido.';
    end;
    select * into o from public.orcamentos where id = v_id;
    if not found then
      raise exception 'Orçamento não encontrado.';
    end if;
  else
    v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
    if nullif(p_dados ->> 'numero', '') is not null then
      select * into o from public.orcamentos
       where paciente_id = v_pac.id and numero = (p_dados ->> 'numero')::int
       order by versao desc limit 1;
      if not found then
        raise exception 'Orçamento nº % não encontrado para %.', p_dados ->> 'numero', v_pac.nome;
      end if;
    else
      select count(*), string_agg('nº ' || numero, ', ' order by numero) into v_n, v_lista
        from public.orcamentos where paciente_id = v_pac.id and status in ('rascunho', 'apresentado');
      if v_n > 1 then
        raise exception 'Há % orçamentos em aberto para % (%): diga qual (numero).', v_n, v_pac.nome, v_lista;
      end if;
      select * into o from public.orcamentos
       where paciente_id = v_pac.id and status in ('rascunho', 'apresentado')
       order by criado_em desc limit 1;
      if not found then
        select * into o from public.orcamentos
         where paciente_id = v_pac.id and status <> 'substituido'
         order by criado_em desc limit 1;
      end if;
      if not found then
        raise exception '% não tem orçamento. Use montar_orcamento.', v_pac.nome;
      end if;
    end if;
  end if;
  -- versão antiga: usa a mais recente do mesmo número
  if o.status = 'substituido' then
    select * into o from public.orcamentos where numero = o.numero order by versao desc limit 1;
  end if;
  return o;
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
    v_valores := public.orcamento_mapa_valores(p_dados -> 'valores');
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
        observacoes, substitui_id, apresentado_em, profissional, cro, solicitacao_id)
      select o.numero, (select max(versao) + 1 from public.orcamentos where numero = o.numero), o.paciente_id,
             'apresentado', o.titulo, public.hoje() + greatest(v_dur, 1), o.desconto_tipo, o.desconto_valor,
             o.pagamento, o.observacoes, o.id, public.hoje(), o.profissional, o.cro,
             nullif(current_setting('app.solicitacao_id', true), '')::uuid
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

-- ---------------------------------------------------------------------
-- Acesso às funções
-- ---------------------------------------------------------------------
revoke execute on function
  public.documentos_ler_numero(text, text),
  public.orcamento_fase_padrao(text, text),
  public.orcamento_fase_nome(int),
  public.explicacao_leiga(text),
  public.orcamento_local(smallint, text, text),
  public.orcamento_status_texto(text),
  public.orcamento_pagamento(numeric, jsonb, boolean),
  public.orcamento_item_conta(text, text),
  public.orcamento_opcao(public.orcamentos, text, numeric),
  public.orcamento_json(uuid),
  public.orcamento_documento(uuid),
  public.orcamento_novo_item(jsonb, smallint, jsonb),
  public.orcamento_mapa_valores(jsonb),
  public.orcamento_faltando_valor(jsonb),
  public.orcamento_condicoes(jsonb, jsonb),
  public.orcamento_desconto(jsonb),
  public.orcamento_atualizar_status(uuid),
  public.orcamento_ao_marcar_odontograma(),
  public.orcamento_ao_registrar_procedimento(),
  public.orcamento_ao_corrigir_atendimento(),
  public.orcamento_localizar(jsonb),
  public.mcp_montar_orcamento(jsonb, text),
  public.mcp_alterar_orcamento(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.documentos_ler_numero(text, text),
  public.orcamento_fase_padrao(text, text),
  public.orcamento_fase_nome(int),
  public.explicacao_leiga(text),
  public.orcamento_local(smallint, text, text),
  public.orcamento_status_texto(text),
  public.orcamento_pagamento(numeric, jsonb, boolean),
  public.orcamento_item_conta(text, text),
  public.orcamento_opcao(public.orcamentos, text, numeric),
  public.orcamento_json(uuid),
  public.orcamento_documento(uuid),
  public.orcamento_novo_item(jsonb, smallint, jsonb),
  public.orcamento_mapa_valores(jsonb),
  public.orcamento_faltando_valor(jsonb),
  public.orcamento_condicoes(jsonb, jsonb),
  public.orcamento_desconto(jsonb),
  public.orcamento_atualizar_status(uuid),
  public.orcamento_ao_marcar_odontograma(),
  public.orcamento_ao_registrar_procedimento(),
  public.orcamento_ao_corrigir_atendimento(),
  public.orcamento_localizar(jsonb),
  public.mcp_montar_orcamento(jsonb, text),
  public.mcp_alterar_orcamento(jsonb, text)
  to service_role;
