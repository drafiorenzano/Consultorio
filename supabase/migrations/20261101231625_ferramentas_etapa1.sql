-- =====================================================================
-- Etapa 1: novas ferramentas da IA.
--   atualizar_paciente, registrar_anamnese, registrar_odontograma,
--   listar_procedimentos, salvar_procedimento
-- Mesmo padrão da etapa 0: uma função por ferramenta, numa transação só,
-- com a solicitação (texto original) aberta no início e mensagens de erro
-- para a IA repassar à dentista.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilitários comuns
-- ---------------------------------------------------------------------

-- Paciente que pode receber registros (existe e não está arquivado).
create or replace function public.obter_paciente_ativo(p_valor text)
returns public.pacientes
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
  v public.pacientes;
begin
  begin
    v_id := nullif(btrim(p_valor), '')::uuid;
  exception when invalid_text_representation then
    raise exception 'paciente_id inválido. Use buscar_paciente para obter o id.';
  end;
  if v_id is null then
    raise exception 'Informe o paciente_id (use buscar_paciente para obter o id).';
  end if;
  select * into v from public.pacientes where id = v_id;
  if not found then
    raise exception 'Paciente não encontrado. Use buscar_paciente para obter o id.';
  end if;
  if v.arquivado_em is not null then
    raise exception 'O paciente % está arquivado. Para voltar a usar, desarquive com atualizar_paciente.', v.nome;
  end if;
  return v;
end
$$;

create or replace function public.ler_dente(p_valor text)
returns smallint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v smallint;
begin
  if p_valor is null or btrim(p_valor) = '' then return null; end if;
  begin
    v := btrim(p_valor)::smallint;
  exception when others then
    raise exception 'Dente "%" inválido: use a numeração FDI (ex.: 36).', p_valor;
  end;
  if not public.dente_valido(v) then
    raise exception 'Dente % não existe na numeração FDI (permanentes 11–48, decíduos 51–85).', v;
  end if;
  return v;
end
$$;

