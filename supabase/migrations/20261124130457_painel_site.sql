-- =====================================================================
-- Site do consultório (evolução do app do iPad).
--
-- 1. Login: conta da Dra. no Supabase Auth, com senha e código de dois
--    fatores (TOTP). A conta só nasce (ou troca de senha) por um convite de
--    uso único que o Claude dela gera (acesso_ipad, escopo "painel").
-- 2. Registro de acesso: cada leitura do site vira uma linha em painel_log.
-- 3. Leituras novas: orçamentos, documentos, preços, atividade do Claude,
--    consumo semanal do estoque, financeiro de 12 meses e ajustes.
--
-- Tudo aqui é leitura, menos o convite/conta e o registro de acesso.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Contas do site e registro de acesso
-- ---------------------------------------------------------------------
create table public.painel_contas (
  usuario_id uuid primary key,                         -- auth.users.id
  email text not null,
  criada_em timestamptz not null default now(),
  senha_definida_em timestamptz not null default now(), -- sessões anteriores deixam de valer
  desativada_em timestamptz
);
comment on table public.painel_contas is
  'Quem entra no site do consultório (usuário do Supabase Auth). Conta nova ou senha nova só pelo convite do Claude (acesso_ipad).';
comment on column public.painel_contas.senha_definida_em is
  'Sessões do site abertas antes disto não valem mais (senha nova ou "tirar o acesso de todos os aparelhos").';
alter table public.painel_contas enable row level security;
revoke all on table public.painel_contas from anon, authenticated;

create table public.painel_log (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),
  usuario_id uuid,
  acao text not null,
  paciente_id uuid
);
comment on table public.painel_log is
  'Registro de acesso do site: quem abriu o quê e quando (prontuário eletrônico). Só inclusão.';
create index painel_log_em_idx on public.painel_log (em desc);
create index painel_log_paciente_idx on public.painel_log (paciente_id, em desc) where paciente_id is not null;
alter table public.painel_log enable row level security;
revoke all on table public.painel_log from anon, authenticated;
create trigger painel_log_so_inclusao before update or delete on public.painel_log
  for each row execute function public.bloquear_alteracao();
create trigger painel_log_sem_truncate before truncate on public.painel_log
  for each statement execute function public.bloquear_alteracao();

-- Convite válido (sem gastar): escopo painel, não usado, até 7 dias.
create or replace function public.painel_convite(p_token_sha256 text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'acesso_id', a.id,
    'email', coalesce((select pc.email from public.painel_contas pc
                        where pc.desativada_em is null order by pc.criada_em desc limit 1),
                      (select lower(btrim(c.email)) from public.configuracao c limit 1)),
    'conta_existe', exists (select 1 from public.painel_contas pc where pc.desativada_em is null)))
    from public.acessos_mcp a
   where a.token_sha256 = lower(p_token_sha256)
     and a.escopo = 'painel'
     and a.revogado_em is null
     and a.criado_em > now() - interval '7 days'
$$;

-- Gasta o convite (uma vez só) e diz para qual conta ele vale.
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
                    where pc.desativada_em is null order by pc.criada_em desc limit 1)));
end
$$;

-- Usuário do Auth com este e-mail (conta criada antes por outro caminho).
create or replace function public.painel_usuario_por_email(p_email text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id from auth.users u where lower(u.email) = lower(btrim(p_email)) limit 1
$$;

-- Conta criada ou senha trocada: a partir de agora só valem sessões novas.
create or replace function public.painel_conta_registrar(p_usuario uuid, p_email text)
returns void
language sql
set search_path = ''
as $$
  insert into public.painel_contas (usuario_id, email)
  values (p_usuario, lower(btrim(p_email)))
  on conflict (usuario_id) do update
    set senha_definida_em = now(), desativada_em = null, email = excluded.email
$$;

-- Confere a sessão do site e registra o acesso. Vale se a conta está ativa,
-- a sessão existe, foi aberta depois da última senha e tem até 30 dias.
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
     where pc.usuario_id = p_usuario
       and pc.desativada_em is null
       and s.id = p_sessao
       and s.created_at >= pc.senha_definida_em
       and s.created_at > now() - interval '30 days'
       and (s.not_after is null or s.not_after > now())) then
    return false;
  end if;
  insert into public.painel_log (usuario_id, acao, paciente_id) values (p_usuario, p_acao, p_paciente);
  return true;
