-- =====================================================================
-- Site do consultório: o código de dois fatores só vale se foi cadastrado
-- junto com o convite.
--
-- Sem isto, quem descobrisse a senha do site de uma conta sem código
-- cadastrado poderia cadastrar o próprio código. Agora a sessão do site só
-- vale com o segundo fator (aal2) feito com um código cadastrado até 24 horas
-- depois de usar o convite. Passou disso, só com um convite novo (que troca
-- a senha e apaga os códigos antigos).
-- =====================================================================

alter table public.painel_contas add column convite_usado_em timestamptz not null default now();
comment on column public.painel_contas.convite_usado_em is
  'Quando o último convite foi usado (senha criada ou trocada). O código de dois fatores precisa ser cadastrado até 24 h depois.';

create or replace function public.painel_conta_registrar(p_usuario uuid, p_email text)
returns void
language sql
set search_path = ''
as $$
  insert into public.painel_contas (usuario_id, email)
  values (p_usuario, lower(btrim(p_email)))
  on conflict (usuario_id) do update
    set senha_definida_em = now(), convite_usado_em = now(), desativada_em = null, email = excluded.email
$$;

-- Confere a sessão do site e registra o acesso. Vale se a conta está ativa,
-- a sessão existe, foi aberta depois da última senha, tem até 30 dias e
-- passou pelo código de dois fatores cadastrado junto com o convite.
create or replace function public.painel_autorizar(
  p_usuario uuid, p_sessao uuid, p_acao text, p_paciente uuid default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
      from public.painel_contas pc
      join auth.sessions s on s.user_id = pc.usuario_id
      join auth.mfa_factors f on f.id = s.factor_id and f.user_id = pc.usuario_id
     where pc.usuario_id = p_usuario
       and pc.desativada_em is null
       and s.id = p_sessao
       and s.aal = 'aal2'
       and s.created_at >= pc.senha_definida_em
       and s.created_at > now() - interval '30 days'
       and (s.not_after is null or s.not_after > now())
       and f.status = 'verified'
       and f.created_at >= pc.convite_usado_em - interval '1 minute'
       and f.created_at <= pc.convite_usado_em + interval '1 day') then
    return false;
  end if;
  insert into public.painel_log (usuario_id, acao, paciente_id) values (p_usuario, p_acao, p_paciente);
  return true;
end
$$;

revoke execute on function
  public.painel_conta_registrar(uuid, text), public.painel_autorizar(uuid, uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function
  public.painel_conta_registrar(uuid, text), public.painel_autorizar(uuid, uuid, text, uuid)
  to service_role;
