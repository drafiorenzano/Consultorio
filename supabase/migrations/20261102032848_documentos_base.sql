-- =====================================================================
-- Etapa 3 (documentos): base comum.
--
-- * documentos_config: padrões do orçamento (validade, condições de
--   pagamento, acompanhamento) numa linha só, fácil de mudar.
-- * documentos: registro de cada PDF gerado (caminho no Storage privado,
--   tamanho, SHA-256). Só inclusão: um PDF novo nunca apaga o anterior.
-- * medicamentos_modelos: modelos de receita (seção 8 da referência).
-- * termos_modelos: textos dos termos de consentimento (TCLE, Anexo 3 do
--   Manual CFO) e das orientações pós-operatórias.
-- * Funções de apoio para os PDFs: cabeçalho, endereço, data por extenso.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Padrões
-- ---------------------------------------------------------------------
create table public.documentos_config (
  id boolean primary key default true check (id),
  orcamento_validade_dias int not null default 30 check (orcamento_validade_dias between 1 and 180),
  desconto_a_vista_pct numeric(5, 2) not null default 5 check (desconto_a_vista_pct between 0 and 50),
  cartao_parcelas_max int not null default 6 check (cartao_parcelas_max between 1 and 24),
  entrada_pct numeric(5, 2) not null default 30 check (entrada_pct between 0 and 100),
  entrada_parcelas_max int not null default 3 check (entrada_parcelas_max between 1 and 24),
  parcela_minima numeric(10, 2) not null default 100 check (parcela_minima > 0),
  destaque_parcela_acima numeric(10, 2) not null default 1000 check (destaque_parcela_acima >= 0),
  acompanhamento_dias int[] not null default '{7,21,45}',
  atualizado_em timestamptz not null default now()
);
comment on table public.documentos_config is
  'Padrões dos documentos (linha única): validade e condições de pagamento do orçamento, dias de acompanhamento.';

insert into public.documentos_config (id) values (true) on conflict (id) do nothing;

create trigger documentos_config_atualizado_em before update on public.documentos_config
  for each row execute function public.tocar_atualizado_em();
create trigger documentos_config_auditoria after insert or update on public.documentos_config
  for each row execute function public.registrar_auditoria();
create trigger documentos_config_sem_exclusao before delete on public.documentos_config
  for each row execute function public.bloquear_alteracao();
create trigger documentos_config_sem_truncate before truncate on public.documentos_config
  for each statement execute function public.bloquear_alteracao();

