// Utilidades dos testes do servidor MCP (sem banco): handler com `rpc`
// falso que registra as chamadas, e um cliente MCP mínimo.

import { criarHandler, sha256Hex } from "../supabase/functions/mcp/servidor.ts";
import type { Arquivos } from "../supabase/functions/mcp/comum.ts";

export const TOKEN = "tokenDeTeste_0123456789abcdefghijklmnopqrstuv";
export const BASE = "https://exemplo.supabase.co/functions/v1/mcp";

export function igual(a: unknown, b: unknown, msg = "") {
  const ja = JSON.stringify(a), jb = JSON.stringify(b);
  if (ja !== jb) throw new Error(`${msg}\n  esperado: ${jb}\n  obtido:   ${ja}`);
}
export function verdade(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

export async function montar(
  respostas: Record<string, (args: Record<string, unknown>) => unknown> = {},
  arquivos?: Arquivos,
) {
  const chamadas: { funcao: string; args: Record<string, unknown> }[] = [];
  const hashValido = await sha256Hex(TOKEN);
  const handler = criarHandler({
    rpc: (funcao, args) => {
      chamadas.push({ funcao, args });
      const r = respostas[funcao];
      return Promise.resolve(r ? r(args) : { ok: true });
    },
    acessoValido: (hash) => Promise.resolve(hash === hashValido),
    arquivos,
  });
  let id = 0;
  async function mcp(method: string, params: Record<string, unknown> = {}, token = TOKEN) {
    const res = await handler(
      new Request(`${BASE}/${token}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "accept": "application/json, text/event-stream",
          "mcp-protocol-version": "2025-11-25",
        },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      }),
    );
    return { status: res.status, corpo: res.status === 200 ? await res.json() : await res.text() };
  }
  return { handler, chamadas, mcp };
}

export const INIT = {
  protocolVersion: "2025-11-25",
  capabilities: {},
  clientInfo: { name: "teste", version: "1" },
};
