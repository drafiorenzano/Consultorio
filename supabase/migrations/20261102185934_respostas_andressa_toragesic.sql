-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): Toragesic
-- (cetorolaco) 10 mg, 1 comprimido sublingual de 6/6 h se houver dor (SOS).
update public.medicamentos_modelos
   set ordem = 19,
       nome = 'Toragesic (cetorolaco de trometamol)',
       quantidade = '1 caixa',
       posologia = 'Colocar 1 comprimido embaixo da língua a cada 6 horas, em caso de dor.',
       indicacao = 'Dor, se precisar (modelo que a Dra. mais usa).',
       sinonimos = array['toragesic', 'toragesic 10', 'cetorolaco', 'cetorolaco sublingual', 'cetorolaco de trometamol'],
       ativo = true
 where codigo = 'cetorolaco_10';
