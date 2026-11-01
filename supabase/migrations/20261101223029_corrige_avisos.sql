-- Corrige a montagem da lista de avisos em cadastrar_paciente
-- (text[] || 'literal' era lido como array) e não avisa falta de telefone
-- quando o responsável tem telefone.

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
    v_avisos := array_append(v_avisos, 'Falta a data de nascimento.');
  end if;
  if v_cpf is null then
    v_avisos := array_append(v_avisos, 'Falta o CPF (necessário para o recibo Receita Saúde).');
  end if;
  if v_tel is null and nullif(v_resp ->> 'telefone', '') is null then
    v_avisos := array_append(v_avisos, 'Falta o telefone.');
  end if;
  if v_idade is not null and v_idade < 18 and v_resp is null then
    v_avisos := array_append(v_avisos, 'Paciente menor de idade sem responsável legal cadastrado.');
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'paciente', public.paciente_ficha(v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;
