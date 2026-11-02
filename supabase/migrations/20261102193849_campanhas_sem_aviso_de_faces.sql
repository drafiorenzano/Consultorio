-- Preço de campanha e calculadora tratam o procedimento como item de tabela:
-- o aviso de "faltaram as faces" (que vale no atendimento) não se aplica.
do $do$
declare
  d text;
begin
  d := pg_get_functiondef('public.mcp_salvar_campanha(jsonb, text)'::regprocedure);
  if position($q$    if v_aviso is not null then
      v_avisos := v_avisos || v_aviso;$q$ in d) = 0 then
    raise exception 'Trecho não encontrado em mcp_salvar_campanha';
  end if;
  execute replace(d, $q$    if v_aviso is not null then
      v_avisos := v_avisos || v_aviso;$q$, $q$    if v_aviso is not null and v_aviso not like 'Faltaram as faces%' then
      v_avisos := v_avisos || v_aviso;$q$);

  d := pg_get_functiondef('public.mcp_calcular_preco(jsonb, text)'::regprocedure);
  if position($q$    if v_aviso is not null then v_avisos := v_avisos || v_aviso; end if;$q$ in d) = 0 then
    raise exception 'Trecho não encontrado em mcp_calcular_preco';
  end if;
  execute replace(d, $q$    if v_aviso is not null then v_avisos := v_avisos || v_aviso; end if;$q$,
                     $q$    if v_aviso is not null and v_aviso not like 'Faltaram as faces%' then v_avisos := v_avisos || v_aviso; end if;$q$);
end
$do$;
