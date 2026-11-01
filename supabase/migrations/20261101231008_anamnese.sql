-- =====================================================================
-- Etapa 1: anamnese.
--
-- Cada registro é uma VERSÃO completa das respostas do paciente: a nova
-- versão herda as respostas anteriores e sobrepõe o que mudou ("alteradas").
-- Nada é apagado; a ficha mostra sempre a última versão.
--
-- Respostas: {codigo: {resposta, detalhe, em}}, com resposta
--   sim | nao | nao_sabe        (perguntas sim_nao)
--   texto livre / número        (perguntas texto / numero)
--
-- As respostas "sim" das perguntas com alerta viram alertas de saúde do
-- paciente (origem = anamnese), somados aos alertas ditos no cadastro.
-- =====================================================================

create table public.anamneses (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  versao int not null check (versao >= 1),
  respostas jsonb not null default '{}'::jsonb check (jsonb_typeof(respostas) = 'object'),
  alteradas text[] not null default '{}',
  pa_sistolica smallint check (pa_sistolica between 60 and 260),
  pa_diastolica smallint check (pa_diastolica between 30 and 160),
  fc smallint check (fc between 30 and 220),
  observacoes text,
  origem text not null default 'ditado' check (origem in ('ditado', 'formulario', 'papel')),
  assinada_em timestamptz,
  profissional text not null,
  cro text not null,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  unique (paciente_id, versao),
  check ((pa_sistolica is null) = (pa_diastolica is null))
);
comment on table public.anamneses is 'Versões da anamnese do paciente (só inclusão). A última versão vale; as anteriores ficam como histórico.';
create index anamneses_solicitacao_idx on public.anamneses (solicitacao_id);

create trigger anamneses_so_inclusao before update or delete on public.anamneses
  for each row execute function public.bloquear_alteracao();
create trigger anamneses_sem_truncate before truncate on public.anamneses
  for each statement execute function public.bloquear_alteracao();
create trigger anamneses_auditoria after insert on public.anamneses
  for each row execute function public.registrar_auditoria();

alter table public.anamneses enable row level security;
revoke all on table public.anamneses from anon, authenticated;

-- ---------------------------------------------------------------------
-- Alertas derivados das respostas
-- ---------------------------------------------------------------------
create or replace function public.anamnese_alertas(p_respostas jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'tipo', q.alerta_tipo,
           'descricao', q.alerta_texto
                        || coalesce(': ' || nullif(btrim(p_respostas -> q.codigo ->> 'detalhe'), ''), ''),
           'detalhe', nullif(btrim(p_respostas -> q.codigo ->> 'detalhe'), ''),
           'origem', 'anamnese',
           'pergunta', q.codigo,
           'registrado_em', coalesce(p_respostas -> q.codigo ->> 'em', public.hoje()::text)))
         order by q.ordem), '[]'::jsonb)
    from public.anamnese_perguntas q
   where q.alerta_tipo is not null
     and p_respostas -> q.codigo ->> 'resposta' = 'sim'
$$;

-- Recalcula os alertas do paciente: mantém os manuais (cadastro) e troca
-- os derivados da anamnese pelos da versão atual. Um alerta derivado não
-- entra se um manual do mesmo tipo já cita o mesmo detalhe.
-- Devolve avisos de conflito (anamnese diz "não", mas há alerta manual).
create or replace function public.aplicar_alertas_da_anamnese(p_paciente uuid, p_respostas jsonb)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  v_atual jsonb;
  v_manuais jsonb;
  v_deriv jsonb;
  v_final jsonb;
  v_avisos text[] := '{}';
  r record;
