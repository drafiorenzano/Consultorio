-- Registrar atendimento: a resposta passa a trazer os avisos do estoque
-- (material acabando, sem contagem...) das baixas automáticas do atendimento.
-- Mesma função de 20261101231852_atendimento_catalogo.sql, só muda o retorno.

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
    'avisos', to_jsonb(v_avisos))
    || jsonb_strip_nulls(jsonb_build_object(
         'avisos_estoque', nullif(to_jsonb(public.estoque_avisos_atendimento(v_id)), '[]'::jsonb)));
end
$$;
