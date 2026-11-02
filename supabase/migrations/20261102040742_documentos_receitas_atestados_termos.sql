-- =====================================================================
-- Etapa 3 (documentos): receitas, atestados, termos e o registro dos PDFs.
--
-- * receitas, atestados, termos_emitidos: só inclusão (documento legal).
--   Cada um guarda o texto/itens como foram emitidos, com número.
-- * mcp_emitir_receita: modelos da seção 8 da referência, checagens de
--   segurança (alergias, anticoagulante + AINE, gestação/amamentação,
--   criança sem peso) que pedem confirmação; controlados são recusados.
-- * mcp_emitir_atestado, mcp_emitir_termo (TCLE ou orientações).
-- * mcp_registrar_documento: o servidor chama depois de subir o PDF.
-- * mcp_ver_documentos: lista por paciente, pendências de acompanhamento
--   dos orçamentos e regeração de PDF.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
create table public.receitas (
  id uuid primary key default gen_random_uuid(),
  numero int not null unique,
  paciente_id uuid not null references public.pacientes (id),
  data date not null,
  itens jsonb not null check (jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) > 0),
  orientacoes text,
  peso_kg numeric(5, 2) check (peso_kg is null or peso_kg between 2 and 300),
  duas_vias boolean not null default false,  -- antibiótico: uma via fica na farmácia
  alertas_confirmados jsonb not null default '[]',
  profissional text,
  cro text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now()
);
comment on table public.receitas is 'Receitas (receita comum) emitidas. Só inclusão. Controlados não passam por aqui.';
create index receitas_paciente_idx on public.receitas (paciente_id, data desc);
create index receitas_solicitacao_idx on public.receitas (solicitacao_id);

create table public.atestados (
  id uuid primary key default gen_random_uuid(),
  numero int not null unique,
  paciente_id uuid not null references public.pacientes (id),
  tipo text not null check (tipo in ('comparecimento', 'repouso', 'acompanhante')),
  data date not null,
  hora_inicio time,
  hora_fim time,
  dias int check (dias is null or dias between 1 and 30),
  a_partir_de date,
  cid text,
  cid_autorizado boolean not null default false,
  acompanhante_nome text,
  finalidade text,
  texto text not null,                        -- texto como saiu no documento
  profissional text,
  cro text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now(),
  check (cid is null or cid_autorizado),
  check (tipo <> 'repouso' or dias is not null),
  check (tipo <> 'acompanhante' or acompanhante_nome is not null)
);
comment on table public.atestados is 'Atestados emitidos. Só inclusão. CID só com autorização do paciente.';
create index atestados_paciente_idx on public.atestados (paciente_id, data desc);
create index atestados_solicitacao_idx on public.atestados (solicitacao_id);

create table public.termos_emitidos (
  id uuid primary key default gen_random_uuid(),
  numero int not null unique,
  paciente_id uuid not null references public.pacientes (id),
  modelo text not null references public.termos_modelos (codigo),
  tipo text not null check (tipo in ('consentimento', 'orientacoes')),
  titulo text not null,
  procedimento text,
  dentes smallint[] not null default '{}',
  observacoes text,
  secoes jsonb not null,                      -- texto como saiu no documento
  responsavel jsonb,
  data date not null,
  profissional text,
  cro text,
  solicitacao_id uuid references public.solicitacoes (id),
  registrado_em timestamptz not null default now()
);
comment on table public.termos_emitidos is 'Termos de consentimento e orientações entregues. Só inclusão.';
create index termos_emitidos_paciente_idx on public.termos_emitidos (paciente_id, data desc);
create index termos_emitidos_solicitacao_idx on public.termos_emitidos (solicitacao_id);

create trigger receitas_so_inclusao before update or delete on public.receitas
  for each row execute function public.bloquear_alteracao();
create trigger receitas_sem_truncate before truncate on public.receitas
  for each statement execute function public.bloquear_alteracao();
create trigger receitas_auditoria after insert on public.receitas
  for each row execute function public.registrar_auditoria();
create trigger atestados_so_inclusao before update or delete on public.atestados
  for each row execute function public.bloquear_alteracao();
create trigger atestados_sem_truncate before truncate on public.atestados
  for each statement execute function public.bloquear_alteracao();
create trigger atestados_auditoria after insert on public.atestados
  for each row execute function public.registrar_auditoria();
create trigger termos_emitidos_so_inclusao before update or delete on public.termos_emitidos
  for each row execute function public.bloquear_alteracao();
create trigger termos_emitidos_sem_truncate before truncate on public.termos_emitidos
  for each statement execute function public.bloquear_alteracao();
create trigger termos_emitidos_auditoria after insert on public.termos_emitidos
  for each row execute function public.registrar_auditoria();

alter table public.receitas enable row level security;
alter table public.atestados enable row level security;
alter table public.termos_emitidos enable row level security;
revoke all on table public.receitas, public.atestados, public.termos_emitidos from anon, authenticated;

-- ---------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------
create or replace function public.numero_extenso(p int)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove', 'dez',
                'onze', 'doze', 'treze', 'catorze', 'quinze', 'dezesseis', 'dezessete', 'dezoito', 'dezenove', 'vinte',
                'vinte e um', 'vinte e dois', 'vinte e três', 'vinte e quatro', 'vinte e cinco', 'vinte e seis',
                'vinte e sete', 'vinte e oito', 'vinte e nove', 'trinta'])[p]
$$;

create or replace function public.hora_texto(p time)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p is null then null
              when extract(minute from p) = 0 then to_char(p, 'FMHH24') || 'h'
              else to_char(p, 'FMHH24"h"MI') end
$$;

-- Próximo número de um documento (sem sequência: tentativa desfeita não gasta número).
create or replace function public.documentos_proximo_numero(p_tabela text)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v int;
begin
  if p_tabela not in ('receitas', 'atestados', 'termos_emitidos') then
    raise exception 'Tabela sem numeração: %.', p_tabela;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.' || p_tabela || '.numero'));
  execute format('select coalesce(max(numero), 0) + 1 from public.%I', p_tabela) into v;
  return v;
end
$$;

