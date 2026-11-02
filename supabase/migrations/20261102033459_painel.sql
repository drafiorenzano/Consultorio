-- =====================================================================
-- Painel do iPad (só leitura).
--
-- O app do iPad chama a Edge Function "painel" com um código de acesso
-- próprio (escopo "painel"), separado do conector do Claude (escopo "mcp").
-- Toda leitura passa por public.painel(acao, parametros), que só devolve
-- dados: nada aqui grava.
-- =====================================================================

alter table public.acessos_mcp
  add column escopo text not null default 'mcp' check (escopo in ('mcp', 'painel'));
comment on column public.acessos_mcp.escopo is 'mcp = conector do Claude; painel = app do iPad (só leitura).';

-- O conector aceita só acessos do escopo mcp.
create or replace function public.mcp_validar_acesso(p_token_sha256 text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id
    from public.acessos_mcp
   where token_sha256 = lower(p_token_sha256)
     and revogado_em is null
     and escopo = 'mcp';
  if v_id is null then
    return false;
  end if;
  update public.acessos_mcp
     set ultimo_uso_em = now()
   where id = v_id
     and (ultimo_uso_em is null or ultimo_uso_em < now() - interval '10 minutes');
  return true;
end
$$;

create or replace function public.painel_validar_acesso(p_token_sha256 text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id
    from public.acessos_mcp
   where token_sha256 = lower(p_token_sha256)
     and revogado_em is null
     and escopo = 'painel';
  if v_id is null then
    return false;
  end if;
  update public.acessos_mcp
     set ultimo_uso_em = now()
   where id = v_id
     and (ultimo_uso_em is null or ultimo_uso_em < now() - interval '10 minutes');
  return true;
end
$$;

-- ---------------------------------------------------------------------
-- Peças reutilizáveis
-- ---------------------------------------------------------------------

-- Consultas ainda não confirmadas no período, com o link de WhatsApp pronto.
create or replace function public.pendentes_confirmacao(p_ini date, p_fim date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'consulta_id', c.id,
           'paciente_id', p.id,
           'paciente', p.nome,
           'data', public.data_local(c.inicio),
           'dia_semana', public.dia_semana(public.data_local(c.inicio)),
           'inicio', public.hora_local(c.inicio),
           'motivo', c.motivo,
           'link_whatsapp', public.link_confirmacao(c.id))) order by c.inicio), '[]'::jsonb)
    from public.consultas c join public.pacientes p on p.id = c.paciente_id
   where c.status = 'agendada' and c.inicio > now()
     and public.data_local(c.inicio) between p_ini and p_fim
$$;

-- Pacientes com retorno previsto (último atendimento) e sem consulta marcada.
create or replace function public.retornos_sem_consulta(p_ate date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x.j order by x.retorno), '[]'::jsonb)
    from (select jsonb_strip_nulls(jsonb_build_object(
                   'paciente_id', p.id, 'paciente', p.nome, 'telefone', public.telefone_contato(p.id),
                   'retorno_previsto', u.retorno_previsto, 'proxima_etapa', u.proxima_etapa,
                   'atrasado', case when u.retorno_previsto < public.hoje() then true end)) as j,
                 u.retorno_previsto as retorno
            from public.pacientes p
            cross join lateral (select a.retorno_previsto, a.proxima_etapa
                                  from public.atendimentos a
                                 where a.paciente_id = p.id
                                 order by a.data desc, a.registrado_em desc limit 1) u
           where p.arquivado_em is null
             and u.retorno_previsto is not null
             and u.retorno_previsto <= p_ate
             and u.retorno_previsto >= public.hoje() - 90
             and not exists (select 1 from public.consultas c
                              where c.paciente_id = p.id and c.status in ('agendada', 'confirmada')
                                and c.fim >= now())
           order by u.retorno_previsto limit 50) x
$$;

-- Consultas de um paciente: próximas, histórico e faltas.
create or replace function public.consultas_do_paciente(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'proximas', coalesce((select jsonb_agg(public.consulta_json(c.id) order by c.inicio)
                            from public.consultas c
                           where c.paciente_id = p_paciente and c.status in ('agendada', 'confirmada')
                             and c.fim >= now()), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(public.consulta_json(x.id) order by x.inicio desc)
                             from (select c.id, c.inicio from public.consultas c
                                    where c.paciente_id = p_paciente
                                      and (c.fim < now() or c.status not in ('agendada', 'confirmada'))
                                    order by c.inicio desc limit 30) x), '[]'::jsonb),
    'faltas', (select count(*) from public.consultas c where c.paciente_id = p_paciente and c.status = 'faltou'))
$$;

-- ---------------------------------------------------------------------
-- Leituras do painel
-- ---------------------------------------------------------------------
create or replace function public.painel_configuracao()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((select jsonb_strip_nulls(jsonb_build_object(
           'nome_consultorio', c.nome_consultorio, 'dentista_nome', c.dentista_nome, 'cro', c.cro,
           'especialidade', c.especialidade, 'endereco', c.endereco, 'cidade', c.cidade, 'uf', c.uf,
           'telefone', c.telefone, 'email', c.email, 'instagram', c.instagram, 'site', c.site))
         from public.configuracao c limit 1), '{}'::jsonb)
