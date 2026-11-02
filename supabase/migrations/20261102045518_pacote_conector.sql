-- Pacote do conector guardado no banco.
--
-- A publicação pela API do Supabase recebe o código num envio só, e o servidor
-- MCP completo (29 ferramentas) passou do tamanho que dá para mandar assim. Por
-- isso a função "mcp" publicada é um carregador pequeno
-- (scripts/pacote/carregador.js): na partida ele lê daqui o pacote montado com
-- deno bundle (gzip, base64, em partes), confere o SHA-256 fixado no próprio
-- carregador e só então roda o código. Quem consegue gravar nesta tabela já
-- tem a chave secreta; mesmo assim, um pacote com outro hash é recusado.
--
-- Quando a função puder ser publicada direto do repositório (CLI ou import do
-- GitHub), esta tabela deixa de ser usada e pode ser apagada.

create table public.pacote_conector (
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  parte int not null check (parte >= 0),
  texto text not null,
  criado_em timestamptz not null default now(),
  primary key (sha256, parte)
);
comment on table public.pacote_conector is
  'Pacote do servidor MCP (deno bundle, gzip em base64, em partes) que a função mcp carrega na partida e confere pelo SHA-256. Não apagar a versão em uso.';

alter table public.pacote_conector enable row level security;
revoke all on table public.pacote_conector from public, anon, authenticated;