end
$$;

create or replace function public.painel_sessoes_ativas()
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from public.painel_contas pc
    join auth.sessions s on s.user_id = pc.usuario_id
   where pc.desativada_em is null
     and s.created_at >= pc.senha_definida_em
     and s.created_at > now() - interval '30 days'
$$;

-- ---------------------------------------------------------------------
-- O link do Claude (acesso_ipad) agora é o convite do site
-- ---------------------------------------------------------------------
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
  v_sessoes int;
begin
  perform public.iniciar_solicitacao('acesso_ipad', p_dados, p_texto_original);
  if v_acao not in ('gerar', 'listar', 'revogar') then
    raise exception 'Ação "%" desconhecida. Use gerar, listar ou revogar.', p_dados ->> 'acao';
  end if;

  if v_acao = 'gerar' then
    -- um convite por vez: o novo cancela os que ainda não foram usados
    update public.acessos_mcp set revogado_em = now() where escopo = 'painel' and revogado_em is null;
    v_codigo := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
    insert into public.acessos_mcp (descricao, token_sha256, escopo)
    values (coalesce(nullif(btrim(p_dados ->> 'aparelho'), ''), 'Convite do site'),
            encode(extensions.digest(v_codigo, 'sha256'), 'hex'), 'painel')
    returning id into v_id;
    select painel_url into v_url from public.configuracao limit 1;
    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'ok',
      'acesso_id', v_id,
      'link', case when v_url is not null then rtrim(v_url, '/') || '/#acesso=' || v_codigo end,
      'validade', 'Vale por 7 dias e funciona uma vez só.',
      'como_usar', case when v_url is not null
        then 'Abra o link no iPhone, no iPad ou no computador. Ele pede uma senha nova para o site e liga o código de '
             || 'dois fatores no app Senhas do iPhone. Depois, em qualquer aparelho, é só entrar com e-mail, senha e '
             || 'código. No iPad, toque em Compartilhar > Adicionar à Tela de Início para virar um app.'
        else 'O endereço do site ainda não foi configurado (configuracao.painel_url).' end,
      'aviso', 'Este link cria ou troca a senha do site: não encaminhe a ninguém. Se esquecer a senha ou trocar de '
               || 'celular, peça um link novo.'));
  end if;

  if v_acao = 'revogar' then
    if nullif(btrim(p_dados ->> 'acesso_id'), '') is not null then
      update public.acessos_mcp set revogado_em = now()
       where id = (p_dados ->> 'acesso_id')::uuid and escopo = 'painel' and revogado_em is null;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'Nenhum convite ativo com esse id.'; end if;
    elsif coalesce((p_dados ->> 'todos')::boolean, false) then
      update public.acessos_mcp set revogado_em = now() where escopo = 'painel' and revogado_em is null;
      get diagnostics v_n = row_count;
      -- tira o site de todos os aparelhos: só entra de novo com senha e código
      update public.painel_contas set senha_definida_em = now() where desativada_em is null;
    else
      raise exception 'Diga qual convite revogar (acesso_id, de listar) ou todos = true para sair de todos os aparelhos.';
    end if;
  end if;

  v_sessoes := public.painel_sessoes_ativas();
  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'revogados', v_n,
    'conta_do_site', (select jsonb_build_object(
        'email', pc.email,
        'senha_definida_em', to_char(pc.senha_definida_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'aparelhos_conectados', v_sessoes)
      from public.painel_contas pc where pc.desativada_em is null order by pc.criada_em desc limit 1),
    'convites_pendentes', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'acesso_id', a.id, 'descricao', a.descricao,
        'criado_em', to_char(a.criado_em at time zone public.fuso(), 'DD/MM/YYYY HH24:MI'),
        'vence_em', to_char((a.criado_em + interval '7 days') at time zone public.fuso(), 'DD/MM/YYYY HH24:MI')))
        order by a.criado_em)
      from public.acessos_mcp a
     where a.escopo = 'painel' and a.revogado_em is null and a.criado_em > now() - interval '7 days'), '[]'::jsonb),
    'nota', case when v_acao = 'revogar' and coalesce((p_dados ->> 'todos')::boolean, false)
                 then 'Todos os aparelhos saíram do site; para entrar de novo, e-mail, senha e código.' end));
