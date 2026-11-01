-- Índice da chave estrangeira atendimentos.solicitacao_id (aviso do Supabase).
create index if not exists atendimentos_solicitacao_idx on public.atendimentos (solicitacao_id);
