-- Ficha online: o paciente preenche cadastro e anamnese antes da consulta.
--
-- Fluxo: a Dra. pede o link (ferramenta ficha_online, ação enviar) e manda
-- pelo WhatsApp. O paciente abre a página (configuracao.ficha_url, com o
-- código depois de "#c="), que fala com a Edge Function "ficha". As respostas
-- ficam guardadas aqui como pendentes; nada muda na ficha até a Dra. revisar
-- (ver_ficha_online) e confirmar (confirmar_ficha_online), que grava pelo
-- mesmo caminho de atualizar_paciente e registrar_anamnese (origem
-- "formulario").
--
-- LGPD: o link é pessoal, guarda só o SHA-256 do código, expira (7 dias por
-- padrão), vale para um envio só e nunca mostra dados já gravados (só o
-- primeiro nome). O paciente aceita o aviso de privacidade antes de enviar.

alter table public.configuracao add column if not exists ficha_url text
  check (ficha_url is null or ficha_url ~ '^https://');
comment on column public.configuracao.ficha_url is
  'Endereço da página pública da ficha online (o link leva o código depois de #c=).';

create table public.fichas_online (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  token_sha256 text not null unique check (token_sha256 ~ '^[0-9a-f]{64}$'),
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  aberto_em timestamptz,
  enviado_em timestamptz,
  respostas jsonb check (respostas is null or jsonb_typeof(respostas) = 'object'),
  termo_versao text,
  situacao text not null default 'aguardando'
    check (situacao in ('aguardando', 'enviada', 'aplicada', 'descartada', 'cancelada')),
  revisado_em timestamptz,
  motivo text,
  resultado jsonb,
  solicitacao_id uuid references public.solicitacoes (id),
  atualizado_em timestamptz not null default now(),
  check (expira_em > criado_em),
  check ((situacao = 'aguardando') or (situacao = 'cancelada') or (respostas is not null and enviado_em is not null))
);
comment on table public.fichas_online is
  'Links da ficha online enviados aos pacientes e as respostas, pendentes até a Dra. revisar.';
create index fichas_online_paciente on public.fichas_online (paciente_id, criado_em desc);
create index fichas_online_situacao on public.fichas_online (situacao) where situacao in ('aguardando', 'enviada');

alter table public.fichas_online enable row level security;
create trigger fichas_online_atualizado_em before update on public.fichas_online
  for each row execute function public.tocar_atualizado_em();
create trigger fichas_online_auditoria after insert or update on public.fichas_online
  for each row execute function public.registrar_auditoria();
create trigger fichas_online_sem_exclusao before delete on public.fichas_online
  for each row execute function public.bloquear_alteracao();

-- Situação para mostrar: "aguardando" vencido vira "expirada".
create or replace function public.ficha_online_situacao(f public.fichas_online)
returns text
language sql
stable
set search_path = ''
as $$
  select case when f.situacao = 'aguardando' and f.expira_em <= now() then 'expirada' else f.situacao end
$$;

-- Versão do aviso de privacidade mostrado na página (a página manda a mesma).
create or replace function public.ficha_online_termo_versao()
returns text
language sql
immutable
set search_path = ''
as $$ select '2026-11-02' $$;

-- Perguntas que só valem para quem pode engravidar (puladas se sexo masculino).
create or replace function public.ficha_online_so_feminino()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['gestacao', 'amamentacao'] $$;

-- O que a página precisa para montar o formulário (sem dado nenhum do paciente).
create or replace function public.ficha_online_definicao()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'consultorio', jsonb_strip_nulls(jsonb_build_object(
      'dentista', cfg.dentista_nome,
      'especialidade', cfg.especialidade,
      'cro', cfg.cro,
      'endereco', concat_ws(', ', cfg.endereco, concat_ws('-', cfg.cidade, cfg.uf)),
      'whatsapp', cfg.whatsapp,
      'email', cfg.email,
      'site', cfg.site)),
    'termo_versao', public.ficha_online_termo_versao(),
    'so_feminino', to_jsonb(public.ficha_online_so_feminino()),
    'perguntas', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'codigo', q.codigo, 'grupo', q.grupo, 'tipo', q.tipo, 'texto', q.texto, 'detalhe', q.detalhe))
        order by q.ordem)
      from public.anamnese_perguntas q where q.ativa and q.tipo in ('sim_nao', 'texto')), '[]'::jsonb))
  from public.configuracao cfg
  limit 1
$$;

-- Página de exemplo (para a Dra. ver o formulário): nada é gravado.
create or replace function public.ficha_online_exemplo()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select public.ficha_online_definicao() || jsonb_build_object('status', 'ok', 'exemplo', true,
    'primeiro_nome', 'Paciente', 'expira_em', to_char(public.hoje() + 7, 'DD/MM/YYYY'))
$$;