end
$$;

-- ---------------------------------------------------------------------
-- Leituras novas
-- ---------------------------------------------------------------------

-- Todos os orçamentos (sem as versões substituídas), com números do funil.
create or replace function public.painel_orcamentos(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with o as (
    select o.id, o.status, o.criado_em, p.id paciente_id, p.nome paciente, public.orcamento_resumo(o.id) r
      from public.orcamentos o
      join public.pacientes p on p.id = o.paciente_id
     where o.status <> 'substituido'
  ),
  v as (
    select o.*,
           coalesce((o.r ->> 'valor')::numeric,
                    (select min((x ->> 'total')::numeric) from jsonb_array_elements(o.r -> 'opcoes') x)) valor,
           (select coalesce(sum(i.quantidade * i.valor_unitario), 0)
              from public.orcamento_itens i
             where i.orcamento_id = o.id and i.status in ('aprovado', 'realizado')) aprovado
      from o
  )
  select jsonb_build_object(
    'resumo', jsonb_strip_nulls(jsonb_build_object(
      'total', count(*),
      'rascunhos', count(*) filter (where status = 'rascunho'),
      'apresentados', count(*) filter (where status = 'apresentado'),
      'aprovados', count(*) filter (where status in ('aprovado', 'parcial', 'concluido')),
      'recusados', count(*) filter (where status in ('recusado', 'expirado')),
      'valor_em_aberto', coalesce(sum(valor) filter (where status in ('rascunho', 'apresentado')), 0),
      'valor_aprovado', coalesce(sum(aprovado) filter (where status in ('aprovado', 'parcial', 'concluido')), 0),
      'taxa_aprovacao', case when count(*) filter (where status in ('aprovado', 'parcial', 'concluido', 'recusado', 'expirado')) > 0
        then round(100.0 * count(*) filter (where status in ('aprovado', 'parcial', 'concluido'))
                   / count(*) filter (where status in ('aprovado', 'parcial', 'concluido', 'recusado', 'expirado'))) end)),
    'orcamentos', coalesce(jsonb_agg(v.r || jsonb_build_object('paciente', v.paciente, 'paciente_id', v.paciente_id)
                                     order by v.criado_em desc), '[]'::jsonb))
    from v
$$;

-- Documentos emitidos (PDFs) e os modelos que ela pode pedir ao Claude.
create or replace function public.painel_documentos(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'total', (select count(*) from public.documentos),
    'por_tipo', (select coalesce(jsonb_object_agg(t.tipo, t.n), '{}'::jsonb)
                   from (select tipo, count(*) n from public.documentos group by tipo) t),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', d.titulo,
               'tipo', d.tipo,
               'data', (d.gerado_em at time zone public.fuso())::date,
               'hora', to_char(d.gerado_em at time zone public.fuso(), 'HH24:MI'),
               'paciente', p.nome,
               'paciente_id', p.id,
               'arquivo', d.caminho)) order by d.gerado_em desc), '[]'::jsonb)
        from (select * from public.documentos x
               where nullif(p_params ->> 'tipo', '') is null or x.tipo = p_params ->> 'tipo'
               order by x.gerado_em desc limit 300) d
        join public.pacientes p on p.id = d.paciente_id),
    'modelos_receita', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'nome', concat_ws(' ', m.nome, m.concentracao),
               'forma', m.forma,
               'posologia', m.posologia,
               'antibiotico', case when m.antibiotico then true end,
               'pediatrico', case when m.pediatrico then true end)) order by m.ordem, m.nome), '[]'::jsonb)
        from public.medicamentos_modelos m where m.ativo),
    'modelos_termo', (
      select coalesce(jsonb_agg(jsonb_build_object('titulo', t.titulo, 'tipo', t.tipo) order by t.ordem, t.titulo), '[]'::jsonb)
        from public.termos_modelos t where t.ativo))
$$;

