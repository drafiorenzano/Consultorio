-- =====================================================================
-- Estoque: materiais típicos de um consultório, fornecedores e kits por
-- procedimento. Sem saldo e sem preço: o saldo entra pela contagem
-- inicial e o custo pelas compras. Mínimos e quantidades dos kits são um
-- ponto de partida, para a Dra. ajustar.
-- =====================================================================

insert into public.estoque_materiais (codigo, nome, categoria, grupo, padrao_do_grupo, variantes, unidade_compra,
                                      unidade_uso, fator, estoque_minimo, controla_validade, sinonimos, observacao)
select t.codigo, t.nome, t.categoria, t.grupo, coalesce(t.padrao, false),
       array(select public.estoque_frase_raiz(v) from unnest(t.variantes) v),
       t.uc, t.uu, t.fator, t.minimo, t.validade,
       array(select distinct public.normalizar(s) from unnest(t.sinonimos) s),
       t.obs
  from (values
    -- Anestésicos e agulhas
    ('articaina_4_epinefrina_100', 'Articaína 4% com epinefrina 1:100.000', 'anestesico', null::text, null::boolean,
     '{}'::text[], 'caixa', 'tubete', 50::numeric, 20::numeric, true,
     array['articaína', 'articaína 4%', 'articaína com epinefrina', 'articaína 1:100.000'], null::text),
    ('lidocaina_2_epinefrina', 'Lidocaína 2% com epinefrina 1:100.000', 'anestesico', null, null, '{}', 'caixa', 'tubete',
     50, 10, true, array['lidocaína com vaso', 'lidocaína com epinefrina', 'lidocaína 2% com epinefrina', 'xylocaína'], null),
    ('lidocaina_2_sem_vaso', 'Lidocaína 2% sem vasoconstritor', 'anestesico', null, null, '{}', 'caixa', 'tubete',
     50, 0, true, array['lidocaína sem vaso', 'lidocaína sem vasoconstritor'], null),
    ('mepivacaina_3_sem_vaso', 'Mepivacaína 3% sem vasoconstritor', 'anestesico', null, null, '{}', 'caixa', 'tubete',
     50, 10, true, array['mepivacaína', 'mepivacaína 3%', 'mepivacaína sem vaso'], null),
    ('prilocaina_3_felipressina', 'Prilocaína 3% com felipressina', 'anestesico', null, null, '{}', 'caixa', 'tubete',
     50, 0, true, array['prilocaína', 'prilocaína com felipressina', 'citanest'], null),
    ('anestesico_topico', 'Anestésico tópico (benzocaína 20%)', 'anestesico', null, null, '{}', 'pote', 'aplicação',
     60, 10, true, array['anestésico tópico', 'tópico', 'benzocaína', 'pomada anestésica'], 'Pote de 12 g, cerca de 60 aplicações.'),
    ('agulha_curta_30g', 'Agulha gengival curta 30G', 'agulha', null, null, '{}', 'caixa', 'unidade',
     100, 20, true, array['agulha curta', 'agulha 30g', 'agulha gengival curta'], null),
    ('agulha_longa_27g', 'Agulha gengival longa 27G', 'agulha', null, null, '{}', 'caixa', 'unidade',
     100, 20, true, array['agulha longa', 'agulha 27g', 'agulha gengival longa'], null),

    -- EPI e descartáveis
    ('luva_procedimento_p', 'Luva de procedimento P', 'epi', 'luva_procedimento', false,
     array['luva p', 'luva pequena', 'tamanho p'], 'caixa', 'par', 50, 0, false,
     array['luva p', 'luva pequena'], 'Caixa com 100 luvas (50 pares).'),
    ('luva_procedimento_m', 'Luva de procedimento M', 'epi', 'luva_procedimento', true,
     array['luva m', 'luva media', 'luva medio', 'tamanho m'], 'caixa', 'par', 50, 25, false,
     array['luva', 'luvas', 'luva de procedimento', 'luva m', 'luva média'], 'Caixa com 100 luvas (50 pares).'),
    ('luva_procedimento_g', 'Luva de procedimento G', 'epi', 'luva_procedimento', false,
     array['luva g', 'luva grande', 'tamanho g'], 'caixa', 'par', 50, 0, false,
     array['luva g', 'luva grande'], 'Caixa com 100 luvas (50 pares).'),
    ('luva_cirurgica_esteril', 'Luva cirúrgica estéril', 'epi', null, null, '{}', 'caixa', 'par',
     50, 4, true, array['luva cirúrgica', 'luva estéril', 'luva cirúrgica estéril'], null),
    ('mascara_tripla', 'Máscara descartável tripla', 'epi', null, null, '{}', 'caixa', 'unidade',
     50, 20, false, array['máscara', 'máscara descartável', 'máscara tripla'], null),
    ('gorro_descartavel', 'Gorro descartável', 'epi', null, null, '{}', 'pacote', 'unidade',
     100, 20, false, array['gorro', 'touca', 'touca descartável'], null),
    ('babador', 'Babador descartável', 'descartavel', null, null, '{}', 'pacote', 'unidade',
     100, 20, false, array['babador', 'guardanapo'], null),
    ('sugador', 'Sugador descartável', 'descartavel', null, null, '{}', 'pacote', 'unidade',
     40, 20, false, array['sugador', 'sugador de saliva'], null),
    ('rolete_algodao', 'Rolete de algodão', 'descartavel', null, null, '{}', 'pacote', 'unidade',
     100, 50, false, array['rolete', 'rolete de algodão', 'algodão'], null),
    ('gaze', 'Gaze', 'descartavel', null, null, '{}', 'pacote', 'unidade',
     500, 50, false, array['gaze', 'compressa de gaze'], 'Pacote com 500 (não estéril).'),
    ('copo_descartavel', 'Copo descartável', 'descartavel', null, null, '{}', 'pacote', 'unidade',
     100, 20, false, array['copo', 'copinho', 'copo descartável'], null),
    ('campo_cirurgico', 'Campo cirúrgico descartável', 'cirurgia', null, null, '{}', 'pacote', 'unidade',
     10, 2, true, array['campo', 'campo cirúrgico', 'campo fenestrado'], null),

    -- Esterilização
    ('envelope_autosselante', 'Envelope autosselante para autoclave', 'esterilizacao', null, null, '{}', 'caixa', 'unidade',
     200, 30, false, array['envelope', 'envelope autosselante', 'envelope de autoclave', 'grau cirúrgico'], null),
    ('indicador_biologico', 'Indicador biológico', 'esterilizacao', null, null, '{}', 'caixa', 'unidade',
     10, 2, true, array['indicador biológico', 'teste biológico'], null),

    -- Dentística
    ('resina_a1', 'Resina composta A1', 'dentistica', 'resina_composta', false, array['a1'], 'seringa', 'g',
     4, 0, true, array['resina a1'], 'Seringa de 4 g.'),
    ('resina_a2', 'Resina composta A2', 'dentistica', 'resina_composta', true, array['a2'], 'seringa', 'g',
     4, 4, true, array['resina', 'resina composta', 'resina a2'], 'Seringa de 4 g. Cor padrão quando a cor não é dita.'),
    ('resina_a3', 'Resina composta A3', 'dentistica', 'resina_composta', false, array['a3'], 'seringa', 'g',
     4, 4, true, array['resina a3'], 'Seringa de 4 g.'),
    ('resina_b1', 'Resina composta B1', 'dentistica', 'resina_composta', false, array['b1'], 'seringa', 'g',
     4, 0, true, array['resina b1'], 'Seringa de 4 g.'),
    ('resina_flow', 'Resina flow A2', 'dentistica', null, null, '{}', 'seringa', 'g',
     2, 0, true, array['flow', 'resina flow', 'resina fluida'], 'Seringa de 2 g.'),
    ('adesivo', 'Adesivo dentinário', 'dentistica', null, null, '{}', 'frasco', 'gota',
     100, 20, true, array['adesivo', 'adesivo dentinário', 'sistema adesivo', 'bond'], 'Frasco de 5 ml, cerca de 100 gotas.'),
    ('acido_fosforico', 'Ácido fosfórico 37%', 'dentistica', null, null, '{}', 'seringa', 'g',
     2.5, 1, true, array['ácido', 'ácido fosfórico', 'ácido 37%', 'condicionador ácido'], 'Seringa de 2,5 g.'),
    ('microbrush', 'Microbrush (aplicador descartável)', 'dentistica', null, null, '{}', 'tubo', 'unidade',
     100, 20, false, array['microbrush', 'aplicador', 'aplicador descartável'], null),
    ('ionomero_vidro', 'Ionômero de vidro restaurador', 'dentistica', null, null, '{}', 'kit', 'porção',
     30, 5, true, array['ionômero', 'ionômero de vidro', 'civ'], 'Kit pó + líquido, cerca de 30 porções.'),
    ('hidroxido_calcio', 'Cimento de hidróxido de cálcio', 'dentistica', null, null, '{}', 'kit', 'porção',
     40, 5, true, array['hidróxido de cálcio', 'dycal'], null),
    ('matriz_aco', 'Matriz de aço', 'dentistica', null, null, '{}', 'pacote', 'unidade',
     50, 10, false, array['matriz', 'fita matriz', 'matriz de aço'], null),
    ('cunha_madeira', 'Cunha de madeira', 'dentistica', null, null, '{}', 'pacote', 'unidade',
     100, 20, false, array['cunha', 'cunha de madeira'], null),

    -- Prótese e moldagem
    ('fio_retrator', 'Fio retrator', 'protese', null, null, '{}', 'frasco', 'cm',
     250, 50, true, array['fio retrator', 'fio afastador', 'fio de afastamento'], 'Frasco com cerca de 2,5 m.'),
    ('alginato', 'Alginato', 'protese', null, null, '{}', 'pacote', 'g',
     454, 100, true, array['alginato'], 'Pacote de 454 g.'),

    -- Profilaxia e antissepsia
    ('pasta_profilatica', 'Pasta profilática', 'profilaxia', null, null, '{}', 'pote', 'g',
     90, 20, true, array['pasta profilática', 'pasta de profilaxia', 'pasta de polimento'], null),
    ('fluor_gel', 'Flúor gel', 'profilaxia', null, null, '{}', 'frasco', 'ml',
     200, 20, true, array['flúor', 'flúor gel', 'fluoreto'], null),
    ('clorexidina_0_12', 'Clorexidina 0,12%', 'antissepsia', null, null, '{}', 'frasco', 'ml',
     250, 250, true, array['clorexidina', 'clorexidina 0,12%', 'bochecho de clorexidina'], 'Frasco de 250 ml.'),

    -- Endodontia
    ('lima_k', 'Lima tipo K (15 a 40)', 'endodontia', null, null, '{}', 'cartela', 'unidade',
     6, 6, false, array['lima', 'limas', 'lima k', 'lima tipo k'], 'Cartela com 6 limas.'),
    ('hipoclorito_2_5', 'Hipoclorito de sódio 2,5%', 'endodontia', null, null, '{}', 'frasco', 'ml',
     1000, 200, true, array['hipoclorito', 'hipoclorito de sódio'], 'Frasco de 1 litro.'),
    ('guta_percha', 'Cone de guta-percha', 'endodontia', null, null, '{}', 'caixa', 'cone',
     120, 20, true, array['guta', 'guta-percha', 'guta percha', 'cone de guta'], null),
    ('cone_papel', 'Cone de papel absorvente', 'endodontia', null, null, '{}', 'caixa', 'cone',
     200, 20, false, array['cone de papel', 'papel absorvente'], null),
    ('cimento_endodontico', 'Cimento endodôntico', 'endodontia', null, null, '{}', 'kit', 'porção',
     30, 5, true, array['cimento endodôntico', 'cimento obturador', 'sealer'], null),

    -- Cirurgia
    ('fio_sutura_nylon_4_0', 'Fio de sutura nylon 4-0', 'cirurgia', 'fio_sutura', true, array['nylon'], 'caixa', 'unidade',
     24, 4, true, array['fio de sutura', 'sutura', 'fio nylon', 'nylon 4-0'], 'Caixa com 24 envelopes.'),
    ('fio_sutura_seda_4_0', 'Fio de sutura seda 4-0', 'cirurgia', 'fio_sutura', false, array['seda'], 'caixa', 'unidade',
     24, 0, true, array['fio de seda', 'seda 4-0', 'sutura de seda'], 'Caixa com 24 envelopes.'),
    ('lamina_bisturi_15', 'Lâmina de bisturi nº 15', 'cirurgia', null, null, '{}', 'caixa', 'unidade',
     100, 5, true, array['lâmina', 'lâmina de bisturi', 'bisturi', 'lâmina 15'], null),
    ('esponja_hemostatica', 'Esponja hemostática', 'cirurgia', null, null, '{}', 'caixa', 'unidade',
     10, 2, true, array['esponja hemostática', 'esponja de colágeno', 'hemostático'], null),
    ('soro_fisiologico', 'Soro fisiológico 0,9% (250 ml)', 'cirurgia', null, null, '{}', 'frasco', 'frasco',
     1, 3, true, array['soro', 'soro fisiológico'], null),

    -- Clareamento
    ('gel_clareador_consultorio', 'Gel clareador de consultório (peróxido de hidrogênio 35%)', 'clareamento', null, null,
     '{}', 'kit', 'aplicação', 3, 0, true, array['clareador de consultório', 'gel de consultório', 'peróxido de hidrogênio'],
     'Kit para 3 sessões.'),
    ('gel_clareador_caseiro', 'Gel clareador caseiro (peróxido de carbamida)', 'clareamento', null, null, '{}', 'kit', 'seringa',
     4, 0, true, array['clareador caseiro', 'gel caseiro', 'peróxido de carbamida'], 'Kit com 4 seringas.'),
    ('barreira_gengival', 'Barreira gengival fotopolimerizável', 'clareamento', null, null, '{}', 'seringa', 'seringa',
     1, 0, true, array['barreira gengival', 'proteção gengival', 'top dam'], null),

    -- Radiologia
    ('filme_periapical', 'Filme radiográfico periapical', 'radiologia', null, null, '{}', 'caixa', 'unidade',
     150, 20, true, array['filme', 'filme periapical', 'filme de raio x'], 'Se a radiografia é digital (sensor), desative.')
  ) as t(codigo, nome, categoria, grupo, padrao, variantes, uc, uu, fator, minimo, validade, sinonimos, obs);

