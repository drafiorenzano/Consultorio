-- =====================================================================
-- Site: mais de uma conta.
--
-- A conta da Dra. continua igual: convite sem e-mail é dela (cria ou troca a
-- senha e o código dela). Convite com e-mail cria a conta de outra pessoa
-- (ex.: Guilherme), separada: não mexe na senha nem no código da Dra., e o
-- convite novo de um não cancela o do outro. A conta de outra pessoa pode ser
-- desligada (acesso_ipad revogar com o e-mail). Ajustes mostra quem entra e,
-- nos últimos acessos, quem abriu o quê.
-- =====================================================================

alter table public.acessos_mcp add column if not exists email_convite text
  check (email_convite is null or email_convite ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
comment on column public.acessos_mcp.email_convite is
  'Convite do site para outra pessoa: e-mail da conta que ela cria ou troca. Nulo = conta da Dra.';

alter table public.painel_contas add column if not exists pessoa text;
comment on column public.painel_contas.pessoa is
  'Quem usa a conta quando não é a Dra. (ex.: Guilherme). Nulo = a Dra.';
create unique index if not exists painel_contas_email on public.painel_contas (email);

-- E-mail da conta da Dra.: a conta sem "pessoa" ou, se ainda não existe, o do consultório.
create or replace function public.painel_email_da_dra()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select pc.email from public.painel_contas pc
      where pc.pessoa is null and pc.desativada_em is null order by pc.criada_em limit 1),
    (select lower(btrim(c.email)) from public.configuracao c limit 1))
$$;

create or replace function public.painel_convite(p_token_sha256 text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'acesso_id', a.id,
    'email', e.email,
    'pessoa', case when a.email_convite is not null then a.descricao end,
    'conta_existe', exists (select 1 from public.painel_contas pc
                             where pc.email = e.email and pc.desativada_em is null)))
    from public.acessos_mcp a
    cross join lateral (select coalesce(lower(btrim(a.email_convite)), public.painel_email_da_dra()) as email) e
   where a.token_sha256 = lower(p_token_sha256)
     and a.escopo = 'painel'
     and a.revogado_em is null
     and a.criado_em > now() - interval '7 days'
$$;

create or replace function public.painel_convite_usar(p_token_sha256 text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := public.painel_convite(p_token_sha256);
begin
  if v is null then
    return null;
  end if;
  update public.acessos_mcp
     set revogado_em = now(), ultimo_uso_em = now()
   where id = (v ->> 'acesso_id')::uuid and revogado_em is null;
  if not found then
    return null;
  end if;
  return v || jsonb_strip_nulls(jsonb_build_object(
    'usuario_id', (select pc.usuario_id from public.painel_contas pc
                    where pc.email = v ->> 'email'
                    order by pc.desativada_em nulls first, pc.criada_em desc limit 1)));
end
$$;

create or replace function public.painel_conta_registrar(p_usuario uuid, p_email text)
returns void
language sql
set search_path = ''
as $$
  insert into public.painel_contas (usuario_id, email, pessoa)
  values (p_usuario, lower(btrim(p_email)),
          (select a.descricao from public.acessos_mcp a
            where a.escopo = 'painel' and lower(btrim(a.email_convite)) = lower(btrim(p_email))
              and a.ultimo_uso_em is not null
            order by a.ultimo_uso_em desc limit 1))
  on conflict (usuario_id) do update
    set senha_definida_em = now(), convite_usado_em = now(), desativada_em = null, email = excluded.email,
        pessoa = coalesce(excluded.pessoa, public.painel_contas.pessoa)
$$;

-- Aparelhos conectados de uma conta.
create or replace function public.painel_sessoes_ativas(p_usuario uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from public.painel_contas pc
    join auth.sessions s on s.user_id = pc.usuario_id
   where pc.usuario_id = p_usuario
     and pc.desativada_em is null
     and s.created_at >= pc.senha_definida_em
     and s.created_at > now() - interval '30 days'
$$;

-- Contas ativas, a da Dra. primeiro.
create or replace function public.painel_contas_json()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'pessoa', coalesce(pc.pessoa, 'Dra.'),
           'da_dra', pc.pessoa is null,
           'email', pc.email,
           'senha_definida_em', pc.senha_definida_em,
           'ultimo_acesso', (select max(l.em) from public.painel_log l where l.usuario_id = pc.usuario_id),
           'aparelhos_conectados', public.painel_sessoes_ativas(pc.usuario_id)))
           order by pc.pessoa is not null, pc.criada_em), '[]'::jsonb)
    from public.painel_contas pc
   where pc.desativada_em is null
$$;

