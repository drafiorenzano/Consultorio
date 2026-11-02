-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): troca a clindamicina
-- 600 mg pela de 300 mg, 1 de 8/8 h por 7 dias. A de 600 mg sai de uso.
update public.medicamentos_modelos set ativo = false where codigo = 'clindamicina_600';

update public.medicamentos_modelos
   set ativo = true,
       ordem = 99,
       quantidade = '21 cápsulas',
       posologia = 'Tomar 1 cápsula a cada 8 horas, por 7 dias.',
       antibiotico = true,
       indicacao = 'Antibiótico para alérgicos à penicilina (modelo que a Dra. usa).',
       sinonimos = array['clindamicina', 'dalacin', 'clindamicina 300', 'clindamicina de 300', 'dalacin 300']
 where codigo = 'clindamicina_300';
