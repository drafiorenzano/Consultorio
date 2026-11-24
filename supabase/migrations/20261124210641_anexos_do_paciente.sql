-- =====================================================================
-- Exames e arquivos na ficha do paciente (radiografia, tomografia, exame de
-- sangue, foto, laudo...).
--
-- O arquivo vai para o bucket privado "documentos", em
-- anexos/<paciente>/<anexo>.<pdf|jpg|png>, por um link de envio que a API do
-- site gera. Depois do envio, mcp_registrar_anexo grava o registro aqui.
-- Faz parte do prontuário: nada se apaga. Anexo errado sai da ficha com
-- "retirar" (registro novo com motivo); o arquivo continua guardado.
-- =====================================================================

create table public.anexos (
  id uuid primary key,
  paciente_id uuid not null references public.pacientes (id),
  tipo text not null check (tipo in ('radiografia', 'tomografia', 'exame', 'foto', 'laudo', 'documento', 'outro')),
  titulo text not null check (length(btrim(titulo)) between 1 and 120),
  data_documento date,
  observacao text check (observacao is null or length(observacao) <= 1000),
  caminho text not null unique check (caminho ~ '^anexos/[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|jpg|png)$'),
  nome_arquivo text check (nome_arquivo is null or length(nome_arquivo) <= 200),
  tipo_arquivo text not null check (tipo_arquivo in ('application/pdf', 'image/jpeg', 'image/png')),
  tamanho_bytes int not null check (tamanho_bytes > 0 and tamanho_bytes <= 20971520),
  enviado_por text not null default 'site',
  solicitacao_id uuid references public.solicitacoes (id),
  criado_em timestamptz not null default now(),
  check (split_part(caminho, '/', 2) = paciente_id::text and split_part(split_part(caminho, '/', 3), '.', 1) = id::text)
);
comment on table public.anexos is
  'Exames e arquivos na ficha do paciente (bucket privado "documentos", pasta anexos/). Só inclusão.';
create index anexos_paciente_idx on public.anexos (paciente_id, criado_em desc);
create index anexos_solicitacao_idx on public.anexos (solicitacao_id);

create table public.anexos_retirados (
  anexo_id uuid primary key references public.anexos (id),
  motivo text not null check (length(btrim(motivo)) >= 3),
  solicitacao_id uuid references public.solicitacoes (id),
  retirado_em timestamptz not null default now()
);
comment on table public.anexos_retirados is 'Anexos tirados da ficha (por engano, paciente errado). Só inclusão.';
create index anexos_retirados_solicitacao_idx on public.anexos_retirados (solicitacao_id);

create trigger anexos_so_inclusao before update or delete on public.anexos
  for each row execute function public.bloquear_alteracao();
create trigger anexos_sem_truncate before truncate on public.anexos
  for each statement execute function public.bloquear_alteracao();
create trigger anexos_auditoria after insert on public.anexos
  for each row execute function public.registrar_auditoria();
create trigger anexos_retirados_so_inclusao before update or delete on public.anexos_retirados
  for each row execute function public.bloquear_alteracao();
create trigger anexos_retirados_sem_truncate before truncate on public.anexos_retirados
  for each statement execute function public.bloquear_alteracao();
create trigger anexos_retirados_auditoria after insert on public.anexos_retirados
  for each row execute function public.registrar_auditoria();

alter table public.anexos enable row level security;
alter table public.anexos_retirados enable row level security;
revoke all on public.anexos, public.anexos_retirados from anon, authenticated;

