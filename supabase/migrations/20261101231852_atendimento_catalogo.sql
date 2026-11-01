-- =====================================================================
-- Etapa 1: atendimento ligado ao catálogo e ao odontograma; ficha completa.
--
--   * cada procedimento do atendimento aponta para o catálogo (por código
--     ou pelo nome dito); a resina é escolhida pelo número de faces e a
--     extração pelo tipo de dente;
--   * procedimento concluído num dente vira marca "realizado" no
--     odontograma (restauração, canal, coroa, implante, extração = ausente);
--   * a correção de um atendimento anula as marcas que ele tinha gerado e
--     cria as novas;
--   * a ficha do paciente passa a trazer anamnese e odontograma.
-- =====================================================================

alter table public.atendimento_itens
  add column procedimento_id uuid references public.procedimentos (id);
create index atendimento_itens_procedimento_idx on public.atendimento_itens (procedimento_id);

-- Resumo do odontograma: extração aparece como "Extraído em ...".
create or replace function public.odontograma_json(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with m as (
    select a.*, c.nome as cond_nome, c.ordem as cond_ordem, p.codigo as proc_codigo, p.nome as proc_nome
      from public.odontograma_ativas(p_paciente) a
      join public.odontograma_condicoes c on c.codigo = a.condicao
      left join public.procedimentos p on p.id = a.procedimento_id
  ),
  por_dente as (
    select m.dente,
           jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'id', m.id,
             'condicao', m.condicao,
             'faces', m.faces,
             'camada', m.camada,
             'detalhe', m.detalhe,
             'procedimento', m.proc_codigo,
             'data', m.data)) order by (m.camada = 'planejado'), m.cond_ordem, m.registrado_em) as marcas,
           string_agg(
             case when m.camada = 'planejado' then 'planejado: ' || coalesce(m.proc_nome, m.cond_nome)
                  when m.camada = 'realizado' and m.condicao = 'ausente' then 'Extraído'
                  else m.cond_nome end
             || coalesce(' ' || m.faces, '')
             || coalesce(' (' || m.detalhe || ')', '')
             || case when m.camada = 'realizado' and m.condicao = 'ausente' then ' em ' || to_char(m.data, 'DD/MM/YYYY')
                     when m.camada = 'realizado' then ' — feito em ' || to_char(m.data, 'DD/MM/YYYY')
                     else '' end,
             '; ' order by (m.camada = 'planejado'), m.cond_ordem, m.registrado_em) as resumo
      from m
     group by m.dente
  )
  select coalesce(jsonb_agg(jsonb_build_object('dente', d.dente, 'resumo', d.resumo, 'marcas', d.marcas)
                            order by d.dente), '[]'::jsonb)
    from por_dente d
$$;

create or replace function public.atendimento_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', a.id,
    'data', a.data,
    'hora_inicio', to_char(a.hora_inicio, 'HH24:MI'),
    'hora_fim', to_char(a.hora_fim, 'HH24:MI'),
    'procedimentos', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'procedimento', i.procedimento, 'codigo', p.codigo, 'dente', i.dente, 'faces', i.faces,
               'regiao', i.regiao, 'etapa', i.etapa, 'observacao', i.observacao))
             order by i.ordem), '[]'::jsonb)
      from public.atendimento_itens i
      left join public.procedimentos p on p.id = i.procedimento_id
      where i.atendimento_id = a.id),
    'evolucao', a.evolucao,
    'anestesia', nullif(a.anestesia, '[]'::jsonb),
    'materiais', nullif(a.materiais, '[]'::jsonb),
    'intercorrencias', a.intercorrencias,
    'orientacoes', a.orientacoes,
    'proxima_etapa', a.proxima_etapa,
    'retorno_previsto', a.retorno_previsto,
    'profissional', a.profissional || ' (' || a.cro || ')',
    'registrado_em', to_char(a.registrado_em at time zone public.fuso(), 'YYYY-MM-DD HH24:MI'),
    'corrige_atendimento_id', a.corrige_atendimento_id,
    'motivo_correcao', a.motivo_correcao,
    'corrigido_por', (
      select jsonb_agg(c.id order by c.registrado_em)
      from public.atendimentos c where c.corrige_atendimento_id = a.id)
  ))
  from public.atendimentos a
  where a.id = p_id
$$;

