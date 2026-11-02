-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): dexametasona 4 mg,
-- 1 comprimido de 12/12 h por 5 dias, é a que ela sempre prescreve. Vira o
-- modelo principal; a dose única pré-operatória continua como modelo à parte.
insert into public.medicamentos_modelos
  (codigo, ordem, nome, concentracao, forma, via, quantidade, posologia, classe, indicacao, sinonimos)
select 'dexametasona_pre_operatoria', 65, nome, concentracao, forma, via, quantidade, posologia, classe,
       'Dose única antes de cirurgia (referência).',
       array['dexametasona pre operatoria', 'dexametasona antes da cirurgia', 'dexametasona dose unica']
  from public.medicamentos_modelos
 where codigo = 'dexametasona_4'
on conflict (codigo) do nothing;

update public.medicamentos_modelos
   set ordem = 18,
       quantidade = '10 comprimidos',
       posologia = 'Tomar 1 comprimido a cada 12 horas, por 5 dias.',
       indicacao = 'Anti-inflamatório (modelo que a Dra. mais usa).',
       sinonimos = array['dexametasona', 'decadron', 'dexametasona 4', 'dexametasona 4mg', 'dexametasona de 4'],
       ativo = true
 where codigo = 'dexametasona_4';
