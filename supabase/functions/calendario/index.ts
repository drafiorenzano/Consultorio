// Edge Function "calendario": a agenda como calendário assinado (iCal), só
// leitura. Publicar com verify_jwt = false (o acesso é o código no caminho,
// conferido em public.calendario_feed contra acessos_mcp com escopo
// "calendario"). O link é gerado pelo conector (ferramenta acesso_calendario).

import { criarHandlerCalendario, type FeedCalendario } from "./handler.ts";

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

async function feed(hash: string): Promise<FeedCalendario | null> {
  const resposta = await fetch(`${SUPABASE_URL}/rest/v1/rpc/calendario_feed`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosDaChave() },
    body: JSON.stringify({ p_token_sha256: hash }),
  });
  if (!resposta.ok) throw new Error(`rpc calendario_feed falhou: ${resposta.status}`);
  return (await resposta.json()) as FeedCalendario | null;
}

Deno.serve(criarHandlerCalendario({ feed }));
