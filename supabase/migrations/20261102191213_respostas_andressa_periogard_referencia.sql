-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme): o Periogard segue a
-- referência que ela mandou (solução bucal 0,12%, via oral, 15 ml por 1 minuto
-- de manhã e à noite, não engolir), com os 7 dias e o "após a higiene oral"
-- que ela já tinha pedido.
update public.medicamentos_modelos
   set forma = 'solução bucal',
       via = 'oral',
       quantidade = '1 frasco',
       posologia = 'Fazer bochecho com 15 ml (1 copo dosador) por 1 minuto, pela manhã e à noite, '
                   || 'após a higiene oral, por 7 dias. Não engolir.'
 where codigo = 'clorexidina_012';
