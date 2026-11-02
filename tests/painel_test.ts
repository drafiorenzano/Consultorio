// deno-lint-ignore-file no-explicit-any
// Testes da API do painel do iPad (sem banco).

import { criarHandlerPainel, sha256Hex } from "../supabase/functions/painel/handler.ts";
import { igual, verdade } from "./util.ts";

const CODIGO = "codigoDoIpad_0123456789abcdefghijklmnopqr";

async function montarPainel(resposta: unknown = { ok: true }) {
  const valido = await sha256Hex(CODIGO);
  const chamadas: any[] = [];
  const handler = criarHandlerPainel({
    rpc: (funcao, args) => {
      chamadas.push({ funcao, args });
      return Promise.resolve(typeof resposta === "function" ? (resposta as any)(args) : resposta);
    },
    acessoValido: (h) => Promise.resolve(h === valido),
    assinar: (caminho) => Promise.resolve(`https://assinado/${caminho}`),
  });
  const pedir = async (corpo: unknown, codigo = CODIGO, method = "POST") => {
    const res = await handler(
      new Request("https://x/functions/v1/painel", {
        method,
        headers: { "content-type": "application/json", "x-acesso": codigo },
        body: method === "POST" ? JSON.stringify(corpo) : undefined,
      }),
    );
    return {
      status: res.status,
      corpo: await res.json().catch(() => null),
      cors: res.headers.get("access-control-allow-origin"),
    };
  };
  return { handler, chamadas, pedir };
}

Deno.test("painel: código errado dá 401 e não lê nada", async () => {
  const { pedir, chamadas } = await montarPainel();
  const r = await pedir({ acao: "inicio" }, "codigoErrado_0123456789abcdefghijklmnopqr");
  igual(r.status, 401);
  igual(chamadas.length, 0);
  igual((await pedir({ acao: "inicio" }, "curto")).status, 401);
});

Deno.test("painel: preflight CORS e só POST", async () => {
  const { handler, pedir } = await montarPainel();
  const res = await handler(new Request("https://x/painel", { method: "OPTIONS" }));
  igual(res.status, 204);
  verdade(res.headers.get("access-control-allow-headers")?.includes("x-acesso"), "CORS sem x-acesso");
  igual((await pedir(null, CODIGO, "GET")).status, 405);
});

Deno.test("painel: ação fora da lista é recusada antes do banco", async () => {
  const { pedir, chamadas } = await montarPainel();
  const r = await pedir({ acao: "mcp_cadastrar_paciente" });
  igual(r.status, 400);
  igual(chamadas.length, 0);
});

Deno.test("painel: repassa ação e parâmetros e assina os arquivos", async () => {
  const { pedir, chamadas } = await montarPainel({ documentos: [{ titulo: "Receita", arquivo: "p1/receita.pdf" }] });
  const r = await pedir({ acao: "paciente", parametros: { id: "p1" } });
  igual(r.status, 200);
  igual(r.cors, "*");
  igual(chamadas[0], { funcao: "painel", args: { p_acao: "paciente", p_params: { id: "p1" } } });
  igual(r.corpo.dados.documentos[0].link, "https://assinado/p1/receita.pdf");
});

Deno.test("painel: ação sem leitura no banco dá 404", async () => {
  const { pedir } = await montarPainel(null);
  igual((await pedir({ acao: "estoque" })).status, 404);
});