create or replace function public.anexo_rotulo(p_tipo text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_tipo
    when 'radiografia' then 'Radiografia'
    when 'tomografia' then 'Tomografia'
    when 'exame' then 'Exame de laboratório'
    when 'foto' then 'Foto'
    when 'laudo' then 'Laudo ou relatório'
    when 'documento' then 'Documento'
    else 'Outro' end
$$;

-- Registrar (padrão) ou retirar um anexo. O arquivo já está no Storage: a API
-- do site confere que ele existe e manda tamanho e tipo de verdade.
create or replace function public.mcp_registrar_anexo(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_acao text := coalesce(nullif(public.normalizar(p_dados ->> 'acao'), ''), 'registrar');
  v_pac public.pacientes;
  v_anexo public.anexos;
  v_tipo text := coalesce(nullif(btrim(p_dados ->> 'tipo'), ''), 'exame');
  v_titulo text;
  v_data date;
  v_avisos text[] := '{}';
begin
  perform public.iniciar_solicitacao('registrar_anexo', p_dados, p_texto_original);
  if v_acao not in ('registrar', 'retirar') then
    raise exception 'Ação "%" desconhecida. Use registrar ou retirar.', p_dados ->> 'acao';
  end if;

  if v_acao = 'retirar' then
    select * into v_anexo from public.anexos where id = (p_dados ->> 'anexo_id')::uuid;
    if not found then raise exception 'Anexo não encontrado.'; end if;
    if exists (select 1 from public.anexos_retirados where anexo_id = v_anexo.id) then
      return jsonb_build_object('status', 'sem_mudanca', 'mensagem', 'Esse anexo já tinha saído da ficha.');
    end if;
    if length(btrim(coalesce(p_dados ->> 'motivo', ''))) < 3 then
      raise exception 'Diga o motivo para tirar o anexo da ficha (ex.: paciente errado).';
    end if;
    insert into public.anexos_retirados (anexo_id, motivo, solicitacao_id)
    values (v_anexo.id, btrim(p_dados ->> 'motivo'), public.fin_solicitacao());
    return jsonb_build_object('status', 'ok', 'anexo_id', v_anexo.id,
      'mensagem', 'Saiu da ficha. O arquivo continua guardado (prontuário não se apaga).');
  end if;

  select * into v_pac from public.pacientes where id = (p_dados ->> 'paciente_id')::uuid;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_pac.arquivado_em is not null then
    v_avisos := v_avisos || 'A ficha desse paciente está arquivada.';
  end if;
  if v_tipo not in ('radiografia', 'tomografia', 'exame', 'foto', 'laudo', 'documento', 'outro') then
    raise exception 'Tipo "%" desconhecido. Use radiografia, tomografia, exame, foto, laudo, documento ou outro.', v_tipo;
  end if;
  v_data := nullif(p_dados ->> 'data_documento', '')::date;
  if v_data > public.hoje() then
    raise exception 'A data do exame não pode estar no futuro.';
  end if;
  v_titulo := left(coalesce(nullif(btrim(p_dados ->> 'titulo'), ''),
                            public.anexo_rotulo(v_tipo) || coalesce(' de ' || to_char(v_data, 'DD/MM/YYYY'), '')), 120);

  insert into public.anexos (id, paciente_id, tipo, titulo, data_documento, observacao, caminho, nome_arquivo,
                             tipo_arquivo, tamanho_bytes, enviado_por, solicitacao_id)
  values ((p_dados ->> 'anexo_id')::uuid, v_pac.id, v_tipo, v_titulo, v_data,
          nullif(btrim(p_dados ->> 'observacao'), ''), p_dados ->> 'caminho',
          left(nullif(btrim(p_dados ->> 'nome_arquivo'), ''), 200), p_dados ->> 'tipo_arquivo',
          (p_dados ->> 'tamanho_bytes')::int,
          coalesce(nullif(current_setting('app.cliente', true), ''), 'mcp'), public.fin_solicitacao())
  returning * into v_anexo;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'anexo', jsonb_build_object('id', v_anexo.id, 'titulo', v_anexo.titulo, 'tipo', public.anexo_rotulo(v_anexo.tipo),
                                'paciente', v_pac.nome),
    'avisos', case when cardinality(v_avisos) > 0 then to_jsonb(v_avisos) end));
end
$$;

-- Anexos da ficha (sem os retirados). "arquivo" vira link temporário na API.
create or replace function public.painel_paciente_anexos(p_params jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('anexos', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', a.id, 'tipo', a.tipo, 'rotulo', public.anexo_rotulo(a.tipo), 'titulo', a.titulo,
           'data', a.data_documento, 'observacao', a.observacao, 'arquivo', a.caminho,
           'tipo_arquivo', a.tipo_arquivo, 'tamanho', a.tamanho_bytes, 'nome_arquivo', a.nome_arquivo,
           'enviado_em', (a.criado_em at time zone public.fuso())::date))
           order by coalesce(a.data_documento, (a.criado_em at time zone public.fuso())::date) desc, a.criado_em desc),
         '[]'::jsonb))
    from public.anexos a
   where a.paciente_id = (p_params ->> 'id')::uuid
     and not exists (select 1 from public.anexos_retirados r where r.anexo_id = a.id)