-- ---------------------------------------------------------------------
-- Registro dos arquivos gerados
-- ---------------------------------------------------------------------
create table public.documentos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id),
  tipo text not null check (tipo in ('orcamento', 'receita', 'atestado', 'termo', 'orientacoes')),
  referencia_id uuid not null,               -- orcamentos / receitas / atestados / termos_emitidos
  titulo text not null check (length(btrim(titulo)) > 0),
  caminho text not null unique check (caminho ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+\.pdf$'),
  tamanho_bytes int not null check (tamanho_bytes > 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  gerado_por text not null default 'mcp',
  solicitacao_id uuid references public.solicitacoes (id),
  gerado_em timestamptz not null default now()
);
comment on table public.documentos is 'PDFs gerados (bucket privado "documentos"). Só inclusão.';
create index documentos_paciente_idx on public.documentos (paciente_id, gerado_em desc);
create index documentos_referencia_idx on public.documentos (referencia_id);
create index documentos_solicitacao_idx on public.documentos (solicitacao_id);

create trigger documentos_so_inclusao before update or delete on public.documentos
  for each row execute function public.bloquear_alteracao();
create trigger documentos_sem_truncate before truncate on public.documentos
  for each statement execute function public.bloquear_alteracao();
create trigger documentos_auditoria after insert on public.documentos
  for each row execute function public.registrar_auditoria();

-- ---------------------------------------------------------------------
-- Modelos de receita
-- ---------------------------------------------------------------------
create table public.medicamentos_modelos (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*$'),
  ordem int not null default 1000,
  nome text not null,                         -- DCB, como vai na receita
  concentracao text,
  forma text not null,                        -- comprimido, cápsula, suspensão oral...
  via text not null default 'oral' check (via in ('oral', 'sublingual', 'bochecho', 'topica')),
  quantidade text,                            -- ex.: 21 cápsulas; 1 frasco
  posologia text not null,
  classe text not null check (classe in (
    'analgesico', 'dipirona', 'aine', 'corticoide', 'betalactamico', 'nitroimidazolico',
    'macrolideo', 'lincosamida', 'antisseptico')),
  antibiotico boolean not null default false,
  indicacao text,                             -- quando usar (para o Claude sugerir)
  sinonimos text[] not null default '{}',     -- formas faladas, normalizadas
  -- dose por peso (modelos pediátricos)
  pediatrico boolean not null default false,
  mg_kg numeric(6, 2),                        -- mg/kg por dia (ou por dose, se dose_unica)
  dose_unica boolean not null default false,
  doses_dia int,
  max_mg_dose numeric(8, 2),
  mg_por_ml numeric(8, 2),
  dias int,
  frasco_ml int,
  ativo boolean not null default true,
  check (not pediatrico or (mg_kg is not null and mg_por_ml is not null and max_mg_dose is not null
                            and (dose_unica or (doses_dia is not null and dias is not null))))
);
comment on table public.medicamentos_modelos is
  'Modelos de receita (receita comum). Controlados não entram: são no talão em papel.';

create trigger medicamentos_modelos_auditoria after insert or update on public.medicamentos_modelos
  for each row execute function public.registrar_auditoria();
create trigger medicamentos_modelos_sem_exclusao before delete on public.medicamentos_modelos
  for each row execute function public.bloquear_alteracao();
create trigger medicamentos_modelos_sem_truncate before truncate on public.medicamentos_modelos
  for each statement execute function public.bloquear_alteracao();

insert into public.medicamentos_modelos
  (codigo, ordem, nome, concentracao, forma, via, quantidade, posologia, classe, antibiotico, indicacao, sinonimos,
   pediatrico, mg_kg, dose_unica, doses_dia, max_mg_dose, mg_por_ml, dias, frasco_ml)
values
  ('dipirona_500', 10, 'Dipirona sódica', '500 mg', 'comprimido', 'oral', '1 caixa',
   'Tomar 1 a 2 comprimidos a cada 4 horas, se houver dor, por até 24 horas.', 'dipirona', false,
   'Dor leve a moderada.', '{dipirona,novalgina}', false, null, false, null, null, null, null, null),
  ('paracetamol_750', 20, 'Paracetamol', '750 mg', 'comprimido', 'oral', '1 caixa',
   'Tomar 1 comprimido a cada 6 horas, se houver dor.', 'analgesico', false,
   'Dor leve; alternativa à dipirona.', '{paracetamol,tylenol}', false, null, false, null, null, null, null, null),
  ('ibuprofeno_600', 30, 'Ibuprofeno', '600 mg', 'comprimido', 'oral', '1 caixa',
   'Tomar 1 comprimido a cada 6 horas, após as refeições, por até 3 dias.', 'aine', false,
   'Dor com inflamação.', '{ibuprofeno,advil,alivium}', false, null, false, null, null, null, null, null),
  ('nimesulida_100', 40, 'Nimesulida', '100 mg', 'comprimido', 'oral', '4 comprimidos',
   'Tomar 1 comprimido a cada 12 horas, após as refeições, por até 2 dias.', 'aine', false,
   'Dor com inflamação, curto prazo.', '{nimesulida}', false, null, false, null, null, null, null, null),
  ('cetorolaco_10', 50, 'Cetorolaco de trometamol', '10 mg', 'comprimido sublingual', 'sublingual', '4 comprimidos',
   'Colocar 1 comprimido embaixo da língua a cada 12 horas, por até 2 dias.', 'aine', false,
   'Dor moderada a intensa pós-operatória, curto prazo.', '{cetorolaco,toragesic}', false, null, false, null, null, null, null, null),
  ('dexametasona_4', 60, 'Dexametasona', '4 mg', 'comprimido', 'oral', '2 comprimidos',
   'Tomar 2 comprimidos (8 mg) em dose única, 1 hora antes da cirurgia.', 'corticoide', false,
   'Antes de cirurgia de dente incluso (controle de edema).', '{dexametasona,decadron}', false, null, false, null, null, null, null, null),
  ('amoxicilina_500', 70, 'Amoxicilina', '500 mg', 'cápsula', 'oral', '21 cápsulas',
   'Tomar 1 cápsula a cada 8 horas, por 7 dias.', 'betalactamico', true,
   'Infecção com sinais sistêmicos (febre acima de 37,8 °C, edema progressivo).', '{amoxicilina,amoxil}',
   false, null, false, null, null, null, null, null),
  ('metronidazol_250', 80, 'Metronidazol', '250 mg', 'comprimido', 'oral', '21 comprimidos',
   'Tomar 1 comprimido a cada 8 horas, por 7 dias, junto com a amoxicilina. Não ingerir bebida alcoólica.',
   'nitroimidazolico', true, 'Infecção grave, associado à amoxicilina.', '{metronidazol,flagyl}',
   false, null, false, null, null, null, null, null),
  ('azitromicina_500', 90, 'Azitromicina', '500 mg', 'comprimido', 'oral', '5 comprimidos',
   'Tomar 1 comprimido por dia, por 5 dias.', 'macrolideo', true,
   'Infecção em paciente alérgico à penicilina.', '{azitromicina,zitromax}', false, null, false, null, null, null, null, null),
  ('clindamicina_300', 100, 'Clindamicina', '300 mg', 'cápsula', 'oral', '28 cápsulas',
   'Tomar 1 cápsula a cada 6 horas, por 7 dias.', 'lincosamida', true,
   'Infecção em paciente alérgico à penicilina.', '{clindamicina,dalacin}', false, null, false, null, null, null, null, null),
  ('clorexidina_012', 110, 'Digluconato de clorexidina', '0,12%', 'solução para bochecho', 'bochecho', '1 frasco',
   'Bochechar 15 ml por 1 minuto, 2 vezes ao dia, 30 minutos após a escovação, por 7 dias. Não engolir.',
   'antisseptico', false, 'Pós-operatório e controle de placa.', '{clorexidina,periogard}',
   false, null, false, null, null, null, null, null),
  ('profilaxia_amoxicilina_2g', 120, 'Amoxicilina', '500 mg', 'cápsula', 'oral', '4 cápsulas',
   'Tomar 4 cápsulas (2 g) em dose única, 30 a 60 minutos antes do procedimento.', 'betalactamico', true,
   'Profilaxia antibiótica (válvula artificial, endocardite prévia).', '{profilaxia}',
   false, null, false, null, null, null, null, null),
  ('profilaxia_azitromicina_500', 130, 'Azitromicina', '500 mg', 'comprimido', 'oral', '1 comprimido',
   'Tomar 1 comprimido em dose única, 30 a 60 minutos antes do procedimento.', 'macrolideo', true,
   'Profilaxia antibiótica em alérgico à penicilina.', '{}', false, null, false, null, null, null, null, null),
  ('amoxicilina_pediatrica', 140, 'Amoxicilina', '250 mg/5 ml', 'suspensão oral', 'oral', null,
   'Tomar {ml} ml a cada 8 horas, por 7 dias.', 'betalactamico', true,
   'Infecção em criança (50 mg/kg/dia).', '{}', true, 50, false, 3, 500, 50, 7, 150),
  ('profilaxia_amoxicilina_pediatrica', 150, 'Amoxicilina', '250 mg/5 ml', 'suspensão oral', 'oral', null,
   'Tomar {ml} ml em dose única, 30 a 60 minutos antes do procedimento.', 'betalactamico', true,
   'Profilaxia em criança (50 mg/kg, máximo 2 g).', '{}', true, 50, true, null, 2000, 50, null, 150),
  ('profilaxia_azitromicina_pediatrica', 160, 'Azitromicina', '200 mg/5 ml', 'suspensão oral', 'oral', null,
   'Tomar {ml} ml em dose única, 30 a 60 minutos antes do procedimento.', 'macrolideo', true,
   'Profilaxia em criança alérgica à penicilina (15 mg/kg, máximo 500 mg).', '{}', true, 15, true, null, 500, 40, null, 15)
on conflict (codigo) do nothing;

-- ---------------------------------------------------------------------
-- Modelos de termos (TCLE) e orientações
-- ---------------------------------------------------------------------
create table public.termos_modelos (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*$'),
  tipo text not null check (tipo in ('consentimento', 'orientacoes')),
  titulo text not null,
  procedimento text,                          -- descrição padrão do tratamento
  secoes jsonb not null check (jsonb_typeof(secoes) = 'array' and jsonb_array_length(secoes) > 0),
  sinonimos text[] not null default '{}',
  ordem int not null default 1000,
  ativo boolean not null default true
);
comment on table public.termos_modelos is
  'Textos dos termos de consentimento (seções do Anexo 3 do Manual CFO) e das orientações. {procedimento} e {dentes} são trocados na emissão.';

create trigger termos_modelos_auditoria after insert or update on public.termos_modelos
  for each row execute function public.registrar_auditoria();
create trigger termos_modelos_sem_exclusao before delete on public.termos_modelos
  for each row execute function public.bloquear_alteracao();
create trigger termos_modelos_sem_truncate before truncate on public.termos_modelos
  for each statement execute function public.bloquear_alteracao();

insert into public.termos_modelos (codigo, tipo, titulo, procedimento, secoes, sinonimos, ordem) values
('exodontia', 'consentimento', 'Termo de consentimento para extração dentária', 'Extração (exodontia) {dentes}',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento}, sob anestesia local. O dente é removido com instrumentos próprios; quando necessário, a gengiva é aberta, parte do osso ao redor é desgastada ou o dente é dividido, e o local é fechado com pontos."},
  {"titulo": "Objetivos e prazo", "texto": "Eliminar dor, infecção ou o problema que motivou a indicação. O procedimento costuma durar de 30 minutos a 1 hora e a cicatrização inicial leva de 7 a 15 dias."},
  {"titulo": "Benefícios esperados", "texto": "Fim da dor ou da infecção, prevenção de problemas nos dentes vizinhos e preparo para outros tratamentos, quando for o caso."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Dor, inchaço e roxo no rosto nos primeiros dias; sangramento; infecção ou alveolite (inflamação do local); limitação para abrir a boca; fratura da raiz, que pode exigir remoção em outra etapa; comunicação com o seio maxilar em dentes superiores; dormência temporária ou, raramente, permanente do lábio, do queixo ou da língua em dentes inferiores próximos ao nervo; reação ao anestésico."},
  {"titulo": "Alternativas", "texto": "Quando possível, tratamento de canal, restauração ou acompanhamento do dente. As alternativas foram explicadas e a extração foi a indicada para o caso."},
  {"titulo": "Riscos de não tratar", "texto": "Persistência ou piora da dor e da infecção, que pode se espalhar, perda de osso e danos aos dentes vizinhos."},
  {"titulo": "Limitações e cuidados", "texto": "A recuperação depende do organismo e dos cuidados do paciente. É indispensável seguir as orientações pós-operatórias, tomar os medicamentos como prescritos e comparecer ao retorno para remover os pontos."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Qualquer intercorrência será tratada pela profissional, com novos procedimentos se necessários. Em caso de sangramento que não para, febre ou piora da dor após o terceiro dia, entre em contato imediatamente."}
 ]$j$::jsonb, '{extracao,exodontia,siso}', 10),
('endodontia', 'consentimento', 'Termo de consentimento para tratamento de canal', 'Tratamento de canal (endodontia) {dentes}',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento}, sob anestesia local e isolamento do dente. A polpa (nervo) inflamada ou infectada é removida, os canais são limpos, desinfetados e preenchidos com material próprio. Pode exigir mais de uma sessão e radiografias durante o tratamento."},
  {"titulo": "Objetivos e prazo", "texto": "Eliminar a dor e a infecção e manter o dente na boca. Em geral são de 1 a 3 sessões; a cicatrização do osso ao redor da raiz pode levar meses e é acompanhada por radiografias."},
  {"titulo": "Benefícios esperados", "texto": "Conservação do próprio dente, alívio da dor e controle da infecção."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Sensibilidade ou dor nos dias seguintes; inchaço; fratura de instrumento dentro do canal; perfuração; canais calcificados ou curvos que impeçam o tratamento completo; fratura do dente, que fica mais frágil depois do canal; necessidade de retratamento ou de cirurgia complementar; reação ao anestésico."},
  {"titulo": "Alternativas", "texto": "Extração do dente, com reposição posterior por implante ou prótese, ou não tratar. As alternativas foram explicadas."},
  {"titulo": "Riscos de não tratar", "texto": "Piora da dor e da infecção, formação de abscesso, perda do osso ao redor da raiz e perda do dente."},
  {"titulo": "Limitações e cuidados", "texto": "Depois do canal, o dente precisa ser restaurado de forma definitiva, muitas vezes com pino e coroa, para não fraturar. O sucesso depende da anatomia do dente, da resposta do organismo e da higiene."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Se a infecção persistir, podem ser indicados retratamento, cirurgia na ponta da raiz ou extração, que serão explicados antes."}
 ]$j$::jsonb, '{canal,endodontia}', 20),
('implante', 'consentimento', 'Termo de consentimento para implante dentário', 'Instalação de implante dentário {dentes}',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento}, sob anestesia local. A gengiva é aberta, o osso é preparado e um implante de titânio é instalado; o local é fechado com pontos. Depois de um período de cicatrização e integração ao osso (em geral de 3 a 6 meses), é feita a parte protética (coroa ou prótese sobre o implante). Pode ser necessário enxerto de osso."},
  {"titulo": "Objetivos e prazo", "texto": "Repor o dente perdido com uma raiz artificial fixa. O tratamento completo costuma levar de 3 a 8 meses, conforme a quantidade e a qualidade do osso."},
  {"titulo": "Benefícios esperados", "texto": "Recuperar a mastigação e a estética com um dente fixo, sem desgastar os dentes vizinhos, e preservar o osso da região."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Dor, inchaço e roxo nos primeiros dias; sangramento; infecção; falta de integração do implante ao osso (perda do implante), que pode exigir nova cirurgia; dormência temporária ou, raramente, permanente do lábio, do queixo ou da língua em implantes inferiores; comunicação com o seio maxilar em implantes superiores; necessidade de enxerto; inflamação ao redor do implante ao longo dos anos (peri-implantite)."},
  {"titulo": "Alternativas", "texto": "Prótese fixa apoiada nos dentes vizinhos (ponte), prótese removível ou não repor o dente. As alternativas foram explicadas."},
  {"titulo": "Riscos de não tratar", "texto": "Movimentação dos dentes vizinhos, perda de osso na região, dificuldade de mastigação e alteração da estética."},
  {"titulo": "Limitações e cuidados", "texto": "Fumar, diabetes descompensada, uso de alguns remédios para os ossos (bisfosfonatos) e higiene deficiente aumentam o risco de perda do implante. O paciente se compromete a informar sua saúde com verdade, seguir as orientações, comparecer às consultas de controle e manter a higiene."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Se o implante não integrar, ele é removido e, após a cicatrização, pode ser feita nova tentativa ou escolhida outra alternativa, que será explicada antes."}
 ]$j$::jsonb, '{implante,implantes}', 30),
('protese', 'consentimento', 'Termo de consentimento para tratamento com prótese', 'Tratamento com prótese dentária {dentes}',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento}. Inclui preparo dos dentes ou dos implantes quando necessário, moldagens ou escaneamento, provas e instalação da prótese feita em laboratório, em várias consultas."},
  {"titulo": "Objetivos e prazo", "texto": "Recuperar a mastigação, a fala e a estética. O prazo depende do tipo de prótese e das etapas de laboratório, em geral de 2 a 6 semanas."},
  {"titulo": "Benefícios esperados", "texto": "Melhora da mastigação, da estética e da proteção dos dentes remanescentes."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Sensibilidade nos dentes preparados; necessidade de tratamento de canal em dentes desgastados; fratura ou descolamento da prótese ou da porcelana; desconforto e feridas no período de adaptação; diferença de cor entre a prótese e os dentes naturais; necessidade de ajustes e de troca ao longo dos anos."},
  {"titulo": "Alternativas", "texto": "Outros tipos de prótese (fixa, removível, sobre implante) ou restaurações, conforme o caso. As alternativas foram explicadas."},
  {"titulo": "Riscos de não tratar", "texto": "Dificuldade de mastigação, movimentação dos dentes, desgaste e sobrecarga dos dentes remanescentes."},
  {"titulo": "Limitações e cuidados", "texto": "A prótese não substitui por completo um dente natural. Exige higiene diária, consultas de controle e cuidado com alimentos muito duros. Próteses removíveis precisam de adaptação."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Fraturas, descolamentos e desadaptações serão avaliados e reparados ou refeitos conforme o caso, o que será explicado antes."}
 ]$j$::jsonb, '{protese,coroa,ponte,protocolo,dentadura}', 40),
('clareamento', 'consentimento', 'Termo de consentimento para clareamento dental', 'Clareamento dental',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento} com gel clareador aplicado no consultório e/ou em casa com moldeiras feitas sob medida, conforme orientação."},
  {"titulo": "Objetivos e prazo", "texto": "Deixar os dentes naturais mais claros. O resultado aparece ao longo de 2 a 4 semanas e varia de pessoa para pessoa."},
  {"titulo": "Benefícios esperados", "texto": "Melhora da cor dos dentes sem desgaste."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Sensibilidade nos dentes durante o tratamento, que costuma passar ao final; irritação da gengiva; resultado diferente do esperado ou desigual entre os dentes; volta parcial da cor com o tempo."},
  {"titulo": "Alternativas", "texto": "Facetas ou lentes de contato dentais, ou não clarear. As alternativas foram explicadas."},
  {"titulo": "Riscos de não tratar", "texto": "Não há risco à saúde em não clarear; trata-se de tratamento estético."},
  {"titulo": "Limitações e cuidados", "texto": "Restaurações, coroas e facetas não clareiam e podem precisar ser trocadas para acompanhar a nova cor. Durante o tratamento, evitar alimentos e bebidas com corante (café, vinho, refrigerante de cola) e cigarro. Não indicado na gestação e na amamentação."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Em caso de sensibilidade forte, o uso do gel é suspenso e é feito tratamento para a sensibilidade."}
 ]$j$::jsonb, '{clareamento}', 50),
('cirurgia', 'consentimento', 'Termo de consentimento para cirurgia oral', 'Cirurgia oral {dentes}',
 $j$[
  {"titulo": "Tratamento proposto e técnica", "texto": "{procedimento}, sob anestesia local, com abertura da gengiva quando necessário e sutura (pontos)."},
  {"titulo": "Objetivos e prazo", "texto": "Tratar a condição indicada e preparar a boca para as próximas etapas do tratamento. A cicatrização inicial leva de 7 a 15 dias."},
  {"titulo": "Benefícios esperados", "texto": "Resolução do problema que motivou a cirurgia."},
  {"titulo": "Riscos e possíveis complicações", "texto": "Dor, inchaço e roxo; sangramento; infecção; abertura dos pontos; dormência temporária na região; resultado diferente do esperado, com necessidade de nova intervenção; reação ao anestésico."},
  {"titulo": "Alternativas", "texto": "As alternativas possíveis para o caso, inclusive não operar, foram explicadas."},
  {"titulo": "Riscos de não tratar", "texto": "Persistência ou piora da condição que motivou a indicação."},
  {"titulo": "Limitações e cuidados", "texto": "O resultado depende do organismo e dos cuidados do paciente. É indispensável seguir as orientações pós-operatórias e comparecer aos retornos."},
  {"titulo": "Conduta em caso de insucesso ou complicação", "texto": "Qualquer intercorrência será tratada pela profissional, com novos procedimentos se necessários, explicados antes."}
 ]$j$::jsonb, '{cirurgia,enxerto,biopsia,frenectomia,gengivectomia}', 60),
('pos_exodontia', 'orientacoes', 'Orientações após extração ou cirurgia', null,
 $j$[
  {"titulo": "Nas primeiras horas", "texto": "Morda a gaze por 30 a 40 minutos. Não cuspa, não faça bochechos e não use canudo nas primeiras 24 horas. Faça repouso e mantenha a cabeça mais alta ao deitar."},
  {"titulo": "Gelo e alimentação", "texto": "Use compressa de gelo no rosto, 20 minutos sim e 20 minutos não, nas primeiras 48 horas. Prefira alimentos frios ou mornos, pastosos e líquidos nos primeiros dias; evite alimentos quentes, duros e com pedaços."},
  {"titulo": "Higiene", "texto": "Escove os outros dentes normalmente desde o primeiro dia, com cuidado no local da cirurgia. Use o bochecho apenas a partir do dia seguinte, se tiver sido prescrito."},
  {"titulo": "Evite", "texto": "Esforço físico, sol forte, bebida alcoólica e cigarro por pelo menos 7 dias."},
  {"titulo": "Medicamentos", "texto": "Tome os medicamentos exatamente como prescritos, nos horários indicados."},
  {"titulo": "Procure a dentista se", "texto": "O sangramento não parar com compressão da gaze por 30 minutos, a dor piorar depois do terceiro dia, surgir febre ou o inchaço aumentar depois do terceiro dia."}
 ]$j$::jsonb, '{extracao,exodontia,cirurgia,siso}', 110),
('pos_implante', 'orientacoes', 'Orientações após cirurgia de implante', null,
 $j$[
  {"titulo": "Nas primeiras horas", "texto": "Morda a gaze por 30 minutos. Não cuspa, não faça bochechos e não use canudo nas primeiras 24 horas. Repouse com a cabeça mais alta."},
  {"titulo": "Gelo e alimentação", "texto": "Compressa de gelo no rosto nas primeiras 48 horas, 20 minutos sim e 20 minutos não. Alimentação fria ou morna e pastosa nos primeiros dias; não mastigue do lado do implante até a liberação."},
  {"titulo": "Higiene", "texto": "Escove os outros dentes normalmente; no local do implante, apenas com cuidado e escova macia. Use o bochecho prescrito a partir do dia seguinte."},
  {"titulo": "Evite", "texto": "Cigarro (atrapalha muito a integração do implante), bebida alcoólica, esforço físico e sol forte por pelo menos 7 dias. Se usa prótese removível, só use na região depois de liberado."},
  {"titulo": "Medicamentos", "texto": "Tome os medicamentos exatamente como prescritos."},
  {"titulo": "Procure a dentista se", "texto": "Houver sangramento que não para, febre, dor que piora depois do terceiro dia, inchaço crescente ou se o parafuso de cobertura soltar."}
 ]$j$::jsonb, '{implante}', 120),
('clareamento_cuidados', 'orientacoes', 'Orientações durante o clareamento', null,
 $j$[
  {"titulo": "Uso do gel", "texto": "Coloque uma pequena gota de gel em cada dente da moldeira, sem exagero. Use pelo tempo indicado e retire o excesso que encostar na gengiva."},
  {"titulo": "Alimentação", "texto": "Durante o tratamento, evite café, chá-preto, vinho, refrigerante de cola, açaí, beterraba, molho de tomate e outros alimentos com corante, além do cigarro."},
  {"titulo": "Sensibilidade", "texto": "Um pouco de sensibilidade é normal. Use creme dental para dentes sensíveis. Se ficar forte, suspenda o gel por um ou dois dias e avise a dentista."},
  {"titulo": "Cuidados com a moldeira", "texto": "Lave a moldeira com água fria e escova macia depois de usar e guarde no estojo, longe do calor."}
 ]$j$::jsonb, '{clareamento}', 130)
on conflict (codigo) do nothing;

-- ---------------------------------------------------------------------
-- Apoio aos PDFs
-- ---------------------------------------------------------------------
create or replace function public.documentos_cabecalho()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'nome', c.nome_consultorio,
    'dentista', c.dentista_nome,
    'especialidade', c.especialidade,
    'cro', c.cro,
    'endereco', c.endereco,
    'cidade', c.cidade,
    'uf', c.uf,
    'telefone', c.telefone,
    'whatsapp', c.whatsapp,
    'email', c.email,
    'instagram', c.instagram,
    'site', c.site))
  from public.configuracao c