-- Tabela de preços, campanhas e quanto sobra por forma de pagamento
-- (mesma conta do calcular_preco: preço − taxa − imposto − materiais).
create or replace function public.painel_precos(p_params jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cfg public.configuracao_financeira;
  v_imp numeric;
  v_base numeric := coalesce(public.custo_materiais(null, true), 0);
  v_hoje date := public.hoje();
begin
  select * into v_cfg from public.configuracao_financeira;
  v_imp := coalesce(v_cfg.imposto_percentual, 6);
  return jsonb_strip_nulls(jsonb_build_object(
    'imposto_pct', v_imp,
    'custo_base', v_base,
    'observacoes', v_cfg.observacoes,
    'formas', (
      select jsonb_agg(jsonb_build_object(
               'forma', f.rotulo,
               'percentual', (public.calcular_taxa_pagamento(f.forma, f.n, 100, v_hoje)).percentual) order by f.ordem)
        from (select * from (values ('pix', 1, 'Pix', 1), ('debito', 1, 'Débito', 2),
                                    ('credito_vista', 1, 'Crédito à vista', 3)) t(forma, n, rotulo, ordem)
              union all
              select 'credito_parcelado', n, 'Crédito ' || n || 'x', 2 + n from generate_series(2, 12) n) f),
    'procedimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'codigo', p.codigo,
               'nome', p.nome,
               'grupo', p.grupo,
               'preco', p.preco,
               'faixa_mercado', case when p.preco is null then p.faixa_mercado end,
               'no_site', case when p.publicar_no_site then true end,
               'custo_materiais', case when p.preco is not null then round(k.custo + v_base, 2) end,
               'kit', case when k.tem then true end,
               'sobra_pix', case when p.preco > 0 then round(p.preco
                 - (public.calcular_taxa_pagamento('pix', 1, p.preco, v_hoje)).taxa
                 - p.preco * v_imp / 100 - k.custo - v_base, 2) end,
               'sobra_credito_vista', case when p.preco > 0 then round(p.preco
                 - (public.calcular_taxa_pagamento('credito_vista', 1, p.preco, v_hoje)).taxa
                 - p.preco * v_imp / 100 - k.custo - v_base, 2) end,
               'sobra_credito_12x', case when p.preco > 0 then round(p.preco
                 - (public.calcular_taxa_pagamento('credito_parcelado', 12, p.preco, v_hoje)).taxa
                 - p.preco * v_imp / 100 - k.custo - v_base, 2) end,
               'campanhas', (select jsonb_agg(jsonb_build_object('campanha', c.nome, 'preco', cp.preco) order by c.inicio)
                               from public.campanha_precos cp
                               join public.campanhas c on c.id = cp.campanha_id
                              where cp.procedimento_id = p.id and cp.preco is not null
                                and c.cancelada_em is null and c.fim >= v_hoje - 30)))
             order by p.ordem, p.nome), '[]'::jsonb)
        from public.procedimentos p
        cross join lateral (
          select exists (select 1 from public.estoque_kits ek where ek.procedimento_id = p.id and ek.ativo) tem) t
        cross join lateral (
          select t.tem, case when t.tem then coalesce(public.custo_materiais(p.id, false), 0) else 0 end custo) k
       where p.ativo),
    'campanhas', (
      select coalesce(jsonb_agg(public.campanha_json(c, true) order by c.inicio desc), '[]'::jsonb)
        from public.campanhas c)));
end
$$;

-- O que o Claude fez: cada pedido, com o texto dito e o que mudou.
create or replace function public.painel_atividade(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with s as (
    select s.*
      from public.solicitacoes s
     where (nullif(p_params ->> 'antes', '') is null or s.criado_em < (p_params ->> 'antes')::timestamptz)
       and (not coalesce((p_params ->> 'so_mudancas')::boolean, false)
            or exists (select 1 from public.auditoria a where a.solicitacao_id = s.id))
     order by s.criado_em desc
     limit 80
  )
  select jsonb_build_object(
    'total', (select count(*) from public.solicitacoes),
    'itens', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'ferramenta', s.ferramenta,
      'texto', s.texto_original,
      'em', s.criado_em,
      'data', (s.criado_em at time zone public.fuso())::date,
      'hora', to_char(s.criado_em at time zone public.fuso(), 'HH24:MI'),
      'ok', s.sucesso,
      'erro', s.erro,
      'mudancas', nullif(a.n, 0),
      'tabelas', a.tabelas,
      'pacientes', pa.lista)) order by s.criado_em desc), '[]'::jsonb))
    from s
    left join lateral (
      select count(*) n, jsonb_agg(distinct au.tabela) filter (where au.tabela is not null) tabelas
        from public.auditoria au where au.solicitacao_id = s.id) a on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome) order by p.nome) lista
        from public.pacientes p
       where p.id in (
         select case when au.tabela = 'pacientes' then au.registro_id
                     else coalesce(au.depois ->> 'paciente_id', au.antes ->> 'paciente_id') end::uuid
           from public.auditoria au
          where au.solicitacao_id = s.id
            and coalesce(case when au.tabela = 'pacientes' then au.registro_id end,
                         au.depois ->> 'paciente_id', au.antes ->> 'paciente_id')
                ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) pa on true
