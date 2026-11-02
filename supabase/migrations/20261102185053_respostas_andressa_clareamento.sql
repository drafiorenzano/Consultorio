-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme), 2ª leva: clareamento.
-- Ela mantém os dois clareamentos. O caseiro passa a ser com 5 seringas
-- (antes 3), mesmo valor (R$ 1.200).
update public.procedimentos
   set nome = 'Clareamento caseiro (5 seringas)'
 where codigo = 'clareamento_caseiro';

-- Os kits do estoque passam a bater com o que cada clareamento entrega:
-- caseiro 5 seringas; conjugado 5 seringas + 2 sessões em consultório.
update public.estoque_kit_itens as i
   set quantidade = v.quantidade
  from (values ('clareamento_caseiro', 'gel_clareador_caseiro', 5),
               ('clareamento_conjugado', 'gel_clareador_caseiro', 5),
               ('clareamento_conjugado', 'gel_clareador_consultorio', 2)) as v(procedimento, material, quantidade),
       public.estoque_kits k, public.procedimentos p, public.estoque_materiais m
 where p.codigo = v.procedimento and k.procedimento_id = p.id and m.codigo = v.material
   and i.kit_id = k.id and i.material_id = m.id;

-- Nome dos kits acompanha o nome do procedimento (onlay e clareamento caseiro).
update public.estoque_kits k
   set nome = 'Kit ' || p.nome
  from public.procedimentos p
 where k.procedimento_id = p.id
   and p.codigo in ('clareamento_caseiro', 'resina_indireta_zirconia');