$$;

-- O site grava anexos pela mesma regra (painel_gravar, tipos "anexo" e "retirar_anexo").
create or replace function public.painel_gravar(p_usuario uuid, p_sessao uuid, p_acao text, p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_texto text := left(coalesce(nullif(btrim(p_dados ->> 'texto_original'), ''), 'Lançado pelo site'), 500);
  v_mov jsonb;
begin
  if p_acao not in ('pagamento', 'estornar_pagamento', 'despesa', 'estornar_despesa', 'estoque', 'anexo',
                    'retirar_anexo') then
    raise exception 'Lançamento "%" desconhecido.', p_acao;
  end if;
  if not public.painel_autorizar(p_usuario, p_sessao, 'gravar:' || p_acao, null) then
    return jsonb_build_object('status', 'sessao_expirada');
  end if;
  perform set_config('app.cliente', 'site', true);
  perform set_config('app.usuario', p_usuario::text, true);

  if p_acao = 'pagamento' then
    return public.mcp_registrar_pagamento(
      jsonb_build_object('acao', 'pagamento') || public.painel_campos(p_dados, array[
        'paciente_id', 'valor', 'forma', 'data', 'parcelas_cartao', 'descricao', 'orcamento_id',
        'confirmar_duplicado', 'quitar_parcela']),
      v_texto);
  elsif p_acao = 'estornar_pagamento' then
    return public.mcp_registrar_pagamento(
      jsonb_build_object('acao', 'estornar') || public.painel_campos(p_dados, array['recebimento_id', 'motivo']),
      v_texto);
  elsif p_acao = 'despesa' then
    return public.mcp_registrar_despesa(
      jsonb_build_object('acao', 'registrar') || public.painel_campos(p_dados, array[
        'valor', 'categoria', 'data', 'descricao', 'fornecedor', 'forma', 'competencia', 'paciente_id',
        'confirmar_duplicada']),
      v_texto);
  elsif p_acao = 'estornar_despesa' then
    return public.mcp_registrar_despesa(
      jsonb_build_object('acao', 'estornar') || public.painel_campos(p_dados, array['despesa_id', 'motivo']),
      v_texto);
  elsif p_acao = 'anexo' then
    return public.mcp_registrar_anexo(
      jsonb_build_object('acao', 'registrar') || public.painel_campos(p_dados, array[
        'anexo_id', 'paciente_id', 'tipo', 'titulo', 'data_documento', 'observacao', 'caminho', 'nome_arquivo',
        'tipo_arquivo', 'tamanho_bytes']),
      v_texto);
  elsif p_acao = 'retirar_anexo' then
    return public.mcp_registrar_anexo(
      jsonb_build_object('acao', 'retirar') || public.painel_campos(p_dados, array['anexo_id', 'motivo']),
      v_texto);
  end if;

  -- estoque: um movimento por vez (uso, perda, vencido, contagem, entrada)
  v_mov := public.painel_campos(p_dados, array['tipo', 'material', 'quantidade', 'unidade', 'motivo', 'preco_unitario']);
  if coalesce(v_mov ->> 'tipo', '') not in ('uso', 'perda', 'vencido', 'contagem', 'entrada') then
    raise exception 'Escolha o tipo: uso, perda, vencido, contagem ou entrada.';
  end if;
  return public.mcp_movimentar_estoque(
    jsonb_strip_nulls(jsonb_build_object('data', p_dados ->> 'data', 'movimentos', jsonb_build_array(v_mov))),
    v_texto);
end
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
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_configuracoes()
    else null
  end;
end
$$;

revoke execute on function
  public.anexo_rotulo(text), public.mcp_registrar_anexo(jsonb, text), public.painel_paciente_anexos(jsonb),
  public.painel_gravar(uuid, uuid, text, jsonb), public.painel(text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.anexo_rotulo(text), public.mcp_registrar_anexo(jsonb, text), public.painel_paciente_anexos(jsonb),
  public.painel_gravar(uuid, uuid, text, jsonb), public.painel(text, jsonb)
  to service_role;