$$;

-- Financeiro: 12 meses até o mês pedido e recibos do Receita Saúde a emitir.
create or replace function public.painel_financeiro_extra(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'historico', (
      select jsonb_agg(public.fin_totais_mes(m::date) order by m)
        from generate_series(date_trunc('month', public.fin_mes(p_params ->> 'mes')) - interval '11 months',
                             date_trunc('month', public.fin_mes(p_params ->> 'mes')), interval '1 month') m),
    'recibos_a_emitir', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'titulo', p.nome, 'paciente_id', p.id, 'data', r.data_pagamento,
               'forma', public.rotulo_forma_pagamento(r.forma, r.parcelas_cartao), 'valor', r.valor_bruto,
               'status', case x.s when 'cancelar' then 'cancelar recibo' else 'a emitir' end))
             order by r.data_pagamento, r.numero), '[]'::jsonb)
        from public.recebimentos r
        join public.pacientes p on p.id = r.paciente_id
        cross join lateral (select public.recibo_situacao(r.id) ->> 'situacao' s) x
       where r.estorna_id is null and r.regime_fiscal = 'pf' and x.s in ('pendente', 'cancelar')))
$$;

-- Estoque: consumo por semana (8 semanas) e últimas movimentações.
create or replace function public.painel_estoque_extra(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with ini as (
    select public.hoje() - (extract(isodow from public.hoje())::int - 1) - 49 d
  ),
  sem as (
    select i, (select d from ini) + 7 * i semana from generate_series(0, 7) i
  ),
  uso as (
    select m.material_id, (date_trunc('week', m.data))::date semana, -sum(m.quantidade) q
      from public.estoque_movimentos m
      left join public.estoque_movimentos o on o.id = m.estorna_id
     where m.data >= (select d from ini)
       and (m.tipo in ('uso_atendimento', 'uso_avulso', 'perda', 'vencido')
            or (m.tipo = 'estorno' and o.tipo in ('uso_atendimento', 'uso_avulso', 'perda', 'vencido')))
     group by 1, 2
  ),
  tot as (
    select material_id, sum(q) total from uso group by 1 having sum(q) > 0
  )
  select jsonb_build_object(
    'semanas', (select jsonb_agg(semana order by i) from sem),
    'consumo', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', mt.nome,
               'unidade', mt.unidade_uso,
               'por_semana', (select jsonb_agg(coalesce((select u.q from uso u
                                                          where u.material_id = mt.id and u.semana = sem.semana), 0)
                                               order by sem.i) from sem),
               'total', public.estoque_qtd(mt.unidade_uso, mt.unidade_compra, mt.fator, tot.total),
               'media_semana', public.estoque_qtd(mt.unidade_uso, mt.unidade_compra, mt.fator, round(tot.total / 8.0, 2)))
             order by mt.nome), '[]'::jsonb)
        from tot join public.estoque_materiais mt on mt.id = tot.material_id),
    'movimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'material', mt.nome,
               'tipo', case m.tipo
                 when 'compra' then 'compra' when 'uso_atendimento' then 'uso no atendimento'
                 when 'uso_avulso' then 'uso' when 'contagem' then 'contagem' when 'perda' then 'perda'
                 when 'vencido' then 'vencido' when 'entrada_avulsa' then 'entrada' when 'estorno' then 'estorno'
                 else m.tipo end,
               'entrada', case when m.quantidade > 0 then true end,
               'quantidade', public.estoque_qtd(mt.unidade_uso, mt.unidade_compra, mt.fator, abs(m.quantidade)),
               'data', m.data,
               'motivo', m.motivo)) order by m.registrado_em desc), '[]'::jsonb)
        from (select * from public.estoque_movimentos order by registrado_em desc limit 25) m
        join public.estoque_materiais mt on mt.id = m.material_id))
