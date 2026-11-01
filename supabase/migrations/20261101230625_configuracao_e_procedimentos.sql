-- =====================================================================
-- Etapa 1: dados reais do consultório e catálogo de procedimentos.
--
-- Os dados da Dra. são os públicos (site e card de divulgação). Os preços
-- vêm da tabela que ela mantém no gerador de orçamento do site, lida em
-- 01/11/2026; os itens sem preço trazem só a faixa de mercado (CIDESP 2026)
-- como referência e ficam fora de orçamento até ela definir o valor.
-- =====================================================================

alter table public.configuracao
  add column especialidade text,
  add column whatsapp text,
  add column instagram text,
  add column site text,
  add column cidade text,
  add column uf text check (uf ~ '^[A-Z]{2}$');

insert into public.configuracao (id, nome_consultorio, dentista_nome, cro, especialidade, endereco,
                                 cidade, uf, telefone, whatsapp, email, instagram, site)
values (true, 'Dra. Andressa Fiorenzano', 'Dra. Andressa Fiorenzano', 'CRO-SP 175419',
        'Cirurgiã-dentista · Implantodontista',
        'Av. República do Líbano, 1673 – Moema', 'São Paulo', 'SP',
        '21981772817', '21981772817', 'dra.fiorenzano@gmail.com', '@dra.andressafiorenzano',
        'https://andressafiorenzano.com.br')
on conflict (id) do update set
  nome_consultorio = excluded.nome_consultorio, dentista_nome = excluded.dentista_nome,
  cro = excluded.cro, especialidade = excluded.especialidade, endereco = excluded.endereco,
  cidade = excluded.cidade, uf = excluded.uf, telefone = excluded.telefone,
  whatsapp = excluded.whatsapp, email = excluded.email, instagram = excluded.instagram,
  site = excluded.site;

-- ---------------------------------------------------------------------
-- Catálogo de procedimentos
-- ---------------------------------------------------------------------
create table public.procedimentos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome text not null check (length(btrim(nome)) >= 3),     -- como aparece no orçamento
  grupo text not null,                                      -- seção do orçamento (como no site)
  categoria text not null check (categoria in (
    'diagnostico', 'prevencao', 'dentistica', 'endodontia', 'periodontia', 'cirurgia',
    'protese', 'implante', 'estetica', 'disfuncao', 'outros')),
  aplica_a text not null check (aplica_a in ('boca', 'arcada', 'sextante', 'dente', 'dente_faces', 'regiao')),
  preco numeric(10, 2) check (preco is null or preco >= 0), -- null = ela ainda não definiu
  faixa_mercado text,                                       -- referência, só quando não há preço
  familia text,                                             -- ex.: resina (escolhe pelo nº de faces)
  faces_min smallint,
  faces_max smallint,
  condicao_resultante text references public.odontograma_condicoes (codigo),
  detalhe_resultante text,                                  -- vai para o odontograma (ex.: resina)
  sinonimos text[] not null default '{}',                   -- formas faladas, já normalizadas
  ordem int not null default 1000,
  ativo boolean not null default true,
  publicar_no_site boolean not null default false,
  observacao text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check ((faces_min is null) = (faces_max is null) and (faces_min is null or faces_min <= faces_max))
);
comment on table public.procedimentos is 'Procedimentos que a Dra. faz, com o preço dela. Nunca apagar: desativar (ativo = false). Mudança de preço fica na auditoria.';
create index procedimentos_familia_idx on public.procedimentos (familia) where familia is not null;
create index procedimentos_condicao_idx on public.procedimentos (condicao_resultante);

create trigger procedimentos_atualizado_em before update on public.procedimentos
  for each row execute function public.tocar_atualizado_em();
create trigger procedimentos_auditoria after insert or update on public.procedimentos
  for each row execute function public.registrar_auditoria();
create trigger procedimentos_sem_exclusao before delete on public.procedimentos
  for each row execute function public.bloquear_alteracao();
create trigger procedimentos_sem_truncate before truncate on public.procedimentos
  for each statement execute function public.bloquear_alteracao();

alter table public.procedimentos enable row level security;
revoke all on table public.procedimentos from anon, authenticated;

