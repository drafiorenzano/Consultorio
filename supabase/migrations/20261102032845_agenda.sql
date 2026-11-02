-- =====================================================================
-- Etapa 2: agenda.
--
-- reservas_sala: horários em que a Dra. alugou a sala (ela aluga por hora).
-- consultas: horários marcados com pacientes. Não se apagam: cancelamento,
--   falta e remarcação mudam o status (com auditoria); remarcar cria uma
--   consulta nova ligada à anterior.
-- Um atendimento registrado no mesmo dia marca a consulta como realizada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilidades de data e hora
-- ---------------------------------------------------------------------

-- "14:30", "14h30", "14h", "14" -> 14:30 / 14:00
create or replace function public.ler_hora(p_valor text, p_campo text)
returns time
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := lower(regexp_replace(coalesce(p_valor, ''), '\s+', '', 'g'));
  m text[];
  h int;
  mi int;
begin
  if v = '' then return null; end if;
  m := regexp_match(v, '^(\d{1,2})(?:[:h](\d{2}))?h?(?:min)?$');
  if m is null then
    raise exception '% "%" inválido: use HH:MM (ex.: 14:30).', p_campo, p_valor;
  end if;
  h := m[1]::int;
  mi := coalesce(m[2], '0')::int;
  if h > 23 or mi > 59 then
    raise exception '% "%" não existe.', p_campo, p_valor;
  end if;
  return make_time(h, mi, 0);
end
$$;

-- Data + hora no fuso do consultório.
create or replace function public.momento(p_data date, p_hora time)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select ((p_data + p_hora) at time zone public.fuso())
$$;

create or replace function public.dia_semana(p_data date)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'])[extract(isodow from p_data)::int]
$$;

create or replace function public.hora_local(p_t timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_t at time zone public.fuso(), 'HH24:MI')
$$;

create or replace function public.data_local(p_t timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select (p_t at time zone public.fuso())::date
$$;

create or replace function public.urlencode(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(string_agg(
           case when c ~ '^[A-Za-z0-9_.~-]$' then c
                else upper(regexp_replace(encode(convert_to(c, 'UTF8'), 'hex'), '(..)', '%\1', 'g')) end,
           '' order by i), '')
    from regexp_split_to_table(coalesce(p, ''), '') with ordinality as t(c, i)
$$;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
create table public.reservas_sala (
  id uuid primary key default gen_random_uuid(),
  inicio timestamptz not null,
  fim timestamptz not null,
  local text,
  valor numeric(10, 2) check (valor >= 0),
  observacao text,
  serie_id uuid,                          -- reservas criadas juntas (toda semana)
  cancelada_em timestamptz,
  motivo_cancelamento text,
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (fim > inicio and fim - inicio <= interval '16 hours'),
  constraint reservas_sala_sem_sobreposicao
    exclude using gist (tstzrange(inicio, fim) with &&) where (cancelada_em is null)
);
comment on table public.reservas_sala is 'Horários em que a sala foi alugada. Cancelar preenche cancelada_em; nada se apaga.';
create index reservas_sala_inicio_idx on public.reservas_sala (inicio);
create index reservas_sala_solicitacao_idx on public.reservas_sala (solicitacao_id);

create table public.consultas (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  inicio timestamptz not null,
  fim timestamptz not null,
  motivo text,
  procedimento_id uuid references public.procedimentos (id),
  observacao text,
  status text not null default 'agendada'
    check (status in ('agendada', 'confirmada', 'realizada', 'faltou', 'cancelada', 'remarcada')),
  status_em timestamptz,
  motivo_status text,
  remarcada_de uuid references public.consultas (id),
  remarcada_para uuid references public.consultas (id),
  atendimento_id uuid references public.atendimentos (id),
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (fim > inicio and fim - inicio <= interval '12 hours'),
  constraint consultas_sem_sobreposicao
    exclude using gist (tstzrange(inicio, fim) with &&) where (status in ('agendada', 'confirmada'))
);
comment on table public.consultas is 'Consultas marcadas. Status muda (com auditoria); nada se apaga. Remarcar cria uma nova ligada à anterior.';
create index consultas_paciente_idx on public.consultas (paciente_id, inicio);
create index consultas_inicio_idx on public.consultas (inicio);
create index consultas_procedimento_idx on public.consultas (procedimento_id);
create index consultas_atendimento_idx on public.consultas (atendimento_id);
create index consultas_remarcada_de_idx on public.consultas (remarcada_de);
create index consultas_remarcada_para_idx on public.consultas (remarcada_para);
create index consultas_solicitacao_idx on public.consultas (solicitacao_id);

create trigger reservas_sala_atualizado_em before update on public.reservas_sala
  for each row execute function public.tocar_atualizado_em();
create trigger reservas_sala_auditoria after insert or update on public.reservas_sala
  for each row execute function public.registrar_auditoria();
create trigger reservas_sala_sem_exclusao before delete or truncate on public.reservas_sala
  for each statement execute function public.bloquear_alteracao();

create trigger consultas_atualizado_em before update on public.consultas
  for each row execute function public.tocar_atualizado_em();
create trigger consultas_auditoria after insert or update on public.consultas
  for each row execute function public.registrar_auditoria();
create trigger consultas_sem_exclusao before delete or truncate on public.consultas
  for each statement execute function public.bloquear_alteracao();

alter table public.reservas_sala enable row level security;
alter table public.consultas enable row level security;
revoke all on table public.reservas_sala, public.consultas from anon, authenticated;

-- ---------------------------------------------------------------------
-- Representações
-- ---------------------------------------------------------------------
create or replace function public.telefone_contato(p_paciente uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select nullif(btrim(p.telefone), '') from public.pacientes p where p.id = p_paciente),
    (select r.telefone from public.responsaveis r
      where r.paciente_id = p_paciente and r.telefone is not null
      order by r.e_pagador desc, r.criado_em limit 1))
$$;

-- Link wa.me com a mensagem de confirmação pronta (a Dra. só toca e envia).
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
           coalesce(cfg.endereco, 'clínica')))
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
    'sala_reservada', case when c.status in ('agendada', 'confirmada') then exists (
      select 1 from public.reservas_sala r
       where r.cancelada_em is null and r.inicio <= c.inicio and r.fim >= c.fim) end))
  from public.consultas c
  join public.pacientes p on p.id = c.paciente_id
  left join public.procedimentos pr on pr.id = c.procedimento_id
  where c.id = p_id
