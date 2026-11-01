// deno-lint-ignore-file no-explicit-any
// Testes locais do servidor MCP, sem banco: o `rpc` é falso e só registra
// as chamadas. Rodar com:
//   deno test --config supabase/functions/mcp/deno.json tests/

import { criarHandler, ErroRpc, sha256Hex, tokenDaUrl } from "../supabase/functions/mcp/servidor.ts";

const TOKEN = "tokenDeTeste_0123456789abcdefghijklmnopqrstuv";
const BASE = "https://exemplo.supabase.co/functions/v1/mcp";

function igual(a: unknown, b: unknown, msg = "") {
  const ja = JSON.stringify(a), jb = JSON.stringify(b);
  if (ja !== jb) throw new Error(`${msg}\n  esperado: ${jb}\n  obtido:   ${ja}`);
}
function verdade(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

async function montar(respostas: Record<string, (args: Record<string, unknown>) => unknown> = {}) {
  const chamadas: { funcao: string; args: Record<string, unknown> }[] = [];
  const hashValido = await sha256Hex(TOKEN);
  const handler = criarHandler({
    rpc: (funcao, args) => {
      chamadas.push({ funcao, args });
      const r = respostas[funcao];
      return Promise.resolve(r ? r(args) : { ok: true });
    },
    acessoValido: (hash) => Promise.resolve(hash === hashValido),
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

const INIT = {
  protocolVersion: "2025-11-25",
  capabilities: {},
  clientInfo: { name: "teste", version: "1" },
};

Deno.test("token: extrai da URL e recusa formatos estranhos", () => {
  igual(tokenDaUrl(`${BASE}/${TOKEN}`), TOKEN);
  igual(tokenDaUrl(`https://x/mcp/${TOKEN}`), TOKEN);
  igual(tokenDaUrl(`${BASE}`), null);
  igual(tokenDaUrl(`${BASE}/curto`), null);
  igual(tokenDaUrl(`${BASE}/${TOKEN}%27or1=1`), null);
});

Deno.test("sem token válido: 404 e nenhuma chamada ao banco de dados clínico", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("initialize", INIT, "tokenErrado_0123456789abcdefghijklmnopqrstuvwx");
  igual(r.status, 404);
  igual(chamadas.length, 0);
});

Deno.test("GET devolve 405 (servidor stateless, só POST)", async () => {
  const { handler } = await montar();
  const res = await handler(new Request(`${BASE}/${TOKEN}`, { method: "GET" }));
  igual(res.status, 405);
});

Deno.test("initialize traz nome, versão e instruções em português", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", INIT);
  igual(r.status, 200);
  const res = (r.corpo as any).result;
  igual(res.serverInfo.name, "consultorio");
  verdade(res.instructions.includes("texto_original"), "instruções sem texto_original");
  verdade(res.capabilities.tools, "sem capacidade de ferramentas");
});

Deno.test("tools/list: 3 ferramentas, busca só leitura, gravações não destrutivas", async () => {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  const tools = (r.corpo as any).result.tools as any[];
  igual(tools.map((t) => t.name).sort(), ["buscar_paciente", "cadastrar_paciente", "registrar_atendimento"]);
  const porNome = Object.fromEntries(tools.map((t) => [t.name, t]));
  igual(porNome.buscar_paciente.annotations.readOnlyHint, true);
  igual(porNome.cadastrar_paciente.annotations.readOnlyHint, false);
  igual(porNome.registrar_atendimento.annotations.destructiveHint, false);
  igual(porNome.registrar_atendimento.inputSchema.required.sort(), ["evolucao", "paciente_id", "texto_original"]);
  igual(porNome.cadastrar_paciente.inputSchema.required.sort(), ["nome", "texto_original"]);
});

Deno.test("buscar_paciente repassa os argumentos para mcp_buscar_paciente", async () => {
  const { mcp, chamadas } = await montar({
    mcp_buscar_paciente: () => ({ encontrados: 1, paciente: { nome: "Mariana" } }),
  });
  const r = await mcp("tools/call", {
    name: "buscar_paciente",
    arguments: { busca: "Mari", texto_original: "abre a Mari" },
  });
  const res = (r.corpo as any).result;
  igual(res.isError, undefined);
  verdade(res.content[0].text.includes("Mariana"), "resposta sem o paciente");
  igual(chamadas.at(-1), {
    funcao: "mcp_buscar_paciente",
    args: { p_busca: "Mari", p_paciente_id: null, p_texto_original: "abre a Mari", p_incluir_arquivados: false },
  });
});

Deno.test("cadastrar_paciente separa dados, texto original e confirmação de homônimo", async () => {
  const { mcp, chamadas } = await montar({ mcp_cadastrar_paciente: () => ({ status: "ok" }) });
  await mcp("tools/call", {
    name: "cadastrar_paciente",
    arguments: {
      nome: "Ana Paula Souza",
      cpf: "116.000.345-94",
      alertas_saude: [{ tipo: "alergia", descricao: "alergia a dipirona" }],
      texto_original: "paciente nova Ana Paula Souza, alérgica a dipirona",
    },
  });
  const c = chamadas.at(-1)!;
  igual(c.funcao, "mcp_cadastrar_paciente");
  igual(c.args.p_texto_original, "paciente nova Ana Paula Souza, alérgica a dipirona");
  igual(c.args.p_confirmar_homonimo, false);
  igual((c.args.p_dados as any).nome, "Ana Paula Souza");
  igual("texto_original" in (c.args.p_dados as any), false, "texto_original vazou para p_dados");
});

Deno.test("argumento inválido (dente como texto) é recusado antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("tools/call", {
    name: "registrar_atendimento",
    arguments: {
      paciente_id: "x",
      evolucao: "Restauração",
      texto_original: "t",
      procedimentos: [{ procedimento: "resina", dente: "trinta e seis" }],
    },
  });
  const res = (r.corpo as any).result ?? (r.corpo as any).error;
  verdade(res.isError === true || (r.corpo as any).error, "deveria recusar dente não numérico");
  igual(chamadas.filter((c) => c.funcao === "mcp_registrar_atendimento").length, 0);
});

Deno.test("erro do banco vira isError, com 'Nada foi gravado' e registro da falha", async () => {
  const { mcp, chamadas } = await montar({
    mcp_registrar_atendimento: () => {
      throw new ErroRpc("Dente 19 não existe na numeração FDI.");
    },
  });
  const r = await mcp("tools/call", {
    name: "registrar_atendimento",
    arguments: {
      paciente_id: "abc",
      evolucao: "Restauração no 19",
      texto_original: "fiz resina no 19",
      procedimentos: [{ procedimento: "resina", dente: 19, faces: "O" }],
    },
  });
  const res = (r.corpo as any).result;
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("Nada foi gravado."), res.content[0].text);
  verdade(res.content[0].text.includes("Dente 19"), "mensagem do banco não repassada");
  const falha = chamadas.find((c) => c.funcao === "mcp_registrar_falha");
  verdade(falha, "falha não registrada");
  igual(falha!.args.p_texto_original, "fiz resina no 19");
});
