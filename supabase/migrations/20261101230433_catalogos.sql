-- =====================================================================
-- Etapa 1: catálogos fixos do prontuário.
--
--   * odontograma_condicoes: o que se marca num dente (cárie, restauração,
--     ausente...). "resolve" diz quais achados um trabalho encerra quando é
--     feito (ex.: restauração encerra a cárie das mesmas faces).
--   * anamnese_perguntas: o questionário padrão. "alerta_tipo" faz uma
--     resposta "sim" virar alerta de saúde na ficha do paciente.
--
-- Os dados vêm de supabase/functions/mcp/catalogos/*.json (fonte única,
-- também usada pelo servidor MCP) e são gerados por
-- scripts/gerar-catalogos.mjs na migração seguinte.
-- =====================================================================

create table public.odontograma_condicoes (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome text not null,
  tipo text not null check (tipo in ('estado', 'achado', 'trabalho', 'ausencia')),
  usa_faces boolean not null default false,
  resolve text[] not null default '{}',
  ordem int not null default 0
);
comment on table public.odontograma_condicoes is 'Condições do odontograma. achado = problema encontrado; trabalho = tratamento existente ou feito; ausencia = dente ausente.';
comment on column public.odontograma_condicoes.resolve is 'Achados/trabalhos que esta condição encerra no mesmo dente (e nas mesmas faces) quando é registrada.';

create table public.anamnese_perguntas (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*$'),
  ordem int not null,
  grupo text not null,
  texto text not null,
  tipo text not null check (tipo in ('sim_nao', 'texto', 'numero')),
  detalhe text,                 -- o que perguntar quando a resposta é sim
  alerta_tipo text,             -- tipo do alerta de saúde gerado pelo "sim"
  alerta_texto text,
  ativa boolean not null default true,
  check ((alerta_tipo is null) = (alerta_texto is null))
);
comment on table public.anamnese_perguntas is 'Questionário padrão de anamnese (a Dra. pode ajustar depois).';

alter table public.odontograma_condicoes enable row level security;
alter table public.anamnese_perguntas enable row level security;
revoke all on table public.odontograma_condicoes, public.anamnese_perguntas from anon, authenticated;

create trigger anamnese_perguntas_auditoria after insert or update on public.anamnese_perguntas
  for each row execute function public.registrar_auditoria();
create trigger odontograma_condicoes_auditoria after insert or update on public.odontograma_condicoes
  for each row execute function public.registrar_auditoria();

-- A auditoria passa a reconhecer tabelas cuja chave é "codigo".
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
          coalesce(v_depois ->> 'id', v_antes ->> 'id', v_depois ->> 'codigo', v_antes ->> 'codigo'),
          v_antes, v_depois,
          coalesce(auth.uid()::text, current_user));
  return null;
end
$$;
revoke execute on function public.registrar_auditoria() from public, anon, authenticated;