$$;

create or replace function public.reserva_json(r public.reservas_sala)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', r.id,
    'data', public.data_local(r.inicio),
    'dia_semana', public.dia_semana(public.data_local(r.inicio)),
    'inicio', public.hora_local(r.inicio),
    'fim', public.hora_local(r.fim),
    'local', r.local,
    'valor', r.valor,
    'observacao', r.observacao,
    'cancelada', case when r.cancelada_em is not null then true end,
    'motivo_cancelamento', r.motivo_cancelamento))
$$;

-- Intervalos livres (>= 15 min) dentro das reservas do dia.
create or replace function public.horarios_livres(p_data date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  r record;
  c record;
  v_t timestamptz;
  v_livres jsonb := '[]'::jsonb;
  v_ini timestamptz := public.momento(p_data, '00:00');
  v_fim timestamptz := public.momento(p_data + 1, '00:00');
begin
  for r in
    select * from public.reservas_sala
     where cancelada_em is null and inicio < v_fim and fim > v_ini
     order by inicio
  loop
    v_t := greatest(r.inicio, now());
    for c in
      select inicio, fim from public.consultas
       where status in ('agendada', 'confirmada', 'realizada')
         and inicio < r.fim and fim > r.inicio
       order by inicio
    loop
      if c.inicio > v_t and c.inicio - v_t >= interval '15 minutes' then
        v_livres := v_livres || jsonb_build_object('inicio', public.hora_local(v_t), 'fim', public.hora_local(c.inicio),
                                                   'minutos', (extract(epoch from c.inicio - v_t) / 60)::int);
      end if;
      v_t := greatest(v_t, c.fim);
    end loop;
    if r.fim > v_t and r.fim - v_t >= interval '15 minutes' then
      v_livres := v_livres || jsonb_build_object('inicio', public.hora_local(v_t), 'fim', public.hora_local(r.fim),
                                                 'minutos', (extract(epoch from r.fim - v_t) / 60)::int);
    end if;
  end loop;
  return v_livres;
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
    'mensagem', case when not exists (select 1 from public.reservas_sala r
                                       where r.cancelada_em is null and public.data_local(r.inicio) = p_data)
                     then 'Sem reserva de sala neste dia.' end))
$$;

