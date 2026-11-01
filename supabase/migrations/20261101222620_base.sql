-- =====================================================================
-- Consultório: base da prova de conceito (etapa 0)
--
-- Princípios:
--   * Registros clínicos (atendimentos) só aceitam inclusão. Correção é um
--     novo registro que aponta para o original (Código de Ética, art. 17).
--   * Pacientes nunca são apagados, só arquivados.
--   * Cada chamada da IA vira uma "solicitação" com o texto original do
--     pedido, e cada linha gravada vira uma entrada de auditoria.
--   * Nenhuma tabela é acessível pela chave pública (anon). Na etapa 0 só o
--     servidor MCP (service_role) acessa; na etapa 2 entram políticas RLS
--     para o login da dentista no iPad.
-- =====================================================================

create extension if not exists unaccent with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------
-- Funções utilitárias
-- ---------------------------------------------------------------------

-- Texto para busca: minúsculas, sem acento, espaços simples.
create or replace function public.normalizar(t text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(
    lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))),
    '\s+', ' ', 'g'))
$$;

create or replace function public.somente_digitos(t text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(regexp_replace(coalesce(t, ''), '\D', '', 'g'), '')
$$;

-- CPF com dígitos verificadores corretos (11 dígitos, sem máscara).
create or replace function public.cpf_valido(cpf text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d int[];
  s int;
  r int;
  i int;
begin
  if cpf is null or cpf !~ '^\d{11}$' or cpf ~ '^(\d)\1{10}$' then
    return false;
  end if;
  select array_agg(substr(cpf, g, 1)::int order by g) into d
    from generate_series(1, 11) g;
  s := 0;
  for i in 1..9 loop s := s + d[i] * (11 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  if r <> d[10] then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + d[i] * (12 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  return r = d[11];
end
$$;

-- Dente na notação FDI: permanentes 11–18, 21–28, 31–38, 41–48;
-- decíduos 51–55, 61–65, 71–75, 81–85.
create or replace function public.dente_valido(d smallint)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select d is not null and (
    (d / 10 between 1 and 4 and d % 10 between 1 and 8) or
    (d / 10 between 5 and 8 and d % 10 between 1 and 5))
$$;

-- Normaliza faces para a forma canônica (ordem M, O/I, D, V, L/P).
-- Aceita letras (MOD, DO, B) ou palavras (mesial, oclusal, vestibular...).
-- Com o dente informado, ajusta O/I (anterior x posterior) e L/P
-- (inferior x superior); B vira V.
create or replace function public.normalizar_faces(p_dente smallint, p_faces text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  f text;
  q int;
  u int;
  c text;
  res text := '';
begin
  if p_faces is null or btrim(p_faces) = '' then
    return null;
  end if;
  f := public.normalizar(p_faces);
  f := regexp_replace(f, 'mesial', 'M', 'g');
  f := regexp_replace(f, 'distal', 'D', 'g');
  f := regexp_replace(f, 'oclusal', 'O', 'g');
  f := regexp_replace(f, 'incisal', 'I', 'g');
  f := regexp_replace(f, 'vestibular|bucal|labial', 'V', 'g');
  f := regexp_replace(f, 'lingual', 'L', 'g');
  f := regexp_replace(f, 'palatin[ao]|palatal', 'P', 'g');
  f := upper(regexp_replace(f, '[^A-Za-z]', '', 'g'));
  f := replace(f, 'B', 'V');
  if f ~ '[^MDOIVLP]' or f = '' then
    raise exception using
      message = format('Face inválida: "%s". Use M, D, O, I, V, L ou P (ex.: MO, MOD).', p_faces);
  end if;
  if p_dente is not null then
    q := p_dente / 10;
    u := p_dente % 10;
    if q in (1, 2, 5, 6) then f := replace(f, 'L', 'P'); else f := replace(f, 'P', 'L'); end if;
    if u <= 3 then f := replace(f, 'O', 'I'); else f := replace(f, 'I', 'O'); end if;
  end if;
  foreach c in array array['M', 'O', 'I', 'D', 'V', 'L', 'P'] loop
    if position(c in f) > 0 then res := res || c; end if;
  end loop;
  return res;
end
$$;

-- ---------------------------------------------------------------------
-- Configuração do consultório (uma linha só)
-- ---------------------------------------------------------------------
create table public.configuracao (
  id boolean primary key default true check (id),
  nome_consultorio text not null,
  dentista_nome text not null,
  cro text not null,                       -- ex.: 'CRO-SP 123456'
  endereco text,
  telefone text,
  email text,
  fuso_horario text not null default 'America/Sao_Paulo',
  atualizado_em timestamptz not null default now()
);
comment on table public.configuracao is 'Dados do consultório usados em toda entrada de prontuário e nos PDFs (linha única).';

create or replace function public.fuso()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce((select fuso_horario from public.configuracao), 'America/Sao_Paulo')
$$;

-- Data de hoje no fuso do consultório.
create or replace function public.hoje()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone public.fuso())::date
$$;

-- ---------------------------------------------------------------------
-- Solicitações da IA e auditoria (só inclusão)
-- ---------------------------------------------------------------------
create table public.solicitacoes (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  ferramenta text not null,
  texto_original text,                     -- o que a dentista disse
  argumentos jsonb not null default '{}'::jsonb,
  cliente text not null default 'mcp',
  usuario uuid,                            -- auth.uid() quando houver login (etapa 2)
  sucesso boolean not null default true,
  erro text
);
comment on table public.solicitacoes is 'Cada chamada de ferramenta feita pela IA, com o texto original do pedido. Também serve de registro de acesso a dados de saúde (LGPD).';
create index solicitacoes_criado_em_idx on public.solicitacoes (criado_em desc);

create table public.auditoria (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  solicitacao_id uuid references public.solicitacoes (id),
  tabela text not null,
  operacao text not null,
  registro_id text,
  antes jsonb,
  depois jsonb,
  usuario text
);
comment on table public.auditoria is 'Antes/depois de cada linha incluída ou alterada, ligada à solicitação que a originou.';
create index auditoria_registro_idx on public.auditoria (tabela, registro_id);
create index auditoria_solicitacao_idx on public.auditoria (solicitacao_id);

-- Abre uma solicitação e a deixa disponível para os gatilhos de auditoria
-- desta transação.
create or replace function public.iniciar_solicitacao(
  p_ferramenta text,
  p_argumentos jsonb,
  p_texto_original text,
  p_cliente text default 'mcp')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.solicitacoes (ferramenta, argumentos, texto_original, cliente, usuario)
  values (p_ferramenta, coalesce(p_argumentos, '{}'::jsonb),
          nullif(btrim(p_texto_original), ''), coalesce(p_cliente, 'mcp'), auth.uid())
  returning id into v_id;
  perform set_config('app.solicitacao_id', v_id::text, true);
  return v_id;
end
$$;

-- Gatilho genérico de auditoria (AFTER INSERT/UPDATE).
create or replace function public.registrar_auditoria()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_antes jsonb;
  v_depois jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_antes := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_depois := to_jsonb(new); end if;
  insert into public.auditoria (solicitacao_id, tabela, operacao, registro_id, antes, depois, usuario)
  values (nullif(current_setting('app.solicitacao_id', true), '')::uuid,
          tg_table_name, tg_op,
          coalesce(v_depois ->> 'id', v_antes ->> 'id'),
          v_antes, v_depois,
          coalesce(auth.uid()::text, current_user));
  return null;
end
$$;

-- Gatilho que impede alterar ou apagar (tabelas só de inclusão).
create or replace function public.bloquear_alteracao()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = format('A tabela %s só aceita inclusões: este registro não pode ser alterado nem apagado.', tg_table_name),
    hint = 'Para corrigir um atendimento, registre um novo com corrige_atendimento_id e o motivo da correção.';
end
$$;

create or replace function public.bloquear_exclusao_paciente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = 'Pacientes não são apagados (guarda mínima de 20 anos, Lei 13.787/2018).',
    hint = 'Para tirar um paciente das buscas, preencha arquivado_em.';
end
$$;

create or replace function public.tocar_atualizado_em()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.atualizado_em := now();
  return new;
end
$$;

-- ---------------------------------------------------------------------
-- Pacientes e responsáveis
-- ---------------------------------------------------------------------
create table public.pacientes (
  id uuid primary key default gen_random_uuid(),
  ficha integer generated always as identity unique,   -- número da ficha
  nome text not null check (length(btrim(nome)) >= 3),
  nome_social text,
  apelido text,
  data_nascimento date check (data_nascimento >= date '1900-01-01'),
  sexo text check (sexo in ('feminino', 'masculino', 'outro', 'nao_informado')),
  cpf text unique check (public.cpf_valido(cpf)),
  rg text,
  telefone text check (telefone ~ '^\d{10,11}$'),       -- DDD + número, só dígitos
  whatsapp boolean not null default true,
  email text,
  endereco jsonb,              -- {logradouro, numero, complemento, bairro, cidade, uf, cep}
  profissao text,
  estado_civil text,
  contato_emergencia jsonb,    -- {nome, parentesco, telefone}
  origem text,                 -- como conheceu o consultório
  convenio text,
  alertas_saude jsonb not null default '[]'::jsonb check (jsonb_typeof(alertas_saude) = 'array'),
  observacoes text,
  consentimento_lgpd_em timestamptz,
  consentimento_imagem_em timestamptz,
  arquivado_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
comment on column public.pacientes.alertas_saude is 'Lista de {tipo, descricao, registrado_em}. Sempre mostrada antes de qualquer procedimento ou receita.';
create index pacientes_nome_trgm_idx on public.pacientes using gin (public.normalizar(nome) extensions.gin_trgm_ops);
create index pacientes_telefone_idx on public.pacientes (telefone);

create trigger pacientes_atualizado_em before update on public.pacientes
  for each row execute function public.tocar_atualizado_em();
create trigger pacientes_sem_exclusao before delete on public.pacientes
  for each row execute function public.bloquear_exclusao_paciente();
create trigger pacientes_sem_truncate before truncate on public.pacientes
  for each statement execute function public.bloquear_alteracao();
create trigger pacientes_auditoria after insert or update on public.pacientes
  for each row execute function public.registrar_auditoria();

create table public.responsaveis (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  nome text not null check (length(btrim(nome)) >= 3),
  cpf text check (public.cpf_valido(cpf)),
  parentesco text,
  telefone text check (telefone ~ '^\d{10,11}$'),
  e_pagador boolean not null default true,
  criado_em timestamptz not null default now()
);
create index responsaveis_paciente_idx on public.responsaveis (paciente_id);
create trigger responsaveis_auditoria after insert or update on public.responsaveis
  for each row execute function public.registrar_auditoria();
create trigger responsaveis_sem_exclusao before delete or truncate on public.responsaveis
  for each statement execute function public.bloquear_alteracao();

-- ---------------------------------------------------------------------
-- Atendimentos (evolução clínica): só inclusão
-- ---------------------------------------------------------------------
create table public.atendimentos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  data date not null,
  hora_inicio time,
  hora_fim time,
  evolucao text not null check (length(btrim(evolucao)) > 0),
  anestesia jsonb not null default '[]'::jsonb check (jsonb_typeof(anestesia) = 'array'),
  materiais jsonb not null default '[]'::jsonb check (jsonb_typeof(materiais) = 'array'),
  intercorrencias text,
  orientacoes text,
  proxima_etapa text,
  retorno_previsto date,
  corrige_atendimento_id uuid references public.atendimentos (id),
  motivo_correcao text,
  profissional text not null,
  cro text not null,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  check ((corrige_atendimento_id is null) = (motivo_correcao is null)),
  check (hora_fim is null or hora_inicio is null or hora_fim >= hora_inicio)
);
comment on table public.atendimentos is 'Evolução clínica. Imutável: uma correção é um novo registro com corrige_atendimento_id e motivo_correcao.';
comment on column public.atendimentos.anestesia is 'Lista de {anestesico, vasoconstritor, tubetes, tecnica}.';
comment on column public.atendimentos.materiais is 'Materiais citados no atendimento, ainda em texto livre: {material, quantidade, unidade, detalhe}. O estoque (etapa 4) passa a dar baixa a partir daqui.';
create index atendimentos_paciente_idx on public.atendimentos (paciente_id, data desc, registrado_em desc);
create index atendimentos_corrige_idx on public.atendimentos (corrige_atendimento_id);

create table public.atendimento_itens (
  id uuid primary key default gen_random_uuid(),
  atendimento_id uuid not null references public.atendimentos (id),
  ordem smallint not null default 1,
  procedimento text not null check (length(btrim(procedimento)) > 0),
  dente smallint check (dente is null or public.dente_valido(dente)),
  faces text check (faces ~ '^M?[OI]?D?V?[LP]?$' and faces <> ''),
  regiao text check (regiao in ('boca', 'arcada_superior', 'arcada_inferior',
                                'Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8',
                                'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'outra')),
  etapa text not null default 'concluido' check (etapa in ('concluido', 'parcial')),
  observacao text,
  check (faces is null or dente is not null)
);
comment on table public.atendimento_itens is 'Procedimentos feitos no atendimento, por dente/faces ou região. Imutável.';
create index atendimento_itens_atendimento_idx on public.atendimento_itens (atendimento_id, ordem);
create index atendimento_itens_dente_idx on public.atendimento_itens (dente);

create trigger atendimentos_so_inclusao before update or delete on public.atendimentos
  for each row execute function public.bloquear_alteracao();
create trigger atendimentos_sem_truncate before truncate on public.atendimentos
  for each statement execute function public.bloquear_alteracao();
create trigger atendimentos_auditoria after insert on public.atendimentos
  for each row execute function public.registrar_auditoria();

create trigger atendimento_itens_so_inclusao before update or delete on public.atendimento_itens
  for each row execute function public.bloquear_alteracao();
create trigger atendimento_itens_sem_truncate before truncate on public.atendimento_itens
  for each statement execute function public.bloquear_alteracao();
create trigger atendimento_itens_auditoria after insert on public.atendimento_itens
  for each row execute function public.registrar_auditoria();

create trigger solicitacoes_so_inclusao before update or delete on public.solicitacoes
  for each row execute function public.bloquear_alteracao();
create trigger solicitacoes_sem_truncate before truncate on public.solicitacoes
  for each statement execute function public.bloquear_alteracao();
create trigger auditoria_so_inclusao before update or delete on public.auditoria
  for each row execute function public.bloquear_alteracao();
create trigger auditoria_sem_truncate before truncate on public.auditoria
  for each statement execute function public.bloquear_alteracao();

create trigger configuracao_atualizado_em before update on public.configuracao
  for each row execute function public.tocar_atualizado_em();
create trigger configuracao_auditoria after insert or update on public.configuracao
  for each row execute function public.registrar_auditoria();

-- ---------------------------------------------------------------------
-- Acesso: RLS ligado em tudo, sem políticas (nega anon e authenticated).
-- Só o servidor MCP (service_role) lê e grava na etapa 0.
-- ---------------------------------------------------------------------
alter table public.configuracao enable row level security;
alter table public.solicitacoes enable row level security;
alter table public.auditoria enable row level security;
alter table public.pacientes enable row level security;
alter table public.responsaveis enable row level security;
alter table public.atendimentos enable row level security;
alter table public.atendimento_itens enable row level security;

revoke all on table
  public.configuracao, public.solicitacoes, public.auditoria, public.pacientes,
  public.responsaveis, public.atendimentos, public.atendimento_itens
  from anon, authenticated;

-- Funções com efeito colateral: só o servidor (service_role) executa.
-- As utilitárias puras (normalizar, cpf_valido etc.) ficam livres porque
-- aparecem em restrições CHECK e índices.
revoke execute on function
  public.iniciar_solicitacao(text, jsonb, text, text),
  public.registrar_auditoria(), public.bloquear_alteracao(),
  public.bloquear_exclusao_paciente(), public.tocar_atualizado_em()
  from public, anon, authenticated;
grant execute on function public.iniciar_solicitacao(text, jsonb, text, text) to service_role;
