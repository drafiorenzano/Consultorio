-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): azitromicina 500 mg,
-- 1 comprimido por dia por 3 dias (o modelo de referência era 5 dias).
update public.medicamentos_modelos
   set ativo = true,
       quantidade = '3 comprimidos',
       posologia = 'Tomar 1 comprimido por dia, por 3 dias.',
       antibiotico = true,
       indicacao = 'Antibiótico de 3 dias (modelo que a Dra. usa).',
       sinonimos = array['azitromicina', 'zitromax', 'azitromicina 500', 'azitromicina de 500']
 where codigo = 'azitromicina_500';