-- Avisos sobre uma consulta ativa (sala, outra consulta do mesmo paciente, horário).
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
begin
  select * into c from public.consultas where id = p_id;
  if c.status not in ('agendada', 'confirmada') then return v_avisos; end if;
  if not exists (select 1 from public.reservas_sala r
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

-- Erro amigável se o horário bate com outra consulta ativa.
create or replace function public.checar_conflito_consulta(p_inicio timestamptz, p_fim timestamptz, p_ignorar uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v record;
begin
  select c.inicio, c.fim, p.nome into v
    from public.consultas c join public.pacientes p on p.id = c.paciente_id
   where c.status in ('agendada', 'confirmada')
     and (p_ignorar is null or c.id <> p_ignorar)
     and tstzrange(c.inicio, c.fim) && tstzrange(p_inicio, p_fim)
   order by c.inicio limit 1;
  if found then
    raise exception 'Conflito: % já está marcado(a) das % às % em %. Escolha outro horário ou remarque essa consulta.',
      v.nome, public.hora_local(v.inicio), public.hora_local(v.fim), to_char(v.inicio at time zone public.fuso(), 'DD/MM');
  end if;
end
$$;

-- Acha a consulta pelo id, ou a próxima ativa do paciente (na data, se dada).
create or replace function public.localizar_consulta(p_dados jsonb)
returns public.consultas
language plpgsql
stable
set search_path = ''
as $$
declare
  v public.consultas;
  v_id uuid;
  v_pac public.pacientes;
  v_data date;
  v_n int;
  v_lista text;
begin
  if nullif(btrim(p_dados ->> 'consulta_id'), '') is not null then
    begin
      v_id := (p_dados ->> 'consulta_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'consulta_id inválido. Use ver_agenda para achar a consulta.';
    end;
    select * into v from public.consultas where id = v_id;
    if not found then raise exception 'Consulta não encontrada. Use ver_agenda para achar a consulta.'; end if;
    return v;
  end if;
  if nullif(btrim(p_dados ->> 'paciente_id'), '') is null then
    raise exception 'Diga qual consulta: consulta_id (de ver_agenda) ou paciente_id (de buscar_paciente).';
  end if;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_data := public.ler_data(p_dados ->> 'data', 'Data');
  select count(*), string_agg(to_char(c.inicio at time zone public.fuso(), 'DD/MM HH24:MI'), ', ' order by c.inicio)
    into v_n, v_lista
    from public.consultas c
   where c.paciente_id = v_pac.id and c.status in ('agendada', 'confirmada')
     and (case when v_data is null then c.fim >= now() - interval '12 hours'
               else public.data_local(c.inicio) = v_data end);
  if v_n = 0 then
    raise exception 'Não achei consulta marcada de %.', v_pac.nome ||
      case when v_data is null then '' else ' em ' || to_char(v_data, 'DD/MM') end;
  end if;
  if v_n > 1 and v_data is not null then
    raise exception '% tem % consultas nesse dia (%). Diga o horário ou use o consulta_id.', v_pac.nome, v_n, v_lista;
  end if;
  select * into v from public.consultas c
   where c.paciente_id = v_pac.id and c.status in ('agendada', 'confirmada')
     and (case when v_data is null then c.fim >= now() - interval '12 hours'
               else public.data_local(c.inicio) = v_data end)
   order by c.inicio limit 1;
  return v;
end
$$;

-- ---------------------------------------------------------------------
-- agendar_consulta
-- ---------------------------------------------------------------------
create or replace function public.mcp_agendar_consulta(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pac public.pacientes;
  v_data date;
  v_hora time;
  v_dur int;
  v_inicio timestamptz;
  v_fim timestamptz;
  v_proc public.procedimentos;
  v_motivo text;
  v_id uuid;
  v_sol uuid;
begin
  v_sol := public.iniciar_solicitacao('agendar_consulta', p_dados, p_texto_original);
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');

  v_data := public.ler_data(p_dados ->> 'data', 'Data');
  if v_data is null then raise exception 'Informe a data da consulta (AAAA-MM-DD).'; end if;
  v_hora := public.ler_hora(p_dados ->> 'hora', 'Horário');
  if v_hora is null then raise exception 'Informe o horário da consulta (HH:MM).'; end if;
  v_dur := coalesce(nullif(p_dados ->> 'duracao_min', '')::int, 60);
  if v_dur not between 10 and 480 then
    raise exception 'Duração de % minutos fora do esperado (10 a 480).', v_dur;
  end if;
  v_inicio := public.momento(v_data, v_hora);
  v_fim := v_inicio + make_interval(mins => v_dur);
  if v_inicio < now() - interval '15 minutes' then
    raise exception 'Esse horário já passou (% às %). Para registrar o que foi feito, use registrar_atendimento.',
      to_char(v_data, 'DD/MM'), to_char(v_hora, 'HH24:MI');
  end if;

  if nullif(btrim(p_dados ->> 'procedimento_codigo'), '') is not null then
    select * into v_proc from public.procedimentos
     where codigo = public.codigo_de(p_dados ->> 'procedimento_codigo') and ativo;
    if not found then
      raise exception 'Procedimento "%" não está no catálogo. Use listar_procedimentos ou diga só o motivo.',
        p_dados ->> 'procedimento_codigo';
    end if;
  end if;
  v_motivo := coalesce(nullif(btrim(p_dados ->> 'motivo'), ''), v_proc.nome);

  perform public.checar_conflito_consulta(v_inicio, v_fim, null);

  insert into public.consultas (paciente_id, inicio, fim, motivo, procedimento_id, observacao, status, status_em,
                                solicitacao_id)
  values (v_pac.id, v_inicio, v_fim, v_motivo, v_proc.id, nullif(btrim(p_dados ->> 'observacao'), ''),
          case when coalesce((p_dados ->> 'confirmada')::boolean, false) then 'confirmada' else 'agendada' end,
          now(), v_sol)
  returning id into v_id;

  return jsonb_build_object(
    'status', 'ok',
    'consulta', public.consulta_json(v_id),
    'agenda_do_dia', public.agenda_dia_json(v_data),
    'avisos', to_jsonb(public.consulta_avisos(v_id)));
end
$$;

-- ---------------------------------------------------------------------
-- alterar_consulta: confirmar, remarcar, cancelar, faltou, reabrir, alterar
-- ---------------------------------------------------------------------
create or replace function public.mcp_alterar_consulta(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := public.normalizar(p_dados ->> 'acao');
  c public.consultas;
  v_pac public.pacientes;
  v_motivo text := nullif(btrim(p_dados ->> 'motivo'), '');
  v_data date;
  v_hora time;
  v_dur int;
  v_inicio timestamptz;
  v_fim timestamptz;
  v_novo uuid;
  v_proc public.procedimentos;
  v_avisos text[] := '{}';
  v_faltas int;
  v_sol uuid;
begin
  v_sol := public.iniciar_solicitacao('alterar_consulta', p_dados, p_texto_original);
  if v_acao not in ('confirmar', 'remarcar', 'cancelar', 'faltou', 'reabrir', 'alterar') then
    raise exception 'Ação "%" desconhecida. Use confirmar, remarcar, cancelar, faltou, reabrir ou alterar.', p_dados ->> 'acao';
  end if;
  c := public.localizar_consulta(p_dados);
  select * into v_pac from public.pacientes where id = c.paciente_id;

  if v_acao in ('confirmar', 'remarcar', 'cancelar', 'faltou', 'alterar')
     and c.status not in ('agendada', 'confirmada') then
    raise exception 'A consulta de % em % está "%": não dá para %.', v_pac.nome,
      to_char(c.inicio at time zone public.fuso(), 'DD/MM HH24:MI'), c.status, v_acao;
  end if;

  if v_acao = 'confirmar' then
    update public.consultas set status = 'confirmada', status_em = now(), motivo_status = v_motivo where id = c.id;

  elsif v_acao = 'cancelar' then
    update public.consultas set status = 'cancelada', status_em = now(), motivo_status = v_motivo where id = c.id;
    if v_motivo is null then
      v_avisos := array_append(v_avisos, 'Cancelada sem motivo registrado.');
    end if;

  elsif v_acao = 'faltou' then
    if public.data_local(c.inicio) > public.hoje() then
      raise exception 'A consulta é em %: ainda não dá para marcar falta. Para desmarcar, use cancelar.',
        to_char(c.inicio at time zone public.fuso(), 'DD/MM');
    end if;
    update public.consultas set status = 'faltou', status_em = now(), motivo_status = v_motivo where id = c.id;
    select count(*) into v_faltas from public.consultas where paciente_id = c.paciente_id and status = 'faltou';
    if v_faltas > 1 then
      v_avisos := array_append(v_avisos, format('%s já faltou %s vezes.', v_pac.nome, v_faltas));
    end if;

  elsif v_acao = 'reabrir' then
    if c.status not in ('cancelada', 'faltou') then
      raise exception 'Só dá para reabrir consulta cancelada ou marcada como falta (esta está "%").', c.status;
    end if;
    if c.fim < now() and c.status = 'cancelada' then
      raise exception 'Esse horário já passou. Para marcar de novo, use agendar_consulta.';
    end if;
    perform public.checar_conflito_consulta(c.inicio, c.fim, c.id);
    update public.consultas set status = 'agendada', status_em = now(), motivo_status = v_motivo where id = c.id;

  elsif v_acao = 'alterar' then
    if nullif(btrim(p_dados ->> 'procedimento_codigo'), '') is not null then
      select * into v_proc from public.procedimentos
       where codigo = public.codigo_de(p_dados ->> 'procedimento_codigo') and ativo;
      if not found then
        raise exception 'Procedimento "%" não está no catálogo.', p_dados ->> 'procedimento_codigo';
      end if;
    end if;
    v_dur := nullif(p_dados ->> 'duracao_min', '')::int;
    if v_dur is not null and v_dur not between 10 and 480 then
      raise exception 'Duração de % minutos fora do esperado (10 a 480).', v_dur;
    end if;
    v_fim := case when v_dur is null then c.fim else c.inicio + make_interval(mins => v_dur) end;
    if v_fim <> c.fim then
      perform public.checar_conflito_consulta(c.inicio, v_fim, c.id);
    end if;
    update public.consultas set
      motivo = coalesce(nullif(btrim(p_dados ->> 'novo_motivo'), ''), case when v_proc.id is not null then v_proc.nome end, motivo),
      procedimento_id = coalesce(v_proc.id, procedimento_id),
      observacao = case when p_dados ? 'observacao' then nullif(btrim(p_dados ->> 'observacao'), '') else observacao end,
      fim = v_fim
     where id = c.id;

  elsif v_acao = 'remarcar' then
    v_data := coalesce(public.ler_data(p_dados ->> 'nova_data', 'Nova data'), public.data_local(c.inicio));
    v_hora := coalesce(public.ler_hora(p_dados ->> 'nova_hora', 'Novo horário'), (c.inicio at time zone public.fuso())::time);
    v_dur := coalesce(nullif(p_dados ->> 'duracao_min', '')::int, (extract(epoch from c.fim - c.inicio) / 60)::int);
    if p_dados ->> 'nova_data' is null and p_dados ->> 'nova_hora' is null then
      raise exception 'Para remarcar, diga a nova data e/ou o novo horário.';
    end if;
    v_inicio := public.momento(v_data, v_hora);
    v_fim := v_inicio + make_interval(mins => v_dur);
    if v_inicio < now() - interval '15 minutes' then
      raise exception 'O novo horário (% às %) já passou.', to_char(v_data, 'DD/MM'), to_char(v_hora, 'HH24:MI');
    end if;
    if v_inicio = c.inicio and v_fim = c.fim then
      raise exception 'O novo horário é igual ao atual.';
    end if;
    perform public.checar_conflito_consulta(v_inicio, v_fim, c.id);
    update public.consultas set status = 'remarcada', status_em = now(), motivo_status = v_motivo where id = c.id;
    insert into public.consultas (paciente_id, inicio, fim, motivo, procedimento_id, observacao, status, status_em,
                                  remarcada_de, solicitacao_id)
    values (c.paciente_id, v_inicio, v_fim, c.motivo, c.procedimento_id, c.observacao,
            case when coalesce((p_dados ->> 'confirmada')::boolean, false) then 'confirmada' else 'agendada' end,
            now(), c.id, v_sol)
    returning id into v_novo;
    update public.consultas set remarcada_para = v_novo where id = c.id;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'acao', v_acao,
    'consulta', public.consulta_json(coalesce(v_novo, c.id)),
    'anterior', case when v_novo is not null then jsonb_build_object(
                  'data', public.data_local(c.inicio), 'inicio', public.hora_local(c.inicio)) end,
    'agenda_do_dia', public.agenda_dia_json(public.data_local(
                       coalesce((select inicio from public.consultas where id = v_novo), c.inicio))),
    'avisos', to_jsonb(v_avisos || public.consulta_avisos(coalesce(v_novo, c.id))));
end
$$;

-- ---------------------------------------------------------------------
-- reservar_sala: reservar (uma vez ou toda semana) ou cancelar
-- ---------------------------------------------------------------------
create or replace function public.mcp_reservar_sala(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'reservar');
  v_data date;
  v_ate date;
  v_hi time;
  v_hf time;
  v_valor numeric;
  v_valor_hora numeric;
  v_serie uuid;
  v_d date;
  v_ids uuid[] := '{}';
  v_id uuid;
  v_conf record;
  v_r public.reservas_sala;
  v_sem_sala jsonb;
  v_avisos text[] := '{}';
  v_sol uuid;
begin
  v_sol := public.iniciar_solicitacao('reservar_sala', p_dados, p_texto_original);
  if v_acao not in ('reservar', 'cancelar') then
    raise exception 'Ação "%" desconhecida. Use reservar ou cancelar.', p_dados ->> 'acao';
  end if;

  v_data := public.ler_data(p_dados ->> 'data', 'Data');
  v_hi := public.ler_hora(p_dados ->> 'hora_inicio', 'Hora de início');
  v_hf := public.ler_hora(p_dados ->> 'hora_fim', 'Hora de fim');

  if v_acao = 'cancelar' then
    if nullif(btrim(p_dados ->> 'reserva_id'), '') is not null then
      select * into v_r from public.reservas_sala where id = (p_dados ->> 'reserva_id')::uuid and cancelada_em is null;
    elsif v_data is not null then
      select * into v_r from public.reservas_sala
       where cancelada_em is null and public.data_local(inicio) = v_data
         and (v_hi is null or (inicio at time zone public.fuso())::time <= v_hi and (fim at time zone public.fuso())::time > v_hi)
       order by inicio limit 1;
      if (select count(*) from public.reservas_sala
           where cancelada_em is null and public.data_local(inicio) = v_data) > 1 and v_hi is null then
        raise exception 'Há mais de uma reserva em %: diga o horário (hora_inicio) ou o reserva_id.', to_char(v_data, 'DD/MM');
      end if;
    else
      raise exception 'Diga qual reserva cancelar: data (e hora_inicio) ou reserva_id.';
    end if;
    if v_r.id is null then raise exception 'Não achei essa reserva da sala.'; end if;
    update public.reservas_sala set cancelada_em = now(), motivo_cancelamento = nullif(btrim(p_dados ->> 'motivo'), '')
     where id = v_r.id;
    select jsonb_agg(public.consulta_json(c.id) order by c.inicio) into v_sem_sala
      from public.consultas c
     where c.status in ('agendada', 'confirmada') and c.inicio < v_r.fim and c.fim > v_r.inicio
       and not exists (select 1 from public.reservas_sala r2
                        where r2.cancelada_em is null and r2.inicio <= c.inicio and r2.fim >= c.fim);
    if v_sem_sala is not null then
      v_avisos := array_append(v_avisos, format('%s consulta(s) desse horário ficaram sem sala: remarque ou reserve de novo.',
                                                jsonb_array_length(v_sem_sala)));
    end if;
    return jsonb_build_object('status', 'ok', 'acao', 'cancelar',
      'reserva', public.reserva_json((select r from public.reservas_sala r where r.id = v_r.id)),
      'consultas_sem_sala', v_sem_sala,
      'avisos', to_jsonb(v_avisos));
  end if;

  -- reservar
  if v_data is null or v_hi is null or v_hf is null then
    raise exception 'Para reservar a sala, diga a data, a hora de início e a hora de fim.';
  end if;
  if v_hf <= v_hi then
    raise exception 'A hora de fim (%) precisa ser depois da de início (%).', to_char(v_hf, 'HH24:MI'), to_char(v_hi, 'HH24:MI');
  end if;
  v_ate := public.ler_data(p_dados ->> 'repetir_semanal_ate', 'Repetir até');
  if v_ate is not null and v_ate < v_data then
    raise exception 'A data final da repetição (%) é antes da primeira (%).', to_char(v_ate, 'DD/MM'), to_char(v_data, 'DD/MM');
  end if;
  if v_ate is not null and v_ate > v_data + 366 then
    raise exception 'Repetição de no máximo um ano.';
  end if;
  v_valor := nullif(p_dados ->> 'valor', '')::numeric;
  v_valor_hora := nullif(p_dados ->> 'valor_hora', '')::numeric;
  if v_valor is null and v_valor_hora is not null then
    v_valor := round(v_valor_hora * extract(epoch from v_hf - v_hi) / 3600, 2);
  end if;
  if public.momento(v_data, v_hf) < now() then
    v_avisos := array_append(v_avisos, 'Reserva registrada para um horário que já passou.');
  end if;

  v_serie := case when v_ate is not null then gen_random_uuid() end;
  v_d := v_data;
  loop
    select r.inicio, r.fim into v_conf from public.reservas_sala r
     where r.cancelada_em is null
       and tstzrange(r.inicio, r.fim) && tstzrange(public.momento(v_d, v_hi), public.momento(v_d, v_hf))
     limit 1;
    if found then
      raise exception 'Já existe reserva em % das % às %. Nada foi reservado.', to_char(v_d, 'DD/MM'),
        public.hora_local(v_conf.inicio), public.hora_local(v_conf.fim);
    end if;
    insert into public.reservas_sala (inicio, fim, local, valor, observacao, serie_id, solicitacao_id)
    values (public.momento(v_d, v_hi), public.momento(v_d, v_hf), nullif(btrim(p_dados ->> 'local'), ''),
            v_valor, nullif(btrim(p_dados ->> 'observacao'), ''), v_serie, v_sol)
    returning id into v_id;
    v_ids := array_append(v_ids, v_id);
    exit when v_ate is null;
    v_d := v_d + 7;
    exit when v_d > v_ate;
  end loop;

  if v_valor is null then
    v_avisos := array_append(v_avisos, 'Sem valor da reserva: o custo da sala não vai para o financeiro.');
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'acao', 'reservar',
    'reservas', (select jsonb_agg(public.reserva_json(r) order by r.inicio) from public.reservas_sala r where r.id = any (v_ids)),
    'total_reservas', cardinality(v_ids),
    'valor_total', (select sum(valor) from public.reservas_sala where id = any (v_ids)),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- ver_agenda: dia, período ou paciente; pendentes de confirmação; retornos
-- ---------------------------------------------------------------------
create or replace function public.mcp_ver_agenda(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ini date;
  v_fim date;
  v_pac public.pacientes;
  v_dias jsonb := '[]'::jsonb;
  v_d date;
  v_pendentes jsonb;
  v_retornos jsonb;
begin
  perform public.iniciar_solicitacao('ver_agenda', p_dados, p_texto_original);

  if nullif(btrim(p_dados ->> 'paciente_id'), '') is not null then
    v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
    return jsonb_build_object(
      'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome),
      'proximas', coalesce((select jsonb_agg(public.consulta_json(c.id) order by c.inicio)
                              from public.consultas c
                             where c.paciente_id = v_pac.id and c.status in ('agendada', 'confirmada')
                               and c.fim >= now()), '[]'::jsonb),
      'historico', coalesce((select jsonb_agg(public.consulta_json(x.id) order by x.inicio desc)
                               from (select c.id, c.inicio from public.consultas c
                                      where c.paciente_id = v_pac.id
                                        and (c.fim < now() or c.status not in ('agendada', 'confirmada'))
                                      order by c.inicio desc limit 10) x), '[]'::jsonb),
      'faltas', (select count(*) from public.consultas c where c.paciente_id = v_pac.id and c.status = 'faltou'));
  end if;

  v_ini := coalesce(public.ler_data(p_dados ->> 'data_inicio', 'Data inicial'),
                    public.ler_data(p_dados ->> 'data', 'Data'), public.hoje());
  v_fim := coalesce(public.ler_data(p_dados ->> 'data_fim', 'Data final'),
                    public.ler_data(p_dados ->> 'data', 'Data'), v_ini);
  if v_fim < v_ini then
    raise exception 'A data final (%) é antes da inicial (%).', to_char(v_fim, 'DD/MM'), to_char(v_ini, 'DD/MM');
  end if;
  if v_fim - v_ini > 62 then
    raise exception 'Período longo demais: até dois meses por vez.';
  end if;

  v_d := v_ini;
  while v_d <= v_fim loop
    if v_ini = v_fim
       or exists (select 1 from public.consultas c where public.data_local(c.inicio) = v_d and c.status <> 'remarcada')
       or exists (select 1 from public.reservas_sala r where r.cancelada_em is null and public.data_local(r.inicio) = v_d) then
      v_dias := v_dias || public.agenda_dia_json(v_d);
    end if;
    v_d := v_d + 1;
  end loop;

  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'consulta_id', c.id,
           'paciente', p.nome,
           'data', public.data_local(c.inicio),
           'inicio', public.hora_local(c.inicio),
           'link_whatsapp', public.link_confirmacao(c.id))) order by c.inicio)
    into v_pendentes
    from public.consultas c join public.pacientes p on p.id = c.paciente_id
   where c.status = 'agendada' and c.inicio > now()
     and public.data_local(c.inicio) between v_ini and v_fim;

  if coalesce((p_dados ->> 'incluir_retornos')::boolean, true) then
    select jsonb_agg(x.j order by x.retorno) into v_retornos
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
               and u.retorno_previsto <= v_fim + 14
               and u.retorno_previsto >= public.hoje() - 90
               and not exists (select 1 from public.consultas c
                                where c.paciente_id = p.id and c.status in ('agendada', 'confirmada')
                                  and c.fim >= now())
             order by u.retorno_previsto limit 30) x;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim),
    'dias', v_dias,
    'total_consultas', (select count(*) from public.consultas c
                         where c.status in ('agendada', 'confirmada', 'realizada')
                           and public.data_local(c.inicio) between v_ini and v_fim),
    'pendentes_de_confirmacao', v_pendentes,
    'retornos_sem_consulta', v_retornos,
    'mensagem', case when jsonb_array_length(v_dias) = 0 then 'Nada marcado e nenhuma reserva de sala no período.' end));
