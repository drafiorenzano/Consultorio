// deno-lint-ignore-file no-explicit-any
// Testes das ferramentas da ficha online e do calendário (sem banco).

import { igual, INIT, montar, verdade } from "./util.ts";

async function chamar(mcp: any, name: string, args: Record<string, unknown>) {
  const r = await mcp("tools/call", { name, arguments: args });
  return (r.corpo as any).result;
}

Deno.test("ficha online e calendário: ferramentas, leitura x gravação", async () => {
  const { mcp } = await montar();
  const tools = ((await mcp("tools/list")).corpo as any).result.tools as any[];
  igual(tools.length, 36, "total de ferramentas");
  const porNome = Object.fromEntries(tools.map((t) => [t.name, t]));
  const esperado: Record<string, boolean> = {
    ficha_online: false,
    ver_ficha_online: true,
    confirmar_ficha_online: false,
    acesso_calendario: false,
  };
  for (const [nome, leitura] of Object.entries(esperado)) {
    verdade(porNome[nome], `falta ${nome}`);
    igual(porNome[nome].annotations.readOnlyHint, leitura, `${nome} readOnlyHint`);
    igual(porNome[nome].annotations.destructiveHint, false, `${nome} destrutiva`);
  }
  verdade(
    porNome.confirmar_ficha_online.inputSchema.required.includes("texto_original"),
    "confirmar sem texto_original",
  );
  verdade(
    !(porNome.ver_ficha_online.inputSchema.required ?? []).includes("texto_original"),
    "ver exige texto_original",
  );
  igual(porNome.confirmar_ficha_online.inputSchema.properties.ignorar.items.enum.includes("anamnese"), true);
});

Deno.test("ficha online: cada ferramenta chama a sua função com p_dados", async () => {
  const { mcp, chamadas } = await montar();
  await chamar(mcp, "ficha_online", { acao: "enviar", paciente_id: "p1", texto_original: "manda a ficha pra Maria" });
  await chamar(mcp, "ver_ficha_online", { paciente_id: "p1" });
  await chamar(mcp, "confirmar_ficha_online", { paciente_id: "p1", ignorar: ["cpf"], texto_original: "pode gravar" });
  await chamar(mcp, "acesso_calendario", { acao: "gerar", texto_original: "quero a agenda no calendário" });
  const f = chamadas.filter((c) => c.funcao.startsWith("mcp_"));
  igual(f.map((c) => c.funcao), [
    "mcp_ficha_online",
    "mcp_ver_ficha_online",
    "mcp_confirmar_ficha_online",
    "mcp_acesso_calendario",
  ]);
  igual(f[0].args, { p_dados: { acao: "enviar", paciente_id: "p1" }, p_texto_original: "manda a ficha pra Maria" });
  igual(f[1].args.p_texto_original, null);
  igual((f[2].args.p_dados as any).ignorar, ["cpf"]);
});

Deno.test("ficha online: ignorar só aceita campos conhecidos", async () => {
  const { mcp, chamadas } = await montar();
  const r = await chamar(mcp, "confirmar_ficha_online", { ignorar: ["senha"], texto_original: "x" });
  verdade(r.isError, "deveria recusar");
  igual(chamadas.filter((c) => c.funcao === "mcp_confirmar_ficha_online").length, 0);
});

Deno.test("ficha online e calendário: instruções", async () => {
  const { mcp } = await montar();
  const inst = ((await mcp("initialize", INIT)).corpo as any).result.instructions as string;
  verdade(inst.includes("ficha_online (enviar)"), "sem a linha da ficha online");
  verdade(inst.includes("confirmar_ficha_online depois que ela concordar"), "sem a regra de confirmar");
  verdade(inst.includes("acesso_calendario"), "sem a linha do calendário");
});
