// Edge Function "ficha": API pública da ficha online. Publicar com
// verify_jwt = false (o acesso é o código pessoal do link, conferido pelo
// SHA-256 no Postgres). A página que o paciente abre está em app/ficha/.

import { criarHandlerFicha, ErroBanco } from "./handler.ts";

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
    const erro = json as { message?: string; code?: string } | null;
    throw new ErroBanco(erro?.message ?? `Erro ${resposta.status} no banco.`, erro?.code);
  }
  return json;
}

Deno.serve(criarHandlerFicha({ rpc }));