insert into public.estoque_fornecedores (nome, site) values
  ('Dental Cremer', 'dentalcremer.com.br'),
  ('Dental Speed', 'dentalspeed.com'),
  ('Surya Dental', 'suryadental.com.br');

-- Kits ---------------------------------------------------------------
insert into public.estoque_kits (codigo, nome, base, observacao)
values ('atendimento_base', 'Kit base do atendimento (biossegurança)', true, 'Somado a todo atendimento registrado.');

insert into public.estoque_kits (codigo, nome, procedimento_id, anestesia_tubetes)
select 'kit_' || p.codigo, 'Kit ' || p.nome, p.id, t.tubetes
  from (values
    ('consulta_preventiva', 0), ('resina_1_face', 1), ('resina_2_faces', 1), ('resina_3_faces', 1),
    ('resina_4_faces', 1), ('restauracao_provisoria', 0), ('selante', 0),
    ('exodontia_permanente', 2), ('exodontia_deciduo', 1), ('exodontia_siso', 2),
    ('exodontia_siso_semi_incluso', 3), ('exodontia_siso_incluso', 3),
    ('canal_unirradicular', 1), ('canal_birradicular', 1), ('canal_molar', 2), ('retratamento_canal', 2),
    ('pulpectomia', 1), ('implante_unitario', 3), ('enxerto_osseo', 3), ('levantamento_seio', 3),
    ('reabertura_implante', 1), ('coroa_metaloceramica', 1), ('coroa_ceramica', 1),
    ('resina_indireta_zirconia', 1), ('coroa_sobre_implante', 0), ('clareamento_conjugado', 0),
    ('clareamento_caseiro', 0), ('raspagem_sextante', 1), ('remocao_sutura', 0),
    ('radiografia_periapical', 0), ('frenectomia', 1), ('gengivectomia', 1), ('biopsia', 1)
  ) as t(codigo, tubetes)
  join public.procedimentos p on p.codigo = t.codigo;