-- Tabela do site (valores da Dra. em 01/11/2026).
insert into public.procedimentos
  (codigo, nome, grupo, categoria, aplica_a, preco, familia, faces_min, faces_max,
   condicao_resultante, detalhe_resultante, sinonimos, ordem, publicar_no_site)
values
  ('consulta_preventiva', 'Consulta preventiva (limpeza completa + profilaxia e flúor)', 'Prevenção', 'prevencao', 'boca', 380,
   null, null, null, null, null,
   array['consulta preventiva', 'limpeza', 'limpeza completa', 'profilaxia', 'profilaxia e fluor', 'preventiva'], 10, true),
  ('clareamento_conjugado', 'Clareamento conjugado (5 seringas + 2 sessões em consultório)', 'Clareamento', 'estetica', 'boca', 2000,
   null, null, null, null, null,
   array['clareamento conjugado', 'clareamento misto', 'clareamento de consultorio'], 20, true),
  ('clareamento_caseiro', 'Clareamento caseiro (3 seringas)', 'Clareamento', 'estetica', 'boca', 1200,
   null, null, null, null, null,
   array['clareamento caseiro', 'clareamento em casa', 'clareamento com moldeira'], 30, true),
  ('resina_1_face', 'Restauração em resina — 1 face', 'Restaurações', 'dentistica', 'dente_faces', 250,
   'resina', 1, 1, 'restauracao', 'resina',
   array['restauracao', 'resina', 'restauracao em resina', 'restauracao de resina', 'restauracao em resina composta', 'resina composta', 'restauracao resina'], 40, true),
  ('resina_2_faces', 'Restauração em resina — 2 faces', 'Restaurações', 'dentistica', 'dente_faces', 280,
   'resina', 2, 2, 'restauracao', 'resina',
   array['restauracao', 'resina', 'restauracao em resina', 'restauracao de resina', 'restauracao em resina composta', 'resina composta', 'restauracao resina'], 50, true),
  ('resina_3_faces', 'Restauração em resina — 3 faces', 'Restaurações', 'dentistica', 'dente_faces', 300,
   'resina', 3, 3, 'restauracao', 'resina',
   array['restauracao', 'resina', 'restauracao em resina', 'restauracao de resina', 'restauracao em resina composta', 'resina composta', 'restauracao resina'], 60, true),
  ('resina_4_faces', 'Restauração em resina — 4 faces', 'Restaurações', 'dentistica', 'dente_faces', 350,
   'resina', 4, 5, 'restauracao', 'resina',
   array['restauracao', 'resina', 'restauracao em resina', 'restauracao de resina', 'restauracao em resina composta', 'resina composta', 'restauracao resina'], 70, true),
  ('exodontia_siso', 'Extração de siso', 'Extrações', 'cirurgia', 'dente', 350,
   null, null, null, 'ausente', null,
   array['extracao de siso', 'exodontia de siso', 'extracao do siso', 'exodontia de terceiro molar', 'extracao de terceiro molar', 'siso erupcionado'], 80, true),
  ('exodontia_siso_semi_incluso', 'Extração de siso semi-incluso', 'Extrações', 'cirurgia', 'dente', 450,
   null, null, null, 'ausente', null,
   array['extracao de siso semi incluso', 'exodontia de siso semi incluso', 'extracao de siso semiincluso', 'siso semi incluso'], 90, true),
  ('exodontia_siso_incluso', 'Extração de siso incluso', 'Extrações', 'cirurgia', 'dente', 600,
   null, null, null, 'ausente', null,
   array['extracao de siso incluso', 'exodontia de siso incluso', 'extracao de terceiro molar incluso', 'siso incluso'], 100, true),
  ('exodontia_permanente', 'Extração de dente permanente', 'Extrações', 'cirurgia', 'dente', 300,
   null, null, null, 'ausente', null,
   array['extracao', 'exodontia', 'extracao simples', 'exodontia simples', 'extracao de dente permanente'], 110, true),
  ('exodontia_deciduo', 'Extração de dente decíduo (de leite)', 'Extrações', 'cirurgia', 'dente', 200,
   null, null, null, 'ausente', null,
   array['extracao de deciduo', 'exodontia de deciduo', 'extracao de dente de leite', 'exodontia de dente de leite'], 120, true),
  ('implante_unitario', 'Cirurgia de implante unitário', 'Implantes', 'implante', 'dente', 1800,
   null, null, null, 'implante', null,
   array['implante', 'cirurgia de implante', 'instalacao de implante', 'implante unitario', 'colocacao de implante'], 130, true),
  ('coroa_sobre_implante', 'Coroa sobre implante unitária', 'Implantes', 'implante', 'dente', 1500,
   null, null, null, 'coroa', 'sobre implante',
   array['coroa sobre implante', 'protese sobre implante', 'coroa no implante', 'coroa implantossuportada'], 140, true),
  ('protocolo_gm', 'Protocolo com implantes GM arco total (fase cirúrgica + protética)', 'Implantes', 'implante', 'arcada', 18000,
   null, null, null, null, null,
   array['protocolo', 'protocolo sobre implantes', 'protese protocolo', 'protocolo gm', 'protocolo arco total'], 150, true),
  ('resina_indireta_zirconia', 'Resina indireta reforçada com zircônia', 'Prótese Fixa', 'protese', 'dente', 850,
   null, null, null, 'coroa', 'resina indireta reforçada com zircônia',
   array['resina indireta', 'resina indireta reforcada com zirconia', 'coroa em resina indireta'], 160, true);

