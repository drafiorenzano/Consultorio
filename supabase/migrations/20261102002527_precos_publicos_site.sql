-- =====================================================================
-- Fonte única de preços: o site (andressafiorenzano.com.br/orcamento) lê
-- daqui, com a chave pública, só os procedimentos marcados para o site.
-- A Dra. muda preço pelo Claude (salvar_procedimento) e o site já mostra.
--
-- Só esta função é aberta ao público. Ela devolve nome, grupo, preço e
-- ordem dos itens com publicar_no_site; nenhuma tabela fica legível.
-- Mesmo formato que o site já usa (id, grupo, nome, valor, ordem).
-- =====================================================================

create or replace function public.precos_site()
returns table (id text, grupo text, nome text, valor numeric, ordem integer)
language sql
stable
security definer
set search_path = ''
as $$
  select p.codigo, p.grupo, p.nome, p.preco, p.ordem
    from public.procedimentos p
   where p.ativo and p.publicar_no_site and p.preco is not null
   order by p.ordem, p.nome
$$;
comment on function public.precos_site() is
  'Preços públicos para o site (só itens com publicar_no_site). Única função liberada para a chave pública.';

revoke execute on function public.precos_site() from public;
grant execute on function public.precos_site() to anon, authenticated, service_role;
