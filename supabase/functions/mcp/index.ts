// Edge Function "mcp": publica o servidor MCP do consultório.
// URL do conector: https://<projeto>.supabase.co/functions/v1/mcp/<token>
// Publicar com verify_jwt = false (o Claude não envia JWT do Supabase; o
// acesso é conferido pelo token da URL em servidor.ts).

import { criarHandler, ErroRpc } from "./servidor.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

// Chave secreta (ignora RLS). Prefere as chaves novas (sb_secret_...),
// com a service_role antiga como reserva.
function cabecalhosDaChave(): Record<string, string> {
  const novas = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (novas) {
    try {
      const chave = JSON.parse(novas)?.default;
      if (chave) return { apikey: chave };
    } catch (_) {
      // cai para a chave antiga
    }
  }
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (antiga) return { apikey: antiga, Authorization: `Bearer ${antiga}` };
  throw new Error("Chave secreta do Supabase ausente no ambiente da função.");
}

async function rpc(funcao: string, argumentos: Record<string, unknown>): Promise<unknown> {
  const resposta = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${funcao}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosDaChave() },
    body: JSON.stringify(argumentos),
  });
  const corpo = await resposta.text();
  let json: unknown = null;
  try {
    json = corpo ? JSON.parse(corpo) : null;
  } catch (_) {
    json = corpo;
  }
  if (!resposta.ok) {
    const e = (json ?? {}) as { message?: string; hint?: string; code?: string };
    console.error(`rpc ${funcao} falhou: ${resposta.status} ${e.code ?? ""}`);
    throw new ErroRpc(e.message ?? `Erro ${resposta.status} no banco.`, e.hint ?? undefined, e.code);
  }
  return json;
}

Deno.serve(criarHandler({
  rpc,
  acessoValido: async (hash) => (await rpc("mcp_validar_acesso", { p_token_sha256: hash })) === true,
}));