-- Linhas: código do material ou nome do grupo (luva_procedimento,
-- resina_composta, fio_sutura), quantidade na unidade de uso.
insert into public.estoque_kit_itens (kit_id, material_id, grupo, quantidade)
select k.id, m.id, case when m.id is null then t.item end, t.q
  from (values
    ('atendimento_base', 'luva_procedimento', 1::numeric), ('atendimento_base', 'mascara_tripla', 1),
    ('atendimento_base', 'gorro_descartavel', 1), ('atendimento_base', 'babador', 1),
    ('atendimento_base', 'sugador', 1), ('atendimento_base', 'copo_descartavel', 1),
    ('atendimento_base', 'envelope_autosselante', 1),

    ('consulta_preventiva', 'pasta_profilatica', 2), ('consulta_preventiva', 'fluor_gel', 5),
    ('consulta_preventiva', 'rolete_algodao', 2),

    ('resina_1_face', 'resina_composta', 0.2), ('resina_1_face', 'adesivo', 2), ('resina_1_face', 'acido_fosforico', 0.1),
    ('resina_1_face', 'microbrush', 2), ('resina_1_face', 'rolete_algodao', 4), ('resina_1_face', 'matriz_aco', 1),
    ('resina_1_face', 'cunha_madeira', 1),
    ('resina_2_faces', 'resina_composta', 0.3), ('resina_2_faces', 'adesivo', 2), ('resina_2_faces', 'acido_fosforico', 0.15),
    ('resina_2_faces', 'microbrush', 2), ('resina_2_faces', 'rolete_algodao', 4), ('resina_2_faces', 'matriz_aco', 1),
    ('resina_2_faces', 'cunha_madeira', 1),
    ('resina_3_faces', 'resina_composta', 0.4), ('resina_3_faces', 'adesivo', 3), ('resina_3_faces', 'acido_fosforico', 0.2),
    ('resina_3_faces', 'microbrush', 2), ('resina_3_faces', 'rolete_algodao', 4), ('resina_3_faces', 'matriz_aco', 1),
    ('resina_3_faces', 'cunha_madeira', 2),
    ('resina_4_faces', 'resina_composta', 0.5), ('resina_4_faces', 'adesivo', 3), ('resina_4_faces', 'acido_fosforico', 0.25),
    ('resina_4_faces', 'microbrush', 2), ('resina_4_faces', 'rolete_algodao', 4), ('resina_4_faces', 'matriz_aco', 1),
    ('resina_4_faces', 'cunha_madeira', 2),

    ('restauracao_provisoria', 'ionomero_vidro', 1), ('restauracao_provisoria', 'rolete_algodao', 2),
    ('restauracao_provisoria', 'microbrush', 1),
    ('selante', 'acido_fosforico', 0.1), ('selante', 'resina_flow', 0.05), ('selante', 'microbrush', 1),
    ('selante', 'rolete_algodao', 2),

    ('exodontia_permanente', 'gaze', 6), ('exodontia_permanente', 'fio_sutura', 1),
    ('exodontia_deciduo', 'gaze', 4),
    ('exodontia_siso', 'gaze', 6), ('exodontia_siso', 'fio_sutura', 1),
    ('exodontia_siso_semi_incluso', 'gaze', 10), ('exodontia_siso_semi_incluso', 'fio_sutura', 1),
    ('exodontia_siso_semi_incluso', 'lamina_bisturi_15', 1), ('exodontia_siso_semi_incluso', 'soro_fisiologico', 1),
    ('exodontia_siso_semi_incluso', 'luva_cirurgica_esteril', 1), ('exodontia_siso_semi_incluso', 'campo_cirurgico', 1),
    ('exodontia_siso_incluso', 'gaze', 10), ('exodontia_siso_incluso', 'fio_sutura', 1),
    ('exodontia_siso_incluso', 'lamina_bisturi_15', 1), ('exodontia_siso_incluso', 'soro_fisiologico', 1),
    ('exodontia_siso_incluso', 'luva_cirurgica_esteril', 1), ('exodontia_siso_incluso', 'campo_cirurgico', 1),

    ('canal_unirradicular', 'lima_k', 1), ('canal_unirradicular', 'hipoclorito_2_5', 20),
    ('canal_unirradicular', 'guta_percha', 3), ('canal_unirradicular', 'cone_papel', 4),
    ('canal_unirradicular', 'cimento_endodontico', 1),
    ('canal_birradicular', 'lima_k', 2), ('canal_birradicular', 'hipoclorito_2_5', 40),
    ('canal_birradicular', 'guta_percha', 6), ('canal_birradicular', 'cone_papel', 8),
    ('canal_birradicular', 'cimento_endodontico', 1),
    ('canal_molar', 'lima_k', 3), ('canal_molar', 'hipoclorito_2_5', 60), ('canal_molar', 'guta_percha', 9),
    ('canal_molar', 'cone_papel', 12), ('canal_molar', 'cimento_endodontico', 2),
    ('retratamento_canal', 'lima_k', 3), ('retratamento_canal', 'hipoclorito_2_5', 60),
    ('retratamento_canal', 'guta_percha', 9), ('retratamento_canal', 'cone_papel', 12),
    ('retratamento_canal', 'cimento_endodontico', 2),
    ('pulpectomia', 'lima_k', 1), ('pulpectomia', 'hipoclorito_2_5', 10), ('pulpectomia', 'cone_papel', 2),

    ('implante_unitario', 'luva_cirurgica_esteril', 2), ('implante_unitario', 'campo_cirurgico', 1),
    ('implante_unitario', 'soro_fisiologico', 1), ('implante_unitario', 'lamina_bisturi_15', 1),
    ('implante_unitario', 'fio_sutura', 1), ('implante_unitario', 'gaze', 10),
    ('implante_unitario', 'clorexidina_0_12', 15),
    ('enxerto_osseo', 'luva_cirurgica_esteril', 2), ('enxerto_osseo', 'campo_cirurgico', 1),
    ('enxerto_osseo', 'soro_fisiologico', 1), ('enxerto_osseo', 'lamina_bisturi_15', 1),
    ('enxerto_osseo', 'fio_sutura', 1), ('enxerto_osseo', 'gaze', 10),
    ('levantamento_seio', 'luva_cirurgica_esteril', 2), ('levantamento_seio', 'campo_cirurgico', 1),
    ('levantamento_seio', 'soro_fisiologico', 1), ('levantamento_seio', 'lamina_bisturi_15', 1),
    ('levantamento_seio', 'fio_sutura', 1), ('levantamento_seio', 'gaze', 10),
    ('reabertura_implante', 'lamina_bisturi_15', 1), ('reabertura_implante', 'fio_sutura', 1),
    ('reabertura_implante', 'gaze', 4),

    ('coroa_metaloceramica', 'fio_retrator', 10), ('coroa_metaloceramica', 'alginato', 20),
    ('coroa_metaloceramica', 'gaze', 2),
    ('coroa_ceramica', 'fio_retrator', 10), ('coroa_ceramica', 'alginato', 20), ('coroa_ceramica', 'gaze', 2),
    ('resina_indireta_zirconia', 'fio_retrator', 10), ('resina_indireta_zirconia', 'alginato', 20),
    ('resina_indireta_zirconia', 'gaze', 2),
    ('coroa_sobre_implante', 'alginato', 20), ('coroa_sobre_implante', 'gaze', 2),

    ('clareamento_conjugado', 'gel_clareador_consultorio', 1), ('clareamento_conjugado', 'barreira_gengival', 1),
    ('clareamento_conjugado', 'gel_clareador_caseiro', 2),
    ('clareamento_caseiro', 'gel_clareador_caseiro', 4),

    ('raspagem_sextante', 'gaze', 2), ('raspagem_sextante', 'clorexidina_0_12', 10),
    ('remocao_sutura', 'gaze', 2),
    ('radiografia_periapical', 'filme_periapical', 1),
    ('frenectomia', 'lamina_bisturi_15', 1), ('frenectomia', 'fio_sutura', 1), ('frenectomia', 'gaze', 4),
    ('gengivectomia', 'lamina_bisturi_15', 1), ('gengivectomia', 'fio_sutura', 1), ('gengivectomia', 'gaze', 4),
    ('biopsia', 'lamina_bisturi_15', 1), ('biopsia', 'fio_sutura', 1), ('biopsia', 'gaze', 4)
  ) as t(kit, item, q)
  join public.estoque_kits k on k.codigo = case when t.kit = 'atendimento_base' then t.kit else 'kit_' || t.kit end
  left join public.estoque_materiais m on m.codigo = t.item
 where m.id is not null or exists (select 1 from public.estoque_materiais g where g.grupo = t.item);
