-- =====================================================================
-- Ferramentas da IA (etapa 0): buscar paciente, cadastrar paciente,
-- registrar atendimento.
--
-- Cada ferramenta é uma função que roda numa transação só: valida, grava,
-- abre a solicitação (texto original) e deixa a auditoria para os gatilhos.
-- O servidor MCP só traduz a chamada da IA para estas funções.
-- Mensagens de erro são escritas para a IA repassar à dentista.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Representações em JSON
-- ---------------------------------------------------------------------

create or replace function public.idade(p_nascimento date)
returns int
language sql
stable
set search_path = ''
as $$
  select case when p_nascimento is null then null
              else extract(year from age(public.hoje(), p_nascimento))::int end
$$;

create or replace function public.paciente_resumo(p public.pacientes)
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
    'telefone', p.telefone,
    'alertas_saude', p.alertas_saude,
    'arquivado', p.arquivado_em is not null,
    'ultimo_atendimento', (
      select jsonb_strip_nulls(jsonb_build_object(
        'data', a.data, 'proxima_etapa', a.proxima_etapa, 'retorno_previsto', a.retorno_previsto))
      from public.atendimentos a
      where a.paciente_id = p.id
      order by a.data desc, a.registrado_em desc
      limit 1)
  ))
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
               'procedimento', i.procedimento, 'dente', i.dente, 'faces', i.faces,
               'regiao', i.regiao, 'etapa', i.etapa, 'observacao', i.observacao))
             order by i.ordem), '[]'::jsonb)
      from public.atendimento_itens i where i.atendimento_id = a.id),
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
-- Registro de falha (chamada que deu erro e foi desfeita)
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_falha(
  p_ferramenta text,
  p_argumentos jsonb,
  p_texto_original text,
  p_erro text)
returns void
language sql
set search_path = ''
as $$
  insert into public.solicitacoes (ferramenta, argumentos, texto_original, sucesso, erro, usuario)
  values (p_ferramenta, coalesce(p_argumentos, '{}'::jsonb), nullif(btrim(p_texto_original), ''),
          false, left(p_erro, 2000), auth.uid())
$$;

-- ---------------------------------------------------------------------
-- buscar_paciente
-- ---------------------------------------------------------------------
create or replace function public.mcp_buscar_paciente(
  p_busca text default null,
  p_paciente_id uuid default null,
  p_texto_original text default null,
  p_incluir_arquivados boolean default false,
  p_limite int default 5)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_termo text;
  v_dig text;
  v_ids uuid[];
  v_lista jsonb;
begin
  perform public.iniciar_solicitacao('buscar_paciente',
    jsonb_strip_nulls(jsonb_build_object('busca', p_busca, 'paciente_id', p_paciente_id,
                                         'incluir_arquivados', p_incluir_arquivados)),
    p_texto_original);

  if p_paciente_id is not null then
    if not exists (select 1 from public.pacientes where id = p_paciente_id) then
      raise exception 'Paciente não encontrado (id %). Busque pelo nome.', p_paciente_id;
    end if;
    return jsonb_build_object('encontrados', 1, 'paciente', public.paciente_ficha(p_paciente_id));
  end if;

  if coalesce(btrim(p_busca), '') = '' then
    raise exception 'Informe nome, apelido, CPF, telefone ou número da ficha para buscar.';
  end if;

  v_termo := public.normalizar(p_busca);
  -- Busca por número (CPF, telefone, ficha) só quando o termo é numérico.
  if regexp_replace(v_termo, '[0-9 .()/+-]', '', 'g') = '' then
    v_dig := public.somente_digitos(p_busca);
  end if;

  with candidatos as (
    select p.id,
      case
        when v_dig is not null then greatest(
          case when length(v_dig) = 11 and p.cpf = v_dig then 1.0 else 0 end,
          case when length(v_dig) >= 8 and p.telefone like '%' || v_dig then 0.95 else 0 end,
          case when length(v_dig) <= 7 and p.ficha::text = v_dig then 0.9 else 0 end)
        else greatest(
          extensions.word_similarity(v_termo, public.normalizar(p.nome)),
          extensions.word_similarity(v_termo, public.normalizar(p.nome_social)),
          extensions.word_similarity(v_termo, public.normalizar(p.apelido)),
          -- todas as palavras ditas aparecem no nome (ex.: "Mariana Lima" para "Mariana Souza Lima")
          coalesce((select min(greatest(
                      extensions.word_similarity(t, public.normalizar(p.nome)),
                      extensions.word_similarity(t, public.normalizar(p.apelido))))
                    from unnest(string_to_array(v_termo, ' ')) t
                    where length(t) >= 2), 0) * 0.95)
      end as score
    from public.pacientes p
    where p_incluir_arquivados or p.arquivado_em is null
  )
  select coalesce(array_agg(c.id order by c.score desc, c.id), '{}')
    into v_ids
    from (select id, score from candidatos
           where score >= 0.5
           order by score desc, id
           limit greatest(1, least(coalesce(p_limite, 5), 20))) c;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object(
      'encontrados', 0,
      'mensagem', format('Nenhum paciente encontrado para "%s". Confira a grafia ou cadastre o paciente.', p_busca));
  elsif cardinality(v_ids) = 1 then
    return jsonb_build_object('encontrados', 1, 'paciente', public.paciente_ficha(v_ids[1]));
  end if;

  select jsonb_agg(public.paciente_resumo(p) order by array_position(v_ids, p.id))
    into v_lista
    from public.pacientes p where p.id = any (v_ids);
  return jsonb_build_object(
    'encontrados', cardinality(v_ids),
    'mensagem', 'Mais de um paciente parecido. Confirme com a Dra. qual deles antes de seguir.',
    'pacientes', v_lista);