$$;

create or replace function public.painel_inicio()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'hoje', public.hoje(),
    'dia_semana', public.dia_semana(public.hoje()),
    'agora', public.hora_local(now()),
    'configuracao', public.painel_configuracao(),
    'agenda_hoje', public.agenda_dia_json(public.hoje()),
    'agenda_amanha', public.agenda_dia_json(public.hoje() + 1),
    'pendentes_de_confirmacao', public.pendentes_confirmacao(public.hoje(), public.hoje() + 7),
    'retornos_sem_consulta', public.retornos_sem_consulta(public.hoje() + 14),
    'numeros', jsonb_build_object(
      'pacientes', (select count(*) from public.pacientes where arquivado_em is null),
      'consultas_semana', (select count(*) from public.consultas c
                            where c.status in ('agendada', 'confirmada', 'realizada')
                              and public.data_local(c.inicio)
                                  between public.hoje() - (extract(isodow from public.hoje())::int - 1)
                                      and public.hoje() + (7 - extract(isodow from public.hoje())::int)),
      'atendimentos_mes', (select count(*) from public.atendimentos a
                            where a.corrige_atendimento_id is null
                              and date_trunc('month', a.data) = date_trunc('month', public.hoje()))))
$$;

create or replace function public.painel_agenda(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ini date := coalesce(public.ler_data(p_params ->> 'inicio', 'Início'), public.hoje());
  v_fim date := coalesce(public.ler_data(p_params ->> 'fim', 'Fim'), v_ini + 6);
  v_dias jsonb := '[]'::jsonb;
  v_d date;
begin
  if v_fim < v_ini then v_fim := v_ini; end if;
  if v_fim - v_ini > 41 then v_fim := v_ini + 41; end if;
  v_d := v_ini;
  while v_d <= v_fim loop
    v_dias := v_dias || public.agenda_dia_json(v_d);
    v_d := v_d + 1;
  end loop;
  return jsonb_build_object(
    'hoje', public.hoje(),
    'inicio', v_ini,
    'fim', v_fim,
    'dias', v_dias,
    'pendentes_de_confirmacao', public.pendentes_confirmacao(v_ini, v_fim));
end
$$;

create or replace function public.painel_pacientes(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with b as (
    select public.normalizar(p_params ->> 'busca') as t,
           regexp_replace(coalesce(p_params ->> 'busca', ''), '\D', '', 'g') as dig,
           coalesce((p_params ->> 'arquivados')::boolean, false) as arq
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', p.id,
           'ficha', p.ficha,
           'nome', p.nome,
           'apelido', p.apelido,
           'idade', public.idade(p.data_nascimento),
           'telefone', public.telefone_contato(p.id),
           'alertas_saude', nullif(p.alertas_saude, '[]'::jsonb),
           'arquivado', case when p.arquivado_em is not null then true end,
           'ultima_visita', (select max(a.data) from public.atendimentos a where a.paciente_id = p.id),
           'proxima_consulta', (select jsonb_build_object('data', public.data_local(c.inicio), 'inicio', public.hora_local(c.inicio))
                                  from public.consultas c
                                 where c.paciente_id = p.id and c.status in ('agendada', 'confirmada') and c.fim >= now()
                                 order by c.inicio limit 1)))
           order by public.normalizar(p.nome)), '[]'::jsonb)
    from public.pacientes p, b
   where (b.arq or p.arquivado_em is null)
     and (b.t = ''
          or public.normalizar(p.nome) like '%' || b.t || '%'
          or public.normalizar(coalesce(p.apelido, '')) like '%' || b.t || '%'
          or public.normalizar(coalesce(p.nome_social, '')) like '%' || b.t || '%'
          or (length(b.dig) >= 4 and (p.telefone like '%' || b.dig || '%' or p.cpf like b.dig || '%'))
          or p.ficha::text = b.dig)
$$;

create or replace function public.painel_paciente(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
  v jsonb;
begin
  begin
    v_id := (p_params ->> 'id')::uuid;
  exception when invalid_text_representation then
    raise exception 'Paciente inválido.';
  end;
  v := public.paciente_ficha(v_id, 50);
  if v is null then raise exception 'Paciente não encontrado.'; end if;
  return v || jsonb_build_object('consultas', public.consultas_do_paciente(v_id));
end
$$;

-- Entrada única do painel. Os módulos acrescentam ações aqui.
create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params)
    else null
  end;
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.mcp_validar_acesso(text), public.painel_validar_acesso(text),
  public.pendentes_confirmacao(date, date), public.retornos_sem_consulta(date), public.consultas_do_paciente(uuid),
  public.painel_configuracao(), public.painel_inicio(), public.painel_agenda(jsonb), public.painel_pacientes(jsonb),
  public.painel_paciente(jsonb), public.painel(text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.mcp_validar_acesso(text), public.painel_validar_acesso(text),
  public.pendentes_confirmacao(date, date), public.retornos_sem_consulta(date), public.consultas_do_paciente(uuid),
  public.painel_configuracao(), public.painel_inicio(), public.painel_agenda(jsonb), public.painel_pacientes(jsonb),
  public.painel_paciente(jsonb), public.painel(text, jsonb)
  to service_role;