create or replace function public.mcp_acesso_ipad(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'listar');
  v_email text := nullif(lower(btrim(p_dados ->> 'email')), '');
  v_pessoa text := nullif(btrim(p_dados ->> 'pessoa'), '');
  v_codigo text;
  v_id uuid;
  v_url text;
  v_n int;
begin
  perform public.iniciar_solicitacao('acesso_ipad', p_dados, p_texto_original);
  if v_acao not in ('gerar', 'listar', 'revogar') then
    raise exception 'Ação "%" desconhecida. Use gerar, listar ou revogar.', p_dados ->> 'acao';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'E-mail "%" não parece válido.', p_dados ->> 'email';
  end if;
  -- o e-mail da própria Dra. é a conta dela
  if v_email = public.painel_email_da_dra() then
    v_email := null;
  end if;

  if v_acao = 'gerar' then
    if v_email is not null and v_pessoa is null then
      raise exception 'Diga de quem é a conta nova (pessoa), por exemplo "Guilherme".';
    end if;
    -- um convite por vez para cada conta: o novo cancela o anterior da mesma conta
    update public.acessos_mcp set revogado_em = now()
     where escopo = 'painel' and revogado_em is null
       and coalesce(lower(btrim(email_convite)), '') = coalesce(v_email, '');
    v_codigo := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    insert into public.acessos_mcp (descricao, token_sha256, escopo, email_convite)
    values (coalesce(v_pessoa, nullif(btrim(p_dados ->> 'aparelho'), ''), 'Convite do site'),
            encode(extensions.digest(v_codigo, 'sha256'), 'hex'), 'painel', v_email)
    returning id into v_id;
    select painel_url into v_url from public.configuracao limit 1;
    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'ok',
      'acesso_id', v_id,
      'conta', case when v_email is null then 'da Dra.' else v_pessoa || ' (' || v_email || '), separada da conta da Dra.' end,
      'link', case when v_url is not null then rtrim(v_url, '/') || '/#acesso=' || v_codigo end,
      'validade', 'Vale por 7 dias e funciona uma vez só.',
      'como_usar', case when v_url is not null
        then 'Abra o link no iPhone, no iPad ou no computador. Ele pede uma senha nova para o site e liga o código de '
             || 'dois fatores no app Senhas do iPhone. Depois, em qualquer aparelho, é só entrar com e-mail, senha e '
             || 'código. No iPad, toque em Compartilhar > Adicionar à Tela de Início para virar um app.'
        else 'O endereço do site ainda não foi configurado (configuracao.painel_url).' end,
      'aviso', case when v_email is null
        then 'Este link cria ou troca a senha do site da Dra.: não encaminhe a ninguém. Se esquecer a senha ou trocar '
             || 'de celular, peça um link novo.'
        else 'Este link cria ou troca a senha da conta de ' || v_pessoa || ' (não mexe na conta da Dra.). Mande só '
             || 'para essa pessoa. Para tirar o acesso dela: acesso_ipad revogar com o e-mail.' end));
  end if;

  if v_acao = 'revogar' then
    if v_email is not null then
      -- desliga a conta de outra pessoa (a da Dra. não sai por aqui)
      update public.acessos_mcp set revogado_em = now()
       where escopo = 'painel' and revogado_em is null and lower(btrim(email_convite)) = v_email;
      update public.painel_contas set desativada_em = now()
       where email = v_email and pessoa is not null and desativada_em is null;
      get diagnostics v_n = row_count;
      if v_n = 0 and not exists (select 1 from public.acessos_mcp
                                  where escopo = 'painel' and lower(btrim(email_convite)) = v_email
                                    and revogado_em > now() - interval '1 minute') then
        raise exception 'Nenhuma conta nem convite do site com o e-mail %.', v_email;
      end if;
    elsif nullif(btrim(p_dados ->> 'acesso_id'), '') is not null then
      update public.acessos_mcp set revogado_em = now()
       where id = (p_dados ->> 'acesso_id')::uuid and escopo = 'painel' and revogado_em is null;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'Nenhum convite ativo com esse id.'; end if;
    elsif coalesce((p_dados ->> 'todos')::boolean, false) then
      update public.acessos_mcp set revogado_em = now() where escopo = 'painel' and revogado_em is null;
      get diagnostics v_n = row_count;
      -- tira o site de todos os aparelhos, de todas as contas: só entra de novo com senha e código
      update public.painel_contas set senha_definida_em = now() where desativada_em is null;
    else
      raise exception 'Diga o que revogar: acesso_id (de listar), email da conta de outra pessoa, ou todos = true '
        'para sair de todos os aparelhos.';
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'revogados', v_n,
    'contas_do_site', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'pessoa', c ->> 'pessoa',
        'email', c ->> 'email',
        'senha_definida_em', to_char((c ->> 'senha_definida_em')::timestamptz at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'ultimo_acesso', to_char((c ->> 'ultimo_acesso')::timestamptz at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'aparelhos_conectados', (c ->> 'aparelhos_conectados')::int)))
      from jsonb_array_elements(public.painel_contas_json()) c),
    'convites_pendentes', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'acesso_id', a.id, 'descricao', a.descricao, 'para', coalesce(a.email_convite, 'conta da Dra.'),
        'criado_em', to_char(a.criado_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'vence_em', to_char((a.criado_em + interval '7 days') at time zone public.fuso(), 'DD/MM/YYYY HH24:MI')))
        order by a.criado_em)
      from public.acessos_mcp a
     where a.escopo = 'painel' and a.revogado_em is null and a.criado_em > now() - interval '7 days'), '[]'::jsonb),
    'nota', case when v_acao = 'revogar' and v_email is not null
                 then 'A conta de ' || v_email || ' foi desligada: não entra mais no site.'
                 when v_acao = 'revogar' and coalesce((p_dados ->> 'todos')::boolean, false)
                 then 'Todos os aparelhos saíram do site; para entrar de novo, e-mail, senha e código.' end));