-- Procedimentos comuns sem preço definido (faixa de mercado só como referência).
insert into public.procedimentos
  (codigo, nome, grupo, categoria, aplica_a, faixa_mercado, condicao_resultante, detalhe_resultante, sinonimos, ordem, observacao)
values
  ('consulta_avaliacao', 'Consulta de avaliação', 'Diagnóstico', 'diagnostico', 'boca', 'R$ 80–250', null, null,
   array['avaliacao', 'consulta', 'consulta de avaliacao', 'primeira consulta', 'consulta inicial', 'exame clinico'], 200, null),
  ('urgencia', 'Atendimento de urgência', 'Diagnóstico', 'diagnostico', 'boca', 'R$ 100–300', null, null,
   array['urgencia', 'emergencia', 'atendimento de urgencia'], 210, null),
  ('radiografia_periapical', 'Radiografia periapical', 'Diagnóstico', 'diagnostico', 'dente', null, null, null,
   array['radiografia', 'rx', 'raio x', 'periapical', 'radiografia periapical', 'rx periapical'], 220, null),
  ('selante', 'Selante', 'Prevenção', 'prevencao', 'dente', null, 'selante', null,
   array['selante', 'selamento', 'selante de fossulas e fissuras'], 230, null),
  ('restauracao_provisoria', 'Restauração provisória (ionômero de vidro)', 'Restaurações', 'dentistica', 'dente', null, 'restauracao_provisoria', 'ionômero de vidro',
   array['restauracao provisoria', 'provisoria', 'ionomero', 'ionomero de vidro', 'curativo', 'selamento provisorio'], 240, null),
  ('canal_unirradicular', 'Tratamento de canal — unirradicular', 'Endodontia', 'endodontia', 'dente', 'R$ 500–1.200', 'tratamento_canal', null,
   array['canal unirradicular', 'tratamento de canal unirradicular', 'endodontia unirradicular'], 250, null),
  ('canal_birradicular', 'Tratamento de canal — birradicular', 'Endodontia', 'endodontia', 'dente', null, 'tratamento_canal', null,
   array['canal birradicular', 'tratamento de canal birradicular', 'endodontia birradicular'], 260, null),
  ('canal_molar', 'Tratamento de canal — molar', 'Endodontia', 'endodontia', 'dente', 'R$ 800–2.000', 'tratamento_canal', null,
   array['canal molar', 'canal de molar', 'tratamento de canal molar', 'endodontia molar', 'endodontia de molar'], 270, null),
  ('retratamento_canal', 'Retratamento de canal', 'Endodontia', 'endodontia', 'dente', 'R$ 600–1.500', 'tratamento_canal', 'retratamento',
   array['retratamento', 'retratamento de canal', 'retratamento endodontico'], 280, null),
  ('pulpectomia', 'Pulpectomia (urgência endodôntica)', 'Endodontia', 'endodontia', 'dente', null, null, null,
   array['pulpectomia', 'pulpotomia', 'abertura coronaria', 'acesso endodontico'], 290, null),
  ('raspagem_sextante', 'Raspagem e alisamento radicular (por sextante)', 'Periodontia', 'periodontia', 'sextante', 'R$ 200–500', null, null,
   array['raspagem', 'raspagem subgengival', 'raspagem e alisamento', 'raspagem e alisamento radicular', 'rar'], 300, null),
  ('gengivectomia', 'Gengivectomia / gengivoplastia', 'Periodontia', 'periodontia', 'regiao', 'R$ 300–800', null, null,
   array['gengivectomia', 'gengivoplastia'], 310, null),
  ('frenectomia', 'Frenectomia', 'Cirurgia', 'cirurgia', 'regiao', null, null, null,
   array['frenectomia', 'frenotomia'], 320, null),
  ('biopsia', 'Biópsia', 'Cirurgia', 'cirurgia', 'regiao', null, null, null,
   array['biopsia'], 330, null),
  ('remocao_sutura', 'Remoção de sutura', 'Cirurgia', 'cirurgia', 'regiao', null, null, null,
   array['remocao de sutura', 'retirada de pontos', 'tirar os pontos', 'remocao de pontos'], 340, 'Normalmente incluída no procedimento cirúrgico.'),
  ('enxerto_osseo', 'Enxerto ósseo', 'Implantes', 'implante', 'regiao', null, null, null,
   array['enxerto', 'enxerto osseo', 'regeneracao ossea', 'rog'], 350, null),
  ('levantamento_seio', 'Levantamento de seio maxilar', 'Implantes', 'implante', 'regiao', null, null, null,
   array['levantamento de seio', 'levantamento de seio maxilar', 'sinus lift'], 360, null),
  ('reabertura_implante', 'Reabertura de implante / cicatrizador', 'Implantes', 'implante', 'dente', null, null, null,
   array['reabertura', 'reabertura de implante', 'cicatrizador', 'instalacao de cicatrizador'], 370, null),
  ('coroa_provisoria', 'Coroa provisória', 'Prótese Fixa', 'protese', 'dente', null, 'coroa', 'provisória',
   array['coroa provisoria', 'provisorio', 'provisoria de coroa'], 380, null),
  ('coroa_metaloceramica', 'Coroa metalocerâmica', 'Prótese Fixa', 'protese', 'dente', 'R$ 800–2.500', 'coroa', 'metalocerâmica',
   array['coroa metalceramica', 'coroa metaloceramica', 'metaloceramica'], 390, null),
  ('coroa_ceramica', 'Coroa cerâmica (zircônia ou dissilicato)', 'Prótese Fixa', 'protese', 'dente', 'R$ 2.000–4.500', 'coroa', 'cerâmica',
   array['coroa ceramica', 'coroa de zirconia', 'coroa em zirconia', 'coroa de porcelana', 'coroa emax', 'coroa de dissilicato'], 400, null),
  ('nucleo', 'Pino / núcleo', 'Prótese Fixa', 'protese', 'dente', null, 'pino_nucleo', null,
   array['pino', 'nucleo', 'pino e nucleo', 'nucleo metalico', 'pino de fibra', 'retentor intrarradicular'], 410, null),
  ('protese_parcial_removivel', 'Prótese parcial removível (PPR)', 'Prótese Removível', 'protese', 'arcada', 'R$ 1.500–3.500', null, null,
   array['ppr', 'protese parcial removivel', 'protese parcial', 'roach'], 420, null),
  ('protese_total', 'Prótese total', 'Prótese Removível', 'protese', 'arcada', 'R$ 2.000–5.000', null, null,
   array['protese total', 'dentadura', 'pt'], 430, null),
  ('placa_miorrelaxante', 'Placa miorrelaxante', 'Disfunção', 'disfuncao', 'arcada', null, null, null,
   array['placa', 'placa miorrelaxante', 'placa de bruxismo', 'placa oclusal'], 440, null);

