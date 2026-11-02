-- =====================================================================
-- Etapa 4b: financeiro (base).
--
-- Recebimentos e despesas são lançamentos só de inclusão: corrigir é
-- estornar (novo lançamento com o valor negativo, ligado ao original).
-- Contas a receber: acordos de pagamento com parcelas previstas; uma
-- parcela está quitada quando os recebimentos ligados a ela somam o valor.
-- Fiscal: hoje pessoa física (Receita Saúde, um recibo por pagamento);
-- a partir da data de virada, pessoa jurídica (NFS-e pelo contador).
-- =====================================================================

-- Lançamentos financeiros não se alteram nem se apagam.
create or replace function public.bloquear_alteracao_financeira()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = format('A tabela %s só aceita inclusões: este lançamento não pode ser alterado nem apagado.', tg_table_name),
    hint = 'Para corrigir, estorne o lançamento (novo lançamento com o motivo) e registre o certo.';
end
$$;

-- Tabelas de cadastro (acordos, despesas fixas, configuração): alteram, não se apagam.
create or replace function public.bloquear_exclusao_financeira()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    message = format('A tabela %s não aceita exclusão: cancele ou encerre o registro.', tg_table_name);
end
$$;

create or replace function public.cnpj_valido(cnpj text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d int[];
  pesos1 int[] := array[5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  pesos2 int[] := array[6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  s int;
  r int;
  i int;
begin
  if cnpj is null or cnpj !~ '^\d{14}$' or cnpj ~ '^(\d)\1{13}$' then
    return false;
  end if;
  select array_agg(substr(cnpj, g, 1)::int order by g) into d from generate_series(1, 14) g;
  s := 0;
  for i in 1..12 loop s := s + d[i] * pesos1[i]; end loop;
  r := s % 11;
  r := case when r < 2 then 0 else 11 - r end;
  if r <> d[13] then return false; end if;
  s := 0;
  for i in 1..13 loop s := s + d[i] * pesos2[i]; end loop;
  r := s % 11;
  r := case when r < 2 then 0 else 11 - r end;
  return r = d[14];
end
$$;

-- ---------------------------------------------------------------------
-- Configuração financeira e fiscal (linha única)
-- ---------------------------------------------------------------------
create table public.configuracao_financeira (
  id boolean primary key default true check (id),
  regime text not null default 'pf' check (regime in ('pf', 'pj')),
  pj_a_partir_de date,
  cpf_profissional text check (cpf_profissional is null or public.cpf_valido(cpf_profissional)),
  cnpj text check (cnpj is null or public.cnpj_valido(cnpj)),
  codigo_ocupacao text not null default '226' check (codigo_ocupacao ~ '^\d{3}$'),
  registro_profissional text check (length(registro_profissional) <= 15),
  -- Taxas por forma: {forma: {percentual, fixo, dias, adicional_por_parcela}}
  taxas jsonb not null check (jsonb_typeof(taxas) = 'object'),
  observacoes text,
  atualizado_em timestamptz not null default now()
);
comment on table public.configuracao_financeira is
  'Regime fiscal (pf hoje; pj a partir de pj_a_partir_de), dados do Receita Saúde e taxas das formas de pagamento.';
comment on column public.configuracao_financeira.taxas is
  'Taxas de referência por forma (InfinitePay, a confirmar): percentual sobre o valor, fixo em R$, dias para cair na conta e, no crédito parcelado, adicional por parcela além da primeira.';

insert into public.configuracao_financeira (regime, pj_a_partir_de, codigo_ocupacao, taxas, observacoes)
values ('pf', date '2026-12-01', '226',
        '{"pix":               {"percentual": 0,    "fixo": 0, "dias": 0},
          "dinheiro":          {"percentual": 0,    "fixo": 0, "dias": 0},
          "transferencia":     {"percentual": 0,    "fixo": 0, "dias": 0},
          "debito":            {"percentual": 1.37, "fixo": 0, "dias": 0},
          "credito_vista":     {"percentual": 3.15, "fixo": 0, "dias": 0},
          "credito_parcelado": {"percentual": 3.15, "fixo": 0, "dias": 0, "adicional_por_parcela": 1.40},
          "boleto":            {"percentual": 0,    "fixo": 0, "dias": 1}}'::jsonb,
        'Taxas de referência; conferir com a InfinitePay da Dra. CPF da Dra. ainda não informado.')
on conflict (id) do nothing;

create trigger configuracao_financeira_atualizado_em before update on public.configuracao_financeira
  for each row execute function public.tocar_atualizado_em();
create trigger configuracao_financeira_auditoria after insert or update on public.configuracao_financeira
  for each row execute function public.registrar_auditoria();
create trigger configuracao_financeira_sem_exclusao before delete on public.configuracao_financeira
  for each row execute function public.bloquear_exclusao_financeira();
create trigger configuracao_financeira_sem_truncate before truncate on public.configuracao_financeira
  for each statement execute function public.bloquear_exclusao_financeira();

-- Regime fiscal numa data.
create or replace function public.regime_fiscal(p_data date)
returns text
language sql
stable
set search_path = ''
as $$
  select case when c.regime = 'pj' or (c.pj_a_partir_de is not null and p_data >= c.pj_a_partir_de)
              then 'pj' else 'pf' end
    from public.configuracao_financeira c
$$;

-- ---------------------------------------------------------------------
-- Contas a receber: acordos de pagamento e parcelas previstas
-- ---------------------------------------------------------------------
create table public.acordos_pagamento (
  id uuid primary key default gen_random_uuid(),
  numero integer generated always as identity unique,
  paciente_id uuid not null references public.pacientes (id),
  descricao text not null check (length(btrim(descricao)) >= 3),
  valor_total numeric(10,2) not null check (valor_total > 0),
  forma_prevista text check (forma_prevista in ('pix', 'dinheiro', 'debito', 'credito_vista', 'credito_parcelado',
                                                 'boleto', 'transferencia')),
  orcamento_id uuid,              -- liga ao orçamento (tabela do módulo de documentos; chave na integração)
  cancelado_em timestamptz,
  motivo_cancelamento text,
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  check ((cancelado_em is null) = (motivo_cancelamento is null))
);
comment on table public.acordos_pagamento is 'Combinação de pagamento em parcelas (ex.: implante em 3x no Pix, todo dia 10).';
create index acordos_pagamento_paciente_idx on public.acordos_pagamento (paciente_id);
create index acordos_pagamento_solicitacao_idx on public.acordos_pagamento (solicitacao_id);

create table public.parcelas_previstas (
  id uuid primary key default gen_random_uuid(),
  acordo_id uuid not null references public.acordos_pagamento (id),
  numero smallint not null check (numero >= 1),
  total smallint not null check (total >= numero),
  vencimento date not null,
  valor numeric(10,2) not null check (valor > 0),
  cancelada_em timestamptz,
  unique (acordo_id, numero)
);
comment on table public.parcelas_previstas is 'Parcelas a receber de um acordo. Quitada quando os recebimentos ligados somam o valor.';
create index parcelas_previstas_vencimento_idx on public.parcelas_previstas (vencimento);

create trigger acordos_pagamento_auditoria after insert or update on public.acordos_pagamento
  for each row execute function public.registrar_auditoria();
create trigger acordos_pagamento_sem_exclusao before delete on public.acordos_pagamento
  for each row execute function public.bloquear_exclusao_financeira();
create trigger acordos_pagamento_sem_truncate before truncate on public.acordos_pagamento
  for each statement execute function public.bloquear_exclusao_financeira();
create trigger parcelas_previstas_auditoria after insert or update on public.parcelas_previstas
  for each row execute function public.registrar_auditoria();
create trigger parcelas_previstas_sem_exclusao before delete on public.parcelas_previstas
  for each row execute function public.bloquear_exclusao_financeira();
create trigger parcelas_previstas_sem_truncate before truncate on public.parcelas_previstas
  for each statement execute function public.bloquear_exclusao_financeira();

-- ---------------------------------------------------------------------
-- Recebimentos (só inclusão; estorno = lançamento negativo ligado)
-- ---------------------------------------------------------------------
create table public.recebimentos (
  id uuid primary key default gen_random_uuid(),
  numero integer generated always as identity unique,
  paciente_id uuid not null references public.pacientes (id),
  data_pagamento date not null,
  valor_bruto numeric(10,2) not null check (valor_bruto <> 0),
  forma text not null check (forma in ('pix', 'dinheiro', 'debito', 'credito_vista', 'credito_parcelado',
                                       'boleto', 'transferencia')),
  parcelas_cartao smallint not null default 1 check (parcelas_cartao between 1 and 24),
  taxa_percentual numeric(6,3) not null default 0 check (taxa_percentual between 0 and 30),
  taxa_valor numeric(10,2) not null default 0,
  valor_liquido numeric(10,2) not null,
  data_credito_prevista date,
  pagador_nome text not null check (length(btrim(pagador_nome)) >= 3),
  pagador_cpf text check (pagador_cpf is null or public.cpf_valido(pagador_cpf)),
  pagador_e_paciente boolean not null,
  beneficiario_cpf text check (beneficiario_cpf is null or public.cpf_valido(beneficiario_cpf)),
  descricao text,
  atendimento_id uuid references public.atendimentos (id),
  orcamento_id uuid,              -- liga ao orçamento (chave estrangeira na integração)
  parcela_id uuid references public.parcelas_previstas (id),
  regime_fiscal text not null check (regime_fiscal in ('pf', 'pj')),
  estorna_id uuid references public.recebimentos (id),
  motivo_estorno text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  check ((estorna_id is null) = (valor_bruto > 0)),
  check ((estorna_id is null) = (motivo_estorno is null)),
  check (abs(valor_liquido - (valor_bruto - taxa_valor)) < 0.005),
  check (parcelas_cartao = 1 or forma = 'credito_parcelado')
);
comment on table public.recebimentos is
  'Pagamentos recebidos. Imutável: estorno é um novo lançamento negativo com estorna_id e motivo.';
create index recebimentos_paciente_idx on public.recebimentos (paciente_id, data_pagamento desc);
create index recebimentos_data_idx on public.recebimentos (data_pagamento);
create index recebimentos_parcela_idx on public.recebimentos (parcela_id);
create index recebimentos_estorna_idx on public.recebimentos (estorna_id);
create index recebimentos_atendimento_idx on public.recebimentos (atendimento_id);
create index recebimentos_solicitacao_idx on public.recebimentos (solicitacao_id);

create trigger recebimentos_so_inclusao before update or delete on public.recebimentos
  for each row execute function public.bloquear_alteracao_financeira();
create trigger recebimentos_sem_truncate before truncate on public.recebimentos
  for each statement execute function public.bloquear_alteracao_financeira();
create trigger recebimentos_auditoria after insert on public.recebimentos
  for each row execute function public.registrar_auditoria();

-- Situação do recibo do Receita Saúde (eventos; o último vale).
create table public.recibos_receita_saude (
  id uuid primary key default gen_random_uuid(),
  recebimento_id uuid not null references public.recebimentos (id),
  situacao text not null check (situacao in ('emitido', 'cancelado')),
  codigo text,
  data_emissao date not null,
  observacao text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now()
);
comment on table public.recibos_receita_saude is 'Emissão e cancelamento dos recibos do Receita Saúde, por recebimento (só inclusão).';
create index recibos_receita_saude_recebimento_idx on public.recibos_receita_saude (recebimento_id, registrado_em desc);
create index recibos_receita_saude_solicitacao_idx on public.recibos_receita_saude (solicitacao_id);
create trigger recibos_receita_saude_so_inclusao before update or delete on public.recibos_receita_saude
  for each row execute function public.bloquear_alteracao_financeira();
create trigger recibos_receita_saude_sem_truncate before truncate on public.recibos_receita_saude
  for each statement execute function public.bloquear_alteracao_financeira();
create trigger recibos_receita_saude_auditoria after insert on public.recibos_receita_saude
  for each row execute function public.registrar_auditoria();

-- ---------------------------------------------------------------------
-- Despesas (só inclusão) e despesas fixas (recorrentes)
-- ---------------------------------------------------------------------
create table public.despesas_recorrentes (
  id uuid primary key default gen_random_uuid(),
  descricao text not null check (length(btrim(descricao)) >= 3),
  categoria text not null check (categoria in ('aluguel_sala', 'materiais', 'laboratorio', 'cro', 'contador', 'inss',
                                               'impostos', 'iss', 'seguro', 'software', 'manutencao', 'marketing',
                                               'outros')),
  fornecedor text,
  fornecedor_documento text check (fornecedor_documento is null
                                   or public.cpf_valido(fornecedor_documento)
                                   or public.cnpj_valido(fornecedor_documento)),
  valor numeric(10,2) not null check (valor > 0),
  dia smallint not null check (dia between 1 and 31),
  forma text check (forma in ('pix', 'dinheiro', 'debito', 'credito_vista', 'credito_parcelado', 'boleto',
                              'transferencia')),
  inicio date not null,
  encerrada_em date,
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now()
);
comment on table public.despesas_recorrentes is 'Despesas fixas do mês (CRO, contador, software...). Lançadas mês a mês em despesas.';
create trigger despesas_recorrentes_auditoria after insert or update on public.despesas_recorrentes
  for each row execute function public.registrar_auditoria();
create trigger despesas_recorrentes_sem_exclusao before delete on public.despesas_recorrentes
  for each row execute function public.bloquear_exclusao_financeira();
create trigger despesas_recorrentes_sem_truncate before truncate on public.despesas_recorrentes
  for each statement execute function public.bloquear_exclusao_financeira();

create table public.despesas (
  id uuid primary key default gen_random_uuid(),
  numero integer generated always as identity unique,
  data date not null,
  competencia date not null check (extract(day from competencia) = 1),
  categoria text not null check (categoria in ('aluguel_sala', 'materiais', 'laboratorio', 'cro', 'contador', 'inss',
                                               'impostos', 'iss', 'seguro', 'software', 'manutencao', 'marketing',
                                               'outros')),
  descricao text not null check (length(btrim(descricao)) >= 2),
  fornecedor text,
  fornecedor_documento text check (fornecedor_documento is null
                                   or public.cpf_valido(fornecedor_documento)
                                   or public.cnpj_valido(fornecedor_documento)),
  valor numeric(10,2) not null check (valor <> 0),
  forma text check (forma in ('pix', 'dinheiro', 'debito', 'credito_vista', 'credito_parcelado', 'boleto',
                              'transferencia')),
  paciente_id uuid references public.pacientes (id),
  origem text not null default 'manual' check (origem in ('manual', 'recorrente', 'reserva_sala', 'compra')),
  origem_id uuid,
  comprovante text,
  estorna_id uuid references public.despesas (id),
  motivo_estorno text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  check ((estorna_id is null) = (valor > 0)),
  check ((estorna_id is null) = (motivo_estorno is null)),
  check ((origem = 'manual') = (origem_id is null))
);
comment on table public.despesas is
  'Despesas do consultório (livro-caixa). Imutável: estorno é um novo lançamento negativo com estorna_id e motivo.';
create index despesas_competencia_idx on public.despesas (competencia, categoria);
create index despesas_data_idx on public.despesas (data);
create index despesas_estorna_idx on public.despesas (estorna_id);
create index despesas_paciente_idx on public.despesas (paciente_id);
create index despesas_solicitacao_idx on public.despesas (solicitacao_id);
create index despesas_origem_idx on public.despesas (origem, origem_id);

create trigger despesas_so_inclusao before update or delete on public.despesas
  for each row execute function public.bloquear_alteracao_financeira();
create trigger despesas_sem_truncate before truncate on public.despesas
  for each statement execute function public.bloquear_alteracao_financeira();
create trigger despesas_auditoria after insert on public.despesas
  for each row execute function public.registrar_auditoria();

-- Pacotes mensais gerados para o contador (só inclusão).
create table public.pacotes_contador (
  id uuid primary key default gen_random_uuid(),
  competencia date not null check (extract(day from competencia) = 1),
  arquivos jsonb not null check (jsonb_typeof(arquivos) = 'array'),
  resumo jsonb not null,
  solicitacao_id uuid references public.solicitacoes (id),
  gerado_em timestamptz not null default now()
);
comment on table public.pacotes_contador is 'Pacotes mensais (CSVs no Storage) mandados ao contador.';
create index pacotes_contador_competencia_idx on public.pacotes_contador (competencia, gerado_em desc);
create index pacotes_contador_solicitacao_idx on public.pacotes_contador (solicitacao_id);
create trigger pacotes_contador_so_inclusao before update or delete on public.pacotes_contador
  for each row execute function public.bloquear_alteracao_financeira();
create trigger pacotes_contador_sem_truncate before truncate on public.pacotes_contador
  for each statement execute function public.bloquear_alteracao_financeira();
create trigger pacotes_contador_auditoria after insert on public.pacotes_contador
  for each row execute function public.registrar_auditoria();

-- ---------------------------------------------------------------------
-- Acesso
-- ---------------------------------------------------------------------
alter table public.configuracao_financeira enable row level security;
alter table public.acordos_pagamento enable row level security;
alter table public.parcelas_previstas enable row level security;
alter table public.recebimentos enable row level security;
alter table public.recibos_receita_saude enable row level security;
alter table public.despesas_recorrentes enable row level security;
alter table public.despesas enable row level security;
alter table public.pacotes_contador enable row level security;

revoke all on table
  public.configuracao_financeira, public.acordos_pagamento, public.parcelas_previstas, public.recebimentos,
  public.recibos_receita_saude, public.despesas_recorrentes, public.despesas, public.pacotes_contador
  from anon, authenticated;

revoke execute on function
  public.bloquear_alteracao_financeira(), public.bloquear_exclusao_financeira(), public.regime_fiscal(date),
  public.cnpj_valido(text)
  from public, anon, authenticated;
grant execute on function public.regime_fiscal(date), public.cnpj_valido(text) to service_role;