-- Abrir o link: devolve só o primeiro nome, a data da próxima consulta e as perguntas.
create or replace function public.ficha_online_abrir(p_token_sha256 text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.fichas_online;
  p public.pacientes;
  cfg public.configuracao;
  v_sit text;
  v_consulta timestamptz;
begin
  select * into f from public.fichas_online where token_sha256 = lower(p_token_sha256);
  if not found then
    return null;
  end if;
  select * into cfg from public.configuracao limit 1;
  v_sit := public.ficha_online_situacao(f);
  if v_sit in ('enviada', 'aplicada', 'descartada') then
    return jsonb_build_object('status', 'enviada',
      'mensagem', 'Esta ficha já foi enviada. Obrigada! Se precisar corrigir algo, avise a ' ||
                  coalesce(cfg.dentista_nome, 'Dra.') || ' pelo WhatsApp.',
      'whatsapp', cfg.whatsapp);
  end if;
  if v_sit in ('expirada', 'cancelada') then
    return jsonb_build_object('status', 'expirada',
      'mensagem', 'Este link expirou. Peça um novo à ' || coalesce(cfg.dentista_nome, 'Dra.') || ' pelo WhatsApp.',
      'whatsapp', cfg.whatsapp);
  end if;

  select * into p from public.pacientes where id = f.paciente_id;
  update public.fichas_online set aberto_em = now() where id = f.id and aberto_em is null;
  select min(c.inicio) into v_consulta from public.consultas c
   where c.paciente_id = p.id and c.status in ('agendada', 'confirmada') and c.inicio > now();

  return public.ficha_online_definicao() || jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'primeiro_nome', split_part(btrim(coalesce(nullif(btrim(p.nome_social), ''), p.nome)), ' ', 1),
    'consulta', case when v_consulta is not null then
      to_char(v_consulta at time zone public.fuso(), 'DD/MM') || ' às ' || public.hora_local(v_consulta) end,
    'expira_em', to_char(f.expira_em at time zone public.fuso(), 'DD/MM/YYYY')));
end
$$;

-- Texto curto e limpo (corta no tamanho máximo).
create or replace function public.ficha_texto(p_valor jsonb, p_max int default 200)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(left(btrim(regexp_replace(
    case when jsonb_typeof(p_valor) in ('string', 'number') then p_valor #>> '{}' end,
    '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')), p_max), '')
$$;

