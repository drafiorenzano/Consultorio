-- O bicarbonato do jato vem com o aluguel da sala (Dra. Andressa, 02/11/2026):
-- materiais fornecidos pela sala não entram no estoque. Tira do kit da
-- preventiva e desativa o material (do jeito do sistema: nada se apaga).
update public.estoque_kit_itens i
   set removido_em = now()
  from public.estoque_materiais m
 where i.material_id = m.id and m.codigo = 'bicarbonato_jato' and i.removido_em is null;

update public.estoque_materiais
   set ativo = false,
       observacao = 'Vem com o aluguel da sala; não entra no estoque.'
 where codigo = 'bicarbonato_jato';
