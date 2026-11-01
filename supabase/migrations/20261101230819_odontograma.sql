-- =====================================================================
-- Etapa 1: odontograma.
--
-- Cada linha é uma marca num dente (e faces), numa de três camadas:
--   inicial    = o que o paciente já tem (achado na avaliação ou trabalho
--                feito por outro dentista);
--   planejado  = tratamento a fazer (vira plano/orçamento na etapa 3);
--   realizado  = feito aqui. Nasce sozinho do registrar_atendimento.
--
-- Como o prontuário, o odontograma só aceita inclusões:
--   * uma marca nova ENCERRA as que deixaram de valer (encerra_ids), ex.:
--     a restauração O do 36 encerra a cárie O do 36; extração encerra tudo
--     no dente, menos o plano de implante;
--   * um ENGANO se desfaz com uma marca de anulação (acao = 'anular'),
--     que faz a marca anulada (e o que ela encerrou) deixar de contar.
-- O estado atual = marcas válidas que nenhuma marca válida encerrou.
-- =====================================================================

create table public.odontograma (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  acao text not null default 'marcar' check (acao in ('marcar', 'anular')),
  dente smallint not null check (public.dente_valido(dente)),
  faces text check (faces ~ '^M?[OI]?D?V?[LP]?$' and faces <> ''),
  condicao text not null references public.odontograma_condicoes (codigo),
  camada text not null check (camada in ('inicial', 'planejado', 'realizado')),
  detalhe text,
  procedimento_id uuid references public.procedimentos (id),
  atendimento_id uuid references public.atendimentos (id),
  origem text not null check (origem in ('avaliacao', 'atendimento', 'correcao')),
  data date not null,
  encerra_ids uuid[] not null default '{}',
  anula_ids uuid[] not null default '{}',
  motivo text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  check (acao = 'marcar' or (cardinality(anula_ids) > 0 and motivo is not null)),
  check (acao = 'anular' or cardinality(anula_ids) = 0)
);
comment on table public.odontograma is 'Marcas do odontograma por dente/faces (inicial, planejado, realizado). Só inclusão: encerrar e anular são novas linhas.';
create index odontograma_paciente_idx on public.odontograma (paciente_id, dente);
create index odontograma_encerra_idx on public.odontograma using gin (encerra_ids);
create index odontograma_anula_idx on public.odontograma using gin (anula_ids);
create index odontograma_atendimento_idx on public.odontograma (atendimento_id);
create index odontograma_procedimento_idx on public.odontograma (procedimento_id);
create index odontograma_solicitacao_idx on public.odontograma (solicitacao_id);

create trigger odontograma_so_inclusao before update or delete on public.odontograma
  for each row execute function public.bloquear_alteracao();
create trigger odontograma_sem_truncate before truncate on public.odontograma
  for each statement execute function public.bloquear_alteracao();
create trigger odontograma_auditoria after insert on public.odontograma
  for each row execute function public.registrar_auditoria();

alter table public.odontograma enable row level security;
revoke all on table public.odontograma from anon, authenticated;

-- ---------------------------------------------------------------------
-- Utilitários
-- ---------------------------------------------------------------------

