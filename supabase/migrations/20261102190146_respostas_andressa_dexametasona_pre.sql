-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): dexametasona 4 mg
-- pré-operatória, 2 comprimidos 1 hora antes do procedimento.
update public.medicamentos_modelos
   set posologia = 'Tomar 2 comprimidos 1 hora antes do procedimento.',
       quantidade = '2 comprimidos',
       indicacao = 'Dose única antes do procedimento (modelo da Dra.).',
       sinonimos = array['dexametasona pre operatoria', 'dexametasona antes da cirurgia', 'dexametasona dose unica',
                         'dexametasona antes do procedimento', 'dexametasona pre'],
       ativo = true
 where codigo = 'dexametasona_pre_operatoria';