end
$$;

-- Ajustes: a conta de quem está vendo (a API manda usuario_id), as contas e quem abriu o quê.
-- Substitui painel_configuracoes() (que fica sem uso).
create or replace function public.painel_ajustes(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'consultorio', public.painel_configuracao(),
    'financeiro', (select f - 'cpf_profissional' - 'taxas' - 'observacoes'
                            || jsonb_strip_nulls(jsonb_build_object(
                                 'cpf_profissional', case when f ? 'cpf_profissional'
                                   then '***.' || substr(f ->> 'cpf_profissional', 4, 3) || '.***-**' end))
                     from (select public.fin_config_json() f) z),
    'conta', (select jsonb_strip_nulls(jsonb_build_object(
                       'email', pc.email,
                       'pessoa', pc.pessoa,
                       'senha_definida_em', pc.senha_definida_em,
                       'aparelhos_conectados', public.painel_sessoes_ativas(pc.usuario_id)))
                from public.painel_contas pc
               where pc.desativada_em is null
               order by (pc.usuario_id::text = p_params ->> 'usuario_id') desc, pc.pessoa is not null, pc.criada_em
               limit 1),
    'contas', public.painel_contas_json(),
    'acessos', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'tipo', case a.escopo when 'mcp' then 'Claude (conector)' when 'painel' then 'Convite do site'
                                        when 'calendario' then 'Calendário do iPhone/iPad' else a.escopo end,
                  'descricao', a.descricao,
                  'criado_em', a.criado_em,
                  'ultimo_uso', a.ultimo_uso_em)) order by a.criado_em)
                  from public.acessos_mcp a
                 where a.revogado_em is null
                   and (a.escopo <> 'painel' or a.criado_em > now() - interval '7 days')),
    'ultimos_acessos_site', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                 'em', l.em, 'acao', l.acao, 'quem', coalesce(pc.pessoa, 'Dra.'))) order by l.em desc)
                               from (select * from public.painel_log order by em desc limit 15) l
                               left join public.painel_contas pc on pc.usuario_id = l.usuario_id)))
$$;

create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio() || public.painel_inicio_extra() || public.painel_inicio_afazer()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params) || public.painel_paciente_anexos(p_params)
    when 'financeiro' then public.painel_financeiro(p_params) || public.painel_financeiro_extra(p_params)
    when 'estoque' then public.painel_estoque(p_params) || public.painel_estoque_extra(p_params)
                        || public.painel_estoque_materiais()
    when 'orcamentos' then public.painel_orcamentos(p_params)
    when 'orcamento_novo' then public.painel_orcamento_novo(p_params)
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_ajustes(p_params)
    else null
  end;
end
$$;

revoke execute on function
  public.painel_email_da_dra(), public.painel_convite(text), public.painel_convite_usar(text),
  public.painel_conta_registrar(uuid, text), public.painel_sessoes_ativas(uuid), public.painel_contas_json(),
  public.mcp_acesso_ipad(jsonb, text), public.painel_ajustes(jsonb), public.painel(text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.painel_email_da_dra(), public.painel_convite(text), public.painel_convite_usar(text),
  public.painel_conta_registrar(uuid, text), public.painel_sessoes_ativas(uuid), public.painel_contas_json(),
  public.mcp_acesso_ipad(jsonb, text), public.painel_ajustes(jsonb), public.painel(text, jsonb)
  to service_role;