$$;

create or replace function public.endereco_texto(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(concat_ws(', ',
    nullif(concat_ws(', ', nullif(btrim(p ->> 'logradouro'), ''), nullif(btrim(p ->> 'numero'), ''),
                     nullif(btrim(p ->> 'complemento'), '')), ''),
    nullif(btrim(p ->> 'bairro'), ''),
    nullif(concat_ws('-', nullif(btrim(p ->> 'cidade'), ''), nullif(upper(btrim(p ->> 'uf')), '')), ''),
    case when nullif(btrim(p ->> 'cep'), '') is not null then 'CEP ' || btrim(p ->> 'cep') end), '')
$$;

create or replace function public.data_extenso(p date)
returns text
language sql
immutable
set search_path = ''
as $$
  select extract(day from p)::int || ' de ' ||
         (array['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto',
                'setembro', 'outubro', 'novembro', 'dezembro'])[extract(month from p)::int] ||
         ' de ' || extract(year from p)::int
$$;

-- Dados do paciente para os documentos (com o responsável, se for menor).
create or replace function public.documentos_paciente(p_paciente uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', p.id,
    'ficha', p.ficha,
    'nome', coalesce(p.nome_social, p.nome),
    'nome_civil', case when p.nome_social is not null then p.nome end,
    'cpf', p.cpf,
    'data_nascimento', p.data_nascimento,
    'idade', public.idade(p.data_nascimento),
    'endereco', public.endereco_texto(p.endereco),
    'telefone', p.telefone,
    'responsavel', case when public.idade(p.data_nascimento) < 18 then (
      select jsonb_strip_nulls(jsonb_build_object('nome', r.nome, 'cpf', r.cpf, 'parentesco', r.parentesco))
        from public.responsaveis r where r.paciente_id = p.id
       order by r.e_pagador desc, r.criado_em limit 1) end))
  from public.pacientes p where p.id = p_paciente