-- O que o paciente tem de saúde que pesa na receita: alertas + anamnese.
create or replace function public.receita_contexto(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with p as (select * from public.pacientes where id = p_paciente),
  a as (select respostas from public.anamneses where paciente_id = p_paciente order by versao desc limit 1),
  al as (select x ->> 'tipo' as tipo, x ->> 'descricao' as descricao
           from p, jsonb_array_elements(p.alertas_saude) x)
  select jsonb_build_object(
    'alergias_texto', nullif(concat_ws('; ',
       (select string_agg(descricao, '; ') from al where tipo = 'alergia'),
       (select string_agg(a.respostas -> k ->> 'detalhe', '; ') from a, unnest(array['alergia_medicamento', 'alergia_anestesico', 'alergia_outras']) k
         where a.respostas -> k ->> 'resposta' = 'sim')), ''),
    'alergias', public.normalizar(concat_ws(' ; ',
       (select string_agg(descricao, ' ; ') from al where tipo = 'alergia'),
       (select string_agg(a.respostas -> k ->> 'detalhe', ' ; ') from a, unnest(array['alergia_medicamento', 'alergia_anestesico', 'alergia_outras']) k
         where a.respostas -> k ->> 'resposta' = 'sim'))),
    'alergia_sem_detalhe', coalesce((select a.respostas -> 'alergia_medicamento' ->> 'resposta' = 'sim'
                                            and nullif(btrim(a.respostas -> 'alergia_medicamento' ->> 'detalhe'), '') is null
                                       from a), false)
                           and not exists (select 1 from al where tipo = 'alergia'),
    'anticoagulante', exists (select 1 from al where tipo in ('anticoagulante', 'antiagregante', 'coagulopatia'))
                      or coalesce((select a.respostas -> 'anticoagulante' ->> 'resposta' = 'sim'
                                          or a.respostas -> 'antiagregante' ->> 'resposta' = 'sim' from a), false),
    'anticoagulante_texto', (select string_agg(descricao, '; ') from al where tipo in ('anticoagulante', 'antiagregante', 'coagulopatia')),
    'gestacao', exists (select 1 from al where tipo = 'gestacao')
                or coalesce((select a.respostas -> 'gestacao' ->> 'resposta' = 'sim' from a), false),
    'amamentacao', exists (select 1 from al where tipo = 'amamentacao')
                   or coalesce((select a.respostas -> 'amamentacao' ->> 'resposta' = 'sim' from a), false),
    'renal', coalesce((select a.respostas -> 'renal' ->> 'resposta' = 'sim' from a), false)
             or exists (select 1 from al where public.normalizar(descricao) ~ '(renal|\mrins?\M)'),
    'hepatica', coalesce((select a.respostas -> 'hepatica' ->> 'resposta' = 'sim' or a.respostas -> 'hepatite' ->> 'resposta' = 'sim' from a), false),
    'respiratoria', coalesce((select a.respostas -> 'respiratoria' ->> 'resposta' = 'sim' from a), false)
                    or exists (select 1 from al where public.normalizar(descricao) like '%asma%'),
    'hipertensao', exists (select 1 from al where tipo = 'hipertensao')
                   or coalesce((select a.respostas -> 'hipertensao' ->> 'resposta' = 'sim' from a), false),
    'anamnese', exists (select 1 from a))
$$;

-- Classe de um medicamento escrito por extenso (para as checagens).
create or replace function public.medicamento_classe(p_nome text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when n ~ '(amoxi|ampicil|penicil|benzetacil|cefalex|cefadrox|cefuroxim|ceftriax|clavulan)' then 'betalactamico'
    when n ~ '(dipirona|novalgin|metamizol|lisador|anador)' then 'dipirona'
    when n ~ '(ibuprof|nimesul|diclofen|cetorolac|naprox|cetoprof|piroxic|meloxic|celecox|etoricox|aspirin|acido acetilsalicilico|\maas\M|toragesic|advil|alivium|cataflam|voltaren|profenid|arcoxia)' then 'aine'
    when n ~ '(metronid|flagyl|tinidaz)' then 'nitroimidazolico'
    when n ~ '(azitro|claritro|eritromic)' then 'macrolideo'
    when n ~ '(clindam|dalacin)' then 'lincosamida'
    when n ~ '(dexamet|betamet|predniso|decadron|celestone)' then 'corticoide'
    when n ~ '(paracetam|tylenol)' then 'analgesico'
    when n ~ '(clorexid|periogard)' then 'antisseptico'
    when n ~ '(ciclina|floxacin|micina|sulfa|bactrim)' then 'outro_antibiotico'
  end
  from (select public.normalizar(p_nome) as n) x
$$;

-- Controle especial (Portaria 344/98): não sai pelo sistema, só no talão.
create or replace function public.medicamento_controlado(p_nome text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select public.normalizar(p_nome) ~
    '(azepam|azolam|zolpidem|tramadol|tramal|codeina|tylex|morfina|oxicodona|metadona|fentanil|tapentadol|buprenorfina|nalbufina|meperidina|petidina|pregabalina|gabapentina|carbamazepina|oxcarbazepina|tegretol|amitriptilina|nortriptilina|fenobarbital|rivotril|frontal|dormonid|lexotan|valium|zolfest|stilnox)'
$$;

create or replace function public.via_texto(p_via text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_via when 'oral' then 'Uso oral' when 'sublingual' then 'Uso sublingual'
                    when 'bochecho' then 'Uso bucal (bochecho)' when 'topica' then 'Uso tópico' else 'Uso oral' end
$$;

create or replace function public.receita_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', r.id,
    'numero', r.numero,
    'data', r.data,
    'data_extenso', public.data_extenso(r.data),
    'paciente', public.documentos_paciente(r.paciente_id),
    'cabecalho', public.documentos_cabecalho(),
    'itens', r.itens,
    'orientacoes', r.orientacoes,
    'peso_kg', r.peso_kg,
    'duas_vias', r.duas_vias,
    'validade_dias', case when r.duas_vias then 10 end,
    'alertas_confirmados', case when jsonb_array_length(r.alertas_confirmados) > 0 then r.alertas_confirmados end,
    'profissional', r.profissional,
    'cro', r.cro))
  from public.receitas r where r.id = p_id
$$;

create or replace function public.atestado_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', a.id,
    'numero', a.numero,
    'tipo', a.tipo,
    'titulo', case a.tipo when 'comparecimento' then 'Declaração de comparecimento'
                          when 'acompanhante' then 'Declaração de acompanhante'
                          else 'Atestado odontológico' end,
    'data', a.data,
    'data_extenso', public.data_extenso(a.data),
    'hora_inicio', public.hora_texto(a.hora_inicio),
    'hora_fim', public.hora_texto(a.hora_fim),
    'dias', a.dias,
    'cid', a.cid,
    'texto', a.texto,
    'paciente', public.documentos_paciente(a.paciente_id),
    'cabecalho', public.documentos_cabecalho(),
    'profissional', a.profissional,
    'cro', a.cro))
  from public.atestados a where a.id = p_id
$$;