-- Todas as faces de a estão em b (ex.: 'O' está em 'MO').
create or replace function public.faces_contidas(a text, b text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select not exists (
    select 1 from regexp_split_to_table(coalesce(a, ''), '') f
     where f <> '' and position(f in coalesce(b, '')) = 0)
$$;

-- Dentes de uma região (permanentes; Q5–Q8 são os decíduos).
create or replace function public.dentes_da_regiao(p_regiao text)
returns smallint[]
language sql
immutable
set search_path = ''
as $$
  select (case p_regiao
    when 'arcada_superior' then array[18,17,16,15,14,13,12,11,21,22,23,24,25,26,27,28]
    when 'arcada_inferior' then array[48,47,46,45,44,43,42,41,31,32,33,34,35,36,37,38]
    when 'Q1' then array[11,12,13,14,15,16,17,18]
    when 'Q2' then array[21,22,23,24,25,26,27,28]
    when 'Q3' then array[31,32,33,34,35,36,37,38]
    when 'Q4' then array[41,42,43,44,45,46,47,48]
    when 'Q5' then array[51,52,53,54,55]
    when 'Q6' then array[61,62,63,64,65]
    when 'Q7' then array[71,72,73,74,75]
    when 'Q8' then array[81,82,83,84,85]
    when 'S1' then array[18,17,16,15,14]
    when 'S2' then array[13,12,11,21,22,23]
    when 'S3' then array[24,25,26,27,28]
    when 'S4' then array[38,37,36,35,34]
    when 'S5' then array[33,32,31,41,42,43]
    when 'S6' then array[44,45,46,47,48]
  end)::smallint[]
$$;

-- Marcas válidas (não anuladas).
create or replace function public.odontograma_validas(p_paciente uuid)
returns setof public.odontograma
language sql
stable
set search_path = ''
as $$
  select o.*
    from public.odontograma o
   where o.paciente_id = p_paciente
     and o.acao = 'marcar'
     and not exists (select 1 from public.odontograma x
                      where x.paciente_id = p_paciente and x.acao = 'anular'
                        and o.id = any (x.anula_ids))
$$;

-- Marcas ativas: válidas e não encerradas por outra marca válida.
create or replace function public.odontograma_ativas(p_paciente uuid)
returns setof public.odontograma
language sql
stable
set search_path = ''
as $$
  with v as (select * from public.odontograma_validas(p_paciente))
  select v.* from v
   where not exists (select 1 from v x where v.id = any (x.encerra_ids))
$$;

-- ---------------------------------------------------------------------
-- Inclusão de uma marca, com as regras de encerramento.
-- ---------------------------------------------------------------------
create or replace function public.odontograma_marcar(
  p_paciente uuid,
  p_dente smallint,
  p_faces text,
  p_condicao text,
  p_camada text,
  p_detalhe text,
  p_procedimento uuid,
  p_atendimento uuid,
  p_origem text,
  p_data date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_cond public.odontograma_condicoes;
  v_encerra uuid[];
  v_id uuid;
  -- planos que continuam valendo depois de o dente sair
  v_reposicao text[] := array['implante', 'protese_fixa_pontico', 'protese_removivel'];
begin
  select * into v_cond from public.odontograma_condicoes where codigo = p_condicao;
  if not found then
    raise exception 'Condição "%" não existe no odontograma.', p_condicao;
  end if;
  if not public.dente_valido(p_dente) then
    raise exception 'Dente % não existe na numeração FDI (permanentes 11–48, decíduos 51–85).', p_dente;
  end if;
  if p_faces is not null and not v_cond.usa_faces then
    raise exception '"%" é marcado no dente inteiro, sem faces (dente %).', v_cond.nome, p_dente;
  end if;
  if p_camada in ('planejado', 'realizado') and v_cond.tipo not in ('trabalho', 'ausencia') then
    raise exception '"%" é um achado: marque como inicial. Planejado/realizado vale para tratamentos (restauração, canal, coroa, implante, extração = ausente).', v_cond.nome;
  end if;

  select coalesce(array_agg(a.id), '{}')
    into v_encerra
    from public.odontograma_ativas(p_paciente) a
    join public.odontograma_condicoes c on c.codigo = a.condicao
   where a.dente = p_dente
     and (
       -- a mesma condição registrada de novo substitui a anterior da mesma camada
       -- (plano substitui plano; estado substitui estado)
       (a.condicao = p_condicao
        and (a.camada = 'planejado') = (p_camada = 'planejado')
        and (a.faces is null or p_faces is null or public.faces_contidas(a.faces, p_faces)))
       or (p_camada <> 'planejado' and (
         -- o plano foi cumprido
         (a.camada = 'planejado' and a.condicao = p_condicao
          and (a.faces is null or p_faces is null or public.faces_contidas(a.faces, p_faces)))
         -- o tratamento resolve o achado/trabalho anterior
         or (a.camada <> 'planejado' and a.condicao = any (v_cond.resolve)
             and (a.faces is null or p_faces is null or public.faces_contidas(a.faces, p_faces)))
         -- dente ausente: encerra tudo, menos planos de reposição
         or (p_condicao = 'ausente'
             and (a.camada <> 'planejado' or not a.condicao = any (v_reposicao)))
         -- hígido encerra achados; qualquer outra marca encerra o hígido
         or (p_condicao = 'higido' and a.camada <> 'planejado' and c.tipo = 'achado')
         or (p_condicao <> 'higido' and a.condicao = 'higido')
       ))
     );

  insert into public.odontograma (
    paciente_id, acao, dente, faces, condicao, camada, detalhe, procedimento_id,
    atendimento_id, origem, data, encerra_ids, solicitacao_id)
  values (
    p_paciente, 'marcar', p_dente, p_faces, p_condicao, p_camada, nullif(btrim(p_detalhe), ''),
    p_procedimento, p_atendimento, p_origem, p_data, v_encerra,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;
  return v_id;
end
$$;

-- Anula marcas (engano). Uma linha de anulação por marca anulada.
create or replace function public.odontograma_anular(
  p_paciente uuid,
  p_ids uuid[],
  p_motivo text,
  p_data date)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v public.odontograma;
  n int := 0;
begin
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Informe o motivo da correção do odontograma.';
  end if;
  for v in select * from public.odontograma_validas(p_paciente) where id = any (p_ids) loop
    insert into public.odontograma (
      paciente_id, acao, dente, faces, condicao, camada, detalhe, procedimento_id,
      atendimento_id, origem, data, anula_ids, motivo, solicitacao_id)
    values (
      p_paciente, 'anular', v.dente, v.faces, v.condicao, v.camada, v.detalhe, v.procedimento_id,
      v.atendimento_id, 'correcao', p_data, array[v.id], btrim(p_motivo),
      nullif(current_setting('app.solicitacao_id', true), '')::uuid);
    n := n + 1;
  end loop;
  return n;
end
$$;

-- ---------------------------------------------------------------------
-- Representação: estado atual por dente.
-- ---------------------------------------------------------------------
create or replace function public.odontograma_json(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with m as (
    select a.*, c.nome as cond_nome, c.ordem as cond_ordem, p.codigo as proc_codigo, p.nome as proc_nome
      from public.odontograma_ativas(p_paciente) a
      join public.odontograma_condicoes c on c.codigo = a.condicao
      left join public.procedimentos p on p.id = a.procedimento_id
  ),
  por_dente as (
    select m.dente,
           jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'id', m.id,
             'condicao', m.condicao,
             'faces', m.faces,
             'camada', m.camada,
             'detalhe', m.detalhe,
             'procedimento', m.proc_codigo,
             'data', m.data)) order by (m.camada = 'planejado'), m.cond_ordem, m.registrado_em) as marcas,
           string_agg(
             case when m.camada = 'planejado' then 'planejado: ' || coalesce(m.proc_nome, m.cond_nome)
                  else m.cond_nome end
             || coalesce(' ' || m.faces, '')
             || coalesce(' (' || m.detalhe || ')', '')
             || case when m.camada = 'realizado' then ' — feito em ' || to_char(m.data, 'DD/MM/YYYY') else '' end,
             '; ' order by (m.camada = 'planejado'), m.cond_ordem, m.registrado_em) as resumo
      from m
     group by m.dente
  )
  select coalesce(jsonb_agg(jsonb_build_object('dente', d.dente, 'resumo', d.resumo, 'marcas', d.marcas)
                            order by d.dente), '[]'::jsonb)
    from por_dente d
$$;

revoke execute on function
  public.odontograma_validas(uuid), public.odontograma_ativas(uuid),
  public.odontograma_marcar(uuid, smallint, text, text, text, text, uuid, uuid, text, date),
  public.odontograma_anular(uuid, uuid[], text, date),
  public.odontograma_json(uuid)
  from public, anon, authenticated;
grant execute on function
  public.odontograma_validas(uuid), public.odontograma_ativas(uuid),
  public.odontograma_marcar(uuid, smallint, text, text, text, text, uuid, uuid, text, date),
  public.odontograma_anular(uuid, uuid[], text, date),
  public.odontograma_json(uuid)
  to service_role;
