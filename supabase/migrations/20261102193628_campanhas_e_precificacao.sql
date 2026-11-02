-- Campanhas com preço próprio (ex.: "Campanha RJ", 1 ou 2 dias de atendimento
-- em outra cidade) e calculadora de preço/lucro por forma de pagamento.
--
-- Campanha: nome, local, datas e uma tabela de preços só dela. Os preços
-- normais do catálogo não mudam. Orçamento feito num dia de campanha usa os
-- preços dela (a Dra. pode dizer "sem campanha"); procedimento sem preço de
-- campanha fica com o preço normal. Nos dias da campanha a confirmação por
-- WhatsApp usa o local da campanha e a agenda não cobra reserva de sala.
-- Nada se apaga: campanha é cancelada; preço sai da campanha com preco nulo.

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
create table public.campanhas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(btrim(nome)) >= 3),
  local text,                                  -- onde (vai na confirmação do WhatsApp e no orçamento)
  cidade text,
  inicio date not null,
  fim date not null,
  observacao text,
  cancelada_em timestamptz,
  motivo_cancelamento text,
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (fim >= inicio),
  check (fim - inicio <= 60)
);
comment on table public.campanhas is
  'Campanhas de atendimento (ex.: Campanha RJ) com datas, local e preços próprios. Nunca apagar: cancelar.';
create index campanhas_datas_idx on public.campanhas (inicio, fim) where cancelada_em is null;

create table public.campanha_precos (
  id uuid primary key default gen_random_uuid(),
  campanha_id uuid not null references public.campanhas (id),
  procedimento_id uuid not null references public.procedimentos (id),
  preco numeric(10, 2) check (preco is null or preco >= 0),   -- nulo = volta ao preço normal
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (campanha_id, procedimento_id)
);
comment on table public.campanha_precos is 'Preço de um procedimento numa campanha. Sem linha (ou preço nulo): preço normal.';

create trigger campanhas_atualizado_em before update on public.campanhas
  for each row execute function public.tocar_atualizado_em();
create trigger campanhas_auditoria after insert or update on public.campanhas
  for each row execute function public.registrar_auditoria();
create trigger campanhas_sem_exclusao before delete on public.campanhas
  for each row execute function public.bloquear_alteracao();
create trigger campanha_precos_atualizado_em before update on public.campanha_precos
  for each row execute function public.tocar_atualizado_em();
create trigger campanha_precos_auditoria after insert or update on public.campanha_precos
  for each row execute function public.registrar_auditoria();
create trigger campanha_precos_sem_exclusao before delete on public.campanha_precos
  for each row execute function public.bloquear_alteracao();

alter table public.campanhas enable row level security;
alter table public.campanha_precos enable row level security;
revoke all on table public.campanhas, public.campanha_precos from anon, authenticated;

alter table public.orcamentos add column campanha_id uuid references public.campanhas (id);
comment on column public.orcamentos.campanha_id is 'Campanha cujos preços o orçamento usou.';
create index orcamentos_campanha_idx on public.orcamentos (campanha_id) where campanha_id is not null;

-- Imposto usado na calculadora de preço (percentual sobre o valor cobrado).
alter table public.configuracao_financeira
  add column imposto_percentual numeric(5, 2) not null default 6 check (imposto_percentual between 0 and 50);
comment on column public.configuracao_financeira.imposto_percentual is
  'Imposto sobre o valor cobrado, usado na calculadora de preço (padrão 6%).';

