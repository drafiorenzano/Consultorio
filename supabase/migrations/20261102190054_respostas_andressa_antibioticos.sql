-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): antibióticos que ela
-- usa. Amoxicilina 500 mg de 8/8 h por 7 dias já era o modelo; entram a de
-- 875 mg e a com clavulanato (875 mg + 125 mg), ambas de 12/12 h por 7 dias.
-- Antibiótico sai em 2 vias (RDC 471/2021), pelo campo antibiotico.
update public.medicamentos_modelos
   set indicacao = 'Antibiótico (modelo que a Dra. mais usa).', antibiotico = true, ativo = true
 where codigo = 'amoxicilina_500';

insert into public.medicamentos_modelos
  (codigo, ordem, nome, concentracao, forma, via, quantidade, posologia, classe, antibiotico, indicacao, sinonimos)
values
  ('amoxicilina_875', 71, 'Amoxicilina', '875 mg', 'comprimido', 'oral', '14 comprimidos',
   'Tomar 1 comprimido a cada 12 horas, por 7 dias.', 'betalactamico', true,
   'Antibiótico de 12/12 h (modelo que a Dra. usa).',
   array['amoxicilina 875', 'amoxicilina de 875', 'amoxicilina 12 em 12']),
  ('amoxicilina_clavulanato_875', 72, 'Amoxicilina + clavulanato de potássio', '875 mg + 125 mg', 'comprimido', 'oral',
   '14 comprimidos', 'Tomar 1 comprimido a cada 12 horas, por 7 dias.', 'betalactamico', true,
   'Antibiótico com clavulanato (modelo que a Dra. usa).',
   array['amoxicilina com clavulanato', 'amoxicilina clavulanato', 'amoxicilina e clavulanato', 'clavulanato',
         'clavulin', 'amoxicilina com clavulanato 875'])
on conflict (codigo) do update
   set ordem = excluded.ordem, nome = excluded.nome, concentracao = excluded.concentracao, forma = excluded.forma,
       quantidade = excluded.quantidade, posologia = excluded.posologia, antibiotico = true,
       indicacao = excluded.indicacao, sinonimos = excluded.sinonimos, ativo = true;
