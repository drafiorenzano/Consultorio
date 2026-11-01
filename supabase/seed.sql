-- =====================================================================
-- Dados FICTÍCIOS para testes da prova de conceito.
-- Nomes, CPFs e telefones são inventados (CPFs só têm dígitos
-- verificadores válidos). Nunca rodar no banco com pacientes reais.
-- O cadastro passa pelas próprias ferramentas, para testar a auditoria.
-- =====================================================================

-- Os dados do consultório (nome, CRO, endereço) e o catálogo de procedimentos
-- vêm das migrations; aqui ficam só pacientes inventados.

select public.mcp_cadastrar_paciente(
  '{"nome": "João Pedro Almeida", "data_nascimento": "1987-03-12", "sexo": "masculino",
    "cpf": "116.000.345-94", "telefone": "(11) 98111-2233", "profissao": "engenheiro",
    "origem": "indicação da Mariana",
    "alertas_saude": [{"tipo": "alergia", "descricao": "alergia a penicilina (urticária)"}]}'::jsonb,
  'seed: dados fictícios');

select public.mcp_cadastrar_paciente(
  '{"nome": "Mariana Costa Ribeiro", "apelido": "Mari", "data_nascimento": "1991-07-25",
    "sexo": "feminino", "cpf": "22787129005", "telefone": "11 97222-3344", "origem": "Instagram",
    "alertas_saude": [{"tipo": "alergia", "descricao": "alergia a dipirona"}],
    "observacoes": "Tem medo de agulha; prefere anestésico tópico antes."}'::jsonb,
  'seed: dados fictícios');

select public.mcp_cadastrar_paciente(
  '{"nome": "Carlos Eduardo Nunes", "data_nascimento": "1958-11-02", "sexo": "masculino",
    "cpf": "50761702113", "telefone": "11 96333-4455",
    "alertas_saude": [
      {"tipo": "anticoagulante", "descricao": "usa rivaroxabana 20 mg (fibrilação atrial)"},
      {"tipo": "hipertensao", "descricao": "hipertenso controlado (losartana)"}]}'::jsonb,
  'seed: dados fictícios');

select public.mcp_cadastrar_paciente(
  '{"nome": "Helena Martins Prado", "data_nascimento": "2017-05-10", "sexo": "feminino",
    "responsavel": {"nome": "Patrícia Martins Prado", "cpf": "53245023677", "parentesco": "mãe",
                    "telefone": "11 95444-5566", "e_pagador": true}}'::jsonb,
  'seed: dados fictícios');

-- Um atendimento anterior do João, para a busca mostrar histórico.
select public.mcp_registrar_atendimento(
  jsonb_build_object(
    'paciente_id', (select id from public.pacientes where cpf = '11600034594'),
    'data', to_char(public.hoje() - 14, 'YYYY-MM-DD'),
    'hora_inicio', '09:00', 'hora_fim', '09:50',
    'procedimentos', '[{"procedimento": "Consulta de avaliação", "regiao": "boca"},
                       {"procedimento": "Profilaxia", "regiao": "boca"}]'::jsonb,
    'evolucao', 'Avaliação inicial. Cárie em 46 (O) e restauração insatisfatória em 26. Profilaxia e orientação de higiene.',
    'proxima_etapa', 'Restauração do 46 e troca da restauração do 26',
    'retorno_em_dias', 15),
  'seed: dados fictícios');

-- Anamnese e odontograma do João (avaliação de 14 dias atrás).
select public.mcp_registrar_anamnese(
  jsonb_build_object(
    'paciente_id', (select id from public.pacientes where cpf = '11600034594'),
    'respostas', '[{"pergunta": "queixa_principal", "resposta": "Check-up; sente o 46 com comida presa"},
                   {"pergunta": "alergia_medicamento", "resposta": "sim", "detalhe": "penicilina, urticária"},
                   {"pergunta": "bruxismo", "resposta": "sim"}]'::jsonb,
    'demais_negativas', true,
    'pressao_arterial', '130x85'),
  'seed: dados fictícios');

select public.mcp_registrar_odontograma(
  jsonb_build_object(
    'paciente_id', (select id from public.pacientes where cpf = '11600034594'),
    'data', to_char(public.hoje() - 14, 'YYYY-MM-DD'),
    'marcas', '[{"dente": 46, "condicao": "carie", "faces": "O"},
                {"dente": 26, "condicao": "restauracao_insatisfatoria", "faces": "MO", "detalhe": "amálgama"},
                {"dente": 46, "procedimento_codigo": "resina_1_face", "faces": "O", "camada": "planejado"},
                {"dente": 26, "procedimento_codigo": "resina_2_faces", "faces": "MO", "camada": "planejado"},
                {"dentes": [18, 28], "condicao": "ausente"}]'::jsonb),
  'seed: dados fictícios');
