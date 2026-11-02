// deno-lint-ignore-file no-explicit-any
// Testes da API pública da ficha online (sem banco).

import { criarHandlerFicha, ErroBanco, LIMITE_BYTES, sha256Hex } from "../supabase/functions/ficha/handler.ts";
import { igual, verdade } from "./util.ts";

const CODIGO = "GvQyAvYnuZN-G4stbihbwg6q1i42Upp6rioQBcTIeZU";

async function montar(respostas: Record<string, (args: any) => unknown> = {}) {
  const valido = await sha256Hex(CODIGO);
  const chamadas: { funcao: string; args: any }[] = [];
  const handler = criarHandlerFicha({
    rpc: (funcao, args) => {
      chamadas.push({ funcao, args });
      try {
        if (respostas[funcao]) return Promise.resolve(respostas[funcao](args));
      } catch (e) {
        return Promise.reject(e);
      }
      if (funcao === "ficha_online_exemplo") return Promise.resolve({ status: "ok", exemplo: true });
      return Promise.resolve(args.p_token_sha256 === valido ? { status: "ok" } : null);
    },
  });
  const pedir = async (corpo: unknown, method = "POST") => {
    const res = await handler(
      new Request("https://x/functions/v1/ficha", {
        method,
        headers: { "content-type": "application/json" },
        body: method === "POST" ? (typeof corpo === "string" ? corpo : JSON.stringify(corpo)) : undefined,
      }),
    );
    return {
      status: res.status,
      corpo: res.status === 204 ? null : await res.json(),
      cors: res.headers.get("access-control-allow-origin"),
      cache: res.headers.get("cache-control"),
    };
  };
  return { chamadas, pedir };
}

Deno.test("ficha: exemplo não precisa de código e não grava", async () => {
  const { pedir, chamadas } = await montar();
  const r = await pedir({ acao: "exemplo" });
  igual(r.status, 200);
  igual(r.corpo.dados.exemplo, true);
  igual(chamadas.map((c) => c.funcao), ["ficha_online_exemplo"]);
  igual(r.cors, "*");
  igual(r.cache, "no-store");
});

Deno.test("ficha: abrir manda só o SHA-256 do código", async () => {
  const { pedir, chamadas } = await montar();
  const r = await pedir({ acao: "abrir", codigo: CODIGO });
  igual(r.status, 200);
  igual(chamadas[0].funcao, "ficha_online_abrir");
  igual(chamadas[0].args, { p_token_sha256: await sha256Hex(CODIGO) });
  verdade(!JSON.stringify(chamadas).includes(CODIGO), "o código não vai ao banco");
});

Deno.test("ficha: código errado ou malformado dá 404", async () => {
  const { pedir, chamadas } = await montar();
  igual((await pedir({ acao: "abrir", codigo: "x".repeat(43) })).status, 404);
  igual((await pedir({ acao: "abrir", codigo: "curto" })).status, 404);
  igual((await pedir({ acao: "abrir", codigo: "<script>alert(1)</script>" + "a".repeat(40) })).status, 404);
  igual(chamadas.length, 1, "só o código bem formado chega ao banco");
});

Deno.test("ficha: enviar repassa as respostas", async () => {
  const { pedir, chamadas } = await montar();
  const respostas = { termo_versao: "2026-11-02", cadastro: { nome: "Maria Teste" } };
  const r = await pedir({ acao: "enviar", codigo: CODIGO, respostas });
  igual(r.status, 200);
  igual(chamadas[0].funcao, "ficha_online_enviar");
  igual(chamadas[0].args.p_respostas, respostas);
  igual((await pedir({ acao: "enviar", codigo: CODIGO })).status, 400);
  igual((await pedir({ acao: "enviar", codigo: CODIGO, respostas: [1, 2] })).status, 400);
});

Deno.test("ficha: erro de validação vai para o paciente; erro interno não", async () => {
  const { pedir } = await montar({
    ficha_online_enviar: (a) => {
      if (a.p_respostas.cpf === "ruim") throw new ErroBanco("Confira o CPF do paciente.", "P0001");
      throw new ErroBanco('relation "x" does not exist', "42P01");
    },
  });
  const ruim = await pedir({ acao: "enviar", codigo: CODIGO, respostas: { cpf: "ruim" } });
  igual(ruim.status, 400);
  igual(ruim.corpo.erro, "Confira o CPF do paciente.");
  const interno = await pedir({ acao: "enviar", codigo: CODIGO, respostas: { cpf: "ok" } });
  igual(interno.status, 503);
  verdade(!interno.corpo.erro.includes("relation"), "não mostra o erro interno");
});

Deno.test("ficha: método, JSON, ação e tamanho", async () => {
  const { pedir } = await montar();
  igual((await pedir(null, "GET")).status, 405);
  igual((await pedir(null, "OPTIONS")).status, 204);
  igual((await pedir("{nada")).status, 400);
  igual((await pedir({ acao: "apagar", codigo: CODIGO })).status, 400);
  const grande = { acao: "enviar", codigo: CODIGO, respostas: { texto: "a".repeat(LIMITE_BYTES) } };
  igual((await pedir(grande)).status, 413);
});