end
$$;

-- ---------------------------------------------------------------------
-- cadastrar_paciente
-- ---------------------------------------------------------------------

-- Converte a lista de alertas ditos em {tipo, descricao, registrado_em}.
create or replace function public.normalizar_alertas(p_alertas jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item jsonb;
  v_tipo text;
  v_desc text;
  v_res jsonb := '[]'::jsonb;
  v_tipos text[] := array['alergia', 'anticoagulante', 'antiagregante', 'bisfosfonato',
                          'gestacao', 'amamentacao', 'cardiopatia', 'profilaxia_antibiotica',
                          'diabetes', 'hipertensao', 'coagulopatia', 'imunossupressao',
                          'radioterapia_cabeca_pescoco', 'epilepsia', 'outro'];
begin
  if p_alertas is null or jsonb_typeof(p_alertas) = 'null' then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p_alertas) <> 'array' then
    raise exception 'alertas_saude deve ser uma lista de {tipo, descricao}.';
  end if;
  for v_item in select * from jsonb_array_elements(p_alertas) loop
    if jsonb_typeof(v_item) = 'string' then
      v_tipo := 'outro';
      v_desc := v_item #>> '{}';
    else
      v_tipo := replace(public.normalizar(v_item ->> 'tipo'), ' ', '_');
      v_desc := btrim(v_item ->> 'descricao');
    end if;
    if coalesce(v_desc, '') = '' then
      raise exception 'Cada alerta de saúde precisa de uma descrição (ex.: "alergia a dipirona").';
    end if;
    if v_tipo is null or v_tipo = '' or not (v_tipo = any (v_tipos)) then
      v_desc := coalesce(nullif(v_item ->> 'tipo', '') || ': ', '') || v_desc;
      v_tipo := 'outro';
    end if;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'tipo', v_tipo, 'descricao', v_desc, 'registrado_em', public.hoje()));
  end loop;
  return v_res;
end
$$;

