-- Acesso do iPad pelo próprio Claude: "me manda o link do iPad", "tira o
-- acesso do iPad antigo". O código só aparece na resposta; aqui fica o hash.

alter table public.configuracao add column if not exists painel_url text;
comment on column public.configuracao.painel_url is 'Endereço do app do iPad (ex.: GitHub Pages), usado no link de acesso.';

create or replace function public.mcp_acesso_ipad(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'listar');
  v_codigo text;
  v_id uuid;
  v_url text;
  v_n int;
begin
  perform public.iniciar_solicitacao('acesso_ipad', p_dados, p_texto_original);
  if v_acao not in ('gerar', 'listar', 'revogar') then
    raise exception 'Ação "%" desconhecida. Use gerar, listar ou revogar.', p_dados ->> 'acao';
  end if;

  if v_acao = 'gerar' then
    v_codigo := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    insert into public.acessos_mcp (descricao, token_sha256, escopo)
    values (coalesce(nullif(btrim(p_dados ->> 'aparelho'), ''), 'iPad'),
            encode(extensions.digest(v_codigo, 'sha256'), 'hex'), 'painel')
    returning id into v_id;
    select painel_url into v_url from public.configuracao limit 1;
    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'ok',
      'acesso_id', v_id,
      'link', case when v_url is not null then rtrim(v_url, '/') || '/#acesso=' || v_codigo end,
      'codigo', v_codigo,
      'como_usar', case when v_url is not null
        then 'Abra o link no Safari do iPad e depois toque em Compartilhar > Adicionar à Tela de Início. Se o app pedir o código, cole o código.'
        else 'O endereço do app ainda não foi configurado: abra o app do iPad e cole o código.' end,
      'aviso', 'Quem tiver este link vê a agenda e as fichas. Não compartilhe; se perder o aparelho, peça para revogar.'));
  end if;

  if v_acao = 'revogar' then
    if nullif(btrim(p_dados ->> 'acesso_id'), '') is not null then
      update public.acessos_mcp set revogado_em = now()
       where id = (p_dados ->> 'acesso_id')::uuid and escopo = 'painel' and revogado_em is null;
    elsif coalesce((p_dados ->> 'todos')::boolean, false) then
      update public.acessos_mcp set revogado_em = now() where escopo = 'painel' and revogado_em is null;
    else
      raise exception 'Diga qual acesso revogar (acesso_id, de listar) ou todos = true.';
    end if;
    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'Nenhum acesso ativo com esse id.'; end if;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'revogados', v_n,
    'acessos_ativos', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'acesso_id', a.id, 'aparelho', a.descricao,
        'criado_em', to_char(a.criado_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'ultimo_uso', to_char(a.ultimo_uso_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'))) order by a.criado_em)
      from public.acessos_mcp a where a.escopo = 'painel' and a.revogado_em is null), '[]'::jsonb));
end
$$;

revoke execute on function public.mcp_acesso_ipad(jsonb, text) from public, anon, authenticated;
grant execute on function public.mcp_acesso_ipad(jsonb, text) to service_role;