create or replace function public.paciente_ficha(p_id uuid, p_qtd_atendimentos int default 10)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', p.id,
    'ficha', p.ficha,
    'nome', p.nome,
    'nome_social', p.nome_social,
    'apelido', p.apelido,
    'data_nascimento', p.data_nascimento,
    'idade', public.idade(p.data_nascimento),
    'sexo', p.sexo,
    'cpf', p.cpf,
    'rg', p.rg,
    'telefone', p.telefone,
    'whatsapp', p.whatsapp,
    'email', p.email,
    'endereco', p.endereco,
    'profissao', p.profissao,
    'estado_civil', p.estado_civil,
    'contato_emergencia', p.contato_emergencia,
    'origem', p.origem,
    'convenio', p.convenio,
    'alertas_saude', p.alertas_saude,
    'observacoes', p.observacoes,
    'consentimento_lgpd_em', p.consentimento_lgpd_em,
    'consentimento_imagem_em', p.consentimento_imagem_em,
    'arquivado_em', p.arquivado_em,
    'cadastrado_em', to_char(p.criado_em at time zone public.fuso(), 'YYYY-MM-DD'),
    'responsaveis', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'nome', r.nome, 'cpf', r.cpf, 'parentesco', r.parentesco,
               'telefone', r.telefone, 'e_pagador', r.e_pagador)) order by r.criado_em)
      from public.responsaveis r where r.paciente_id = p.id),
    'anamnese', public.anamnese_json(p.id),
    'odontograma', nullif(public.odontograma_json(p.id), '[]'::jsonb),
    'total_atendimentos', (select count(*) from public.atendimentos a where a.paciente_id = p.id),
    'ultimos_atendimentos', (
      select coalesce(jsonb_agg(public.atendimento_json(x.id) order by x.data desc, x.registrado_em desc), '[]'::jsonb)
      from (select a.id, a.data, a.registrado_em
              from public.atendimentos a
             where a.paciente_id = p.id
             order by a.data desc, a.registrado_em desc
             limit greatest(1, least(coalesce(p_qtd_atendimentos, 10), 50))) x)
  ))
  from public.pacientes p
  where p.id = p_id
$$;