-- Confere e limpa o que veio da página. Erros em linguagem de paciente.
create or replace function public.ficha_online_normalizar(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c jsonb := coalesce(p -> 'cadastro', '{}'::jsonb);
  r jsonb := p -> 'responsavel';
  v_nome text;
  v_nasc date;
  v_idade int;
  v_sexo text;
  v_cpf text;
  v_tel text;
  v_email text;
  v_end jsonb;
  v_emerg jsonb;
  v_resp jsonb;
  v_anam jsonb := '{}'::jsonb;
  q record;
  v_item jsonb;
  v_val text;
  v_faltam text[] := '{}';
  v_por text := coalesce(public.ficha_texto(p -> 'preenchido_por', 20), 'paciente');
begin
  if jsonb_typeof(p) <> 'object' or pg_column_size(p) > 60000 then
    raise exception 'Não consegui ler a ficha. Recarregue a página e tente de novo.';
  end if;
  if coalesce((p #>> '{consentimentos,privacidade}')::boolean, false) is not true
     or coalesce((p #>> '{consentimentos,veracidade}')::boolean, false) is not true then
    raise exception 'Para enviar, marque que leu o aviso de privacidade e que as informações são verdadeiras.';
  end if;
  if v_por not in ('paciente', 'responsavel') then
    v_por := 'paciente';
  end if;

  v_nome := btrim(regexp_replace(coalesce(public.ficha_texto(c -> 'nome', 120), ''), '\s+', ' ', 'g'));
  if length(v_nome) < 5 or position(' ' in v_nome) = 0 then
    raise exception 'Escreva o nome completo do paciente (nome e sobrenome).';
  end if;

  begin
    v_nasc := (c ->> 'data_nascimento')::date;
  exception when others then
    v_nasc := null;
  end;
  if v_nasc is null or v_nasc < date '1900-01-01' or v_nasc > public.hoje() then
    raise exception 'Confira a data de nascimento.';
  end if;
  v_idade := public.idade(v_nasc);

  v_sexo := case c ->> 'sexo' when 'feminino' then 'feminino' when 'masculino' then 'masculino'
                              when 'outro' then 'outro' when 'nao_informado' then 'nao_informado' end;

  v_cpf := public.somente_digitos(c ->> 'cpf');
  if v_cpf is not null and not public.cpf_valido(v_cpf) then
    raise exception 'Confira o CPF do paciente: os números não conferem.';
  end if;

  begin
    v_tel := public.normalizar_telefone(c ->> 'telefone');
  exception when others then
    raise exception 'Confira o telefone: escreva com DDD (ex.: 11 98765-4321).';
  end;

  v_email := nullif(lower(public.ficha_texto(c -> 'email', 120)), '');
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Confira o e-mail.';
  end if;

  v_end := jsonb_strip_nulls(jsonb_build_object(
    'cep', public.somente_digitos(c #>> '{endereco,cep}'),
    'logradouro', public.ficha_texto(c #> '{endereco,logradouro}', 150),
    'numero', public.ficha_texto(c #> '{endereco,numero}', 20),
    'complemento', public.ficha_texto(c #> '{endereco,complemento}', 80),
    'bairro', public.ficha_texto(c #> '{endereco,bairro}', 80),
    'cidade', public.ficha_texto(c #> '{endereco,cidade}', 80),
    'uf', upper(public.ficha_texto(c #> '{endereco,uf}', 2))));
  if v_end ? 'cep' and length(v_end ->> 'cep') <> 8 then
    raise exception 'Confira o CEP (8 números).';
  end if;

  v_emerg := jsonb_strip_nulls(jsonb_build_object(
    'nome', public.ficha_texto(c #> '{contato_emergencia,nome}', 120),
    'parentesco', public.ficha_texto(c #> '{contato_emergencia,parentesco}', 40),
    'telefone', public.somente_digitos(c #>> '{contato_emergencia,telefone}')));
  if v_emerg ? 'telefone' then
    begin
      v_emerg := v_emerg || jsonb_build_object('telefone', public.normalizar_telefone(v_emerg ->> 'telefone'));
    exception when others then
      raise exception 'Confira o telefone do contato de emergência (com DDD).';
    end;
  end if;

  if r is not null and jsonb_typeof(r) = 'object' and public.ficha_texto(r -> 'nome', 120) is not null then
    v_resp := jsonb_strip_nulls(jsonb_build_object(
      'nome', btrim(regexp_replace(public.ficha_texto(r -> 'nome', 120), '\s+', ' ', 'g')),
      'cpf', public.somente_digitos(r ->> 'cpf'),
      'parentesco', public.ficha_texto(r -> 'parentesco', 40),
      'telefone', public.somente_digitos(r ->> 'telefone')));
    if length(v_resp ->> 'nome') < 5 or position(' ' in (v_resp ->> 'nome')) = 0 then
      raise exception 'Escreva o nome completo do responsável.';
    end if;
    if v_resp ? 'cpf' and not public.cpf_valido(v_resp ->> 'cpf') then
      raise exception 'Confira o CPF do responsável: os números não conferem.';
    end if;
    if v_resp ? 'telefone' then
      begin
        v_resp := v_resp || jsonb_build_object('telefone', public.normalizar_telefone(v_resp ->> 'telefone'));
      exception when others then
        raise exception 'Confira o telefone do responsável (com DDD).';
      end;
    end if;
  end if;

  if v_idade < 18 and (v_resp is null or not v_resp ? 'cpf') then
    raise exception 'Paciente menor de idade: preencha os dados do responsável, com CPF.';
  end if;
  if v_idade >= 18 and v_cpf is null then
    raise exception 'Preencha o CPF do paciente (vai no recibo de saúde para o Imposto de Renda).';
  end if;
  if v_tel is null and (v_resp is null or not v_resp ? 'telefone') then
    raise exception 'Preencha um telefone com DDD.';
  end if;

  for q in select * from public.anamnese_perguntas where ativa and tipo in ('sim_nao', 'texto') order by ordem loop
    v_item := p -> 'anamnese' -> q.codigo;
    if q.tipo = 'sim_nao' then
      v_val := v_item ->> 'resposta';
      if v_val is null and v_sexo = 'masculino' and q.codigo = any (public.ficha_online_so_feminino()) then
        continue;
      end if;
      if v_val is null or v_val not in ('sim', 'nao', 'nao_sabe') then
        v_faltam := array_append(v_faltam, q.texto);
        continue;
      end if;
      v_anam := v_anam || jsonb_build_object(q.codigo, jsonb_strip_nulls(jsonb_build_object(
        'resposta', v_val,
        'detalhe', case when v_val <> 'nao' then public.ficha_texto(v_item -> 'detalhe', 300) end)));
    else
      v_val := public.ficha_texto(v_item -> 'resposta', 600);
      if v_val is null and q.codigo = 'queixa_principal' then
        raise exception 'Conte o motivo da consulta (pode ser "revisão" ou "avaliação").';
      end if;
      if v_val is not null then
        v_anam := v_anam || jsonb_build_object(q.codigo, jsonb_build_object('resposta', v_val));
      end if;
    end if;
  end loop;
  if cardinality(v_faltam) > 0 then
    raise exception 'Faltou responder: %.', array_to_string(v_faltam[1:3], '; ') ||
      case when cardinality(v_faltam) > 3 then format(' e mais %s', cardinality(v_faltam) - 3) else '' end;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'preenchido_por', v_por,
    'cadastro', jsonb_strip_nulls(jsonb_build_object(
      'nome', v_nome,
      'nome_social', public.ficha_texto(c -> 'nome_social', 120),
      'data_nascimento', v_nasc,
      'sexo', v_sexo,
      'cpf', v_cpf,
      'rg', public.ficha_texto(c -> 'rg', 20),
      'telefone', v_tel,
      'whatsapp', coalesce((c ->> 'whatsapp')::boolean, true),
      'email', v_email,
      'profissao', public.ficha_texto(c -> 'profissao', 80),
      'estado_civil', public.ficha_texto(c -> 'estado_civil', 30),
      'endereco', nullif(v_end, '{}'::jsonb),
      'contato_emergencia', nullif(v_emerg, '{}'::jsonb),
      'origem', public.ficha_texto(c -> 'origem', 80))),
    'responsavel', v_resp,
    'anamnese', v_anam,
    'observacoes', public.ficha_texto(p -> 'observacoes', 2000)));
end
$$;

-- Enviar: guarda as respostas como pendentes. Vale uma vez só.
create or replace function public.ficha_online_enviar(p_token_sha256 text, p_respostas jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.fichas_online;
  cfg public.configuracao;
  v_limpo jsonb;
  v_sit text;
begin
  select * into f from public.fichas_online where token_sha256 = lower(p_token_sha256) for update;
  if not found then
    return null;
  end if;
  select * into cfg from public.configuracao limit 1;
  v_sit := public.ficha_online_situacao(f);
  if v_sit <> 'aguardando' then
    raise exception '%', case when v_sit in ('expirada', 'cancelada')
      then 'Este link expirou. Peça um novo à ' || coalesce(cfg.dentista_nome, 'Dra.') || ' pelo WhatsApp.'
      else 'Esta ficha já foi enviada. Se precisar corrigir algo, avise pelo WhatsApp.' end;
  end if;
  if coalesce(p_respostas ->> 'termo_versao', '') <> public.ficha_online_termo_versao() then
    raise exception 'A página está desatualizada. Recarregue e envie de novo (o que já preencheu continua lá).';
  end if;

  v_limpo := public.ficha_online_normalizar(p_respostas);
  perform public.iniciar_solicitacao('ficha_online_enviar',
    jsonb_build_object('ficha_online_id', f.id, 'paciente_id', f.paciente_id), null, 'paciente');

  update public.fichas_online
     set respostas = v_limpo,
         enviado_em = now(),
         aberto_em = coalesce(aberto_em, now()),
         termo_versao = public.ficha_online_termo_versao(),
         situacao = 'enviada'
   where id = f.id;

  return jsonb_build_object('status', 'ok',
    'mensagem', 'Pronto! Sua ficha foi enviada para a ' || coalesce(cfg.dentista_nome, 'Dra.') ||
                '. Ela vai revisar antes da consulta. Obrigada!');
end
$$;

-- Ficha online mais recente que interessa (por id, ou do paciente).
create or replace function public.ficha_online_localizar(p_dados jsonb, p_situacoes text[])
returns public.fichas_online
language plpgsql
stable
set search_path = ''
as $$
declare
  f public.fichas_online;
  v_pac public.pacientes;
begin
  if nullif(btrim(p_dados ->> 'ficha_online_id'), '') is not null then
    select * into f from public.fichas_online where id = (p_dados ->> 'ficha_online_id')::uuid;
    if not found then
      raise exception 'Ficha online não encontrada. Use ficha_online (listar) para ver as pendentes.';
    end if;
    return f;
  end if;
  if nullif(btrim(p_dados ->> 'paciente_id'), '') is null then
    raise exception 'Diga de qual paciente (paciente_id) ou qual ficha online (ficha_online_id).';
  end if;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  select * into f from public.fichas_online
   where paciente_id = v_pac.id and situacao = any (p_situacoes)
   order by coalesce(enviado_em, criado_em) desc limit 1;
  if not found then
    raise exception 'O paciente % não tem ficha online %.', v_pac.nome,
      case when p_situacoes = array['enviada'] then 'enviada esperando revisão' else 'nessa situação' end;
  end if;
  return f;
end
$$;

create or replace function public.ficha_online_resumo(f public.fichas_online)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'ficha_online_id', f.id,
    'paciente', jsonb_build_object('id', p.id, 'nome', p.nome, 'ficha', p.ficha),
    'situacao', public.ficha_online_situacao(f),
    'enviado_link_em', to_char(f.criado_em at time zone public.fuso(), 'DD/MM HH24:MI'),
    'aberto_em', to_char(f.aberto_em at time zone public.fuso(), 'DD/MM HH24:MI'),
    'respondido_em', to_char(f.enviado_em at time zone public.fuso(), 'DD/MM HH24:MI'),
    'expira_em', case when f.situacao = 'aguardando' then to_char(f.expira_em at time zone public.fuso(), 'DD/MM HH24:MI') end,
    'revisado_em', to_char(f.revisado_em at time zone public.fuso(), 'DD/MM HH24:MI')))
  from public.pacientes p where p.id = f.paciente_id
$$;

-- Ferramenta ficha_online: enviar (gera o link), listar e cancelar.
create or replace function public.mcp_ficha_online(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'listar');
  cfg public.configuracao;
  v_pac public.pacientes;
  v_dias int;
  v_codigo text;
  v_link text;
  v_id uuid;
  v_expira timestamptz;
  v_consulta timestamptz;
  v_msg text;
  v_tel text;
  v_n int;
  f public.fichas_online;
begin
  perform public.iniciar_solicitacao('ficha_online', p_dados, p_texto_original);
  if v_acao = 'gerar' then v_acao := 'enviar'; end if;
  if v_acao not in ('enviar', 'listar', 'cancelar') then
    raise exception 'Ação "%" desconhecida. Use enviar, listar ou cancelar.', p_dados ->> 'acao';
  end if;
  select * into cfg from public.configuracao limit 1;

  if v_acao = 'enviar' then
    if cfg.ficha_url is null then
      raise exception 'A página da ficha online ainda não está publicada, então ainda não dá para gerar o link.';
    end if;
    v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
    v_dias := coalesce((p_dados ->> 'dias_validade')::int, 7);
    if v_dias not between 1 and 30 then
      raise exception 'Validade do link entre 1 e 30 dias.';
    end if;
    update public.fichas_online set situacao = 'cancelada', motivo = 'Substituída por um link novo.'
     where paciente_id = v_pac.id and situacao = 'aguardando';
    get diagnostics v_n = row_count;

    v_codigo := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    v_expira := (public.hoje() + v_dias + 1)::timestamp at time zone public.fuso();
    insert into public.fichas_online (paciente_id, token_sha256, expira_em, solicitacao_id)
    values (v_pac.id, encode(extensions.digest(v_codigo, 'sha256'), 'hex'), v_expira,
            nullif(current_setting('app.solicitacao_id', true), '')::uuid)
    returning id into v_id;
    v_link := rtrim(cfg.ficha_url, '/') || '/#c=' || v_codigo;

    select min(c.inicio) into v_consulta from public.consultas c
     where c.paciente_id = v_pac.id and c.status in ('agendada', 'confirmada') and c.inicio > now();
    v_msg := format('Olá, %s! Aqui é da %s. Para agilizar sua consulta%s, preencha sua ficha antes por este link ' ||
                    '(leva uns 5 minutos): %s' || E'\n' || 'O link é pessoal e vale até %s.',
      coalesce(nullif(btrim(v_pac.apelido), ''), split_part(coalesce(nullif(btrim(v_pac.nome_social), ''), v_pac.nome), ' ', 1)),
      coalesce(cfg.dentista_nome, 'Dra. Andressa'),
      case when v_consulta is not null then
        format(' de %s às %s', to_char(v_consulta at time zone public.fuso(), 'DD/MM'), public.hora_local(v_consulta)) else '' end,
      v_link,
      to_char(v_expira at time zone public.fuso() - interval '1 minute', 'DD/MM'));
    v_tel := public.telefone_contato(v_pac.id);

    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'ok',
      'ficha_online_id', v_id,
      'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
      'link', v_link,
      'mensagem_whatsapp', v_msg,
      'link_whatsapp', case when v_tel is not null then
        'https://wa.me/' || case when length(v_tel) in (10, 11) then '55' || v_tel else v_tel end ||
        '?text=' || public.urlencode(v_msg) end,
      'vale_ate', to_char(v_expira at time zone public.fuso() - interval '1 minute', 'DD/MM/YYYY'),
      'links_anteriores_cancelados', nullif(v_n, 0),
      'como_usar', 'Mostre o link_whatsapp para ela tocar e enviar (abre o WhatsApp com a mensagem pronta). ' ||
                   'Quando o paciente enviar, use ver_ficha_online para revisar e confirmar_ficha_online para gravar.',
      'avisos', case when v_tel is null then jsonb_build_array(
        'O paciente não tem telefone na ficha: copie a mensagem e envie por onde ela falar com ele.') end));
  end if;

  if v_acao = 'cancelar' then
    f := public.ficha_online_localizar(p_dados, array['aguardando']);
    update public.fichas_online set situacao = 'cancelada',
           motivo = coalesce(nullif(btrim(p_dados ->> 'motivo'), ''), 'Cancelada pela Dra.')
     where id = f.id and situacao = 'aguardando';
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'Esse link não está mais aguardando resposta (já foi respondido, cancelado ou expirou).';
    end if;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'cancelados', v_n,
    'para_revisar', coalesce((select jsonb_agg(public.ficha_online_resumo(f2) order by f2.enviado_em)
      from public.fichas_online f2 where f2.situacao = 'enviada'), '[]'::jsonb),
    'aguardando_paciente', coalesce((select jsonb_agg(public.ficha_online_resumo(f2) order by f2.criado_em)
      from public.fichas_online f2 where f2.situacao = 'aguardando' and f2.expira_em > now()), '[]'::jsonb),
    'recentes', coalesce((select jsonb_agg(public.ficha_online_resumo(x) order by x.atualizado_em desc)
      from (select * from public.fichas_online f2
             where f2.situacao in ('aplicada', 'descartada', 'cancelada')
                or (f2.situacao = 'aguardando' and f2.expira_em <= now())
             order by f2.atualizado_em desc limit 5) x), '[]'::jsonb));
end
$$;

-- O que o paciente respondeu, lado a lado com o que já está na ficha.
create or replace function public.ficha_online_comparacao(f public.fichas_online)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  p public.pacientes;
  c jsonb := f.respostas -> 'cadastro';
  v_atual jsonb;
  v_campos jsonb := '[]'::jsonb;
  k text;
  v_novo jsonb;
  v_velho jsonb;
  v_sim jsonb;
  v_nao_sabe jsonb;
  v_textos jsonb;
  v_ultima public.anamneses;
  v_avisos text[] := '{}';
  v_outro text;
begin
  select * into p from public.pacientes where id = f.paciente_id;
  v_atual := to_jsonb(p);
  foreach k in array array['nome', 'nome_social', 'data_nascimento', 'sexo', 'cpf', 'rg', 'telefone', 'whatsapp',
                           'email', 'profissao', 'estado_civil', 'endereco', 'contato_emergencia', 'origem'] loop
    v_novo := c -> k;
    v_velho := v_atual -> k;
    if v_novo is null then continue; end if;
    if jsonb_typeof(v_novo) = 'object' and jsonb_typeof(v_velho) = 'object' then
      if v_velho @> v_novo then continue; end if;
    elsif v_novo = coalesce(v_velho, 'null'::jsonb) then
      continue;
    end if;
    v_campos := v_campos || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'campo', k, 'na_ficha', v_velho, 'paciente_escreveu', v_novo)));
  end loop;

  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('pergunta', q.texto, 'detalhe', a.value ->> 'detalhe'))
                  order by q.ordem), '[]'::jsonb) into v_sim
    from jsonb_each(f.respostas -> 'anamnese') a
    join public.anamnese_perguntas q on q.codigo = a.key
   where a.value ->> 'resposta' = 'sim';
  select coalesce(jsonb_agg(q.texto order by q.ordem), '[]'::jsonb) into v_nao_sabe
    from jsonb_each(f.respostas -> 'anamnese') a
    join public.anamnese_perguntas q on q.codigo = a.key
   where a.value ->> 'resposta' = 'nao_sabe';
  select coalesce(jsonb_agg(jsonb_build_object('pergunta', q.texto, 'resposta', a.value ->> 'resposta')
                  order by q.ordem), '[]'::jsonb) into v_textos
    from jsonb_each(f.respostas -> 'anamnese') a
    join public.anamnese_perguntas q on q.codigo = a.key
   where q.tipo = 'texto';

  if c ? 'cpf' then
    select nome || ' (ficha ' || ficha || ')' into v_outro
      from public.pacientes where cpf = c ->> 'cpf' and id <> p.id;
    if v_outro is not null then
      v_avisos := array_append(v_avisos, format('O CPF informado já está na ficha de %s. Confira antes de confirmar; ' ||
        'para gravar sem o CPF, use ignorar ["cpf"].', v_outro));
    end if;
  end if;
  if c ? 'nome' and extensions.similarity(public.normalizar(c ->> 'nome'), public.normalizar(p.nome)) < 0.4 then
    v_avisos := array_append(v_avisos, format('O nome escrito (%s) é bem diferente do da ficha (%s). Confira se é a pessoa certa.',
      c ->> 'nome', p.nome));
  end if;
  select * into v_ultima from public.anamneses where paciente_id = p.id order by versao desc limit 1;
  if found then
    v_avisos := array_append(v_avisos, format('O paciente já tinha anamnese (versão %s, %s). As respostas novas viram a versão %s; ' ||
      'as que não mudaram ficam iguais.', v_ultima.versao, to_char(v_ultima.registrado_em at time zone public.fuso(), 'DD/MM/YYYY'),
      v_ultima.versao + 1));
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'resumo', public.ficha_online_resumo(f),
    'preenchido_por', f.respostas ->> 'preenchido_por',
    'cadastro_muda', v_campos,
    'responsavel', f.respostas -> 'responsavel',
    'anamnese_sim', v_sim,
    'anamnese_nao_sabe', nullif(v_nao_sabe, '[]'::jsonb),
    'anamnese_nao', (select count(*) from jsonb_each(f.respostas -> 'anamnese') a where a.value ->> 'resposta' = 'nao'),
    'respostas_abertas', v_textos,
    'observacoes_do_paciente', f.respostas ->> 'observacoes',
    'alertas_que_vao_entrar', (select jsonb_agg(x) from jsonb_array_elements(
        public.anamnese_alertas(f.respostas -> 'anamnese')) x
      where not exists (select 1 from jsonb_array_elements(p.alertas_saude) a
                         where public.normalizar(a ->> 'descricao') = public.normalizar(x ->> 'descricao'))),
    'avisos', nullif(to_jsonb(v_avisos), '[]'::jsonb)));
end
$$;

-- Ferramenta ver_ficha_online: o que o paciente respondeu x o que já está na ficha.
create or replace function public.mcp_ver_ficha_online(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.fichas_online;
begin
  perform public.iniciar_solicitacao('ver_ficha_online', p_dados, p_texto_original);
  if nullif(btrim(p_dados ->> 'ficha_online_id'), '') is null and nullif(btrim(p_dados ->> 'paciente_id'), '') is null then
    return jsonb_build_object('status', 'ok',
      'para_revisar', coalesce((select jsonb_agg(public.ficha_online_resumo(f2) order by f2.enviado_em)
        from public.fichas_online f2 where f2.situacao = 'enviada'), '[]'::jsonb),
      'mensagem', 'Escolha uma (ficha_online_id) para ver as respostas.');
  end if;
  f := public.ficha_online_localizar(p_dados, array['enviada', 'aplicada', 'descartada']);
  return jsonb_build_object('status', 'ok') || public.ficha_online_comparacao(f) || jsonb_build_object(
    'proximo_passo', case when f.situacao = 'enviada' then
      'Mostre à Dra. o que muda no cadastro e as respostas "sim" da anamnese. Se ela concordar, use ' ||
      'confirmar_ficha_online (aplicar); para deixar algum campo de fora, passe em ignorar (ex.: ["cpf"] ou ' ||
      '["anamnese"]). Se não for para usar, confirmar_ficha_online com acao descartar.'
      else 'Esta ficha já foi revisada.' end);
end
$$;

-- Ferramenta confirmar_ficha_online: grava na ficha (aplicar) ou descarta.
create or replace function public.mcp_confirmar_ficha_online(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'aplicar');
  f public.fichas_online;
  v_ign text[];
  v_validos text[] := array['nome', 'nome_social', 'data_nascimento', 'sexo', 'cpf', 'rg', 'telefone', 'whatsapp',
                            'email', 'profissao', 'estado_civil', 'endereco', 'contato_emergencia', 'origem',
                            'responsavel', 'anamnese'];
  k text;
  v_dados jsonb;
  v_r1 jsonb;
  v_r2 jsonb;
  v_arr jsonb;
  v_obs text;
  v_avisos jsonb := '[]'::jsonb;
  v_quem text;
begin
  perform public.iniciar_solicitacao('confirmar_ficha_online', p_dados, p_texto_original);
  if v_acao not in ('aplicar', 'descartar') then
    raise exception 'Ação "%" desconhecida. Use aplicar ou descartar.', p_dados ->> 'acao';
  end if;
  f := public.ficha_online_localizar(p_dados, array['enviada']);
  select * into f from public.fichas_online where id = f.id for update;
  if f.situacao <> 'enviada' then
    raise exception 'Esta ficha online já foi %.', case f.situacao when 'aplicada' then 'gravada na ficha'
      when 'descartada' then 'descartada' else 'cancelada ou ainda não foi respondida' end;
  end if;

  if v_acao = 'descartar' then
    update public.fichas_online set situacao = 'descartada', revisado_em = now(),
           motivo = coalesce(nullif(btrim(p_dados ->> 'motivo'), ''), 'Descartada pela Dra.')
     where id = f.id;
    return jsonb_build_object('status', 'ok', 'mensagem', 'Respostas descartadas; a ficha do paciente não mudou.',
      'ficha_online', public.ficha_online_resumo((select x from public.fichas_online x where x.id = f.id)));
  end if;

  v_ign := coalesce(array(select jsonb_array_elements_text(coalesce(p_dados -> 'ignorar', '[]'::jsonb))), '{}');
  foreach k in array v_ign loop
    if not k = any (v_validos) then
      raise exception 'Não sei ignorar "%". Use: %.', k, array_to_string(v_validos, ', ');
    end if;
  end loop;

  -- Cadastro (pelo mesmo caminho de atualizar_paciente)
  v_dados := (f.respostas -> 'cadastro') - v_ign;
  if not 'responsavel' = any (v_ign) and f.respostas ? 'responsavel' then
    v_dados := v_dados || jsonb_build_object('responsavel', f.respostas -> 'responsavel');
  end if;
  v_dados := v_dados || jsonb_build_object('consentimento_lgpd', true);
  v_r1 := public.mcp_atualizar_paciente(f.paciente_id, v_dados, p_texto_original);
  v_avisos := v_avisos || coalesce(v_r1 -> 'avisos', '[]'::jsonb);

  -- Anamnese (nova versão, origem formulário)
  if not 'anamnese' = any (v_ign) then
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'pergunta', a.key, 'resposta', a.value ->> 'resposta', 'detalhe', a.value ->> 'detalhe')))
      into v_arr
      from jsonb_each(f.respostas -> 'anamnese') a;
    v_quem := case f.respostas ->> 'preenchido_por' when 'responsavel' then 'pelo responsável' else 'pelo paciente' end;
    v_obs := concat_ws(E'\n',
      format('Preenchida online %s em %s (aceitou o aviso de privacidade e declarou que as informações são verdadeiras).',
             v_quem, to_char(f.enviado_em at time zone public.fuso(), 'DD/MM/YYYY "às" HH24:MI')),
      case when f.respostas ? 'observacoes' then 'Paciente acrescentou: ' || (f.respostas ->> 'observacoes') end);
    begin
      v_r2 := public.mcp_registrar_anamnese(jsonb_build_object(
        'paciente_id', f.paciente_id, 'respostas', coalesce(v_arr, '[]'::jsonb),
        'origem', 'formulario', 'observacoes', v_obs), p_texto_original);
      v_avisos := v_avisos || coalesce(v_r2 -> 'avisos', '[]'::jsonb);
    exception when raise_exception then
      if sqlerrm like 'Nada novo%' then
        v_avisos := v_avisos || jsonb_build_array('A anamnese já estava com essas respostas; nada mudou nela.');
      else
        raise;
      end if;
    end;
  end if;

  update public.fichas_online
     set situacao = 'aplicada', revisado_em = now(),
         motivo = case when cardinality(v_ign) > 0 then 'Ignorados: ' || array_to_string(v_ign, ', ') end,
         resultado = jsonb_strip_nulls(jsonb_build_object(
           'cadastro_alterado', v_r1 -> 'alterados', 'anamnese_versao', v_r2 -> 'versao'))
   where id = f.id;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', f.paciente_id,
      'nome', (select nome from public.pacientes where id = f.paciente_id),
      'ficha', (select ficha from public.pacientes where id = f.paciente_id)),
    'cadastro_alterado', v_r1 -> 'alterados',
    'anamnese_versao', v_r2 -> 'versao',
    'anamnese_alteradas', jsonb_array_length(coalesce(v_r2 -> 'alteradas', '[]'::jsonb)),
    'alertas_saude', (select alertas_saude from public.pacientes where id = f.paciente_id),
    'ignorados', nullif(to_jsonb(v_ign), '[]'::jsonb),
    'avisos', nullif(v_avisos, '[]'::jsonb)));
end
$$;

revoke all on table public.fichas_online from anon, authenticated;
revoke execute on function
  public.ficha_online_situacao(public.fichas_online), public.ficha_online_termo_versao(),
  public.ficha_online_so_feminino(), public.ficha_online_definicao(), public.ficha_online_exemplo(),
  public.ficha_online_abrir(text), public.ficha_texto(jsonb, int), public.ficha_online_normalizar(jsonb),
  public.ficha_online_enviar(text, jsonb), public.ficha_online_localizar(jsonb, text[]),
  public.ficha_online_resumo(public.fichas_online), public.ficha_online_comparacao(public.fichas_online),
  public.mcp_ficha_online(jsonb, text), public.mcp_ver_ficha_online(jsonb, text),
  public.mcp_confirmar_ficha_online(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.ficha_online_situacao(public.fichas_online), public.ficha_online_termo_versao(),
  public.ficha_online_so_feminino(), public.ficha_online_definicao(), public.ficha_online_exemplo(),
  public.ficha_online_abrir(text), public.ficha_texto(jsonb, int), public.ficha_online_normalizar(jsonb),
  public.ficha_online_enviar(text, jsonb), public.ficha_online_localizar(jsonb, text[]),
  public.ficha_online_resumo(public.fichas_online), public.ficha_online_comparacao(public.fichas_online),
  public.mcp_ficha_online(jsonb, text), public.mcp_ver_ficha_online(jsonb, text),
  public.mcp_confirmar_ficha_online(jsonb, text)
  to service_role;
