-- Bucket privado para os documentos gerados pelo servidor (orçamentos,
-- receitas, atestados, termos, relatórios para o contador). Sem políticas:
-- só a chave secreta (Edge Function) grava e assina links temporários.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 20971520,
        array['application/pdf', 'text/csv', 'image/png', 'image/jpeg'])
on conflict (id) do nothing;