-- Taxas da InfinitePay: tabela publicada do Plano Inicial (até R$ 20 mil/mês),
-- recebimento em 1 dia útil, Visa e Mastercard (infinitepay.io/taxas, 02/11/2026).
-- Substitui a conta aproximada (3,15% + 1,40% por parcela) pela tabela exata.
update public.configuracao_financeira
   set taxas = taxas
         || jsonb_build_object('debito', coalesce(taxas -> 'debito', '{}'::jsonb) || '{"percentual": 1.37, "dias": 1}')
         || jsonb_build_object('credito_vista', coalesce(taxas -> 'credito_vista', '{}'::jsonb) || '{"percentual": 3.15, "dias": 1}')
         || jsonb_build_object('credito_parcelado', coalesce(taxas -> 'credito_parcelado', '{}'::jsonb)
              || jsonb_build_object('dias', 1, 'por_parcelas', jsonb_build_object(
                   '2', 5.39, '3', 6.12, '4', 6.85, '5', 7.57, '6', 8.28, '7', 8.99,
                   '8', 9.69, '9', 10.38, '10', 11.06, '11', 11.74, '12', 12.40))),
       observacoes = 'Taxas da InfinitePay: Plano Inicial (até R$ 20 mil/mês), em 1 dia útil, Visa/Master '
                     || '(tabela do site em 02/11/2026). Confirmar com a Dra. o plano e a bandeira. '
                     || 'CPF da Dra. ainda não informado.'
 where id;

-- ---------------------------------------------------------------------
-- Funções de apoio
-- ---------------------------------------------------------------------
create or replace function public.campanha_periodo(c public.campanhas)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when c.inicio = c.fim then to_char(c.inicio, 'DD/MM/YYYY')
    when date_trunc('month', c.inicio) = date_trunc('month', c.fim)
      then to_char(c.inicio, 'DD') || ' a ' || to_char(c.fim, 'DD/MM/YYYY')
    else to_char(c.inicio, 'DD/MM') || ' a ' || to_char(c.fim, 'DD/MM/YYYY') end
$$;

create or replace function public.campanha_situacao(c public.campanhas)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when c.cancelada_em is not null then 'cancelada'
    when public.hoje() < c.inicio then 'proxima'
    when public.hoje() > c.fim then 'encerrada'
    else 'em_andamento' end
$$;

-- Campanha (não cancelada) que cobre o dia, ou nulo.
create or replace function public.campanha_na_data(p_data date)
returns public.campanhas
language sql
stable
set search_path = ''
as $$
  select c.* from public.campanhas c
   where c.cancelada_em is null and p_data between c.inicio and c.fim
   order by c.inicio desc
   limit 1
$$;

-- Acha a campanha pelo id ou pelo nome (exato ou parte); com nomes repetidos,
-- fica a em andamento/próxima mais perto de hoje.
create or replace function public.campanha_localizar(p_ref text)
returns public.campanhas
language plpgsql
stable
set search_path = ''
as $$
declare
  c public.campanhas;
  v_t text := public.normalizar(p_ref);
begin
  if nullif(btrim(p_ref), '') is null then
    raise exception 'Diga qual campanha (nome).';
  end if;
  if p_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into c from public.campanhas where id = p_ref::uuid;
    if found then return c; end if;
  end if;
  select * into c from public.campanhas x
   where x.cancelada_em is null and public.normalizar(x.nome) = v_t
   order by (x.fim >= public.hoje()) desc, abs(x.inicio - public.hoje()) limit 1;
  if found then return c; end if;
  select * into c from public.campanhas x
   where x.cancelada_em is null and public.normalizar(x.nome) like '%' || v_t || '%'
   order by (x.fim >= public.hoje()) desc, abs(x.inicio - public.hoje()) limit 1;
  if found then return c; end if;
  raise exception 'Campanha "%" não encontrada.%', p_ref,
    coalesce(' Campanhas: ' || (select string_agg(x.nome || ' (' || public.campanha_periodo(x) || ')', '; ' order by x.inicio desc)
                                   from public.campanhas x where x.cancelada_em is null) || '.',
             ' Não há campanha cadastrada: crie com salvar_campanha.');
end
$$;

-- {procedimento_id: preço} da campanha (formato dos valores do orçamento).
create or replace function public.campanha_mapa_precos(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(cp.procedimento_id::text, cp.preco), '{}'::jsonb)
    from public.campanha_precos cp
   where cp.campanha_id = p_id and cp.preco is not null
$$;