$$;

-- Início: fichas online para revisar, campanhas e orçamentos em rascunho.
create or replace function public.painel_inicio_extra()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'fichas_online', (
      select jsonb_agg(jsonb_build_object('paciente', p.nome, 'paciente_id', p.id,
                                          'enviada_em', (f.enviado_em at time zone public.fuso())::date)
                       order by f.enviado_em)
        from public.fichas_online f join public.pacientes p on p.id = f.paciente_id
       where f.situacao = 'enviada'),
    'campanhas', (
      select jsonb_agg(public.campanha_json(c) order by c.inicio)
        from public.campanhas c
       where c.cancelada_em is null and c.fim >= public.hoje() and c.inicio <= public.hoje() + 45),
    'orcamentos_rascunho', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'paciente', p.nome, 'paciente_id', p.id, 'titulo', x ->> 'titulo', 'valor', x -> 'valor',
               'opcoes', x -> 'opcoes')) order by o.criado_em desc)
        from public.orcamentos o
        join public.pacientes p on p.id = o.paciente_id and p.arquivado_em is null
        cross join lateral (select public.orcamento_resumo(o.id) x) z
       where o.status = 'rascunho')))
$$;

-- Ajustes: dados do consultório, financeiro e acessos (sem códigos).
create or replace function public.painel_configuracoes()
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
    'conta', (select jsonb_build_object('email', pc.email,
                                        'senha_definida_em', pc.senha_definida_em,
                                        'aparelhos_conectados', public.painel_sessoes_ativas())
                from public.painel_contas pc where pc.desativada_em is null order by pc.criada_em desc limit 1),
    'acessos', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'tipo', case a.escopo when 'mcp' then 'Claude (conector)' when 'painel' then 'Convite do site'
                                        when 'calendario' then 'Calendário do iPhone/iPad' else a.escopo end,
                  'descricao', a.descricao,
                  'criado_em', a.criado_em,
                  'ultimo_uso', a.ultimo_uso_em)) order by a.criado_em)
                  from public.acessos_mcp a
                 where a.revogado_em is null
                   and (a.escopo <> 'painel' or a.criado_em > now() - interval '7 days')),
    'ultimos_acessos_site', (select jsonb_agg(jsonb_build_object('em', l.em, 'acao', l.acao) order by l.em desc)
                               from (select * from public.painel_log order by em desc limit 15) l)))
$$;

-- Entrada única do painel com as ações novas.
create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio() || public.painel_inicio_extra()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params)
    when 'financeiro' then public.painel_financeiro(p_params) || public.painel_financeiro_extra(p_params)
    when 'estoque' then public.painel_estoque(p_params) || public.painel_estoque_extra(p_params)
    when 'orcamentos' then public.painel_orcamentos(p_params)
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_configuracoes()
    else null
  end;
end
$$;

-- ---------------------------------------------------------------------
-- Permissões: só a Edge Function (chave secreta) chama.
-- ---------------------------------------------------------------------
revoke execute on function
  public.painel_convite(text), public.painel_convite_usar(text), public.painel_usuario_por_email(text),
  public.painel_conta_registrar(uuid, text), public.painel_autorizar(uuid, uuid, text, uuid),
  public.painel_sessoes_ativas(), public.mcp_acesso_ipad(jsonb, text),
  public.painel_orcamentos(jsonb), public.painel_documentos(jsonb), public.painel_precos(jsonb),
  public.painel_atividade(jsonb), public.painel_financeiro_extra(jsonb), public.painel_estoque_extra(jsonb),
  public.painel_inicio_extra(), public.painel_configuracoes(), public.painel(text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.painel_convite(text), public.painel_convite_usar(text), public.painel_usuario_por_email(text),
  public.painel_conta_registrar(uuid, text), public.painel_autorizar(uuid, uuid, text, uuid),
  public.painel_sessoes_ativas(), public.mcp_acesso_ipad(jsonb, text),
  public.painel_orcamentos(jsonb), public.painel_documentos(jsonb), public.painel_precos(jsonb),
  public.painel_atividade(jsonb), public.painel_financeiro_extra(jsonb), public.painel_estoque_extra(jsonb),
  public.painel_inicio_extra(), public.painel_configuracoes(), public.painel(text, jsonb)
  to service_role;
