-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): além da dipirona
-- 1 g (padrão), volta a opção de 500 mg, 1 comprimido de 6/6 h em caso de dor.
update public.medicamentos_modelos
   set ativo = true,
       ordem = 11,
       quantidade = '1 caixa',
       posologia = 'Tomar 1 comprimido a cada 6 horas, em caso de dor.',
       indicacao = 'Dor (opção de 500 mg; a padrão é a de 1 g).',
       sinonimos = array['dipirona 500', 'dipirona de 500', 'dipirona 500mg', 'novalgina 500']
 where codigo = 'dipirona_500';