-- Telefone: só dígitos, sem o 55 do país.
create or replace function public.normalizar_telefone(p_tel text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := public.somente_digitos(p_tel);
begin
  if v is null then return null; end if;
  if length(v) in (12, 13) and left(v, 2) = '55' then v := substr(v, 3); end if;
  if length(v) not between 10 and 11 then
    raise exception 'Telefone "%" incompleto: informe com DDD (ex.: 11 98765-4321).', p_tel;
  end if;
  return v;
end
$$;

create or replace function public.ler_data(p_valor text, p_campo text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_valor is null or btrim(p_valor) = '' then return null; end if;
  if p_valor !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception '% "%" inválida: use o formato AAAA-MM-DD.', p_campo, p_valor;
  end if;
  return p_valor::date;
exception
  when datetime_field_overflow or invalid_datetime_format then
    raise exception '% "%" não existe no calendário.', p_campo, p_valor;
end
$$;

create or replace function public.mcp_cadastrar_paciente(
  p_dados jsonb,
  p_texto_original text default null,
  p_confirmar_homonimo boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_nome text := btrim(regexp_replace(coalesce(p_dados ->> 'nome', ''), '\s+', ' ', 'g'));
  v_cpf text := public.somente_digitos(p_dados ->> 'cpf');
  v_tel text;
  v_nasc date;
  v_sexo text;
  v_parecidos jsonb;
  v_id uuid;
  v_resp jsonb := p_dados -> 'responsavel';
  v_resp_cpf text;
  v_avisos text[] := '{}';
  v_idade int;
  v_existente text;
begin
  perform public.iniciar_solicitacao('cadastrar_paciente',
    p_dados || jsonb_build_object('confirmar_homonimo', coalesce(p_confirmar_homonimo, false)),
    p_texto_original);

  if length(v_nome) < 3 or position(' ' in v_nome) = 0 then
    raise exception 'Informe o nome completo do paciente (nome e sobrenome).';
  end if;

  if v_cpf is not null then
    if not public.cpf_valido(v_cpf) then
      raise exception 'O CPF "%" não é válido (os dígitos verificadores não conferem). Confirme o número.', p_dados ->> 'cpf';
    end if;
    select nome || ' (ficha ' || ficha || ')' into v_existente from public.pacientes where cpf = v_cpf;
    if v_existente is not null then
      raise exception 'Já existe paciente com este CPF: %. Use buscar_paciente.', v_existente;
    end if;
  end if;

  v_tel := public.normalizar_telefone(p_dados ->> 'telefone');
  v_nasc := public.ler_data(p_dados ->> 'data_nascimento', 'Data de nascimento');
  if v_nasc is not null and v_nasc > public.hoje() then
    raise exception 'Data de nascimento no futuro: %.', v_nasc;
  end if;

  v_sexo := case public.normalizar(p_dados ->> 'sexo')
              when '' then null
              when 'f' then 'feminino' when 'feminino' then 'feminino' when 'mulher' then 'feminino'
              when 'm' then 'masculino' when 'masculino' then 'masculino' when 'homem' then 'masculino'
              when 'outro' then 'outro'
              else 'nao_informado' end;

  if not coalesce(p_confirmar_homonimo, false) then
    select jsonb_agg(public.paciente_resumo(p))
      into v_parecidos
      from public.pacientes p
     where p.arquivado_em is null
       and extensions.similarity(public.normalizar(p.nome), public.normalizar(v_nome)) >= 0.6;
    if v_parecidos is not null then
      return jsonb_build_object(
        'status', 'confirmacao_necessaria',
        'mensagem', 'Já existe paciente com nome parecido. Pergunte à Dra. se é a mesma pessoa. Se for outra, chame de novo com confirmar_homonimo = true.',
        'parecidos', v_parecidos);
    end if;
  end if;

  insert into public.pacientes (
    nome, nome_social, apelido, data_nascimento, sexo, cpf, rg, telefone, whatsapp, email,
    endereco, profissao, estado_civil, contato_emergencia, origem, convenio,
    alertas_saude, observacoes, consentimento_lgpd_em, consentimento_imagem_em)
  values (
    v_nome,
    nullif(btrim(p_dados ->> 'nome_social'), ''),
    nullif(btrim(p_dados ->> 'apelido'), ''),
    v_nasc,
    v_sexo,
    v_cpf,
    nullif(btrim(p_dados ->> 'rg'), ''),
    v_tel,
    coalesce((p_dados ->> 'whatsapp')::boolean, true),
    nullif(lower(btrim(p_dados ->> 'email')), ''),
    nullif(jsonb_strip_nulls(p_dados -> 'endereco'), '{}'::jsonb),
    nullif(btrim(p_dados ->> 'profissao'), ''),
    nullif(btrim(p_dados ->> 'estado_civil'), ''),
    nullif(jsonb_strip_nulls(p_dados -> 'contato_emergencia'), '{}'::jsonb),
    nullif(btrim(p_dados ->> 'origem'), ''),
    nullif(btrim(p_dados ->> 'convenio'), ''),
    public.normalizar_alertas(p_dados -> 'alertas_saude'),
    nullif(btrim(p_dados ->> 'observacoes'), ''),
    case when (p_dados ->> 'consentimento_lgpd')::boolean then now() end,
    case when (p_dados ->> 'consentimento_imagem')::boolean then now() end)
  returning id into v_id;

  if v_resp is not null and jsonb_typeof(v_resp) = 'object' then
    v_resp_cpf := public.somente_digitos(v_resp ->> 'cpf');
    if v_resp_cpf is not null and not public.cpf_valido(v_resp_cpf) then
      raise exception 'O CPF do responsável "%" não é válido.', v_resp ->> 'cpf';
    end if;
    if length(btrim(coalesce(v_resp ->> 'nome', ''))) < 3 then
      raise exception 'Informe o nome do responsável.';
    end if;
    insert into public.responsaveis (paciente_id, nome, cpf, parentesco, telefone, e_pagador)
    values (v_id, btrim(v_resp ->> 'nome'), v_resp_cpf, nullif(btrim(v_resp ->> 'parentesco'), ''),
            public.normalizar_telefone(v_resp ->> 'telefone'),
            coalesce((v_resp ->> 'e_pagador')::boolean, true));
  end if;

  v_idade := public.idade(v_nasc);
  if v_nasc is null then
    v_avisos := v_avisos || 'Falta a data de nascimento.';
  end if;
  if v_cpf is null then
    v_avisos := v_avisos || 'Falta o CPF (necessário para o recibo Receita Saúde).';
  end if;
  if v_tel is null then
    v_avisos := v_avisos || 'Falta o telefone.';
  end if;
  if v_idade is not null and v_idade < 18 and v_resp is null then
    v_avisos := v_avisos || 'Paciente menor de idade sem responsável legal cadastrado.';
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', public.paciente_ficha(v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- registrar_atendimento
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
  v_pac_id uuid;
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
begin
  perform public.iniciar_solicitacao('registrar_atendimento', p_dados, p_texto_original);

  select * into v_cfg from public.configuracao;
  if not found then
    raise exception 'Configuração do consultório ausente (nome da dentista e CRO). Avise o Guilherme.';
  end if;

  begin
    v_pac_id := (p_dados ->> 'paciente_id')::uuid;
  exception when invalid_text_representation then
    raise exception 'paciente_id inválido. Use buscar_paciente para obter o id.';
  end;
  select * into v_pac from public.pacientes where id = v_pac_id;
  if not found then
    raise exception 'Paciente não encontrado. Use buscar_paciente para obter o id.';
  end if;
  if v_pac.arquivado_em is not null then
    raise exception 'O paciente % está arquivado.', v_pac.nome;
  end if;

  if coalesce(btrim(p_dados ->> 'evolucao'), '') = '' then
    raise exception 'Escreva a evolução clínica do atendimento (campo evolucao).';
  end if;

  -- Data e horário (fuso do consultório)
  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data do atendimento'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data do atendimento (%) está no futuro. Para marcar consulta, use a agenda.', v_data;
  end if;
  if v_data < public.hoje() - 7 then
    v_avisos := v_avisos || format('Registro retroativo: atendimento de %s gravado em %s.', v_data, public.hoje());
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
    if v_corrige_pac <> v_pac_id then
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
    v_avisos := v_avisos || format('Foram registrados %s tubetes; confira se o número está correto.', v_tubetes);
  end if;
  if jsonb_typeof(v_materiais) <> 'array' then
    raise exception 'materiais deve ser uma lista de {material, quantidade, unidade, detalhe}.';
  end if;

  insert into public.atendimentos (
    paciente_id, data, hora_inicio, hora_fim, evolucao, anestesia, materiais,
    intercorrencias, orientacoes, proxima_etapa, retorno_previsto,
    corrige_atendimento_id, motivo_correcao, profissional, cro, solicitacao_id)
  values (
    v_pac_id, v_data, v_hi, v_hf, btrim(p_dados ->> 'evolucao'), v_anestesia, v_materiais,
    nullif(btrim(p_dados ->> 'intercorrencias'), ''),
    nullif(btrim(p_dados ->> 'orientacoes'), ''),
    nullif(btrim(p_dados ->> 'proxima_etapa'), ''),
    v_retorno,
    v_corrige, v_motivo, v_cfg.dentista_nome, v_cfg.cro,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  -- Procedimentos
  if p_dados ? 'procedimentos' and jsonb_typeof(p_dados -> 'procedimentos') <> 'array' then
    raise exception 'procedimentos deve ser uma lista.';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'procedimentos', '[]'::jsonb)) loop
    v_ordem := v_ordem + 1;
    if coalesce(btrim(v_item ->> 'procedimento'), '') = '' then
      raise exception 'Procedimento % sem descrição.', v_ordem;
    end if;
    v_dente := null;
    if nullif(v_item ->> 'dente', '') is not null then
      begin
        v_dente := (v_item ->> 'dente')::smallint;
      exception when others then
        raise exception 'Dente "%" inválido: use a numeração FDI (ex.: 36).', v_item ->> 'dente';
      end;
      if not public.dente_valido(v_dente) then
        raise exception 'Dente % não existe na numeração FDI (permanentes 11–48, decíduos 51–85).', v_dente;
      end if;
    end if;
    v_faces := public.normalizar_faces(v_dente, v_item ->> 'faces');
    if v_faces is not null and v_dente is null then
      raise exception 'Faces informadas sem dente no procedimento "%".', v_item ->> 'procedimento';
    end if;
    v_regiao := nullif(btrim(v_item ->> 'regiao'), '');
    if v_regiao is not null then
      v_regiao := case
        when upper(v_regiao) ~ '^[SQ][1-8]$' then upper(v_regiao)
        else replace(public.normalizar(v_regiao), ' ', '_') end;
      if not v_regiao = any (array['boca', 'arcada_superior', 'arcada_inferior',
                                   'Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8',
                                   'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'outra']) then
        raise exception 'Região "%" não reconhecida. Use boca, arcada_superior, arcada_inferior, Q1–Q4, S1–S6 ou outra.', v_item ->> 'regiao';
      end if;
    end if;
    v_etapa := coalesce(nullif(public.normalizar(v_item ->> 'etapa'), ''), 'concluido');
    if v_etapa not in ('concluido', 'parcial') then
      raise exception 'Etapa "%" inválida: use concluido ou parcial.', v_item ->> 'etapa';
    end if;
    insert into public.atendimento_itens (atendimento_id, ordem, procedimento, dente, faces, regiao, etapa, observacao)
    values (v_id, v_ordem, btrim(v_item ->> 'procedimento'), v_dente, v_faces, v_regiao, v_etapa,
            nullif(btrim(v_item ->> 'observacao'), ''));
  end loop;

  if jsonb_array_length(v_pac.alertas_saude) > 0 then
    v_avisos := v_avisos || format('Alertas de saúde de %s: %s.', v_pac.nome,
      (select string_agg(a ->> 'descricao', '; ') from jsonb_array_elements(v_pac.alertas_saude) a));
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'atendimento', public.atendimento_json(v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões: só o servidor MCP (service_role) chama as ferramentas.
-- ---------------------------------------------------------------------
revoke execute on function
  public.idade(date),
  public.paciente_resumo(public.pacientes),
  public.atendimento_json(uuid),
  public.paciente_ficha(uuid, int),
  public.mcp_registrar_falha(text, jsonb, text, text),
  public.mcp_buscar_paciente(text, uuid, text, boolean, int),
  public.normalizar_alertas(jsonb),
  public.mcp_cadastrar_paciente(jsonb, text, boolean),
  public.mcp_registrar_atendimento(jsonb, text)
  from public, anon, authenticated;

grant execute on function
  public.idade(date),
  public.paciente_resumo(public.pacientes),
  public.atendimento_json(uuid),
  public.paciente_ficha(uuid, int),
  public.normalizar_alertas(jsonb),
  public.mcp_registrar_falha(text, jsonb, text, text),
  public.mcp_buscar_paciente(text, uuid, text, boolean, int),
  public.mcp_cadastrar_paciente(jsonb, text, boolean),
  public.mcp_registrar_atendimento(jsonb, text)
  to service_role;
