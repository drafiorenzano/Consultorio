-- Agenda no Calendário do iPhone/iPad (assinatura iCal, só leitura).
--
-- A Edge Function "calendario" recebe GET /calendario/<código>, confere o
-- SHA-256 do código aqui (acessos_mcp com escopo "calendario") e monta o .ics
-- com os eventos devolvidos por calendario_feed. Dados mínimos do paciente:
-- primeiro nome e inicial do sobrenome, mais o procedimento. Nada de telefone,
-- CPF ou saúde. O link é gerado e revogado pelo conector (acesso_calendario).

alter table public.configuracao add column if not exists funcoes_url text
  check (funcoes_url is null or funcoes_url ~ '^https://[^/]+/functions/v1$');
comment on column public.configuracao.funcoes_url is
  'Endereço base das Edge Functions do projeto (para montar o link do calendário).';
update public.configuracao set funcoes_url = 'https://wyubbsqurhqrztpexkdc.supabase.co/functions/v1'
 where funcoes_url is null;

-- "Maria Souza Lima" -> "Maria L."; nome social tem preferência.
create or replace function public.nome_curto(p_nome text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when array_length(regexp_split_to_array(btrim(p_nome), '\s+'), 1) > 1
      then split_part(btrim(p_nome), ' ', 1) || ' ' ||
           upper(left((regexp_split_to_array(btrim(p_nome), '\s+'))[array_length(regexp_split_to_array(btrim(p_nome), '\s+'), 1)], 1)) || '.'
    else btrim(p_nome) end
$$;

create or replace function public.calendario_validar_acesso(p_token_sha256 text)
returns uuid
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
     and escopo = 'calendario';
  if v_id is not null then
    update public.acessos_mcp
       set ultimo_uso_em = now()
     where id = v_id
       and (ultimo_uso_em is null or ultimo_uso_em < now() - interval '10 minutes');
  end if;
  return v_id;
end
$$;

-- Eventos do calendário: consultas (60 dias para trás, 13 meses para frente),
-- reservas de sala (livres, sem bloquear) e campanhas (dia inteiro).
-- Devolve null se o código não vale.
create or replace function public.calendario_feed(p_token_sha256 text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cfg public.configuracao;
  v_local_padrao text;
  v_de timestamptz := now() - interval '60 days';
  v_ate timestamptz := now() + interval '13 months';
  v_eventos jsonb;
begin
  if p_token_sha256 is null or public.calendario_validar_acesso(p_token_sha256) is null then
    return null;
  end if;
  select * into v_cfg from public.configuracao limit 1;
  v_local_padrao := concat_ws(', ', v_cfg.endereco, concat_ws('-', v_cfg.cidade, v_cfg.uf));

  select coalesce(jsonb_agg(e order by e ->> 'ordem'), '[]'::jsonb) into v_eventos
  from (
    select jsonb_strip_nulls(jsonb_build_object(
      'ordem', to_char(c.inicio at time zone 'UTC', 'YYYYMMDDHH24MI') || '1',
      'uid', 'consulta-' || c.id || '@consultorio',
      'inicio', c.inicio,
      'fim', c.fim,
      'titulo', case c.status when 'confirmada' then '✓ ' else '' end
                || public.nome_curto(coalesce(nullif(btrim(p.nome_social), ''), p.nome))
                || ' · ' || coalesce(pr.nome, nullif(btrim(c.motivo), ''), 'Consulta')
                || case c.status when 'faltou' then ' (faltou)' when 'realizada' then ' (atendida)' else '' end,
      'local', coalesce((select nullif(concat_ws(', ', x.local, x.cidade), '')
                           from public.campanha_na_data(public.data_local(c.inicio)) x
                          where x.id is not null), v_local_padrao),
      'descricao', concat_ws(E'\n',
        'Ficha nº ' || p.ficha,
        case c.status
          when 'agendada' then 'Agendada (ainda não confirmou)'
          when 'confirmada' then 'Confirmada pelo paciente'
          when 'realizada' then 'Atendida'
          when 'faltou' then 'Faltou' end,
        case when not exists (select 1 from public.atendimentos a where a.paciente_id = p.id)
             then 'Primeira consulta' end,
        'Detalhes: pergunte ao Claude ou veja no app do iPad.'),
      'sequencia', greatest(0, floor(extract(epoch from c.atualizado_em))::bigint - 1700000000),
      'modificado_em', c.atualizado_em)) e
    from public.consultas c
    join public.pacientes p on p.id = c.paciente_id
    left join public.procedimentos pr on pr.id = c.procedimento_id
    where c.status not in ('cancelada', 'remarcada')
      and c.inicio >= v_de and c.inicio < v_ate

    union all
    select jsonb_strip_nulls(jsonb_build_object(
      'ordem', to_char(r.inicio at time zone 'UTC', 'YYYYMMDDHH24MI') || '0',
      'uid', 'sala-' || r.id || '@consultorio',
      'inicio', r.inicio,
      'fim', r.fim,
      'titulo', 'Sala reservada',
      'local', coalesce(nullif(btrim(r.local), ''), v_local_padrao),
      'descricao', nullif(btrim(r.observacao), ''),
      'livre', true,
      'sequencia', greatest(0, floor(extract(epoch from r.atualizado_em))::bigint - 1700000000),
      'modificado_em', r.atualizado_em))
    from public.reservas_sala r
    where r.cancelada_em is null
      and r.inicio >= v_de and r.inicio < v_ate

    union all
    select jsonb_strip_nulls(jsonb_build_object(
      'ordem', to_char(k.inicio, 'YYYYMMDD') || '0000' || '0',
      'uid', 'campanha-' || k.id || '@consultorio',
      'dia_inteiro', true,
      'data_inicio', k.inicio,
      'data_fim', k.fim + 1,
      'titulo', k.nome,
      'local', nullif(concat_ws(', ', k.local, k.cidade), ''),
      'descricao', nullif(btrim(k.observacao), ''),
      'livre', true,
      'sequencia', greatest(0, floor(extract(epoch from k.atualizado_em))::bigint - 1700000000),
      'modificado_em', k.atualizado_em))
    from public.campanhas k
    where k.cancelada_em is null
      and k.fim >= (v_de at time zone public.fuso())::date
      and k.inicio < (v_ate at time zone public.fuso())::date
  ) s(e);

  return jsonb_build_object(
    'nome', 'Consultório · ' || coalesce(v_cfg.dentista_nome, v_cfg.nome_consultorio, 'Agenda'),
    'fuso', public.fuso(),
    'eventos', (select coalesce(jsonb_agg(x - 'ordem'), '[]'::jsonb) from jsonb_array_elements(v_eventos) x));
end
$$;

-- Ferramenta acesso_calendario: gerar, listar e revogar o link de assinatura.
create or replace function public.mcp_acesso_calendario(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'listar');
  v_codigo text;
  v_id uuid;
  v_base text;
  v_link text;
  v_n int;
begin
  perform public.iniciar_solicitacao('acesso_calendario', p_dados, p_texto_original);
  if v_acao not in ('gerar', 'listar', 'revogar') then
    raise exception 'Ação "%" desconhecida. Use gerar, listar ou revogar.', p_dados ->> 'acao';
  end if;

  if v_acao = 'gerar' then
    select funcoes_url into v_base from public.configuracao limit 1;
    if v_base is null then
      raise exception 'O endereço das funções (configuracao.funcoes_url) não está configurado.';
    end if;
    v_codigo := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    insert into public.acessos_mcp (descricao, token_sha256, escopo)
    values (coalesce(nullif(btrim(p_dados ->> 'aparelho'), ''), 'Calendário'),
            encode(extensions.digest(v_codigo, 'sha256'), 'hex'), 'calendario')
    returning id into v_id;
    v_link := rtrim(v_base, '/') || '/calendario/' || v_codigo;
    return jsonb_build_object(
      'status', 'ok',
      'acesso_id', v_id,
      'link_assinar', 'webcal://' || substring(v_link from 9),
      'link', v_link,
      'como_usar',
        'No iPhone: toque no link_assinar e confirme Assinar (ou: app Calendário > Calendários > Adicionar ' ||
        'Calendário > Adicionar Calendário Assinado > cole o link > Assinar). Na tela seguinte, em Conta, ' ||
        'escolha iCloud para aparecer também no iPad; se escolher "No Meu iPhone", repita no iPad. ' ||
        'É só leitura: para marcar, remarcar ou cancelar, continue pedindo ao Claude.',
      'aviso', 'Quem tiver este link vê os horários e o primeiro nome dos pacientes. Não compartilhe; ' ||
               'se vazar ou trocar de aparelho, peça para revogar e gere outro.');
  end if;

  if v_acao = 'revogar' then
    if nullif(btrim(p_dados ->> 'acesso_id'), '') is not null then
      update public.acessos_mcp set revogado_em = now()
       where id = (p_dados ->> 'acesso_id')::uuid and escopo = 'calendario' and revogado_em is null;
    elsif coalesce((p_dados ->> 'todos')::boolean, false) then
      update public.acessos_mcp set revogado_em = now() where escopo = 'calendario' and revogado_em is null;
    else
      raise exception 'Diga qual link revogar (acesso_id, de listar) ou todos = true.';
    end if;
    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'Nenhum link de calendário ativo com esse id.'; end if;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'revogados', v_n,
    'links_ativos', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'acesso_id', a.id, 'aparelho', a.descricao,
        'criado_em', to_char(a.criado_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'ultimo_uso', to_char(a.ultimo_uso_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'))) order by a.criado_em)
      from public.acessos_mcp a where a.escopo = 'calendario' and a.revogado_em is null), '[]'::jsonb),
    'observacao', 'O link só aparece na hora de gerar. Se ela perdeu o link, revogue o antigo e gere outro.');
end
$$;

revoke all on function public.nome_curto(text) from public, anon, authenticated;
revoke all on function public.calendario_validar_acesso(text) from public, anon, authenticated;
revoke all on function public.calendario_feed(text) from public, anon, authenticated;
revoke all on function public.mcp_acesso_calendario(jsonb, text) from public, anon, authenticated;
grant execute on function public.nome_curto(text) to service_role;
grant execute on function public.calendario_validar_acesso(text) to service_role;
grant execute on function public.calendario_feed(text) to service_role;
grant execute on function public.mcp_acesso_calendario(jsonb, text) to service_role;