begin
  select alertas_saude into v_atual from public.pacientes where id = p_paciente;

  select coalesce(jsonb_agg(a), '[]'::jsonb) into v_manuais
    from jsonb_array_elements(v_atual) a
   where coalesce(a ->> 'origem', 'manual') <> 'anamnese';

  select coalesce(jsonb_agg(d), '[]'::jsonb) into v_deriv
    from jsonb_array_elements(public.anamnese_alertas(p_respostas)) d
   where not exists (
     select 1 from jsonb_array_elements(v_manuais) m
      where m ->> 'tipo' = d ->> 'tipo'
        and d ->> 'detalhe' is not null
        and public.normalizar(m ->> 'descricao') like '%' || public.normalizar(d ->> 'detalhe') || '%');

  v_final := v_manuais || v_deriv;
  if v_final is distinct from v_atual then
    update public.pacientes set alertas_saude = v_final where id = p_paciente;
  end if;

  -- "não" na anamnese x alerta manual do mesmo tipo (tipos com uma pergunta só)
  for r in
    select q.texto, m ->> 'descricao' as descricao
      from public.anamnese_perguntas q
      join jsonb_array_elements(v_manuais) m on m ->> 'tipo' = q.alerta_tipo
     where p_respostas -> q.codigo ->> 'resposta' = 'nao'
       and (select count(*) from public.anamnese_perguntas q2
             where q2.alerta_tipo = q.alerta_tipo and q2.ativa) = 1
  loop
    v_avisos := array_append(v_avisos, format(
      'Conflito: na anamnese a resposta a "%s" foi não, mas a ficha tem o alerta "%s". Confirme com a Dra. qual vale.',
      r.texto, r.descricao));
  end loop;
  return v_avisos;
end
$$;

-- ---------------------------------------------------------------------
-- Representação da anamnese atual
-- ---------------------------------------------------------------------
create or replace function public.anamnese_json(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with ult as (
    select * from public.anamneses where paciente_id = p_paciente order by versao desc limit 1
  ),
  sinais as (
    select a.pa_sistolica, a.pa_diastolica, a.registrado_em
      from public.anamneses a
     where a.paciente_id = p_paciente and a.pa_sistolica is not null
     order by a.versao desc limit 1
  ),
  freq as (
    select a.fc, a.registrado_em
      from public.anamneses a
     where a.paciente_id = p_paciente and a.fc is not null
     order by a.versao desc limit 1
  ),
  r as (
    select q.codigo, q.ordem, q.texto, q.tipo, q.ativa,
           u.respostas -> q.codigo ->> 'resposta' as resposta,
           u.respostas -> q.codigo ->> 'detalhe' as detalhe
      from public.anamnese_perguntas q, ult u
  )
  select case when not exists (select 1 from ult) then
    jsonb_build_object('registrada', false,
                       'mensagem', 'Sem anamnese registrada. Faça antes de procedimentos invasivos.')
  else jsonb_strip_nulls(jsonb_build_object(
    'registrada', true,
    'versao', u.versao,
    'atualizada_em', to_char(u.registrado_em at time zone public.fuso(), 'YYYY-MM-DD'),
    'origem', u.origem,
    'assinada', u.assinada_em is not null,
    'ultima_assinatura', (select to_char(max(a.assinada_em) at time zone public.fuso(), 'YYYY-MM-DD')
                            from public.anamneses a where a.paciente_id = p_paciente),
    'positivas', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                           'pergunta', r.codigo, 'texto', r.texto, 'detalhe', r.detalhe)) order by r.ordem)
                    from r where r.tipo = 'sim_nao' and r.resposta = 'sim'),
    'respostas_abertas', (select jsonb_agg(jsonb_build_object(
                                   'pergunta', r.codigo, 'texto', r.texto,
                                   'resposta', coalesce(r.resposta, r.detalhe)) order by r.ordem)
                            from r where r.tipo <> 'sim_nao' and coalesce(r.resposta, r.detalhe) is not null),
    'nao_sabe', (select jsonb_agg(r.codigo order by r.ordem) from r where r.resposta = 'nao_sabe'),
    'negativas', (select count(*) from r where r.resposta = 'nao'),
    'pendentes', (select jsonb_agg(r.codigo order by r.ordem) from r
                   where r.ativa and r.resposta is null and r.detalhe is null),
    'pressao_arterial', (select s.pa_sistolica || 'x' || s.pa_diastolica || ' mmHg ('
                                || to_char(s.registrado_em at time zone public.fuso(), 'DD/MM/YYYY') || ')'
                           from sinais s),
    'frequencia_cardiaca', (select f.fc || ' bpm (' || to_char(f.registrado_em at time zone public.fuso(), 'DD/MM/YYYY') || ')'
                              from freq f),
    'observacoes', u.observacoes))
  end
  from (select 1) _ left join ult u on true
$$;

revoke execute on function
  public.anamnese_alertas(jsonb),
  public.aplicar_alertas_da_anamnese(uuid, jsonb),
  public.anamnese_json(uuid)
  from public, anon, authenticated;
grant execute on function
  public.anamnese_alertas(jsonb),
  public.aplicar_alertas_da_anamnese(uuid, jsonb),
  public.anamnese_json(uuid)
  to service_role;