-- Região dita -> forma canônica (boca, arcada_superior, Q1, S3...).
create or replace function public.normalizar_regiao(p_regiao text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := nullif(btrim(p_regiao), '');
begin
  if v is null then return null; end if;
  v := case when upper(v) ~ '^[SQ][1-8]$' then upper(v)
            else replace(public.normalizar(v), ' ', '_') end;
  v := case v when 'superior' then 'arcada_superior' when 'inferior' then 'arcada_inferior'
              when 'boca_toda' then 'boca' when 'toda_a_boca' then 'boca' else v end;
  if not v = any (array['boca', 'arcada_superior', 'arcada_inferior',
                        'Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8',
                        'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'outra']) then
    raise exception 'Região "%" não reconhecida. Use boca, arcada_superior, arcada_inferior, Q1–Q4, S1–S6 ou outra.', p_regiao;
  end if;
  return v;
end
$$;

create or replace function public.codigo_de(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(btrim(regexp_replace(public.normalizar(p_texto), '[^a-z0-9]+', '_', 'g'), '_'), 48)
$$;

-- Escolhe o procedimento do catálogo: pelo código, pelo nome/sinônimo
-- exato ou (no planejamento) pela condição do odontograma. Ajusta a resina
-- pelo número de faces e a extração pelo tipo de dente.
create or replace function public.escolher_procedimento(
  p_codigo text,
  p_texto text,
  p_condicao text,
  p_dente smallint,
  p_n_faces int,
  out proc_id uuid,
  out aviso text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v public.procedimentos;
  v_alt public.procedimentos;
  v_t text;
  v_por_condicao boolean := false;
begin
  if nullif(btrim(p_codigo), '') is not null then
    select * into v from public.procedimentos where codigo = public.codigo_de(p_codigo);
    if not found then
      raise exception 'Procedimento "%" não está no catálogo. Use listar_procedimentos para ver os códigos.', p_codigo;
    end if;
    if not v.ativo then
      raise exception 'O procedimento "%" está desativado no catálogo.', v.nome;
    end if;
  elsif nullif(btrim(p_texto), '') is not null then
    v_t := public.normalizar(p_texto);
    select * into v from public.procedimentos p
     where p.ativo and (public.normalizar(p.nome) = v_t or v_t = any (p.sinonimos))
     order by (public.normalizar(p.nome) = v_t) desc, p.ordem
     limit 1;
  elsif p_condicao is not null then
    v_por_condicao := true;
    if p_condicao = 'ausente' and p_dente is not null then
      select * into v from public.procedimentos
       where ativo and codigo = case when p_dente / 10 >= 5 then 'exodontia_deciduo'
                                     when p_dente % 10 = 8 then 'exodontia_siso'
                                     else 'exodontia_permanente' end;
    elsif p_condicao = 'tratamento_canal' and p_dente is not null then
      select * into v from public.procedimentos
       where ativo and codigo = case when p_dente % 10 >= 6 then 'canal_molar'
                                     when p_dente in (14, 24) then 'canal_birradicular'
                                     else 'canal_unirradicular' end;
    else
      -- só quando a condição leva a um procedimento (ou a uma família) só
      select * into v from public.procedimentos p
       where p.ativo and p.condicao_resultante = p_condicao
       order by p.ordem limit 1;
      if found and exists (select 1 from public.procedimentos p
                            where p.ativo and p.condicao_resultante = p_condicao and p.id <> v.id
                              and (v.familia is null or p.familia is distinct from v.familia)) then
        v := null;
      end if;
    end if;
  end if;
  if v.id is null then
    return;
  end if;

  -- resina: escolhe pela quantidade de faces
  if v.familia is not null and v.faces_min is not null then
    if p_n_faces is null then
      aviso := format('Faltaram as faces da %s%s: confira.', lower(v.nome),
                      coalesce(' no dente ' || p_dente, ''));
    else
      select * into v_alt from public.procedimentos p
       where p.ativo and p.familia = v.familia and p_n_faces between p.faces_min and p.faces_max
       order by p.ordem limit 1;
      if found and v_alt.id <> v.id then
        if nullif(btrim(p_codigo), '') is not null then
          aviso := format('Troquei "%s" por "%s" (%s faces).', v.nome, v_alt.nome, p_n_faces);
        end if;
        v := v_alt;
      end if;
    end if;
  end if;

  -- extração: decíduo x permanente x siso
  if not v_por_condicao and v.condicao_resultante = 'ausente' and p_dente is not null then
    if p_dente / 10 >= 5 and v.codigo <> 'exodontia_deciduo' then
      select * into v_alt from public.procedimentos where codigo = 'exodontia_deciduo' and ativo;
      if found then v := v_alt; end if;
    elsif p_dente / 10 < 5 and v.codigo = 'exodontia_deciduo' then
      aviso := format('O dente %s é permanente, mas o procedimento é de decíduo: confira.', p_dente);
    elsif p_dente % 10 = 8 and v.codigo = 'exodontia_permanente' then
      select * into v_alt from public.procedimentos where codigo = 'exodontia_siso' and ativo;
      if found then v := v_alt; end if;
    end if;
  end if;

  proc_id := v.id;
end
$$;

-- ---------------------------------------------------------------------
-- atualizar_paciente
-- ---------------------------------------------------------------------
create or replace function public.mcp_atualizar_paciente(
  p_paciente_id uuid,
  p_dados jsonb,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old public.pacientes;
  v_new public.pacientes;
  v_patch jsonb := '{}'::jsonb;
  v_campos text[];
  v_limpar text[];
  k text;
  v_txt text;
  v_cpf text;
  v_nasc date;
  v_existente text;
  v_alertas jsonb;
  v_novos jsonb;
  v_item jsonb;
  v_termo text;
  v_n int;
  v_resp jsonb;
  v_resp_cpf text;
  v_resp_id uuid;
  v_avisos text[] := '{}';
  v_mudou_resp boolean := false;
  v_simples text[] := array['nome_social', 'apelido', 'rg', 'profissao', 'estado_civil', 'origem', 'convenio'];
  v_limpaveis text[] := array['nome_social', 'apelido', 'data_nascimento', 'sexo', 'cpf', 'rg', 'telefone',
                              'email', 'endereco', 'profissao', 'estado_civil', 'contato_emergencia',
                              'origem', 'convenio', 'observacoes'];
  v_permitidos text[] := array['nome', 'nome_social', 'apelido', 'data_nascimento', 'sexo', 'cpf', 'rg',
                               'telefone', 'whatsapp', 'email', 'endereco', 'profissao', 'estado_civil',
                               'contato_emergencia', 'origem', 'convenio', 'observacoes',
                               'observacoes_acrescentar', 'consentimento_lgpd', 'consentimento_imagem',
                               'arquivar', 'responsavel', 'alertas_adicionar', 'alertas_remover', 'limpar'];
begin
  perform public.iniciar_solicitacao('atualizar_paciente',
    jsonb_build_object('paciente_id', p_paciente_id) || coalesce(p_dados, '{}'::jsonb), p_texto_original);

  select * into v_old from public.pacientes where id = p_paciente_id for update;
  if not found then
    raise exception 'Paciente não encontrado. Use buscar_paciente para obter o id.';
  end if;
  if p_dados is null or p_dados = '{}'::jsonb then
    raise exception 'Diga o que mudar na ficha (ex.: telefone, e-mail, endereço, alertas).';
  end if;
  for k in select jsonb_object_keys(p_dados) loop
    if not k = any (v_permitidos) then
      raise exception 'O campo "%" não é alterado por aqui.', k;
    end if;
  end loop;
  if v_old.arquivado_em is not null and not (p_dados ? 'arquivar') then
    raise exception 'O paciente % está arquivado. Desarquive (arquivar = false) antes de alterar a ficha.', v_old.nome;
  end if;

  -- Campos a esvaziar
  v_limpar := coalesce(array(select jsonb_array_elements_text(p_dados -> 'limpar')), '{}');
  foreach k in array v_limpar loop
    if not k = any (v_limpaveis) then
      raise exception 'O campo "%" não pode ser apagado.', k;
    end if;
    if p_dados ? k then
      raise exception 'O campo "%" está ao mesmo tempo em limpar e com valor novo.', k;
    end if;
    v_patch := v_patch || jsonb_build_object(k, null);
  end loop;

  -- Nome
  if p_dados ? 'nome' then
    v_txt := btrim(regexp_replace(coalesce(p_dados ->> 'nome', ''), '\s+', ' ', 'g'));
    if length(v_txt) < 3 or position(' ' in v_txt) = 0 then
      raise exception 'Informe o nome completo do paciente (nome e sobrenome).';
    end if;
    v_patch := v_patch || jsonb_build_object('nome', v_txt);
  end if;

  -- Textos simples
  foreach k in array v_simples loop
    if p_dados ? k then
      v_patch := v_patch || jsonb_build_object(k, nullif(btrim(p_dados ->> k), ''));
    end if;
  end loop;

  if p_dados ? 'data_nascimento' then
    v_nasc := public.ler_data(p_dados ->> 'data_nascimento', 'Data de nascimento');
    if v_nasc > public.hoje() then
      raise exception 'Data de nascimento no futuro: %.', v_nasc;
    end if;
    v_patch := v_patch || jsonb_build_object('data_nascimento', v_nasc);
  end if;

  if p_dados ? 'sexo' then
    v_patch := v_patch || jsonb_build_object('sexo', case public.normalizar(p_dados ->> 'sexo')
      when '' then null
      when 'f' then 'feminino' when 'feminino' then 'feminino' when 'mulher' then 'feminino'
      when 'm' then 'masculino' when 'masculino' then 'masculino' when 'homem' then 'masculino'
      when 'outro' then 'outro'
      else 'nao_informado' end);
  end if;

  if p_dados ? 'cpf' then
    v_cpf := public.somente_digitos(p_dados ->> 'cpf');
    if v_cpf is not null and not public.cpf_valido(v_cpf) then
      raise exception 'O CPF "%" não é válido (os dígitos verificadores não conferem). Confirme o número.', p_dados ->> 'cpf';
    end if;
    select nome || ' (ficha ' || ficha || ')' into v_existente
      from public.pacientes where cpf = v_cpf and id <> p_paciente_id;
    if v_existente is not null then
      raise exception 'Este CPF já está na ficha de %.', v_existente;
    end if;
    v_patch := v_patch || jsonb_build_object('cpf', v_cpf);
  end if;

  if p_dados ? 'telefone' then
    v_patch := v_patch || jsonb_build_object('telefone', public.normalizar_telefone(p_dados ->> 'telefone'));
  end if;
  if p_dados ? 'whatsapp' then
    v_patch := v_patch || jsonb_build_object('whatsapp', coalesce((p_dados ->> 'whatsapp')::boolean, true));
  end if;
  if p_dados ? 'email' then
    v_txt := nullif(lower(btrim(p_dados ->> 'email')), '');
    if v_txt is not null and v_txt !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'E-mail "%" parece incompleto.', p_dados ->> 'email';
    end if;
    v_patch := v_patch || jsonb_build_object('email', v_txt);
  end if;

  -- Endereço e contato de emergência: completa o que já existe
  if p_dados ? 'endereco' then
    v_patch := v_patch || jsonb_build_object('endereco',
      nullif(coalesce(v_old.endereco, '{}'::jsonb) || jsonb_strip_nulls(coalesce(p_dados -> 'endereco', '{}'::jsonb)), '{}'::jsonb));
  end if;
  if p_dados ? 'contato_emergencia' then
    v_item := jsonb_strip_nulls(coalesce(p_dados -> 'contato_emergencia', '{}'::jsonb));
    if v_item ? 'telefone' then
      v_item := v_item || jsonb_build_object('telefone', public.normalizar_telefone(v_item ->> 'telefone'));
    end if;
    v_patch := v_patch || jsonb_build_object('contato_emergencia',
      nullif(coalesce(v_old.contato_emergencia, '{}'::jsonb) || v_item, '{}'::jsonb));
  end if;

  -- Observações: substituir ou acrescentar (com data)
  if p_dados ? 'observacoes' then
    v_patch := v_patch || jsonb_build_object('observacoes', nullif(btrim(p_dados ->> 'observacoes'), ''));
  end if;
  if nullif(btrim(p_dados ->> 'observacoes_acrescentar'), '') is not null then
    v_patch := v_patch || jsonb_build_object('observacoes',
      concat_ws(E'\n', coalesce(v_patch ->> 'observacoes', case when p_dados ? 'observacoes' then null else v_old.observacoes end),
                to_char(public.hoje(), 'DD/MM/YYYY') || ': ' || btrim(p_dados ->> 'observacoes_acrescentar')));
  end if;

  -- Consentimentos e arquivamento
  if p_dados ? 'consentimento_lgpd' then
    v_patch := v_patch || jsonb_build_object('consentimento_lgpd_em',
      case when (p_dados ->> 'consentimento_lgpd')::boolean then coalesce(v_old.consentimento_lgpd_em, now()) end);
  end if;
  if p_dados ? 'consentimento_imagem' then
    v_patch := v_patch || jsonb_build_object('consentimento_imagem_em',
      case when (p_dados ->> 'consentimento_imagem')::boolean then coalesce(v_old.consentimento_imagem_em, now()) end);
  end if;
  if p_dados ? 'arquivar' then
    v_patch := v_patch || jsonb_build_object('arquivado_em',
      case when (p_dados ->> 'arquivar')::boolean then coalesce(v_old.arquivado_em, now()) end);
  end if;

  -- Alertas de saúde (os da anamnese só mudam pela anamnese)
  v_alertas := v_old.alertas_saude;
  if jsonb_typeof(p_dados -> 'alertas_remover') = 'array' then
    for v_termo in select jsonb_array_elements_text(p_dados -> 'alertas_remover') loop
      v_termo := public.normalizar(v_termo);
      if length(v_termo) < 3 then
        raise exception 'Diga qual alerta remover (ex.: "dipirona").';
      end if;
      if exists (select 1 from jsonb_array_elements(v_alertas) a
                  where a ->> 'origem' = 'anamnese'
                    and public.normalizar(a ->> 'descricao') like '%' || v_termo || '%') then
        raise exception 'O alerta "%" vem da anamnese: corrija a resposta com registrar_anamnese.', v_termo;
      end if;
      select count(*) into v_n from jsonb_array_elements(v_alertas) a
       where public.normalizar(a ->> 'descricao') like '%' || v_termo || '%';
      if v_n = 0 then
        raise exception 'Nenhum alerta da ficha cita "%". Alertas atuais: %.', v_termo,
          coalesce((select string_agg(a ->> 'descricao', '; ') from jsonb_array_elements(v_alertas) a), 'nenhum');
      end if;
      select coalesce(jsonb_agg(a), '[]'::jsonb) into v_alertas
        from jsonb_array_elements(v_alertas) a
       where public.normalizar(a ->> 'descricao') not like '%' || v_termo || '%';
    end loop;
  end if;
  if p_dados ? 'alertas_adicionar' then
    v_novos := public.normalizar_alertas(p_dados -> 'alertas_adicionar');
    select coalesce(jsonb_agg(n), '[]'::jsonb) into v_novos
      from jsonb_array_elements(v_novos) n
     where not exists (select 1 from jsonb_array_elements(v_alertas) a
                        where public.normalizar(a ->> 'descricao') = public.normalizar(n ->> 'descricao'));
    v_alertas := v_alertas || v_novos;
  end if;
  if v_alertas is distinct from v_old.alertas_saude then
    v_patch := v_patch || jsonb_build_object('alertas_saude', v_alertas);
  end if;

  -- Aplica
  v_new := jsonb_populate_record(v_old, v_patch);
  select coalesce(array_agg(n.key order by n.key), '{}') into v_campos
    from jsonb_each(to_jsonb(v_new)) n
   where n.value is distinct from to_jsonb(v_old) -> n.key;

  if cardinality(v_campos) > 0 then
    update public.pacientes set
      nome = v_new.nome, nome_social = v_new.nome_social, apelido = v_new.apelido,
      data_nascimento = v_new.data_nascimento, sexo = v_new.sexo, cpf = v_new.cpf, rg = v_new.rg,
      telefone = v_new.telefone, whatsapp = v_new.whatsapp, email = v_new.email,
      endereco = v_new.endereco, profissao = v_new.profissao, estado_civil = v_new.estado_civil,
      contato_emergencia = v_new.contato_emergencia, origem = v_new.origem, convenio = v_new.convenio,
      alertas_saude = v_new.alertas_saude, observacoes = v_new.observacoes,
      consentimento_lgpd_em = v_new.consentimento_lgpd_em,
      consentimento_imagem_em = v_new.consentimento_imagem_em,
      arquivado_em = v_new.arquivado_em
     where id = p_paciente_id;
  end if;

  -- Responsável: atualiza o de mesmo nome ou inclui um novo
  v_resp := p_dados -> 'responsavel';
  if v_resp is not null and jsonb_typeof(v_resp) = 'object' then
    if length(btrim(coalesce(v_resp ->> 'nome', ''))) < 3 then
      raise exception 'Informe o nome do responsável.';
    end if;
    v_resp_cpf := public.somente_digitos(v_resp ->> 'cpf');
    if v_resp_cpf is not null and not public.cpf_valido(v_resp_cpf) then
      raise exception 'O CPF do responsável "%" não é válido.', v_resp ->> 'cpf';
    end if;
    select id into v_resp_id from public.responsaveis
     where paciente_id = p_paciente_id and public.normalizar(nome) = public.normalizar(v_resp ->> 'nome');
    if v_resp_id is null then
      insert into public.responsaveis (paciente_id, nome, cpf, parentesco, telefone, e_pagador)
      values (p_paciente_id, btrim(v_resp ->> 'nome'), v_resp_cpf, nullif(btrim(v_resp ->> 'parentesco'), ''),
              public.normalizar_telefone(v_resp ->> 'telefone'), coalesce((v_resp ->> 'e_pagador')::boolean, true));
    else
      update public.responsaveis set
        cpf = coalesce(v_resp_cpf, cpf),
        parentesco = coalesce(nullif(btrim(v_resp ->> 'parentesco'), ''), parentesco),
        telefone = coalesce(public.normalizar_telefone(v_resp ->> 'telefone'), telefone),
        e_pagador = coalesce((v_resp ->> 'e_pagador')::boolean, e_pagador)
       where id = v_resp_id;
    end if;
    v_mudou_resp := true;
    v_campos := array_append(v_campos, 'responsavel');
  end if;

  if cardinality(v_campos) = 0 then
    return jsonb_build_object('status', 'sem_mudanca',
      'mensagem', 'A ficha já estava assim; nada foi alterado.',
      'paciente', public.paciente_ficha(p_paciente_id, 3));
  end if;

  if v_new.arquivado_em is not null and v_old.arquivado_em is null then
    v_avisos := array_append(v_avisos, 'Paciente arquivado: some das buscas, mas o prontuário continua guardado.');
  end if;
  if v_new.cpf is null then
    v_avisos := array_append(v_avisos, 'Ainda falta o CPF (necessário para o recibo Receita Saúde).');
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'alterados', to_jsonb(v_campos),
    'paciente', public.paciente_ficha(p_paciente_id, 3),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- registrar_anamnese
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_anamnese(
  p_dados jsonb,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cfg public.configuracao;
  v_pac public.pacientes;
  v_prev public.anamneses;
  v_resp jsonb;
  v_alteradas text[] := '{}';
  v_item jsonb;
  v_cod text;
  v_q public.anamnese_perguntas;
  v_val text;
  v_det text;
  v_valor jsonb;
  v_m text[];
  v_pas int;
  v_pad int;
  v_fc int;
  v_obs text;
  v_origem text;
  v_assinada boolean := coalesce((p_dados ->> 'assinada')::boolean, false);
  v_id uuid;
  v_avisos text[] := '{}';
begin
  perform public.iniciar_solicitacao('registrar_anamnese', p_dados, p_texto_original);

  select * into v_cfg from public.configuracao;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');

  select * into v_prev from public.anamneses
   where paciente_id = v_pac.id order by versao desc limit 1;
  v_resp := coalesce(v_prev.respostas, '{}'::jsonb);

  if p_dados ? 'respostas' and jsonb_typeof(p_dados -> 'respostas') <> 'array' then
    raise exception 'respostas deve ser uma lista de {pergunta, resposta, detalhe}.';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_dados -> 'respostas', '[]'::jsonb)) loop
    v_cod := replace(public.normalizar(v_item ->> 'pergunta'), ' ', '_');
    select * into v_q from public.anamnese_perguntas where codigo = v_cod and ativa;
    if not found then
      raise exception 'Pergunta "%" não existe na anamnese. Use os códigos listados na ferramenta.', v_item ->> 'pergunta';
    end if;
    v_det := nullif(btrim(v_item ->> 'detalhe'), '');

    if v_q.tipo = 'sim_nao' then
      if jsonb_typeof(v_item -> 'resposta') = 'boolean' then
        v_val := case when (v_item ->> 'resposta')::boolean then 'sim' else 'nao' end;
      else
        v_val := case public.normalizar(v_item ->> 'resposta')
          when '' then null
          when 'sim' then 'sim' when 's' then 'sim' when 'positivo' then 'sim'
          when 'nao' then 'nao' when 'n' then 'nao' when 'negativo' then 'nao' when 'nega' then 'nao'
          when 'nao_sabe' then 'nao_sabe' when 'nao sabe' then 'nao_sabe' when 'nao sei' then 'nao_sabe'
          when 'nao lembra' then 'nao_sabe' when 'nao soube informar' then 'nao_sabe'
          else 'invalida' end;
      end if;
      if v_val is null and v_det is not null then
        v_val := 'sim';
      end if;
      if v_val is null or v_val = 'invalida' then
        raise exception 'Resposta "%" inválida para "%": use sim, nao ou nao_sabe.', v_item ->> 'resposta', v_q.texto;
      end if;
      v_valor := jsonb_build_object('resposta', v_val, 'detalhe', v_det);
    elsif v_q.tipo = 'texto' then
      v_val := coalesce(nullif(btrim(v_item ->> 'resposta'), ''), v_det);
      if v_val is null then
        raise exception 'Resposta vazia para "%".', v_q.texto;
      end if;
      v_valor := jsonb_build_object('resposta', v_val);
    else
      begin
        v_valor := jsonb_build_object('resposta', (v_item ->> 'resposta')::numeric, 'detalhe', v_det);
      exception when others then
        raise exception 'A resposta de "%" deve ser um número.', v_q.texto;
      end;
    end if;
    v_valor := jsonb_strip_nulls(v_valor);

    if (v_resp -> v_cod) - 'em' is distinct from v_valor then
      v_resp := v_resp || jsonb_build_object(v_cod, v_valor || jsonb_build_object('em', public.hoje()));
      if not v_cod = any (v_alteradas) then
        v_alteradas := array_append(v_alteradas, v_cod);
      end if;
    end if;
  end loop;

  -- "o resto tudo não": completa as perguntas sim/não ainda sem resposta
  if coalesce((p_dados ->> 'demais_negativas')::boolean, false) then
    for v_cod in
      select codigo from public.anamnese_perguntas
       where ativa and tipo = 'sim_nao' and not (v_resp ? codigo)
       order by ordem
    loop
      v_resp := v_resp || jsonb_build_object(v_cod, jsonb_build_object('resposta', 'nao', 'em', public.hoje()));
      v_alteradas := array_append(v_alteradas, v_cod);
    end loop;
  end if;

  -- Pressão arterial ("120x80", "12 por 8")
  if nullif(btrim(p_dados ->> 'pressao_arterial'), '') is not null then
    v_m := regexp_match(lower(p_dados ->> 'pressao_arterial'), '(\d{1,3})\s*(?:x|/|por)\s*(\d{1,3})');
    if v_m is null then
      raise exception 'Pressão "%" não entendida: use o formato 120x80.', p_dados ->> 'pressao_arterial';
    end if;
    v_pas := v_m[1]::int;
    v_pad := v_m[2]::int;
    if v_pas < 30 and v_pad < 30 then
      v_pas := v_pas * 10;
      v_pad := v_pad * 10;
    end if;
    if v_pas not between 60 and 260 or v_pad not between 30 and 160 or v_pad >= v_pas then
      raise exception 'Pressão %x% fora do possível: confira.', v_pas, v_pad;
    end if;
    if v_pas >= 180 or v_pad >= 110 then
      v_avisos := array_append(v_avisos, format('Pressão %sx%s muito alta: considere adiar procedimento eletivo e orientar avaliação médica.', v_pas, v_pad));
    elsif v_pas >= 160 or v_pad >= 100 then
      v_avisos := array_append(v_avisos, format('Pressão %sx%s elevada.', v_pas, v_pad));
    end if;
  end if;
  if nullif(p_dados ->> 'frequencia_cardiaca', '') is not null then
    begin
      v_fc := (p_dados ->> 'frequencia_cardiaca')::numeric::int;
    exception when others then
      raise exception 'Frequência cardíaca deve ser um número (batimentos por minuto).';
    end;
    if v_fc not between 30 and 220 then
      raise exception 'Frequência cardíaca % fora do possível: confira.', v_fc;
    end if;
    if v_fc > 100 or v_fc < 50 then
      v_avisos := array_append(v_avisos, format('Frequência cardíaca de %s bpm fora do normal (50–100).', v_fc));
    end if;
  end if;

  v_obs := coalesce(nullif(btrim(p_dados ->> 'observacoes'), ''), v_prev.observacoes);
  v_origem := coalesce(nullif(public.normalizar(p_dados ->> 'origem'), ''), 'ditado');
  if v_origem not in ('ditado', 'formulario', 'papel') then
    raise exception 'Origem "%" inválida: use ditado, formulario ou papel.', p_dados ->> 'origem';
  end if;

  if cardinality(v_alteradas) = 0 and v_pas is null and v_fc is null and not v_assinada
     and v_obs is not distinct from v_prev.observacoes then
    raise exception 'Nada novo para registrar na anamnese (as respostas já estavam assim).';
  end if;

  insert into public.anamneses (
    paciente_id, versao, respostas, alteradas, pa_sistolica, pa_diastolica, fc, observacoes,
    origem, assinada_em, profissional, cro, solicitacao_id)
  values (
    v_pac.id, coalesce(v_prev.versao, 0) + 1, v_resp, v_alteradas, v_pas, v_pad, v_fc, v_obs,
    v_origem, case when v_assinada then now() end, v_cfg.dentista_nome, v_cfg.cro,
    nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  v_avisos := v_avisos || public.aplicar_alertas_da_anamnese(v_pac.id, v_resp);

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'versao', coalesce(v_prev.versao, 0) + 1,
    'alteradas', to_jsonb(v_alteradas),
    'anamnese', public.anamnese_json(v_pac.id),
    'alertas_saude', (select alertas_saude from public.pacientes where id = v_pac.id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- registrar_odontograma
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_odontograma(
  p_dados jsonb,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pac public.pacientes;
  v_data date;
  v_item jsonb;
  v_dentes smallint[];
  v_d smallint;
  v_txt text;
  v_regiao text;
  v_cond text;
  v_camada text;
  v_faces text;
  v_proc public.procedimentos;
  v_proc_id uuid;
  v_aviso text;
  v_detalhe text;
  v_motivo text;
  v_alvo uuid[];
  v_n_marcadas int := 0;
  v_n_anuladas int := 0;
  v_avisos text[] := '{}';
  v_ordem int := 0;
begin
  perform public.iniciar_solicitacao('registrar_odontograma', p_dados, p_texto_original);
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data (%) está no futuro.', v_data;
  end if;
  if jsonb_typeof(p_dados -> 'marcas') is distinct from 'array' or jsonb_array_length(p_dados -> 'marcas') = 0 then
    raise exception 'Informe as marcas do odontograma (lista de {dente, condicao, faces, camada}).';
  end if;

  for v_item in select * from jsonb_array_elements(p_dados -> 'marcas') loop
    v_ordem := v_ordem + 1;

    -- Dentes: um, vários ou uma região
    v_dentes := '{}';
    if nullif(v_item ->> 'dente', '') is not null then
      v_dentes := array_append(v_dentes, public.ler_dente(v_item ->> 'dente'));
    end if;
    if jsonb_typeof(v_item -> 'dentes') = 'array' then
      for v_txt in select jsonb_array_elements_text(v_item -> 'dentes') loop
        v_dentes := array_append(v_dentes, public.ler_dente(v_txt));
      end loop;
    end if;
    if nullif(v_item ->> 'regiao', '') is not null then
      v_regiao := public.normalizar_regiao(v_item ->> 'regiao');
      if public.dentes_da_regiao(v_regiao) is null then
        raise exception 'A região "%" não corresponde a dentes; marque os dentes um a um.', v_item ->> 'regiao';
      end if;
      v_dentes := v_dentes || public.dentes_da_regiao(v_regiao);
    end if;
    if cardinality(v_dentes) = 0 then
      raise exception 'Marca %: informe o dente (FDI), a lista de dentes ou a região.', v_ordem;
    end if;

    -- Procedimento e condição
    v_proc := null;
    if nullif(btrim(v_item ->> 'procedimento_codigo'), '') is not null then
      select * into v_proc from public.procedimentos where codigo = public.codigo_de(v_item ->> 'procedimento_codigo');
      if not found or not v_proc.ativo then
        raise exception 'Procedimento "%" não está no catálogo. Use listar_procedimentos.', v_item ->> 'procedimento_codigo';
      end if;
    end if;
    v_cond := nullif(replace(public.normalizar(v_item ->> 'condicao'), ' ', '_'), '');
    if v_cond is null then
      v_cond := v_proc.condicao_resultante;
    end if;
    if v_cond is null then
      raise exception 'Marca %: informe a condição (ex.: carie, restauracao, ausente).', v_ordem;
    end if;
    if not exists (select 1 from public.odontograma_condicoes where codigo = v_cond) then
      raise exception 'Condição "%" não existe no odontograma.', v_item ->> 'condicao';
    end if;

    if coalesce((v_item ->> 'remover')::boolean, false) then
      -- Desfaz um engano
      v_motivo := coalesce(nullif(btrim(v_item ->> 'motivo'), ''), nullif(btrim(p_dados ->> 'motivo'), ''));
      if v_motivo is null then
        raise exception 'Para remover uma marca, informe o motivo (ex.: "marcado no dente errado").';
      end if;
      v_camada := nullif(public.normalizar(v_item ->> 'camada'), '');
      foreach v_d in array v_dentes loop
        v_faces := public.normalizar_faces(v_d, v_item ->> 'faces');
        select array_agg(a.id) into v_alvo
          from public.odontograma_ativas(v_pac.id) a
         where a.dente = v_d and a.condicao = v_cond
           and (v_camada is null or a.camada = v_camada)
           and (v_faces is null or (a.faces is not null and public.faces_contidas(v_faces, a.faces)));
        if v_alvo is null then
          raise exception 'Não há "%"% ativo no dente % para remover.', v_cond, coalesce(' ' || v_faces, ''), v_d;
        end if;
        if exists (select 1 from public.odontograma o where o.id = any (v_alvo) and o.origem = 'atendimento') then
          raise exception 'A marca de % no dente % veio de um atendimento: para corrigir, registre a correção do atendimento.', v_cond, v_d;
        end if;
        v_n_anuladas := v_n_anuladas + public.odontograma_anular(v_pac.id, v_alvo, v_motivo, v_data);
      end loop;
    else
      v_camada := coalesce(nullif(public.normalizar(v_item ->> 'camada'), ''), 'inicial');
      if v_camada = 'realizado' then
        raise exception 'O que foi feito no consultório se registra com registrar_atendimento (o odontograma é atualizado sozinho). Trabalho feito por outro dentista: use camada inicial.';
      end if;
      if v_camada not in ('inicial', 'planejado') then
        raise exception 'Camada "%" inválida: use inicial ou planejado.', v_item ->> 'camada';
      end if;
      foreach v_d in array v_dentes loop
        v_faces := public.normalizar_faces(v_d, v_item ->> 'faces');
        v_proc_id := v_proc.id;
        v_aviso := null;
        if v_camada = 'planejado' then
          select e.proc_id, e.aviso into v_proc_id, v_aviso
            from public.escolher_procedimento(v_proc.codigo, null, v_cond, v_d, length(v_faces)) e;
          if v_proc_id is null then
            v_avisos := array_append(v_avisos, format(
              'Dente %s: planejado sem procedimento do catálogo (%s); o orçamento vai precisar dele.', v_d, v_cond));
          end if;
          if v_aviso is not null then
            v_avisos := array_append(v_avisos, v_aviso);
          end if;
        end if;
        v_detalhe := nullif(btrim(v_item ->> 'detalhe'), '');
        perform public.odontograma_marcar(v_pac.id, v_d, v_faces, v_cond, v_camada, v_detalhe,
                                          v_proc_id, null, 'avaliacao', v_data);
        v_n_marcadas := v_n_marcadas + 1;
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
    'marcadas', v_n_marcadas,
    'removidas', v_n_anuladas,
    'odontograma', public.odontograma_json(v_pac.id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- listar_procedimentos
-- ---------------------------------------------------------------------
create or replace function public.procedimento_json(p public.procedimentos)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'codigo', p.codigo,
    'nome', p.nome,
    'grupo', p.grupo,
    'aplica_a', p.aplica_a,
    'preco', p.preco,
    'faixa_mercado', case when p.preco is null then p.faixa_mercado end,
    'sem_preco', case when p.preco is null then true end,
    'odontograma', p.condicao_resultante,
    'ativo', case when not p.ativo then false end,
    'no_site', case when p.publicar_no_site then true end,
    'observacao', p.observacao))
$$;

create or replace function public.mcp_listar_procedimentos(
  p_busca text default null,
  p_categoria text default null,
  p_incluir_inativos boolean default false,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_t text := nullif(public.normalizar(p_busca), '');
  v_lista jsonb;
begin
  perform public.iniciar_solicitacao('listar_procedimentos',
    jsonb_strip_nulls(jsonb_build_object('busca', p_busca, 'categoria', p_categoria,
                                         'incluir_inativos', p_incluir_inativos)),
    p_texto_original);

  select coalesce(jsonb_agg(public.procedimento_json(p) order by p.ordem, p.nome), '[]'::jsonb)
    into v_lista
    from public.procedimentos p
   where (coalesce(p_incluir_inativos, false) or p.ativo)
     and (p_categoria is null or p.categoria = public.normalizar(p_categoria))
     and (v_t is null
          or public.normalizar(p.nome) like '%' || v_t || '%'
          or p.codigo like '%' || replace(v_t, ' ', '_') || '%'
          or public.normalizar(p.grupo) like '%' || v_t || '%'
          or exists (select 1 from unnest(p.sinonimos) s where s like '%' || v_t || '%'));

  return jsonb_build_object(
    'total', jsonb_array_length(v_lista),
    'procedimentos', v_lista,
    'mensagem', case when jsonb_array_length(v_lista) = 0
                     then format('Nada no catálogo para "%s". Para incluir, use salvar_procedimento.', p_busca) end);
end
$$;

-- ---------------------------------------------------------------------
-- salvar_procedimento (incluir ou alterar, inclusive preço)
-- ---------------------------------------------------------------------
create or replace function public.mcp_salvar_procedimento(
  p_dados jsonb,
  p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old public.procedimentos;
  v_cod text := nullif(public.codigo_de(p_dados ->> 'codigo'), '');
  v_nome text := nullif(btrim(regexp_replace(coalesce(p_dados ->> 'nome', ''), '\s+', ' ', 'g')), '');
  v_cat text := nullif(public.normalizar(p_dados ->> 'categoria'), '');
  v_aplica text := nullif(replace(public.normalizar(p_dados ->> 'aplica_a'), ' ', '_'), '');
  v_preco numeric;
  v_sin text[];
  v_cond text := nullif(replace(public.normalizar(p_dados ->> 'condicao_odontograma'), ' ', '_'), '');
  v_id uuid;
  v_status text;
  v_avisos text[] := '{}';
  v_n int := 1;
  v_grupo_padrao text;
begin
  perform public.iniciar_solicitacao('salvar_procedimento', p_dados, p_texto_original);

  if p_dados ? 'preco' and jsonb_typeof(p_dados -> 'preco') <> 'null' then
    begin
      v_preco := (p_dados ->> 'preco')::numeric;
    exception when others then
      raise exception 'Preço "%" inválido: use só o número (ex.: 280).', p_dados ->> 'preco';
    end;
    if v_preco < 0 or v_preco > 200000 then
      raise exception 'Preço R$ % fora do esperado: confira.', v_preco;
    end if;
  end if;
  if v_cat is not null and v_cat not in ('diagnostico', 'prevencao', 'dentistica', 'endodontia', 'periodontia',
                                         'cirurgia', 'protese', 'implante', 'estetica', 'disfuncao', 'outros') then
    raise exception 'Categoria "%" inválida.', p_dados ->> 'categoria';
  end if;
  if v_aplica is not null and v_aplica not in ('boca', 'arcada', 'sextante', 'dente', 'dente_faces', 'regiao') then
    raise exception 'aplica_a "%" inválido: use boca, arcada, sextante, dente, dente_faces ou regiao.', p_dados ->> 'aplica_a';
  end if;
  if v_cond is not null and not exists (select 1 from public.odontograma_condicoes where codigo = v_cond) then
    raise exception 'Condição do odontograma "%" não existe.', p_dados ->> 'condicao_odontograma';
  end if;
  v_sin := coalesce(array(select distinct public.normalizar(s)
                            from jsonb_array_elements_text(coalesce(p_dados -> 'sinonimos_adicionar', '[]'::jsonb)) s
                           where public.normalizar(s) <> ''), '{}');

  -- Acha o existente: pelo código ou pelo nome
  if v_cod is not null then
    select * into v_old from public.procedimentos where codigo = v_cod for update;
  end if;
  if v_old.id is null and v_nome is not null then
    select * into v_old from public.procedimentos
     where public.normalizar(nome) = public.normalizar(v_nome) for update;
  end if;

  if v_old.id is not null then
    update public.procedimentos set
      nome = coalesce(v_nome, nome),
      grupo = coalesce(nullif(btrim(p_dados ->> 'grupo'), ''), grupo),
      categoria = coalesce(v_cat, categoria),
      aplica_a = coalesce(v_aplica, aplica_a),
      preco = case when p_dados ? 'preco' then v_preco else preco end,
      faixa_mercado = coalesce(nullif(btrim(p_dados ->> 'faixa_mercado'), ''), faixa_mercado),
      condicao_resultante = coalesce(v_cond, condicao_resultante),
      detalhe_resultante = coalesce(nullif(btrim(p_dados ->> 'detalhe_odontograma'), ''), detalhe_resultante),
      sinonimos = (select coalesce(array_agg(distinct s), '{}') from unnest(sinonimos || v_sin) s),
      ativo = coalesce((p_dados ->> 'ativo')::boolean, ativo),
      publicar_no_site = coalesce((p_dados ->> 'publicar_no_site')::boolean, publicar_no_site),
      observacao = case when p_dados ? 'observacao' then nullif(btrim(p_dados ->> 'observacao'), '') else observacao end
     where id = v_old.id;
    v_id := v_old.id;
    v_status := 'atualizado';
    if p_dados ? 'preco' and v_preco is distinct from v_old.preco and v_old.preco is not null and v_preco is not null
       and abs(v_preco - v_old.preco) > v_old.preco * 0.5 then
      v_avisos := array_append(v_avisos, format('O preço mudou mais de 50%% (de R$ %s para R$ %s): confira.', v_old.preco, v_preco));
    end if;
  else
    if v_nome is null or length(v_nome) < 3 then
      raise exception 'Para incluir um procedimento novo, informe o nome.';
    end if;
    if v_cat is null then
      raise exception 'Para incluir "%", informe a categoria (ex.: dentistica, cirurgia, protese, implante).', v_nome;
    end if;
    v_aplica := coalesce(v_aplica, 'dente');
    v_grupo_padrao := case v_cat
      when 'diagnostico' then 'Diagnóstico' when 'prevencao' then 'Prevenção' when 'dentistica' then 'Restaurações'
      when 'endodontia' then 'Endodontia' when 'periodontia' then 'Periodontia' when 'cirurgia' then 'Cirurgia'
      when 'protese' then 'Prótese Fixa' when 'implante' then 'Implantes' when 'estetica' then 'Estética'
      when 'disfuncao' then 'Disfunção' else 'Outros' end;
    v_cod := coalesce(v_cod, public.codigo_de(v_nome));
    if v_cod !~ '^[a-z]' then
      v_cod := 'p_' || v_cod;
    end if;
    while exists (select 1 from public.procedimentos where codigo = v_cod || case when v_n > 1 then '_' || v_n else '' end) loop
      v_n := v_n + 1;
    end loop;
    v_cod := v_cod || case when v_n > 1 then '_' || v_n else '' end;
    insert into public.procedimentos (codigo, nome, grupo, categoria, aplica_a, preco, faixa_mercado,
                                      condicao_resultante, detalhe_resultante, sinonimos, ordem,
                                      ativo, publicar_no_site, observacao)
    values (v_cod, v_nome, coalesce(nullif(btrim(p_dados ->> 'grupo'), ''), v_grupo_padrao), v_cat, v_aplica,
            v_preco, nullif(btrim(p_dados ->> 'faixa_mercado'), ''), v_cond,
            nullif(btrim(p_dados ->> 'detalhe_odontograma'), ''),
            (select coalesce(array_agg(distinct s), '{}') from unnest(v_sin || public.normalizar(v_nome)) s),
            (select coalesce(max(ordem), 0) + 10 from public.procedimentos),
            coalesce((p_dados ->> 'ativo')::boolean, true),
            coalesce((p_dados ->> 'publicar_no_site')::boolean, false),
            nullif(btrim(p_dados ->> 'observacao'), ''))
    returning id into v_id;
    v_status := 'criado';
    if v_preco is null then
      v_avisos := array_append(v_avisos, 'Incluído sem preço: não entra em orçamento até ter valor.');
    end if;
  end if;

  return jsonb_build_object(
    'status', v_status,
    'procedimento', (select public.procedimento_json(p) from public.procedimentos p where p.id = v_id),
    'antes', case when v_old.id is not null then public.procedimento_json(v_old) end,
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.obter_paciente_ativo(text),
  public.escolher_procedimento(text, text, text, smallint, int),
  public.procedimento_json(public.procedimentos),
  public.mcp_atualizar_paciente(uuid, jsonb, text),
  public.mcp_registrar_anamnese(jsonb, text),
  public.mcp_registrar_odontograma(jsonb, text),
  public.mcp_listar_procedimentos(text, text, boolean, text),
  public.mcp_salvar_procedimento(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.obter_paciente_ativo(text),
  public.escolher_procedimento(text, text, text, smallint, int),
  public.procedimento_json(public.procedimentos),
  public.mcp_atualizar_paciente(uuid, jsonb, text),
  public.mcp_registrar_anamnese(jsonb, text),
  public.mcp_registrar_odontograma(jsonb, text),
  public.mcp_listar_procedimentos(text, text, boolean, text),
  public.mcp_salvar_procedimento(jsonb, text)
  to service_role;