$$;

-- Caminho do arquivo no bucket: <paciente>/<tipo>-<numero>[-v<versao>]-<carimbo>.pdf
create or replace function public.documentos_caminho(p_paciente uuid, p_tipo text, p_numero int, p_versao int default null)
returns text
language sql
stable
set search_path = ''
as $$
  select p_paciente::text || '/' || p_tipo || '-' || p_numero ||
         coalesce('-v' || p_versao, '') || '-' ||
         to_char(clock_timestamp() at time zone public.fuso(), 'YYYYMMDD-HH24MISS') || '.pdf'
$$;

-- ---------------------------------------------------------------------
-- Acesso: RLS ligado, sem políticas; funções só para o servidor.
-- ---------------------------------------------------------------------
alter table public.documentos_config enable row level security;
alter table public.documentos enable row level security;
alter table public.medicamentos_modelos enable row level security;
alter table public.termos_modelos enable row level security;
revoke all on table public.documentos_config, public.documentos, public.medicamentos_modelos, public.termos_modelos
  from anon, authenticated;

revoke execute on function
  public.documentos_cabecalho(),
  public.endereco_texto(jsonb),
  public.data_extenso(date),
  public.documentos_paciente(uuid),
  public.documentos_caminho(uuid, text, int, int)
  from public, anon, authenticated;
grant execute on function
  public.documentos_cabecalho(),
  public.endereco_texto(jsonb),
  public.data_extenso(date),
  public.documentos_paciente(uuid),
  public.documentos_caminho(uuid, text, int, int)
  to service_role;