create or replace function public.campanha_resumo(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with c as (select * from public.campanhas where id = p_id),
  o as (select o.* from public.orcamentos o where o.campanha_id = p_id and o.status <> 'substituido')
  select jsonb_build_object(
    'consultas', (select count(*) from public.consultas k, c
                   where public.data_local(k.inicio) between c.inicio and c.fim
                     and k.status not in ('cancelada', 'remarcada')),
    'pacientes_atendidos', (select count(distinct a.paciente_id) from public.atendimentos a, c
                             where a.data between c.inicio and c.fim),
    'orcamentos', (select count(*) from o),
    'orcamentos_aprovados', (select count(*) from o where o.status in ('aprovado', 'parcial', 'concluido')),
    'valor_aprovado', (select coalesce(sum(i.quantidade * i.valor_unitario), 0)
                         from o join public.orcamento_itens i on i.orcamento_id = o.id
                        where o.status in ('aprovado', 'parcial', 'concluido')
                          and i.status in ('aprovado', 'realizado')),
    'recebido', (select coalesce(sum(r.valor_bruto), 0) from public.recebimentos r
                  where r.orcamento_id in (select id from o) and r.estorna_id is null
                    and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id)))
$$;

create or replace function public.campanha_json(c public.campanhas, p_detalhe boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', c.id,
    'nome', c.nome,
    'local', c.local,
    'cidade', c.cidade,
    'inicio', c.inicio,
    'fim', c.fim,
    'periodo', public.campanha_periodo(c),
    'situacao', public.campanha_situacao(c),
    'observacao', c.observacao,
    'motivo_cancelamento', c.motivo_cancelamento,
    'precos_especiais', (select count(*) from public.campanha_precos cp
                          where cp.campanha_id = c.id and cp.preco is not null),
    'precos', case when p_detalhe then (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'codigo', p.codigo,
               'procedimento', p.nome,
               'preco_campanha', cp.preco,
               'preco_normal', p.preco,
               'diferenca_pct', case when p.preco > 0 then round(100 * (cp.preco - p.preco) / p.preco, 1) end))
             order by p.ordem, p.nome), '[]'::jsonb)
        from public.campanha_precos cp join public.procedimentos p on p.id = cp.procedimento_id
       where cp.campanha_id = c.id and cp.preco is not null) end,
    'resumo', case when p_detalhe then public.campanha_resumo(c.id) end))
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: salvar_campanha (criar, mudar, preços, cancelar)
-- ---------------------------------------------------------------------
create or replace function public.mcp_salvar_campanha(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c public.campanhas;
  v_old public.campanhas;
  v_ref text := nullif(btrim(p_dados ->> 'campanha'), '');
  v_nome text := nullif(btrim(p_dados ->> 'nome'), '');
  v_nova boolean := false;
  v_avisos text[] := '{}';
  v_item jsonb;
  v_proc_id uuid;
  v_proc public.procedimentos;
  v_aviso text;
  v_preco numeric;
  v_outra public.campanhas;
  v_mudou_preco int := 0;
  v_tirou int := 0;
begin
  perform public.iniciar_solicitacao('salvar_campanha', p_dados, p_texto_original);

  if v_ref is not null then
    c := public.campanha_localizar(v_ref);
  elsif v_nome is not null then
    select * into c from public.campanhas x
     where x.cancelada_em is null and public.normalizar(x.nome) = public.normalizar(v_nome)
       and x.fim >= public.hoje()
     order by x.inicio limit 1;
  end if;

  if c.id is null then
    -- campanha nova
    if v_nome is null then
      raise exception 'Para criar a campanha, diga o nome (ex.: Campanha RJ) e a data.';
    end if;
    if nullif(btrim(p_dados ->> 'inicio'), '') is null then
      raise exception 'Diga a data da campanha "%" (inicio; e fim, se for mais de um dia).', v_nome;
    end if;
    c.nome := v_nome;
    c.inicio := public.ler_data(p_dados ->> 'inicio', 'Data de início');
    c.fim := coalesce(public.ler_data(p_dados ->> 'fim', 'Data de fim'), c.inicio);
    c.local := nullif(btrim(p_dados ->> 'local'), '');
    c.cidade := nullif(btrim(p_dados ->> 'cidade'), '');
    c.observacao := nullif(btrim(p_dados ->> 'observacao'), '');
    v_nova := true;
  else
    v_old := c;
    if c.cancelada_em is not null then
      raise exception 'A campanha "%" foi cancelada. Para fazer de novo, crie outra com salvar_campanha.', c.nome;
    end if;
    if coalesce((p_dados ->> 'cancelar')::boolean, false) then
      update public.campanhas
         set cancelada_em = now(),
             motivo_cancelamento = coalesce(nullif(btrim(p_dados ->> 'motivo'), ''), 'Cancelada pela Dra.')
       where id = c.id
      returning * into c;
      if exists (select 1 from public.orcamentos o where o.campanha_id = c.id and o.status <> 'substituido') then
        v_avisos := v_avisos || 'Os orçamentos já feitos com os preços da campanha continuam com esses valores.'::text;
      end if;
      return jsonb_build_object('status', 'cancelada', 'campanha', public.campanha_json(c), 'avisos', to_jsonb(v_avisos));
    end if;
    if v_nome is not null and v_ref is not null then c.nome := v_nome; end if;
    if p_dados ? 'inicio' then c.inicio := public.ler_data(p_dados ->> 'inicio', 'Data de início'); end if;
    if p_dados ? 'fim' then c.fim := public.ler_data(p_dados ->> 'fim', 'Data de fim'); end if;
    if p_dados ? 'inicio' and not p_dados ? 'fim' and c.fim < c.inicio then c.fim := c.inicio; end if;
    if p_dados ? 'local' then c.local := nullif(btrim(p_dados ->> 'local'), ''); end if;
    if p_dados ? 'cidade' then c.cidade := nullif(btrim(p_dados ->> 'cidade'), ''); end if;
    if p_dados ? 'observacao' then c.observacao := nullif(btrim(p_dados ->> 'observacao'), ''); end if;
  end if;

  if c.fim < c.inicio then
    raise exception 'A campanha termina (%) antes de começar (%).', to_char(c.fim, 'DD/MM/YYYY'), to_char(c.inicio, 'DD/MM/YYYY');
  end if;
  if c.fim - c.inicio > 60 then
    raise exception 'Campanha de mais de 60 dias: confira as datas.';
  end if;
  select * into v_outra from public.campanhas x
   where x.cancelada_em is null and x.id is distinct from c.id
     and x.inicio <= c.fim and x.fim >= c.inicio
   limit 1;
  if found then
    raise exception 'As datas batem com a campanha "%" (%). Uma campanha por dia: mude as datas ou cancele a outra.',
      v_outra.nome, public.campanha_periodo(v_outra);
  end if;
  if c.fim < public.hoje() then
    v_avisos := v_avisos || format('A campanha é de %s, que já passou.', public.campanha_periodo(c));
  end if;

  if v_nova then
    insert into public.campanhas (nome, local, cidade, inicio, fim, observacao, solicitacao_id)
    values (c.nome, c.local, c.cidade, c.inicio, c.fim, c.observacao,
            nullif(current_setting('app.solicitacao_id', true), '')::uuid)
    returning * into c;
  elsif row(c.nome, c.local, c.cidade, c.inicio, c.fim, c.observacao)
        is distinct from row(v_old.nome, v_old.local, v_old.cidade, v_old.inicio, v_old.fim, v_old.observacao) then
    update public.campanhas
       set nome = c.nome, local = c.local, cidade = c.cidade, inicio = c.inicio, fim = c.fim, observacao = c.observacao
     where id = c.id
    returning * into c;
  end if;

  -- Preços da campanha
  if p_dados ? 'precos' and jsonb_typeof(p_dados -> 'precos') <> 'array' then
    raise exception 'precos deve ser uma lista de {procedimento_codigo ou procedimento, preco}.';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'precos', '[]')) loop
    select e.proc_id, e.aviso into v_proc_id, v_aviso
      from public.escolher_procedimento(v_item ->> 'procedimento_codigo', v_item ->> 'procedimento', null, null, null) e;
    if v_proc_id is null then
      raise exception '"%" não está no catálogo. Inclua com salvar_procedimento (sem preço, se só existir na campanha) e repita.',
        coalesce(v_item ->> 'procedimento', v_item ->> 'procedimento_codigo');
    end if;
    if v_aviso is not null then
      v_avisos := v_avisos || v_aviso;
    end if;
    select * into v_proc from public.procedimentos where id = v_proc_id;
    if jsonb_typeof(v_item -> 'preco') = 'null' or not v_item ? 'preco'
       or coalesce((v_item ->> 'remover')::boolean, false) then
      v_preco := null;
    else
      v_preco := public.fin_valor(v_item ->> 'preco', 'Preço de ' || v_proc.nome);
      if v_preco < 0 or v_preco > 200000 then
        raise exception 'Preço R$ % de "%" fora do esperado: confira.', v_preco, v_proc.nome;
      end if;
    end if;
    insert into public.campanha_precos (campanha_id, procedimento_id, preco, solicitacao_id)
    values (c.id, v_proc.id, v_preco, nullif(current_setting('app.solicitacao_id', true), '')::uuid)
    on conflict (campanha_id, procedimento_id) do update
       set preco = excluded.preco, solicitacao_id = excluded.solicitacao_id
     where campanha_precos.preco is distinct from excluded.preco;
    if v_preco is null then
      v_tirou := v_tirou + 1;
    else
      v_mudou_preco := v_mudou_preco + 1;
      if v_proc.preco is not null and v_preco > v_proc.preco then
        v_avisos := v_avisos || format('%s: R$ %s na campanha, acima do preço normal (R$ %s). Confira.',
                                       v_proc.nome, v_preco, v_proc.preco);
      elsif v_proc.preco is not null and v_preco < v_proc.preco * 0.5 then
        v_avisos := v_avisos || format('%s: R$ %s na campanha, menos da metade do preço normal (R$ %s). Confira.',
                                       v_proc.nome, v_preco, v_proc.preco);
      end if;
    end if;
  end loop;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', case when v_nova then 'criada' else 'ok' end,
    'campanha', public.campanha_json(c, true),
    'precos_gravados', nullif(v_mudou_preco, 0),
    'precos_retirados', nullif(v_tirou, 0),
    'como_funciona', format(
      'Orçamentos feitos de %s usam esses preços sozinhos (o que não tiver preço de campanha fica com o normal). '
      || 'Os preços normais não mudam. Nesses dias a confirmação por WhatsApp leva o local da campanha.',
      public.campanha_periodo(c)),
    'avisos', to_jsonb(v_avisos)));
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: ver_campanhas
-- ---------------------------------------------------------------------
create or replace function public.mcp_ver_campanhas(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c public.campanhas;
  v_ref text := nullif(btrim(p_dados ->> 'campanha'), '');
begin
  perform public.iniciar_solicitacao('ver_campanhas', p_dados, p_texto_original);
  if v_ref is not null then
    c := public.campanha_localizar(v_ref);
    return jsonb_build_object('campanha', public.campanha_json(c, true));
  end if;
  c := public.campanha_na_data(public.hoje());
  return jsonb_strip_nulls(jsonb_build_object(
    'hoje', case when c.id is not null then public.campanha_json(c, true) end,
    'campanhas', (select coalesce(jsonb_agg(public.campanha_json(x) order by x.inicio desc), '[]'::jsonb)
                    from (select * from public.campanhas x
                           where x.cancelada_em is null or coalesce((p_dados ->> 'incluir_canceladas')::boolean, false)
                           order by x.inicio desc limit 20) x),
    'mensagem', case when not exists (select 1 from public.campanhas)
                     then 'Nenhuma campanha cadastrada. Para criar: salvar_campanha com nome, data, local e preços.' end));
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: calcular_preco (lucro por forma de pagamento)
-- ---------------------------------------------------------------------
create or replace function public.mcp_calcular_preco(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cfg public.configuracao_financeira;
  v_proc public.procedimentos;
  v_proc_id uuid;
  v_aviso text;
  v_avisos text[] := '{}';
  v_camp public.campanhas;
  v_preco numeric := public.fin_valor(p_dados ->> 'preco', 'Preço');
  v_origem text := 'informado';
  v_imp numeric;
  v_margem numeric := public.fin_valor(p_dados ->> 'margem_desejada', 'Margem desejada');
  v_max int := coalesce(public.fin_inteiro(p_dados ->> 'parcelas_max', 'Parcelas'), 12);
  v_custos jsonb := '[]';
  v_total numeric := 0;
  v_det jsonb;
  v_valor numeric;
  v_item jsonb;
  v_horas numeric := public.fin_valor(p_dados ->> 'horas_sala', 'Horas de sala');
  v_hora numeric := public.fin_valor(p_dados ->> 'valor_hora_sala', 'Valor da hora da sala');
  v_formas jsonb := '[]';
  v_f record;
  v_t record;
  v_fixo numeric;
  v_imposto numeric;
  v_lucro numeric;
  v_lucro_pix numeric;
  v_ref_pix numeric;
  v_den numeric;
  v_sugerido numeric;
  v_resumo text;
begin
  perform public.iniciar_solicitacao('calcular_preco', p_dados, p_texto_original);
  select * into v_cfg from public.configuracao_financeira;
  v_imp := coalesce(public.fin_valor(p_dados ->> 'imposto_percentual', 'Imposto'), v_cfg.imposto_percentual, 6);
  if v_imp < 0 or v_imp > 50 then
    raise exception '%', format('Imposto de %s%% fora do esperado.', v_imp);
  end if;
  if v_margem is not null and (v_margem <= 0 or v_margem >= 90) then
    raise exception '%', format('Margem desejada de %s%% fora do esperado (use de 1 a 89).', v_margem);
  end if;
  if v_max < 1 or v_max > 12 then
    raise exception 'Parcelas: de 1 a 12.';
  end if;

  -- Procedimento (opcional): traz o preço atual e o custo do kit do estoque
  if nullif(btrim(coalesce(p_dados ->> 'procedimento_codigo', p_dados ->> 'procedimento')), '') is not null then
    select e.proc_id, e.aviso into v_proc_id, v_aviso
      from public.escolher_procedimento(p_dados ->> 'procedimento_codigo', p_dados ->> 'procedimento', null, null, null) e;
    if v_aviso is not null then v_avisos := v_avisos || v_aviso; end if;
    if v_proc_id is not null then
      select * into v_proc from public.procedimentos where id = v_proc_id;
    end if;
  end if;
  if nullif(btrim(p_dados ->> 'campanha'), '') is not null then
    v_camp := public.campanha_localizar(p_dados ->> 'campanha');
  end if;
  if v_preco is null and v_proc.id is not null and v_camp.id is not null then
    select cp.preco into v_preco from public.campanha_precos cp
     where cp.campanha_id = v_camp.id and cp.procedimento_id = v_proc.id;
    if v_preco is not null then v_origem := v_camp.nome; end if;
  end if;
  if v_preco is null and v_proc.id is not null and v_proc.preco is not null then
    v_preco := v_proc.preco;
    v_origem := 'catálogo';
  end if;
  if v_preco is null and v_margem is null then
    raise exception 'Diga quanto ela pensa em cobrar (preco) ou a margem que quer ter (margem_desejada).';
  end if;
  if v_preco is not null and (v_preco <= 0 or v_preco > 200000) then
    raise exception 'Preço R$ % fora do esperado.', v_preco;
  end if;

  -- Custos
  if v_proc.id is not null and coalesce((p_dados ->> 'usar_kit')::boolean, true) then
    v_det := public.custo_materiais_detalhe(v_proc.id, false);
    if exists (select 1 from public.estoque_kits k where k.procedimento_id = v_proc.id and k.ativo) then
      v_valor := coalesce((v_det ->> 'custo_total')::numeric, 0);
      v_custos := v_custos || jsonb_build_array(jsonb_build_object('custo', 'Materiais do kit (estoque)', 'valor', v_valor));
      v_total := v_total + v_valor;
      if jsonb_array_length(coalesce(v_det -> 'sem_custo', '[]')) > 0 then
        v_avisos := v_avisos || format('Materiais sem custo no estoque (nenhuma compra registrada), contados como zero: %s. Se ela souber o gasto, diga em custos.',
                                       (select string_agg(x, ', ') from jsonb_array_elements_text(v_det -> 'sem_custo') x));
      end if;
    end if;
    v_valor := coalesce(public.custo_materiais(null, true), 0);
    if v_valor > 0 then
      v_custos := v_custos || jsonb_build_array(jsonb_build_object('custo', 'Kit base (luva, máscara, babador...)', 'valor', v_valor));
      v_total := v_total + v_valor;
    end if;
  end if;
  if v_horas is not null then
    if v_hora is null then
      select round(r.valor / nullif(extract(epoch from r.fim - r.inicio) / 3600, 0), 2) into v_hora
        from public.reservas_sala r
       where r.cancelada_em is null and r.valor > 0
       order by r.inicio desc limit 1;
    end if;
    if v_hora is null then
      v_avisos := v_avisos || 'Sem o valor da hora da sala: diga valor_hora_sala para entrar no custo.'::text;
    else
      v_valor := round(v_horas * v_hora, 2);
      v_custos := v_custos || jsonb_build_array(jsonb_build_object(
        'custo', format('Sala (%s h a R$ %s)', v_horas, v_hora), 'valor', v_valor));
      v_total := v_total + v_valor;
    end if;
  end if;
  if p_dados ? 'custos' and jsonb_typeof(p_dados -> 'custos') <> 'array' then
    raise exception 'custos deve ser uma lista de {descricao, valor}.';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'custos', '[]')) loop
    v_valor := public.fin_valor(v_item ->> 'valor', 'Custo');
    if v_valor is null or v_valor < 0 then
      raise exception 'Informe o valor do custo "%".', coalesce(v_item ->> 'descricao', '?');
    end if;
    v_custos := v_custos || jsonb_build_array(jsonb_build_object(
      'custo', coalesce(nullif(btrim(v_item ->> 'descricao'), ''), 'Outro custo'), 'valor', v_valor));
    v_total := v_total + v_valor;
  end loop;

  -- Sem preço, com margem: o preço de referência é o do Pix para a margem pedida
  if v_preco is null then
    if v_total = 0 then
      raise exception 'Sem custos não dá para calcular o preço pela margem: diga os custos ou o preço.';
    end if;
    if v_imp + v_margem >= 95 then
      raise exception '%', format('Imposto (%s%%) mais margem (%s%%) passam de 95%%: não há preço possível.', v_imp, v_margem);
    end if;
    v_preco := ceil(v_total / (1 - v_imp / 100 - v_margem / 100));
    v_origem := format('sugerido para %s%% de margem no Pix', v_margem);
  end if;

  -- Formas de pagamento
  for v_f in
    select * from (values ('pix', 1, 'Pix', 1), ('debito', 1, 'Débito', 2), ('credito_vista', 1, 'Crédito à vista', 3)) t(forma, n, rotulo, ordem)
    union all
    select 'credito_parcelado', n, 'Crédito em ' || n || 'x', 2 + n from generate_series(2, v_max) n
    order by 4
  loop
    select * into v_t from public.calcular_taxa_pagamento(v_f.forma, v_f.n, v_preco, public.hoje());
    v_fixo := (select taxa from public.calcular_taxa_pagamento(v_f.forma, v_f.n, 0, public.hoje()));
    v_imposto := round(v_preco * v_imp / 100, 2);
    v_lucro := round(v_preco - v_t.taxa - v_imposto - v_total, 2);
    if v_f.forma = 'pix' then
      v_lucro_pix := v_lucro;
      v_ref_pix := v_lucro + v_total;   -- o que sobra antes dos custos no Pix
    end if;
    v_den := 1 - v_imp / 100 - v_t.percentual / 100;
    v_sugerido := case when v_margem is not null and v_den - v_margem / 100 > 0
                       then round((v_total + v_fixo) / (v_den - v_margem / 100), 2) end;
    v_formas := v_formas || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'forma', v_f.rotulo,
      'parcela', case when v_f.n > 1 then round(v_preco / v_f.n, 2) end,
      'taxa_pct', v_t.percentual,
      'taxa', v_t.taxa,
      'imposto', v_imposto,
      'custos', v_total,
      'lucro', v_lucro,
      'margem_pct', round(100 * v_lucro / v_preco, 1),
      'preco_para_lucro_igual_ao_pix', case when v_f.forma <> 'pix' and v_den > 0
                                            then round((v_ref_pix + v_fixo) / v_den, 2) end,
      'preco_para_margem_desejada', v_sugerido)));
  end loop;

  if v_lucro_pix < 0 then
    v_avisos := v_avisos || format('Nesse preço ela tem prejuízo até no Pix (R$ %s).', v_lucro_pix);
  end if;
  if v_cfg.observacoes ilike '%confirmar%' then
    v_avisos := v_avisos || 'Taxas do cartão: tabela pública da InfinitePay (Plano Inicial, 1 dia útil, Visa/Master). Se o plano dela for outro, ajuste com configurar_financeiro.'::text;
  end if;

  select format('Cobrando R$ %s: no Pix ela fica com R$ %s (%s%%); no %s, R$ %s (%s%%).',
                v_preco, v_lucro_pix, round(100 * v_lucro_pix / v_preco, 1),
                lower(v_formas -> -1 ->> 'forma'),
                (v_formas -> -1 ->> 'lucro'), (v_formas -> -1 ->> 'margem_pct'))
    into v_resumo;

  return jsonb_strip_nulls(jsonb_build_object(
    'procedimento', v_proc.nome,
    'preco', v_preco,
    'origem_do_preco', v_origem,
    'preco_normal', case when v_origem <> 'catálogo' then v_proc.preco end,
    'campanha', case when v_camp.id is not null then v_camp.nome end,
    'imposto_pct', v_imp,
    'custos', jsonb_build_object('itens', v_custos, 'total', v_total),
    'margem_desejada_pct', v_margem,
    'formas', v_formas,
    'resumo', v_resumo,
    'nota', 'Lucro = valor cobrado - taxa da maquininha - imposto sobre o valor cobrado - custos. '
            || 'Não entra a hora clínica nem despesas fixas do mês, só os custos informados.',
    'avisos', to_jsonb(v_avisos)));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.campanha_periodo(public.campanhas),
  public.campanha_situacao(public.campanhas),
  public.campanha_na_data(date),
  public.campanha_localizar(text),
  public.campanha_mapa_precos(uuid),
  public.campanha_resumo(uuid),
  public.campanha_json(public.campanhas, boolean),
  public.mcp_salvar_campanha(jsonb, text),
  public.mcp_ver_campanhas(jsonb, text),
  public.mcp_calcular_preco(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.campanha_periodo(public.campanhas),
  public.campanha_situacao(public.campanhas),
  public.campanha_na_data(date),
  public.campanha_localizar(text),
  public.campanha_mapa_precos(uuid),
  public.campanha_resumo(uuid),
  public.campanha_json(public.campanhas, boolean),
  public.mcp_salvar_campanha(jsonb, text),
  public.mcp_ver_campanhas(jsonb, text),
  public.mcp_calcular_preco(jsonb, text)
  to service_role;