create or replace function public.termo_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', t.id,
    'numero', t.numero,
    'modelo', t.modelo,
    'tipo', t.tipo,
    'titulo', t.titulo,
    'procedimento', t.procedimento,
    'dentes', case when cardinality(t.dentes) > 0 then to_jsonb(t.dentes) end,
    'secoes', t.secoes,
    'observacoes', t.observacoes,
    'declaracao', case when t.tipo = 'consentimento' then
      'Declaro que li (ou ouvi a leitura de) este termo, que recebi explicações claras sobre o tratamento proposto, '
      || 'seus benefícios, riscos, alternativas e possíveis complicações, que pude fazer perguntas e que elas foram '
      || 'respondidas. Sei que o resultado não pode ser garantido, porque depende também da resposta do organismo e '
      || 'dos cuidados após o tratamento. Comprometo-me a informar com verdade minha condição de saúde, a seguir as '
      || 'orientações e a comparecer aos retornos. Autorizo a realização do tratamento descrito e sei que posso '
      || 'retirar esta autorização a qualquer momento antes do procedimento.' end,
    'responsavel', t.responsavel,
    'data', t.data,
    'data_extenso', public.data_extenso(t.data),
    'paciente', public.documentos_paciente(t.paciente_id),
    'cabecalho', public.documentos_cabecalho(),
    'profissional', t.profissional,
    'cro', t.cro))
  from public.termos_emitidos t where t.id = p_id
$$;