end
$$;

-- ---------------------------------------------------------------------
-- Atendimento registrado -> consulta realizada
-- ---------------------------------------------------------------------
create or replace function public.vincular_consulta_ao_atendimento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if new.corrige_atendimento_id is not null then
    update public.consultas set atendimento_id = new.id where atendimento_id = new.corrige_atendimento_id;
    return null;
  end if;
  select c.id into v_id
    from public.consultas c
   where c.paciente_id = new.paciente_id
     and c.status in ('agendada', 'confirmada')
     and public.data_local(c.inicio) = new.data
   order by abs(extract(epoch from (c.inicio at time zone public.fuso())::time
                                 - coalesce(new.hora_inicio, (c.inicio at time zone public.fuso())::time)))
   limit 1;
  if v_id is not null then
    update public.consultas set status = 'realizada', status_em = now(), atendimento_id = new.id where id = v_id;
  end if;
  return null;
end
$$;

create trigger atendimentos_vincula_consulta after insert on public.atendimentos
  for each row execute function public.vincular_consulta_ao_atendimento();

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.ler_hora(text, text), public.momento(date, time), public.dia_semana(date), public.hora_local(timestamptz),
  public.data_local(timestamptz), public.urlencode(text), public.telefone_contato(uuid), public.link_confirmacao(uuid),
  public.consulta_json(uuid), public.reserva_json(public.reservas_sala), public.horarios_livres(date),
  public.agenda_dia_json(date), public.consulta_avisos(uuid),
  public.checar_conflito_consulta(timestamptz, timestamptz, uuid), public.localizar_consulta(jsonb),
  public.mcp_agendar_consulta(jsonb, text), public.mcp_alterar_consulta(jsonb, text),
  public.mcp_reservar_sala(jsonb, text), public.mcp_ver_agenda(jsonb, text),
  public.vincular_consulta_ao_atendimento()
  from public, anon, authenticated;
grant execute on function
  public.ler_hora(text, text), public.momento(date, time), public.dia_semana(date), public.hora_local(timestamptz),
  public.data_local(timestamptz), public.urlencode(text), public.telefone_contato(uuid), public.link_confirmacao(uuid),
  public.consulta_json(uuid), public.reserva_json(public.reservas_sala), public.horarios_livres(date),
  public.agenda_dia_json(date), public.consulta_avisos(uuid),
  public.checar_conflito_consulta(timestamptz, timestamptz, uuid), public.localizar_consulta(jsonb),
  public.mcp_agendar_consulta(jsonb, text), public.mcp_alterar_consulta(jsonb, text),
  public.mcp_reservar_sala(jsonb, text), public.mcp_ver_agenda(jsonb, text)
  to service_role;
