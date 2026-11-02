-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): bochecho com
-- Periogard (clorexidina 0,12%), 2 vezes ao dia por 7 dias. Na receita sai
-- "Periogard (clorexidina 0,12%), solução para bochecho".
update public.medicamentos_modelos
   set ativo = true,
       nome = 'Periogard (clorexidina 0,12%)',
       concentracao = null,
       quantidade = '1 frasco',
       posologia = 'Bochechar 2 vezes ao dia, por 7 dias.',
       indicacao = 'Bochecho antisséptico (modelo que a Dra. usa).',
       sinonimos = array['periogard', 'clorexidina', 'bochecho', 'bochecho de clorexidina', 'clorexidina 0,12',
                         'clorexidina 012', 'enxaguante de clorexidina']
 where codigo = 'clorexidina_012';
