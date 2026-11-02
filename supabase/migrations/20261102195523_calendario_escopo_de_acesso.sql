-- Link de assinatura da agenda no Calendário (iPhone/iPad): novo escopo de acesso.
alter table public.acessos_mcp drop constraint acessos_mcp_escopo_check;
alter table public.acessos_mcp add constraint acessos_mcp_escopo_check
  check (escopo in ('mcp', 'painel', 'calendario'));