-- ---------------------------------------------------------------------
-- registrar_atendimento (substitui a versão da etapa 0)
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_atendimento(
  p_dados jsonb,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cfg public.configuracao;
  v_pac public.pacientes;
  v_data date;
  v_hi time;
  v_hf time;
  v_id uuid;
  v_item jsonb;
  v_ordem int := 0;
  v_dente smallint;
  v_faces text;
  v_regiao text;
  v_etapa text;
  v_corrige uuid;
  v_corrige_pac uuid;
  v_motivo text := nullif(btrim(p_dados ->> 'motivo_correcao'), '');
  v_retorno date;
  v_anestesia jsonb := coalesce(p_dados -> 'anestesia', '[]'::jsonb);
  v_materiais jsonb := coalesce(p_dados -> 'materiais', '[]'::jsonb);
  v_tubetes numeric := 0;
  v_avisos text[] := '{}';
  v_proc public.procedimentos;
  v_proc_id uuid;
  v_aviso text;
  v_nome_item text;
  v_cond public.odontograma_condicoes;
  v_dentes_tocados smallint[] := '{}';
  v_anuladas int := 0;
  v_marcas int := 0;
  v_invasivo boolean := false;
begin
  perform public.iniciar_solicitacao('registrar_atendimento', p_dados, p_texto_original);

  select * into v_cfg from public.configuracao;
  if not found then
    raise exception 'Configuração do consultório ausente (nome da dentista e CRO). Avise o Guilherme.';
  end if;

  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');

  if coalesce(btrim(p_dados ->> 'evolucao'), '') = '' then
    raise exception 'Escreva a evolução clínica do atendimento (campo evolucao).';
  end if;

  -- Data e horário (fuso do consultório)
  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data do atendimento'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data do atendimento (%) está no futuro. Para marcar consulta, use a agenda.', v_data;
  end if;
  if v_data < public.hoje() - 7 then
    v_avisos := array_append(v_avisos, format('Registro retroativo: atendimento de %s gravado em %s.', v_data, public.hoje()));
  end if;
  begin
    v_hi := nullif(btrim(p_dados ->> 'hora_inicio'), '')::time;
    v_hf := nullif(btrim(p_dados ->> 'hora_fim'), '')::time;
  exception when others then
    raise exception 'Horário inválido: use HH:MM (ex.: 14:30).';
  end;
  if v_hi is not null and v_hf is not null and v_hf < v_hi then
    raise exception 'A hora de fim (%) é anterior à de início (%).', v_hf, v_hi;
  end if;

  -- Correção de um atendimento anterior
  if nullif(p_dados ->> 'corrige_atendimento_id', '') is not null then
    begin
      v_corrige := (p_dados ->> 'corrige_atendimento_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'corrige_atendimento_id inválido.';
    end;
    select paciente_id into v_corrige_pac from public.atendimentos where id = v_corrige;
    if v_corrige_pac is null then
      raise exception 'O atendimento a corrigir não foi encontrado.';
    end if;
    if v_corrige_pac <> v_pac.id then
      raise exception 'O atendimento a corrigir é de outro paciente.';
    end if;
    if v_motivo is null then
      raise exception 'Informe o motivo da correção (motivo_correcao).';
    end if;
  elsif v_motivo is not null then
    raise exception 'motivo_correcao só vale junto com corrige_atendimento_id.';
  end if;

  -- Retorno
  v_retorno := public.ler_data(p_dados ->> 'retorno_previsto', 'Data de retorno');
  if v_retorno is null and nullif(p_dados ->> 'retorno_em_dias', '') is not null then
    v_retorno := v_data + (p_dados ->> 'retorno_em_dias')::int;
  end if;
  if v_retorno is not null and v_retorno < v_data then
    raise exception 'A data de retorno (%) é anterior ao atendimento.', v_retorno;
  end if;

  -- Anestesia e materiais
  if jsonb_typeof(v_anestesia) <> 'array' then
    raise exception 'anestesia deve ser uma lista de {anestesico, vasoconstritor, tubetes, tecnica}.';
  end if;
  for v_item in select * from jsonb_array_elements(v_anestesia) loop
    if coalesce(btrim(v_item ->> 'anestesico'), '') = '' then
      raise exception 'Informe o nome do anestésico (ex.: articaína 4%%).';
    end if;
    if v_item ? 'tubetes' and jsonb_typeof(v_item -> 'tubetes') <> 'number' then
      raise exception 'O número de tubetes deve ser um número.';
    end if;
    if coalesce((v_item ->> 'tubetes')::numeric, 0) not between 0 and 20 then
      raise exception 'Número de tubetes fora do esperado: %.', v_item ->> 'tubetes';
    end if;
    v_tubetes := v_tubetes + coalesce((v_item ->> 'tubetes')::numeric, 0);
  end loop;
  if v_tubetes > 7 then
    v_avisos := array_append(v_avisos, format('Foram registrados %s tubetes; confira se o número está correto.', v_tubetes));
  end if;
  if jsonb_typeof(v_materiais) <> 'array' then
    raise exception 'materiais deve ser uma lista de {material, quantidade, unidade, detalhe}.';
  end if;

  insert into public.atendimentos (
    paciente_id, data, hora_inicio, hora_fim, evolucao, anestesia, materiais,
    intercorrencias, orientacoes, proxima_etapa, retorno_previsto,
    corrige_atendimento_id, motivo_correcao, profissional, cro, solicitacao_id)
  values (
    v_pac.id, v_data, v_hi, v_hf, btrim(p_dados ->> 'evolucao'), v_anestesia, v_materiais,
    nullif(btrim(p_dados ->> 'intercorrencias'), ''),
    nullif(btrim(p_dados ->> 'orientacoes'), ''),
    nullif(btrim(p_dados ->> 'proxima_etapa'), ''),
    v_retorno,
    v_corrige, v_motivo, v_cfg.dentista_nome, v_cfg.cro,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  -- A correção substitui o atendimento original: as marcas de odontograma
  -- que ele gerou deixam de valer e as do registro corrigido entram abaixo.
  if v_corrige is not null then
    v_anuladas := public.odontograma_anular(v_pac.id,
      coalesce((select array_agg(o.id) from public.odontograma_validas(v_pac.id) o
                 where o.atendimento_id = v_corrige), '{}'),
      'Correção do atendimento: ' || v_motivo, v_data);
  end if;

  -- Procedimentos
  if p_dados ? 'procedimentos' and jsonb_typeof(p_dados -> 'procedimentos') <> 'array' then
    raise exception 'procedimentos deve ser uma lista.';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'procedimentos', '[]'::jsonb)) loop
    v_ordem := v_ordem + 1;
    if coalesce(btrim(v_item ->> 'procedimento'), '') = '' and coalesce(btrim(v_item ->> 'procedimento_codigo'), '') = '' then
      raise exception 'Procedimento % sem descrição nem código do catálogo.', v_ordem;
    end if;
    v_dente := public.ler_dente(v_item ->> 'dente');
    v_faces := public.normalizar_faces(v_dente, v_item ->> 'faces');
    if v_faces is not null and v_dente is null then
      raise exception 'Faces informadas sem dente no procedimento %.', v_ordem;
    end if;
    v_regiao := public.normalizar_regiao(v_item ->> 'regiao');
    v_etapa := coalesce(nullif(public.normalizar(v_item ->> 'etapa'), ''), 'concluido');
    if v_etapa not in ('concluido', 'parcial') then
      raise exception 'Etapa "%" inválida: use concluido ou parcial.', v_item ->> 'etapa';
    end if;

    -- Catálogo
    select e.proc_id, e.aviso into v_proc_id, v_aviso
      from public.escolher_procedimento(v_item ->> 'procedimento_codigo', v_item ->> 'procedimento',
                                        null, v_dente, length(v_faces)) e;
    v_proc := null;
    if v_proc_id is not null then
      select * into v_proc from public.procedimentos where id = v_proc_id;
    else
      v_avisos := array_append(v_avisos, format(
        '"%s" não está no catálogo: ficou registrado só como texto (sem preço nem odontograma).', v_item ->> 'procedimento'));
    end if;
    if v_aviso is not null then
      v_avisos := array_append(v_avisos, v_aviso);
    end if;
    if v_proc.id is not null and v_proc.aplica_a in ('dente', 'dente_faces') and v_dente is null then
      v_avisos := array_append(v_avisos, format('Faltou o dente em "%s".', v_proc.nome));
    end if;
    if v_proc.categoria in ('cirurgia', 'implante', 'endodontia', 'periodontia') then
      v_invasivo := true;
    end if;

    v_nome_item := coalesce(nullif(btrim(v_item ->> 'procedimento'), ''), v_proc.nome);
    insert into public.atendimento_itens (atendimento_id, ordem, procedimento, procedimento_id, dente, faces,
                                          regiao, etapa, observacao)
    values (v_id, v_ordem, v_nome_item, v_proc.id, v_dente, v_faces, v_regiao, v_etapa,
            nullif(btrim(v_item ->> 'observacao'), ''));

    -- Odontograma: procedimento concluído no dente
    if v_etapa = 'concluido' and v_dente is not null and v_proc.condicao_resultante is not null then
      select * into v_cond from public.odontograma_condicoes where codigo = v_proc.condicao_resultante;
      perform public.odontograma_marcar(
        v_pac.id, v_dente, case when v_cond.usa_faces then v_faces end, v_cond.codigo, 'realizado',
        v_proc.detalhe_resultante, v_proc.id, v_id, 'atendimento', v_data);
      v_marcas := v_marcas + 1;
      v_dentes_tocados := array_append(v_dentes_tocados, v_dente);
    end if;
  end loop;

  if jsonb_array_length(v_pac.alertas_saude) > 0 then
    v_avisos := array_append(v_avisos, format('Alertas de saúde de %s: %s.', v_pac.nome,
      (select string_agg(a ->> 'descricao', '; ') from jsonb_array_elements(v_pac.alertas_saude) a)));
  end if;
  if v_invasivo and not exists (select 1 from public.anamneses where paciente_id = v_pac.id) then
    v_avisos := array_append(v_avisos, 'Procedimento invasivo em paciente sem anamnese registrada: registre a anamnese.');
  end if;
  if v_anuladas > 0 then
    v_avisos := array_append(v_avisos, format('Odontograma: %s marca(s) do atendimento corrigido foram substituídas.', v_anuladas));
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'atendimento', public.atendimento_json(v_id),
    'odontograma_atualizado', (
      select jsonb_agg(x) from jsonb_array_elements(public.odontograma_json(v_pac.id)) x
       where (x ->> 'dente')::smallint = any (v_dentes_tocados)),
    'avisos', to_jsonb(v_avisos));
end
$$;
