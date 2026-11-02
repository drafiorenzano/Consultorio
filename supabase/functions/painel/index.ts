// Edge Function "painel": API só de leitura do app do iPad.
// Publicar com verify_jwt = false (o acesso é o código no cabeçalho x-acesso,
// conferido em handler.ts contra acessos_mcp com escopo "painel").

import { criarHandlerPainel } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

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
  const json = corpo ? JSON.parse(corpo) : null;
  if (!resposta.ok) {
    console.error(`rpc ${funcao} falhou: ${resposta.status}`);
    throw new Error((json as { message?: string })?.message ?? `Erro ${resposta.status} no banco.`);
  }
  return json;
}

const caminhoSeguro = (caminho: string) => caminho.split("/").map(encodeURIComponent).join("/");

async function assinar(caminho: string, segundos: number): Promise<string> {
  const resposta = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/documentos/${caminhoSeguro(caminho)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosDaChave() },
    body: JSON.stringify({ expiresIn: segundos }),
  });
  const corpo = await resposta.json().catch(() => ({}));
  const assinado = (corpo as { signedURL?: string }).signedURL;
  if (!resposta.ok || !assinado) throw new Error(`Storage ${resposta.status}`);
  return `${SUPABASE_URL}/storage/v1${assinado}`;
}

Deno.serve(criarHandlerPainel({
  rpc,
  acessoValido: async (hash) => (await rpc("painel_validar_acesso", { p_token_sha256: hash })) === true,
  assinar,
}));
