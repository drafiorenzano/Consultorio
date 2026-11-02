-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): o bochecho com
-- Periogard é feito após a higiene oral.
update public.medicamentos_modelos
   set posologia = 'Bochechar 2 vezes ao dia, após a higiene oral, por 7 dias.'
 where codigo = 'clorexidina_012';
