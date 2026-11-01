-- Acesso ao servidor MCP na prova de conceito: URL com um token secreto.
--
-- O conector do Claude chama https://<projeto>.supabase.co/functions/v1/mcp/<token>.
-- Aqui fica só o SHA-256 do token (nunca o token). Para revogar, preencha
-- revogado_em; para criar outro, insira um novo hash.
-- Na etapa com dados reais, este acesso dá lugar ao login OAuth do Supabase.

create table public.acessos_mcp (
  id uuid primary key default gen_random_uuid(),
  descricao text not null,
  token_sha256 text not null unique check (token_sha256 ~ '^[0-9a-f]{64}$'),
  criado_em timestamptz not null default now(),
  revogado_em timestamptz,
  ultimo_uso_em timestamptz
);
comment on table public.acessos_mcp is 'Tokens de acesso ao conector MCP (só o hash SHA-256).';

alter table public.acessos_mcp enable row level security;
revoke all on table public.acessos_mcp from anon, authenticated;

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
     and revogado_em is null;
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

revoke execute on function public.mcp_validar_acesso(text) from public, anon, authenticated;
grant execute on function public.mcp_validar_acesso(text) to service_role;
