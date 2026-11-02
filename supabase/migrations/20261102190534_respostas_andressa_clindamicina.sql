-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): clindamicina 600 mg,
-- 1 comprimido de 12/12 h por 7 dias, vira a clindamicina padrão. A de 300 mg
-- (6/6 h) fica como opção, chamada pela dose.
insert into public.medicamentos_modelos
  (codigo, ordem, nome, concentracao, forma, via, quantidade, posologia, classe, antibiotico, indicacao, sinonimos)
values
  ('clindamicina_600', 99, 'Clindamicina', '600 mg', 'comprimido', 'oral', '14 comprimidos',
   'Tomar 1 comprimido a cada 12 horas, por 7 dias.', 'lincosamida', true,
   'Antibiótico para alérgicos à penicilina (modelo que a Dra. usa).',
   array['clindamicina', 'dalacin', 'clindamicina 600', 'clindamicina de 600'])
on conflict (codigo) do update
   set ordem = excluded.ordem, concentracao = excluded.concentracao, forma = excluded.forma,
       quantidade = excluded.quantidade, posologia = excluded.posologia, antibiotico = true,
       indicacao = excluded.indicacao, sinonimos = excluded.sinonimos, ativo = true;

update public.medicamentos_modelos
   set sinonimos = array['clindamicina 300', 'clindamicina de 300', 'dalacin 300']
 where codigo = 'clindamicina_300';