-- Pacote para o servidor gerar o PDF de qualquer documento.
create or replace function public.documento_para_pdf(p_tipo text, p_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pac uuid;
  v_num int;
  v_titulo text;
  v_dados jsonb;
  v_tipo text := p_tipo;
begin
  if p_tipo = 'orcamento' then
    return public.orcamento_documento(p_id);
  elsif p_tipo = 'receita' then
    select paciente_id, numero, 'Receita nº ' || numero into v_pac, v_num, v_titulo from public.receitas where id = p_id;
    v_dados := public.receita_json(p_id);
  elsif p_tipo = 'atestado' then
    select paciente_id, numero,
           case tipo when 'comparecimento' then 'Declaração de comparecimento nº ' when 'acompanhante' then 'Declaração de acompanhante nº '
                     else 'Atestado nº ' end || numero
      into v_pac, v_num, v_titulo from public.atestados where id = p_id;
    v_dados := public.atestado_json(p_id);
  elsif p_tipo in ('termo', 'orientacoes') then
    select paciente_id, numero, titulo, case tipo when 'consentimento' then 'termo' else 'orientacoes' end
      into v_pac, v_num, v_titulo, v_tipo from public.termos_emitidos where id = p_id;
    v_dados := public.termo_json(p_id);
  else
    raise exception 'Tipo de documento "%" desconhecido: use orcamento, receita, atestado, termo ou orientacoes.', p_tipo;
  end if;
  if v_pac is null then
    raise exception 'Documento não encontrado (% %).', p_tipo, p_id;
  end if;
  return jsonb_build_object(
    'tipo', v_tipo,
    'referencia_id', p_id,
    'paciente_id', v_pac,
    'titulo', v_titulo,
    'caminho', public.documentos_caminho(v_pac, v_tipo, v_num),
    'solicitacao_id', nullif(current_setting('app.solicitacao_id', true), ''),
    'dados', v_dados);
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: emitir_receita
-- ---------------------------------------------------------------------
create or replace function public.mcp_emitir_receita(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conf public.configuracao;
  v_pac public.pacientes;
  v_ctx jsonb;
  v_idade int;
  v_data date;
  v_peso numeric := public.documentos_ler_numero(p_dados ->> 'peso_kg', 'Peso (kg)');
  v_confirmar boolean := coalesce((p_dados ->> 'confirmar_alertas')::boolean, false);
  v_med jsonb;
  v_mod public.medicamentos_modelos;
  v_itens jsonb := '[]';
  v_alertas text[] := '{}';
  v_avisos text[] := '{}';
  v_nome text;
  v_classe text;
  v_antibiotico boolean;
  v_posologia text;
  v_quantidade text;
  v_mg numeric;
  v_ml numeric;
  v_ml_txt text;
  v_frascos int;
  v_alerg text;
  v_alerg_txt text;
  v_tem_antibiotico boolean := false;
  v_tem_aine boolean := false;
  v_id uuid;
  v_n int := 0;
  v_txt text;
begin
  perform public.iniciar_solicitacao('emitir_receita', p_dados, p_texto_original);
  select * into v_conf from public.configuracao;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_idade := public.idade(v_pac.data_nascimento);
  v_ctx := public.receita_contexto(v_pac.id);
  v_alerg := coalesce(v_ctx ->> 'alergias', '');
  v_alerg_txt := coalesce(v_ctx ->> 'alergias_texto', v_alerg);
  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data da receita'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data da receita (%) está no futuro.', v_data;
  end if;
  if v_data < public.hoje() - 7 then
    v_avisos := v_avisos || format('Receita com data retroativa (%s).', to_char(v_data, 'DD/MM/YYYY'));
  end if;
  if v_peso is not null and (v_peso < 2 or v_peso > 300) then
    raise exception 'Peso de % kg fora do esperado.', v_peso;
  end if;
  if jsonb_typeof(p_dados -> 'medicamentos') is distinct from 'array' or jsonb_array_length(p_dados -> 'medicamentos') = 0 then
    raise exception 'Informe os medicamentos (lista de {modelo} ou {nome, concentracao, forma, quantidade, posologia}).';
  end if;

  for v_med in select * from jsonb_array_elements(p_dados -> 'medicamentos') loop
    v_n := v_n + 1;
    v_mod := null;
    v_txt := coalesce(nullif(btrim(v_med ->> 'modelo'), ''), nullif(btrim(v_med ->> 'nome'), ''));
    if v_txt is null then
      raise exception 'Medicamento %: informe o modelo (ex.: amoxicilina_500) ou o nome.', v_n;
    end if;
    if public.medicamento_controlado(v_txt) then
      raise exception '"%" é de controle especial (Portaria 344/98): não sai por aqui. Use o talão de receita de controle especial em papel.', v_txt;
    end if;
    if nullif(btrim(v_med ->> 'modelo'), '') is not null then
      select * into v_mod from public.medicamentos_modelos m
       where m.ativo and (m.codigo = public.codigo_de(v_med ->> 'modelo')
                          or public.normalizar(v_med ->> 'modelo') = any (m.sinonimos))
       order by (m.codigo = public.codigo_de(v_med ->> 'modelo')) desc, m.ordem
       limit 1;
      if not found then
        raise exception 'Modelo de receita "%" não existe. Modelos: %.', v_med ->> 'modelo',
          (select string_agg(codigo, ', ' order by ordem) from public.medicamentos_modelos where ativo);
      end if;
    end if;

    if v_mod.codigo is not null then
      v_nome := v_mod.nome;
      v_classe := v_mod.classe;
      v_antibiotico := v_mod.antibiotico;
      v_posologia := coalesce(nullif(btrim(v_med ->> 'posologia'), ''), v_mod.posologia);
      v_quantidade := coalesce(nullif(btrim(v_med ->> 'quantidade'), ''), v_mod.quantidade);
      if v_mod.pediatrico then
        if v_peso is null then
          raise exception 'Informe o peso da criança (peso_kg) para calcular a dose de %.', lower(v_mod.nome);
        end if;
        if v_mod.dose_unica then
          v_mg := least(v_mod.mg_kg * v_peso, v_mod.max_mg_dose);
          v_ml := round(v_mg / v_mod.mg_por_ml, 1);
          v_frascos := greatest(1, ceil(v_ml / v_mod.frasco_ml));
        else
          v_mg := least(v_mod.mg_kg * v_peso / v_mod.doses_dia, v_mod.max_mg_dose);
          v_ml := round(v_mg / v_mod.mg_por_ml, 1);
          v_frascos := greatest(1, ceil(v_ml * v_mod.doses_dia * v_mod.dias / v_mod.frasco_ml));
        end if;
        v_ml_txt := replace(trim(trailing '.' from trim(trailing '0' from v_ml::text)), '.', ',');
        v_posologia := replace(v_posologia, '{ml}', v_ml_txt);
        v_quantidade := coalesce(nullif(btrim(v_med ->> 'quantidade'), ''),
                                 v_frascos || case when v_frascos = 1 then ' frasco de ' else ' frascos de ' end || v_mod.frasco_ml || ' ml');
        v_avisos := v_avisos || format('%s: %s mg por dose (%s ml) para %s kg. Confira o cálculo.',
                                       v_mod.nome, round(v_mg), v_ml_txt, v_peso);
        if v_idade is not null and v_idade >= 12 then
          v_avisos := v_avisos || format('Modelo pediátrico para paciente de %s anos: confira.', v_idade);
        end if;
      elsif v_idade is not null and v_idade < 12 and v_mod.classe <> 'antisseptico' then
        v_alertas := v_alertas || format('Paciente de %s anos e %s é dose de adulto: para criança a dose é pelo peso (use o modelo pediátrico com peso_kg).',
                                         v_idade, v_mod.nome || coalesce(' ' || v_mod.concentracao, ''));
      end if;
      v_med := jsonb_strip_nulls(jsonb_build_object(
        'modelo', v_mod.codigo, 'nome', v_mod.nome, 'concentracao', v_mod.concentracao, 'forma', v_mod.forma,
        'via', v_mod.via, 'via_texto', public.via_texto(v_mod.via), 'quantidade', v_quantidade,
        'posologia', v_posologia, 'classe', v_mod.classe, 'antibiotico', v_mod.antibiotico));
    else
      v_nome := btrim(v_med ->> 'nome');
      v_classe := public.medicamento_classe(v_nome);
      v_antibiotico := v_classe in ('betalactamico', 'nitroimidazolico', 'macrolideo', 'lincosamida', 'outro_antibiotico');
      v_posologia := nullif(btrim(v_med ->> 'posologia'), '');
      v_quantidade := nullif(btrim(v_med ->> 'quantidade'), '');
      if v_posologia is null then
        raise exception 'Informe a posologia de % (como tomar, de quanto em quanto tempo, por quantos dias).', v_nome;
      end if;
      if v_quantidade is null then
        v_avisos := v_avisos || format('Faltou a quantidade de %s (ex.: 1 caixa, 21 cápsulas).', v_nome);
      end if;
      if nullif(btrim(v_med ->> 'concentracao'), '') is null then
        v_avisos := v_avisos || format('Faltou a concentração de %s (ex.: 500 mg).', v_nome);
      end if;
      if v_idade is not null and v_idade < 12 and v_classe is distinct from 'antisseptico' then
        v_alertas := v_alertas || format('Paciente de %s anos: confirme que a dose de %s está ajustada ao peso.', v_idade, v_nome);
      end if;
      v_med := jsonb_strip_nulls(jsonb_build_object(
        'nome', v_nome, 'concentracao', nullif(btrim(v_med ->> 'concentracao'), ''),
        'forma', nullif(btrim(v_med ->> 'forma'), ''),
        'via', coalesce(nullif(btrim(v_med ->> 'via'), ''), 'oral'),
        'via_texto', public.via_texto(coalesce(nullif(btrim(v_med ->> 'via'), ''), 'oral')),
        'quantidade', v_quantidade, 'posologia', v_posologia, 'classe', v_classe, 'antibiotico', v_antibiotico));
    end if;

    -- Checagens de segurança
    if v_classe = 'betalactamico' and v_alerg ~ '(penicil|amoxi|ampicil|benzetacil|betalact|cefal)' then
      v_alertas := v_alertas || format('Alergia registrada (%s) e a receita tem %s, que é da família da penicilina. Troque por azitromicina ou clindamicina, ou confirme.',
                                       v_alerg_txt, v_nome);
    end if;
    if v_classe = 'dipirona' and v_alerg ~ '(dipirona|novalgin|metamizol)' then
      v_alertas := v_alertas || format('Alergia a dipirona registrada e a receita tem %s. Troque por paracetamol, ou confirme.', v_nome);
    end if;
    if v_classe = 'aine' and v_alerg ~ '(aine|anti-?inflamat|ibuprof|nimesul|diclofen|cetorolac|aspirin|\maas\M|acido acetilsalicilico|naprox|cetoprof)' then
      v_alertas := v_alertas || format('Alergia a anti-inflamatório registrada (%s) e a receita tem %s. Confirme.', v_alerg_txt, v_nome);
    end if;
    if v_alerg <> '' and v_classe is distinct from 'betalactamico' and v_classe is distinct from 'dipirona'
       and v_classe is distinct from 'aine'
       and position(split_part(public.normalizar(v_nome), ' ', 1) in v_alerg) > 0 then
      v_alertas := v_alertas || format('A alergia registrada (%s) cita %s. Confirme.', v_alerg_txt, v_nome);
    end if;
    if v_classe = 'aine' then
      v_tem_aine := true;
      if (v_ctx ->> 'anticoagulante')::boolean then
        v_alertas := v_alertas || format('Usa anticoagulante/antiagregante (%s) e %s aumenta o risco de sangramento. Prefira dipirona ou paracetamol, ou confirme.',
                                         coalesce(v_ctx ->> 'anticoagulante_texto', 'anamnese'), v_nome);
      end if;
      if (v_ctx ->> 'gestacao')::boolean then
        v_alertas := v_alertas || format('Gestante: anti-inflamatório (%s) deve ser evitado, principalmente no último trimestre. Confirme.', v_nome);
      end if;
      if (v_ctx ->> 'renal')::boolean then
        v_alertas := v_alertas || format('Problema renal registrado e %s pode piorar a função dos rins. Confirme.', v_nome);
      end if;
      if (v_ctx ->> 'hipertensao')::boolean then
        v_avisos := v_avisos || format('Hipertenso: %s pode elevar a pressão; use pelo menor tempo possível.', v_nome);
      end if;
      if (v_ctx ->> 'respiratoria')::boolean then
        v_avisos := v_avisos || format('Doença respiratória/asma registrada: %s pode desencadear crise em asmáticos sensíveis.', v_nome);
      end if;
    end if;
    if v_classe = 'nitroimidazolico' then
      if (v_ctx ->> 'gestacao')::boolean then
        v_alertas := v_alertas || format('Gestante: %s deve ser evitado, principalmente no primeiro trimestre. Confirme.', v_nome);
      end if;
      if (v_ctx ->> 'amamentacao')::boolean then
        v_alertas := v_alertas || format('Amamentando: %s passa para o leite (orientar suspender a amamentação durante o uso e por 12 a 24 h depois). Confirme.', v_nome);
      end if;
    end if;
    if v_classe = 'analgesico' and (v_ctx ->> 'hepatica')::boolean then
      v_avisos := v_avisos || format('Doença do fígado registrada: %s exige dose reduzida.', v_nome);
    end if;
    if v_antibiotico then
      v_tem_antibiotico := true;
    end if;
    v_itens := v_itens || jsonb_build_array(v_med);
  end loop;

  if (v_ctx ->> 'alergia_sem_detalhe')::boolean then
    v_alertas := v_alertas || 'A anamnese diz alergia a medicamento sem dizer qual. Confirme com o paciente que não é a nenhum destes.'::text;
  end if;
  if not (v_ctx ->> 'anamnese')::boolean and jsonb_array_length(v_pac.alertas_saude) = 0 then
    v_avisos := v_avisos || 'Paciente sem anamnese registrada: as checagens de alergia e saúde ficaram limitadas.'::text;
  end if;

  if cardinality(v_alertas) > 0 and not v_confirmar then
    return jsonb_build_object(
      'status', 'confirmacao_necessaria',
      'mensagem', 'Nada foi gravado. Leia os alertas para a Dra.; se ela mantiver a receita, chame de novo com confirmar_alertas: true. Se ela trocar o medicamento, chame com a receita nova.',
      'alertas', to_jsonb(v_alertas),
      'avisos', to_jsonb(v_avisos));
  end if;

  if v_tem_antibiotico then
    v_avisos := v_avisos || 'Antibiótico: imprima as 2 vias (uma fica retida na farmácia). A receita vale 10 dias.'::text;
    if v_pac.endereco is null or public.endereco_texto(v_pac.endereco) is null then
      v_avisos := v_avisos || 'Paciente sem endereço no cadastro: a farmácia pode exigir o endereço na receita de antibiótico.'::text;
    end if;
  end if;

  insert into public.receitas (numero, paciente_id, data, itens, orientacoes, peso_kg, duas_vias, alertas_confirmados,
                               profissional, cro, solicitacao_id)
  values (public.documentos_proximo_numero('receitas'), v_pac.id, v_data, v_itens,
          nullif(btrim(p_dados ->> 'orientacoes'), ''), v_peso, v_tem_antibiotico, to_jsonb(v_alertas),
          v_conf.dentista_nome, v_conf.cro, nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  return jsonb_build_object(
    'status', 'ok',
    'receita', public.receita_json(v_id) - 'cabecalho',
    'documento', public.documento_para_pdf('receita', v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: emitir_atestado
-- ---------------------------------------------------------------------
create or replace function public.mcp_emitir_atestado(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conf public.configuracao;
  v_pac public.pacientes;
  v_tipo text := coalesce(nullif(public.normalizar(p_dados ->> 'tipo'), ''), 'comparecimento');
  v_data date;
  v_hi time;
  v_hf time;
  v_dias numeric;
  v_a_partir date;
  v_cid text := nullif(upper(btrim(p_dados ->> 'cid')), '');
  v_cid_ok boolean := coalesce((p_dados ->> 'cid_autorizado')::boolean, false);
  v_acomp text := nullif(btrim(p_dados ->> 'acompanhante_nome'), '');
  v_finalidade text := nullif(btrim(p_dados ->> 'finalidade'), '');
  v_nome text;
  v_ident text;
  v_horario text;
  v_texto text;
  v_avisos text[] := '{}';
  v_resp jsonb;
  v_id uuid;
begin
  perform public.iniciar_solicitacao('emitir_atestado', p_dados, p_texto_original);
  select * into v_conf from public.configuracao;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  if v_tipo not in ('comparecimento', 'repouso', 'acompanhante') then
    raise exception 'Tipo de atestado "%" inválido: use comparecimento, repouso ou acompanhante.', p_dados ->> 'tipo';
  end if;
  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data do atendimento'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data do atestado (%) está no futuro.', v_data;
  end if;
  begin
    v_hi := nullif(btrim(p_dados ->> 'hora_inicio'), '')::time;
    v_hf := nullif(btrim(p_dados ->> 'hora_fim'), '')::time;
  exception when others then
    raise exception 'Horário inválido: use HH:MM (ex.: 14:30).';
  end;
  -- horário do atendimento do dia, se não foi dito
  if v_hi is null then
    select a.hora_inicio, coalesce(v_hf, a.hora_fim) into v_hi, v_hf
      from public.atendimentos a
     where a.paciente_id = v_pac.id and a.data = v_data and a.hora_inicio is not null
     order by a.registrado_em desc limit 1;
    if v_hi is not null then
      v_avisos := v_avisos || format('Horário tirado do atendimento de %s: %s às %s.', to_char(v_data, 'DD/MM/YYYY'),
                                     public.hora_texto(v_hi), coalesce(public.hora_texto(v_hf), '?'));
    end if;
  end if;
  if v_hi is not null and v_hf is not null and v_hf < v_hi then
    raise exception 'A hora de fim (%) é anterior à de início (%).', v_hf, v_hi;
  end if;
  if v_tipo in ('comparecimento', 'acompanhante') and (v_hi is null or v_hf is null) then
    raise exception 'Informe hora_inicio e hora_fim (não há atendimento com horário registrado em %).', to_char(v_data, 'DD/MM/YYYY');
  end if;

  if v_cid is not null and not v_cid_ok then
    raise exception 'O CID só entra no atestado com autorização expressa do paciente. Pergunte e, se ele autorizar, mande cid_autorizado: true.';
  end if;
  if v_cid is not null and v_cid !~ '^[A-Z][0-9]{2}(\.?[0-9]{1,2})?$' then
    raise exception 'CID "%" em formato estranho (ex.: K08.1).', p_dados ->> 'cid';
  end if;

  v_nome := coalesce(v_pac.nome_social, v_pac.nome);
  v_ident := v_nome || case when v_pac.cpf is not null then
    ', CPF ' || substr(v_pac.cpf, 1, 3) || '.' || substr(v_pac.cpf, 4, 3) || '.' || substr(v_pac.cpf, 7, 3) || '-' || substr(v_pac.cpf, 10, 2) || ','
    else '' end;
  v_horario := case when v_hi is not null and v_hf is not null then ', das ' || public.hora_texto(v_hi) || ' às ' || public.hora_texto(v_hf)
                    when v_hi is not null then ', a partir das ' || public.hora_texto(v_hi) else '' end;

  if v_tipo = 'repouso' then
    v_dias := public.documentos_ler_numero(p_dados ->> 'dias', 'Dias de repouso');
    if v_dias is null or v_dias <> trunc(v_dias) or v_dias not between 1 and 30 then
      raise exception 'Informe os dias de repouso (1 a 30).';
    end if;
    if v_dias > 5 then
      v_avisos := v_avisos || format('%s dias de repouso: confira.', v_dias);
    end if;
    v_a_partir := coalesce(public.ler_data(p_dados ->> 'a_partir_de', 'Início do repouso'), v_data);
    v_texto := format('Atesto, para os devidos fins, que %s esteve em atendimento odontológico neste consultório em %s%s, '
                      || 'e necessita de %s (%s) dia%s de repouso, a partir de %s.',
                      v_ident, public.data_extenso(v_data), v_horario, v_dias, public.numero_extenso(v_dias::int),
                      case when v_dias > 1 then 's' else '' end, public.data_extenso(v_a_partir));
  elsif v_tipo = 'acompanhante' then
    if v_acomp is null and public.idade(v_pac.data_nascimento) < 18 then
      select nome into v_acomp from public.responsaveis where paciente_id = v_pac.id order by e_pagador desc, criado_em limit 1;
      if v_acomp is not null then
        v_avisos := v_avisos || format('Acompanhante: %s (responsável cadastrado).', v_acomp);
      end if;
    end if;
    if v_acomp is null then
      raise exception 'Informe o nome do acompanhante (acompanhante_nome).';
    end if;
    v_texto := format('Declaro, para os devidos fins, que %s esteve neste consultório em %s%s, acompanhando %s em atendimento odontológico.',
                      v_acomp, public.data_extenso(v_data), v_horario, rtrim(v_ident, ','));
  else
    v_texto := format('Declaro, para os devidos fins, que %s esteve neste consultório em atendimento odontológico em %s%s.',
                      v_ident, public.data_extenso(v_data), v_horario);
  end if;
  if v_finalidade is not null then
    v_texto := v_texto || ' Finalidade: ' || v_finalidade || '.';
  end if;
  if v_cid is not null then
    v_texto := v_texto || ' CID ' || v_cid || ', informado com autorização expressa do paciente.';
  end if;

  insert into public.atestados (numero, paciente_id, tipo, data, hora_inicio, hora_fim, dias, a_partir_de, cid, cid_autorizado,
                                acompanhante_nome, finalidade, texto, profissional, cro, solicitacao_id)
  values (public.documentos_proximo_numero('atestados'), v_pac.id, v_tipo, v_data, v_hi, v_hf, v_dias::int, v_a_partir,
          v_cid, v_cid_ok and v_cid is not null, case when v_tipo = 'acompanhante' then v_acomp end, v_finalidade, v_texto,
          v_conf.dentista_nome, v_conf.cro, nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  return jsonb_build_object(
    'status', 'ok',
    'atestado', public.atestado_json(v_id) - 'cabecalho' - 'paciente',
    'documento', public.documento_para_pdf('atestado', v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: emitir_termo (consentimento ou orientações)
-- ---------------------------------------------------------------------
create or replace function public.mcp_emitir_termo(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conf public.configuracao;
  v_pac public.pacientes;
  v_mod public.termos_modelos;
  v_tipo text := nullif(replace(public.normalizar(p_dados ->> 'tipo'), ' ', '_'), '');
  v_busca text := nullif(btrim(p_dados ->> 'modelo'), '');
  v_dentes smallint[] := '{}';
  v_dentes_txt text := '';
  v_proc text;
  v_secoes jsonb;
  v_resp jsonb;
  v_data date;
  v_avisos text[] := '{}';
  v_id uuid;
begin
  perform public.iniciar_solicitacao('emitir_termo', p_dados, p_texto_original);
  select * into v_conf from public.configuracao;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  if v_tipo in ('orientacao', 'pos_operatorio', 'cuidados') then
    v_tipo := 'orientacoes';
  elsif v_tipo in ('termo', 'tcle') then
    v_tipo := 'consentimento';
  end if;
  if v_tipo is not null and v_tipo not in ('consentimento', 'orientacoes') then
    raise exception 'Tipo "%" inválido: use consentimento ou orientacoes.', p_dados ->> 'tipo';
  end if;
  if v_busca is null then
    raise exception 'Informe o modelo. Termos: %. Orientações: %.',
      (select string_agg(codigo, ', ' order by ordem) from public.termos_modelos where ativo and tipo = 'consentimento'),
      (select string_agg(codigo, ', ' order by ordem) from public.termos_modelos where ativo and tipo = 'orientacoes');
  end if;
  select * into v_mod from public.termos_modelos m
   where m.ativo and (v_tipo is null or m.tipo = v_tipo)
     and (m.codigo = public.codigo_de(v_busca) or public.normalizar(v_busca) = any (m.sinonimos))
   order by (m.codigo = public.codigo_de(v_busca)) desc, (m.tipo = 'consentimento') desc, m.ordem
   limit 1;
  if not found then
    raise exception 'Modelo "%" não encontrado. Termos: %. Orientações: %.', v_busca,
      (select string_agg(codigo, ', ' order by ordem) from public.termos_modelos where ativo and tipo = 'consentimento'),
      (select string_agg(codigo, ', ' order by ordem) from public.termos_modelos where ativo and tipo = 'orientacoes');
  end if;

  if jsonb_typeof(p_dados -> 'dentes') = 'array' then
    v_dentes := array(select public.ler_dente(x) from jsonb_array_elements_text(p_dados -> 'dentes') x);
  elsif nullif(p_dados ->> 'dente', '') is not null then
    v_dentes := array[public.ler_dente(p_dados ->> 'dente')];
  end if;
  if cardinality(v_dentes) = 1 then
    v_dentes_txt := 'do dente ' || v_dentes[1];
  elsif cardinality(v_dentes) > 1 then
    v_dentes_txt := 'dos dentes ' || array_to_string(v_dentes[1:cardinality(v_dentes) - 1], ', ') || ' e ' || v_dentes[cardinality(v_dentes)];
  end if;
  v_proc := coalesce(nullif(btrim(p_dados ->> 'procedimento'), ''),
                     btrim(replace(coalesce(v_mod.procedimento, v_mod.titulo), '{dentes}', v_dentes_txt)));
  if nullif(btrim(p_dados ->> 'procedimento'), '') is not null and v_dentes_txt <> '' and position(v_dentes_txt in v_proc) = 0 then
    v_proc := v_proc || ' ' || v_dentes_txt;
  end if;
  select jsonb_agg(jsonb_build_object('titulo', s ->> 'titulo', 'texto', replace(s ->> 'texto', '{procedimento}', v_proc)) order by o)
    into v_secoes
    from jsonb_array_elements(v_mod.secoes) with ordinality t(s, o);

  v_data := coalesce(public.ler_data(p_dados ->> 'data', 'Data'), public.hoje());
  if v_data > public.hoje() then
    raise exception 'A data (%) está no futuro.', v_data;
  end if;

  if public.idade(v_pac.data_nascimento) < 18 then
    select jsonb_strip_nulls(jsonb_build_object('nome', r.nome, 'cpf', r.cpf, 'parentesco', r.parentesco)) into v_resp
      from public.responsaveis r where r.paciente_id = v_pac.id order by r.e_pagador desc, r.criado_em limit 1;
    if v_resp is null and v_mod.tipo = 'consentimento' then
      v_avisos := v_avisos || 'Paciente menor sem responsável cadastrado: o termo precisa ser assinado pelo responsável (cadastre com atualizar_paciente).'::text;
    end if;
  end if;
  if v_mod.tipo = 'consentimento' and not exists (select 1 from public.anamneses where paciente_id = v_pac.id) then
    v_avisos := v_avisos || 'Paciente sem anamnese registrada: registre antes do procedimento.'::text;
  end if;
  if v_mod.tipo = 'consentimento' then
    v_avisos := v_avisos || 'Imprima e colha a assinatura antes do procedimento; guarde o termo assinado.'::text;
  end if;

  insert into public.termos_emitidos (numero, paciente_id, modelo, tipo, titulo, procedimento, dentes, observacoes, secoes,
                                      responsavel, data, profissional, cro, solicitacao_id)
  values (public.documentos_proximo_numero('termos_emitidos'), v_pac.id, v_mod.codigo, v_mod.tipo, v_mod.titulo,
          case when v_mod.tipo = 'consentimento' then v_proc end, v_dentes,
          nullif(btrim(p_dados ->> 'observacoes'), ''), v_secoes, v_resp, v_data,
          v_conf.dentista_nome, v_conf.cro, nullif(current_setting('app.solicitacao_id', true), '')::uuid)
  returning id into v_id;

  return jsonb_build_object(
    'status', 'ok',
    'termo', jsonb_build_object('numero', (select numero from public.termos_emitidos where id = v_id), 'modelo', v_mod.codigo,
                                'titulo', v_mod.titulo, 'procedimento', case when v_mod.tipo = 'consentimento' then v_proc end,
                                'data', v_data),
    'documento', public.documento_para_pdf(case when v_mod.tipo = 'consentimento' then 'termo' else 'orientacoes' end, v_id),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Registro do PDF (chamado pelo servidor depois de subir o arquivo)
-- ---------------------------------------------------------------------
create or replace function public.mcp_registrar_documento(p_dados jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tipo text := p_dados ->> 'tipo';
  v_ref uuid;
  v_pac uuid;
  v_sol uuid;
  v_id uuid;
begin
  begin
    v_ref := (p_dados ->> 'referencia_id')::uuid;
    v_sol := nullif(p_dados ->> 'solicitacao_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Identificador inválido no registro do documento.';
  end;
  if v_sol is not null and exists (select 1 from public.solicitacoes where id = v_sol) then
    perform set_config('app.solicitacao_id', v_sol::text, true);
  else
    v_sol := public.iniciar_solicitacao('registrar_documento', p_dados, null);
  end if;
  v_pac := case v_tipo
    when 'orcamento' then (select paciente_id from public.orcamentos where id = v_ref)
    when 'receita' then (select paciente_id from public.receitas where id = v_ref)
    when 'atestado' then (select paciente_id from public.atestados where id = v_ref)
    when 'termo' then (select paciente_id from public.termos_emitidos where id = v_ref and tipo = 'consentimento')
    when 'orientacoes' then (select paciente_id from public.termos_emitidos where id = v_ref and tipo = 'orientacoes')
  end;
  if v_pac is null then
    raise exception 'Documento de origem não encontrado (% %).', v_tipo, v_ref;
  end if;
  if left(p_dados ->> 'caminho', 37) <> v_pac::text || '/' then
    raise exception 'O caminho do arquivo não é da pasta do paciente.';
  end if;
  insert into public.documentos (paciente_id, tipo, referencia_id, titulo, caminho, tamanho_bytes, sha256, solicitacao_id)
  values (v_pac, v_tipo, v_ref, coalesce(nullif(btrim(p_dados ->> 'titulo'), ''), v_tipo), p_dados ->> 'caminho',
          (p_dados ->> 'tamanho_bytes')::int, lower(p_dados ->> 'sha256'), v_sol)
  returning id into v_id;
  return jsonb_build_object('status', 'ok', 'documento_id', v_id);
end
$$;

-- ---------------------------------------------------------------------
-- Ferramenta: ver_documentos
-- ---------------------------------------------------------------------
create or replace function public.documento_arquivo(p_referencia uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('caminho', d.caminho, 'gerado_em', to_char(d.gerado_em at time zone public.fuso(), 'YYYY-MM-DD HH24:MI'))
    from public.documentos d where d.referencia_id = p_referencia order by d.gerado_em desc limit 1
$$;

create or replace function public.mcp_ver_documentos(p_dados jsonb, p_texto_original text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pac public.pacientes;
  v_tipo text := nullif(public.normalizar(p_dados ->> 'tipo'), '');
  v_reg jsonb := p_dados -> 'regerar';
  v_ref uuid;
  v_rtipo text;
  v_num int;
  v_limite int := 10;
  v_res jsonb;
begin
  perform public.iniciar_solicitacao('ver_documentos', p_dados, p_texto_original);
  if v_tipo is not null and v_tipo not in ('orcamento', 'receita', 'atestado', 'termo', 'orientacoes') then
    raise exception 'Tipo "%" inválido: use orcamento, receita, atestado, termo ou orientacoes.', p_dados ->> 'tipo';
  end if;

  -- PDF novo de um documento já emitido
  if v_reg is not null and jsonb_typeof(v_reg) = 'object' then
    v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
    v_rtipo := nullif(public.normalizar(v_reg ->> 'tipo'), '');
    v_num := public.documentos_ler_numero(v_reg ->> 'numero', 'Número')::int;
    if v_num is null then
      raise exception 'Diga o número do documento a gerar de novo (regerar.numero).';
    end if;
    v_ref := case v_rtipo
      when 'orcamento' then (select id from public.orcamentos where paciente_id = v_pac.id and numero = v_num order by versao desc limit 1)
      when 'receita' then (select id from public.receitas where paciente_id = v_pac.id and numero = v_num)
      when 'atestado' then (select id from public.atestados where paciente_id = v_pac.id and numero = v_num)
      when 'termo' then (select id from public.termos_emitidos where paciente_id = v_pac.id and numero = v_num)
      when 'orientacoes' then (select id from public.termos_emitidos where paciente_id = v_pac.id and numero = v_num)
    end;
    if v_ref is null then
      raise exception '% nº % não encontrado para %.', coalesce(v_reg ->> 'tipo', 'Documento'), v_num, v_pac.nome;
    end if;
    return jsonb_build_object('status', 'ok', 'documento', public.documento_para_pdf(v_rtipo, v_ref));
  end if;

  if nullif(p_dados ->> 'paciente_id', '') is not null then
    v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
    select jsonb_strip_nulls(jsonb_build_object(
      'paciente', jsonb_build_object('id', v_pac.id, 'nome', v_pac.nome, 'ficha', v_pac.ficha),
      'orcamentos', case when v_tipo is null or v_tipo = 'orcamento' then (
         select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'numero', j -> 'numero', 'versao', j -> 'versao', 'titulo', j ->> 'titulo',
                  'status', j ->> 'status_texto', 'emitido_em', j ->> 'emitido_em', 'validade', j ->> 'validade',
                  'total', j -> 'total', 'totais_por_opcao', case when j -> 'total' is null then
                    (select jsonb_object_agg(x ->> 'alternativa', x -> 'total') from jsonb_array_elements(j -> 'opcoes') x) end,
                  'proximo_contato', j -> 'acompanhamento' -> 'proximo_contato',
                  'arquivo', public.documento_arquivo(o.id))) order by o.criado_em desc)
           from public.orcamentos o, lateral (select public.orcamento_json(o.id) j) x
          where o.paciente_id = v_pac.id and o.status <> 'substituido') end,
      'receitas', case when v_tipo is null or v_tipo = 'receita' then (
         select jsonb_agg(jsonb_build_object(
                  'numero', r.numero, 'data', r.data,
                  'medicamentos', (select string_agg(concat_ws(' ', i ->> 'nome', i ->> 'concentracao'), '; ')
                                     from jsonb_array_elements(r.itens) i),
                  'arquivo', public.documento_arquivo(r.id)) order by r.data desc, r.numero desc)
           from public.receitas r where r.paciente_id = v_pac.id) end,
      'atestados', case when v_tipo is null or v_tipo = 'atestado' then (
         select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'numero', a.numero, 'tipo', a.tipo, 'data', a.data, 'dias', a.dias,
                  'arquivo', public.documento_arquivo(a.id))) order by a.data desc, a.numero desc)
           from public.atestados a where a.paciente_id = v_pac.id) end,
      'termos', case when v_tipo is null or v_tipo in ('termo', 'orientacoes') then (
         select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'numero', t.numero, 'tipo', t.tipo, 'titulo', t.titulo, 'procedimento', t.procedimento, 'data', t.data,
                  'arquivo', public.documento_arquivo(t.id))) order by t.data desc, t.numero desc)
           from public.termos_emitidos t where t.paciente_id = v_pac.id
            and (v_tipo is null or t.tipo = case v_tipo when 'termo' then 'consentimento' else 'orientacoes' end)) end))
      into v_res;
    if v_res ?| array['orcamentos', 'receitas', 'atestados', 'termos'] then
      return v_res;
    end if;
    return v_res || jsonb_build_object('mensagem', format('%s ainda não tem documentos emitidos.', v_pac.nome));
  end if;

  -- Visão geral: contatos de acompanhamento em dia, orçamentos vencendo e últimos documentos
  select jsonb_strip_nulls(jsonb_build_object(
    'acompanhamento_pendente', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'paciente', p.nome, 'paciente_id', p.id, 'numero', o.numero, 'versao', o.versao,
               'apresentado_em', o.apresentado_em, 'proximo_contato', j -> 'acompanhamento' -> 'proximo_contato',
               'contatos_feitos', jsonb_array_length(o.acompanhamentos),
               'total', j -> 'total', 'status', j ->> 'status_texto'))
             order by j -> 'acompanhamento' ->> 'proximo_contato')
        from public.orcamentos o
        join public.pacientes p on p.id = o.paciente_id and p.arquivado_em is null
        cross join lateral (select public.orcamento_json(o.id) j) x
       where o.status = 'apresentado'
         and (j -> 'acompanhamento' ->> 'em_atraso')::boolean),
    'vencendo_em_3_dias', (
      select jsonb_agg(jsonb_build_object('paciente', p.nome, 'paciente_id', p.id, 'numero', o.numero,
                                          'validade', o.validade) order by o.validade)
        from public.orcamentos o join public.pacientes p on p.id = o.paciente_id
       where o.status = 'apresentado' and o.validade between public.hoje() and public.hoje() + 3),
    'ultimos_documentos', (
      select jsonb_agg(jsonb_build_object('paciente', p.nome, 'titulo', d.titulo, 'tipo', d.tipo,
                                          'gerado_em', to_char(d.gerado_em at time zone public.fuso(), 'YYYY-MM-DD HH24:MI'),
                                          'arquivo', jsonb_build_object('caminho', d.caminho)) order by d.gerado_em desc)
        from (select * from public.documentos
               where v_tipo is null or tipo = v_tipo
               order by gerado_em desc limit v_limite) d
        join public.pacientes p on p.id = d.paciente_id)))
    into v_res;
  if v_res = '{}'::jsonb then
    return jsonb_build_object('mensagem', 'Nenhum documento emitido ainda e nenhum orçamento esperando contato.');
  end if;
  return v_res;
end
$$;

-- ---------------------------------------------------------------------
-- Acesso às funções
-- ---------------------------------------------------------------------
revoke execute on function
  public.numero_extenso(int),
  public.hora_texto(time),
  public.documentos_proximo_numero(text),
  public.receita_contexto(uuid),
  public.medicamento_classe(text),
  public.medicamento_controlado(text),
  public.via_texto(text),
  public.receita_json(uuid),
  public.atestado_json(uuid),
  public.termo_json(uuid),
  public.documento_para_pdf(text, uuid),
  public.mcp_emitir_receita(jsonb, text),
  public.mcp_emitir_atestado(jsonb, text),
  public.mcp_emitir_termo(jsonb, text),
  public.mcp_registrar_documento(jsonb),
  public.documento_arquivo(uuid),
  public.mcp_ver_documentos(jsonb, text)
  from public, anon, authenticated;
grant execute on function
  public.numero_extenso(int),
  public.hora_texto(time),
  public.documentos_proximo_numero(text),
  public.receita_contexto(uuid),
  public.medicamento_classe(text),
  public.medicamento_controlado(text),
  public.via_texto(text),
  public.receita_json(uuid),
  public.atestado_json(uuid),
  public.termo_json(uuid),
  public.documento_para_pdf(text, uuid),
  public.mcp_emitir_receita(jsonb, text),
  public.mcp_emitir_atestado(jsonb, text),
  public.mcp_emitir_termo(jsonb, text),
  public.mcp_registrar_documento(jsonb),
  public.documento_arquivo(uuid),
  public.mcp_ver_documentos(jsonb, text)
  to service_role;
