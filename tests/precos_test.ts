// deno-lint-ignore-file no-explicit-any
// Testes do módulo de preços (campanhas e calculadora) sem banco: esquemas,
// leitura x gravação e o que vai para cada função do Postgres.

import { igual, INIT, montar, verdade } from "./util.ts";

async function chamar(mcp: any, name: string, args: Record<string, unknown>) {
  const r = await mcp("tools/call", { name, arguments: args });
  return (r.corpo as any).result;
}

Deno.test("preços: três ferramentas, leitura x gravação certas", async () => {
  const { mcp } = await montar();
  const tools = ((await mcp("tools/list")).corpo as any).result.tools as any[];
  const porNome = Object.fromEntries(tools.map((t) => [t.name, t]));
  const esperado: Record<string, boolean> = { salvar_campanha: false, ver_campanhas: true, calcular_preco: true };
  for (const [nome, leitura] of Object.entries(esperado)) {
    verdade(porNome[nome], `falta ${nome}`);
    igual(porNome[nome].annotations.readOnlyHint, leitura, `${nome} readOnlyHint`);
    igual(porNome[nome].annotations.destructiveHint, false, `${nome} destrutiva`);
  }
  verdade(porNome.salvar_campanha.inputSchema.required.includes("texto_original"), "texto_original obrigatório");
  verdade(
    !(porNome.calcular_preco.inputSchema.required ?? []).includes("texto_original"),
    "calcular sem texto_original",
  );
  verdade(porNome.montar_orcamento.inputSchema.properties.campanha, "montar_orcamento sem campanha");
  verdade(porNome.configurar_financeiro.inputSchema.properties.imposto_percentual, "configurar sem imposto");
});

Deno.test("preços: instruções falam de campanha e precificação", async () => {
  const { mcp } = await montar();
  const inst = ((await mcp("initialize", INIT)).corpo as any).result.instructions as string;
  verdade(inst.includes("Campanha RJ"), "sem a linha das campanhas");
  verdade(
    inst.includes('campanha \\"nenhuma\\"') || inst.includes('campanha "nenhuma"'),
    "sem o jeito de usar o preço normal",
  );
  verdade(inst.includes("calcular_preco"), "sem a linha da precificação");
});

Deno.test("salvar_campanha: preços e texto_original vão para mcp_salvar_campanha", async () => {
  const { mcp, chamadas } = await montar({ mcp_salvar_campanha: () => ({ status: "criada" }) });
  const res = await chamar(mcp, "salvar_campanha", {
    nome: "Campanha RJ",
    inicio: "2026-11-21",
    fim: "2026-11-22",
    local: "Clínica Parceira, Copacabana",
    precos: [{ procedimento_codigo: "consulta_avaliacao", preco: 150 }, { procedimento: "panorâmica", preco: null }],
    texto_original: "campanha no rio dia 21 e 22, avaliação 150",
  });
  igual(res.isError, undefined);
  igual(chamadas.at(-1)?.funcao, "mcp_salvar_campanha");
  const args = chamadas.at(-1)!.args as any;
  igual(args.p_texto_original, "campanha no rio dia 21 e 22, avaliação 150");
  igual(args.p_dados.precos[1].preco, null);
  igual(args.p_dados.texto_original, undefined);
});

Deno.test("salvar_campanha: data em formato errado é recusada antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const res = await chamar(mcp, "salvar_campanha", { nome: "Campanha RJ", inicio: "21/11", texto_original: "x" });
  igual(res.isError, true);
  igual(chamadas.filter((c) => c.funcao === "mcp_salvar_campanha").length, 0);
});

Deno.test("calcular_preco: custos e margem vão em p_dados, sem texto_original obrigatório", async () => {
  const { mcp, chamadas } = await montar({ mcp_calcular_preco: () => ({ preco: 1800, formas: [] }) });
  const res = await chamar(mcp, "calcular_preco", {
    procedimento_codigo: "implante_unitario",
    preco: 1800,
    custos: [{ descricao: "Implante e componentes", valor: 450 }],
    margem_desejada: 40,
  });
  igual(res.isError, undefined);
  const args = chamadas.at(-1)!.args as any;
  igual(chamadas.at(-1)?.funcao, "mcp_calcular_preco");
  igual(args.p_dados.custos[0].valor, 450);
  igual(args.p_texto_original, null);
});

Deno.test("calcular_preco: mais de 12 parcelas é recusado", async () => {
  const { mcp, chamadas } = await montar();
  const res = await chamar(mcp, "calcular_preco", { preco: 500, parcelas_max: 18 });
  igual(res.isError, true);
  igual(chamadas.filter((c) => c.funcao === "mcp_calcular_preco").length, 0);
});
