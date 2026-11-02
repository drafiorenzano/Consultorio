-- Rótulo das formas de pagamento com os códigos do financeiro
-- (credito_vista, credito_parcelado).
create or replace function public.rotulo_forma_pagamento(p_forma text, p_parcelas int default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_forma
    when 'pix' then 'Pix' when 'dinheiro' then 'Dinheiro' when 'debito' then 'Débito'
    when 'credito_vista' then 'Crédito à vista'
    when 'credito_parcelado' then 'Crédito' || case when p_parcelas > 1 then ' ' || p_parcelas || 'x' else ' parcelado' end
    when 'credito' then 'Crédito' || case when p_parcelas > 1 then ' ' || p_parcelas || 'x' else '' end
    when 'transferencia' then 'Transferência' when 'boleto' then 'Boleto' when 'cheque' then 'Cheque'
    else initcap(replace(coalesce(p_forma, ''), '_', ' ')) end
$$;
