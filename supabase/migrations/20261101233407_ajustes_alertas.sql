-- =====================================================================
-- Etapa 1: ajustes nos alertas de saúde (achados no teste ponta a ponta).
--
-- 1. Alerta derivado da anamnese repetia o alerta do cadastro quando o
--    detalhe trazia mais palavras ("alergia a dipirona" no cadastro x
--    "dipirona, urticária" na anamnese). Agora basta uma palavra
--    significativa em comum, no mesmo tipo de alerta.
-- 2. alertas_remover: remove os alertas do cadastro que citam o termo e só
--    recusa quando o termo aparece apenas em alertas da anamnese. A
--    mensagem usa o texto do alerta, não o termo normalizado.
-- =====================================================================

-- Um alerta do cadastro já cobre o detalhe vindo da anamnese?
create or replace function public.alerta_coberto(p_manual text, p_detalhe text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_detalhe is not null and (
    public.normalizar(p_manual) like '%' || public.normalizar(p_detalhe) || '%'
    or exists (
      select 1
        from regexp_split_to_table(public.normalizar(p_detalhe), '[^a-z0-9]+') w
       where length(w) >= 4
         and w not in ('alergia', 'alergico', 'alergica', 'medicamento', 'medicamentos', 'remedio', 'remedios',
                       'reacao', 'reacoes', 'dose', 'toma', 'tomou', 'teve', 'para', 'pela', 'pelo', 'todos',
                       'todas', 'qualquer', 'muito', 'pouco', 'desde', 'anos', 'vezes', 'quando', 'depois',
                       'antes', 'sempre', 'nunca', 'apenas', 'somente', 'leve', 'forte', 'grave', 'tipo')
         and public.normalizar(p_manual) ~ ('\m' || w || '\M')))
$$;

create or replace function public.aplicar_alertas_da_anamnese(p_paciente uuid, p_respostas jsonb)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  v_atual jsonb;
  v_manuais jsonb;
  v_deriv jsonb;
  v_final jsonb;
  v_avisos text[] := '{}';
  r record;
begin
  select alertas_saude into v_atual from public.pacientes where id = p_paciente;

  select coalesce(jsonb_agg(a), '[]'::jsonb) into v_manuais
    from jsonb_array_elements(v_atual) a
   where coalesce(a ->> 'origem', 'manual') <> 'anamnese';

  select coalesce(jsonb_agg(d), '[]'::jsonb) into v_deriv
    from jsonb_array_elements(public.anamnese_alertas(p_respostas)) d
   where not exists (
     select 1 from jsonb_array_elements(v_manuais) m
      where m ->> 'tipo' = d ->> 'tipo'
        and public.alerta_coberto(m ->> 'descricao', d ->> 'detalhe'));

  v_final := v_manuais || v_deriv;
  if v_final is distinct from v_atual then
    update public.pacientes set alertas_saude = v_final where id = p_paciente;
  end if;

  -- "não" na anamnese x alerta manual do mesmo tipo (tipos com uma pergunta só)
  for r in
    select q.texto, m ->> 'descricao' as descricao
      from public.anamnese_perguntas q
      join jsonb_array_elements(v_manuais) m on m ->> 'tipo' = q.alerta_tipo
     where p_respostas -> q.codigo ->> 'resposta' = 'nao'
       and (select count(*) from public.anamnese_perguntas q2
             where q2.alerta_tipo = q.alerta_tipo and q2.ativa) = 1
  loop
    v_avisos := array_append(v_avisos, format(
      'Conflito: na anamnese a resposta a "%s" foi não, mas a ficha tem o alerta "%s". Confirme com a Dra. qual vale.',
      r.texto, r.descricao));
  end loop;
  return v_avisos;
end
$$;

-- Remove da lista os alertas do cadastro que citam cada termo.
create or replace function public.remover_alertas(p_alertas jsonb, p_termos jsonb,
  out alertas jsonb, out avisos text[])
language plpgsql
set search_path = ''
as $$
declare
  v_original text;
  v_termo text;
  v_manuais int;
  v_anamnese text;
begin
  alertas := coalesce(p_alertas, '[]'::jsonb);
  avisos := '{}';
  for v_original in select jsonb_array_elements_text(p_termos) loop
    v_termo := public.normalizar(v_original);
    if length(v_termo) < 3 then
      raise exception 'Diga qual alerta remover (ex.: "dipirona").';
    end if;
    select count(*) into v_manuais from jsonb_array_elements(alertas) a
     where coalesce(a ->> 'origem', 'manual') <> 'anamnese'
       and public.normalizar(a ->> 'descricao') like '%' || v_termo || '%';
    select string_agg('"' || (a ->> 'descricao') || '"', ', ') into v_anamnese
      from jsonb_array_elements(alertas) a
     where a ->> 'origem' = 'anamnese'
       and public.normalizar(a ->> 'descricao') like '%' || v_termo || '%';
    if v_manuais = 0 and v_anamnese is null then
      raise exception 'Nenhum alerta da ficha cita "%". Alertas atuais: %.', btrim(v_original),
        coalesce((select string_agg(a ->> 'descricao', '; ') from jsonb_array_elements(alertas) a), 'nenhum');
    end if;
    if v_manuais = 0 then
      raise exception 'O alerta % vem da anamnese: corrija a resposta com registrar_anamnese.', v_anamnese;
    end if;
    select coalesce(jsonb_agg(a), '[]'::jsonb) into alertas
      from jsonb_array_elements(alertas) a
     where a ->> 'origem' = 'anamnese'
        or public.normalizar(a ->> 'descricao') not like '%' || v_termo || '%';
    if v_anamnese is not null then
      avisos := array_append(avisos, format(
        'O alerta %s continua porque vem da anamnese; para tirar, corrija a resposta com registrar_anamnese.',
        v_anamnese));
    end if;
  end loop;
end
$$;

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
    select r.alertas, v_avisos || r.avisos into v_alertas, v_avisos
      from public.remover_alertas(v_alertas, p_dados -> 'alertas_remover') r;
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

revoke execute on function
  public.alerta_coberto(text, text),
  public.remover_alertas(jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.alerta_coberto(text, text),
  public.remover_alertas(jsonb, jsonb)
  to service_role;
