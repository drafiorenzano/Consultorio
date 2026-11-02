-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): os remédios que ela
-- mais receita viram os modelos principais.

-- Dipirona: ela usa 1 g de 6/6 h por 3 dias ou se houver dor. O modelo de
-- 500 mg sai de uso (fica no histórico).
update public.medicamentos_modelos set ativo = false where codigo = 'dipirona_500';

insert into public.medicamentos_modelos
  (codigo, ordem, nome, concentracao, forma, via, quantidade, posologia, classe, indicacao, sinonimos)
values
  ('dipirona_1g', 10, 'Dipirona sódica', '1 g', 'comprimido', 'oral', '1 caixa',
   'Tomar 1 comprimido a cada 6 horas, por 3 dias ou em caso de dor.', 'dipirona',
   'Dor (modelo que a Dra. mais usa).',
   array['dipirona', 'novalgina', 'dipirona 1g', 'dipirona 1 g', 'dipirona de 1 grama', 'dipirona 1 grama']),
  ('arflex_200', 15, 'Arflex Retard (nimesulida)', '200 mg', 'cápsula de ação prolongada', 'oral', '1 caixa com 6 cápsulas',
   'Tomar 1 cápsula a cada 24 horas, por 5 dias.', 'aine',
   'Anti-inflamatório (modelo que a Dra. mais usa).',
   array['arflex', 'arflex retard', 'arflex 200', 'nimesulida 200', 'nimesulida retard', 'nimesulida de 200'])
on conflict (codigo) do update
   set ordem = excluded.ordem, nome = excluded.nome, concentracao = excluded.concentracao,
       forma = excluded.forma, quantidade = excluded.quantidade, posologia = excluded.posologia,
       classe = excluded.classe, indicacao = excluded.indicacao, sinonimos = excluded.sinonimos,
       ativo = true;
