// deno-lint-ignore-file no-explicit-any
// Testes do módulo de estoque, sem banco: conferem esquemas, anotações e o
// que chega ao `rpc` (a regra de estoque é testada no banco, ver docs/estoque.md).

import { ErroRpc } from "../supabase/functions/mcp/servidor.ts";
import { igual, INIT, montar, verdade } from "./util.ts";

const FERRAMENTAS = ["movimentar_estoque", "registrar_compra", "salvar_material", "ver_estoque"];

async function listar() {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  const tools = (r.corpo as any).result.tools as any[];
  return Object.fromEntries(tools.map((t) => [t.name, t]));
}

async function chamar(
  nome: string,
  args: Record<string, unknown>,
  respostas: Record<string, (a: Record<string, unknown>) => unknown> = {},
) {
  const m = await montar(respostas);
  const r = await m.mcp("tools/call", { name: nome, arguments: args });
  return { ...m, resultado: (r.corpo as any).result, corpo: r.corpo as any };
}

Deno.test("estoque: quatro ferramentas, leitura x gravação, nenhuma destrutiva", async () => {
  const porNome = await listar();
  for (const n of FERRAMENTAS) verdade(porNome[n], `falta ${n}`);
  igual(porNome.ver_estoque.annotations.readOnlyHint, true);
  for (const n of ["registrar_compra", "movimentar_estoque", "salvar_material"]) {
    igual(porNome[n].annotations.readOnlyHint, false, `${n} deveria gravar`);
  }
  for (const n of FERRAMENTAS) {
    igual(porNome[n].annotations.destructiveHint, false, `${n} destrutiva`);
    verdade(porNome[n].description.length > 100, `${n} sem descrição útil`);
  }
  igual(porNome.registrar_compra.inputSchema.required.sort(), ["itens", "texto_original"]);
  igual(porNome.movimentar_estoque.inputSchema.required.sort(), ["movimentos", "texto_original"]);
  igual(porNome.salvar_material.inputSchema.required, ["texto_original"]);
  igual(porNome.ver_estoque.inputSchema.required ?? [], []);
});

Deno.test("estoque: descrições trazem exemplos de ditado e enums do banco", async () => {
  const porNome = await listar();
  verdade(porNome.registrar_compra.description.includes("Dental Cremer"), "compra sem exemplo de ditado");
  verdade(porNome.movimentar_estoque.description.includes("contagem"), "movimento sem contagem");
  const tipos = porNome.movimentar_estoque.inputSchema.properties.movimentos.items.properties.tipo.enum;
  igual(tipos, ["uso", "perda", "vencido", "contagem", "entrada", "desfazer", "cancelar_compra"]);
  const visoes = porNome.ver_estoque.inputSchema.properties.visao.enum;
  igual(visoes.length, 8);
  verdade(visoes.includes("lista_compras") && visoes.includes("custos"), "faltam visões");
  const formas = porNome.registrar_compra.inputSchema.properties.forma_pagamento.enum;
  verdade(formas.includes("pix") && formas.includes("credito_parcelado"), "faltam formas de pagamento");
});

Deno.test("estoque: instruções do servidor falam da baixa automática", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", INIT);
  const txt = (r.corpo as any).result.instructions as string;
  verdade(txt.includes("- Estoque: o gasto de cada atendimento sai sozinho"), "instrução da baixa automática");
  verdade(txt.includes("salvar_material"), "instrução do cadastro de material");
});

Deno.test("registrar_compra: manda os itens em p_dados e o ditado em p_texto_original", async () => {
  const ditado = "comprei duas caixas de articaína a 180 cada na Dental Cremer, paguei no pix";
  const { chamadas, resultado } = await chamar("registrar_compra", {
    fornecedor: "Dental Cremer",
    itens: [{ material: "articaína", quantidade: 2, unidade: "caixa", preco_unitario: 180 }],
    forma_pagamento: "pix",
    texto_original: ditado,
  }, { mcp_registrar_compra: () => ({ status: "registrada", avisos: [] }) });
  igual(chamadas.length, 1);
  igual(chamadas[0].funcao, "mcp_registrar_compra");
  igual(chamadas[0].args, {
    p_dados: {
      fornecedor: "Dental Cremer",
      itens: [{ material: "articaína", quantidade: 2, unidade: "caixa", preco_unitario: 180 }],
      forma_pagamento: "pix",
    },
    p_texto_original: ditado,
  });
  verdade(!resultado.isError, "não deveria ser erro");
  verdade(resultado.content[0].text.includes("registrada"), "resposta do banco não voltou");
});

Deno.test("registrar_compra: recusa sem itens, quantidade zero ou validade sem formato, sem chamar o banco", async () => {
  const base = { fornecedor: "Dental Speed", texto_original: "comprei luva" };
  const casos = [
    { ...base, itens: [] },
    { ...base, itens: [{ material: "luva M", quantidade: 0 }] },
    { ...base, itens: [{ material: "luva M", quantidade: 1, validade: "março de 2027" }] },
    { ...base, itens: [{ material: "luva M", quantidade: 1 }], forma_pagamento: "cheque" },
    { itens: [{ material: "luva M", quantidade: 1 }] },
  ];
  for (const args of casos) {
    const { chamadas, resultado, corpo } = await chamar("registrar_compra", args);
    verdade(resultado?.isError || corpo.error, `deveria recusar ${JSON.stringify(args)}`);
    igual(chamadas.length, 0, `não deveria chamar o banco: ${JSON.stringify(args)}`);
  }
});

Deno.test("registrar_compra: validade aceita mês/ano nos três formatos", async () => {
  for (const validade of ["2027-03-31", "2027-03", "03/2027"]) {
    const { chamadas } = await chamar("registrar_compra", {
      itens: [{ material: "resina A2", quantidade: 1, validade }],
      texto_original: "comprei uma resina A2",
    });
    igual(chamadas.length, 1, `validade ${validade} recusada`);
    igual((chamadas[0].args.p_dados as any).itens[0].validade, validade);
  }
});

Deno.test("movimentar_estoque: contagem, perda e desfazer chegam juntos em p_dados", async () => {
  const movimentos = [
    { tipo: "contagem", material: "luva M", quantidade: 3, unidade: "caixa" },
    { tipo: "perda", material: "lidocaína", quantidade: 2, motivo: "caiu no chão" },
    { tipo: "desfazer", motivo: "lancei duas vezes", movimento_id: "00000000-0000-0000-0000-000000000001" },
  ];
  const { chamadas } = await chamar("movimentar_estoque", {
    data: "2026-11-01",
    movimentos,
    texto_original: "contei 3 caixas de luva M, perdi dois tubetes de lidocaína",
  });
  igual(chamadas[0].funcao, "mcp_movimentar_estoque");
  igual(chamadas[0].args.p_dados, { data: "2026-11-01", movimentos });
  igual(chamadas[0].args.p_texto_original, "contei 3 caixas de luva M, perdi dois tubetes de lidocaína");
});

Deno.test("movimentar_estoque: recusa tipo desconhecido, quantidade negativa e data sem formato", async () => {
  const casos = [
    { movimentos: [{ tipo: "apagar", material: "gaze", quantidade: 1 }], texto_original: "x" },
    { movimentos: [{ tipo: "perda", material: "gaze", quantidade: -1 }], texto_original: "x" },
    { data: "01/11/2026", movimentos: [{ tipo: "uso", material: "gaze", quantidade: 1 }], texto_original: "x" },
    { movimentos: [], texto_original: "x" },
  ];
  for (const args of casos) {
    const { chamadas, resultado, corpo } = await chamar("movimentar_estoque", args);
    verdade(resultado?.isError || corpo.error, `deveria recusar ${JSON.stringify(args)}`);
    igual(chamadas.length, 0);
  }
});

Deno.test("ver_estoque: sem argumentos vai como resumo de leitura, com p_texto_original null", async () => {
  const { chamadas } = await chamar("ver_estoque", {});
  igual(chamadas[0].funcao, "mcp_ver_estoque");
  igual(chamadas[0].args, { p_dados: {}, p_texto_original: null });
  const outra = await chamar("ver_estoque", { visao: "custos", procedimento_codigo: "canal_molar" });
  igual(outra.chamadas[0].args.p_dados, { visao: "custos", procedimento_codigo: "canal_molar" });
  const ruim = await chamar("ver_estoque", { visao: "tudo" });
  igual(ruim.chamadas.length, 0);
  const semanas = await chamar("ver_estoque", { visao: "consumo", semanas: 52 });
  igual(semanas.chamadas.length, 0);
});

Deno.test("salvar_material: material e kit no mesmo p_dados", async () => {
  const kit = {
    procedimento_codigo: "exodontia_permanente",
    itens: [{ material: "gaze", quantidade: 4 }],
    remover: ["fio de seda"],
  };
  const { chamadas } = await chamar("salvar_material", {
    nome: "articaína",
    estoque_minimo: 2,
    estoque_minimo_unidade: "caixa",
    kit,
    texto_original: "o mínimo de articaína é 2 caixas e no kit da extração vão 4 gazes",
  });
  igual(chamadas[0].funcao, "mcp_salvar_material");
  igual(chamadas[0].args.p_dados, { nome: "articaína", estoque_minimo: 2, estoque_minimo_unidade: "caixa", kit });
  const ruim = await chamar("salvar_material", { nome: "x", categoria: "comida", texto_original: "x" });
  igual(ruim.chamadas.length, 0, "categoria fora da lista não deveria chegar ao banco");
  const fator = await chamar("salvar_material", { nome: "x", fator: 0, texto_original: "x" });
  igual(fator.chamadas.length, 0, "fator zero não deveria chegar ao banco");
});

Deno.test("estoque: erro do banco volta como 'Nada foi gravado' ou 'A consulta não foi feita', com a dica", async () => {
  const falhar = () => {
    throw new ErroRpc('Material "xyz" não encontrado no estoque.', "Cadastre antes com salvar_material.");
  };
  const compra = await chamar("registrar_compra", {
    itens: [{ material: "xyz", quantidade: 1 }],
    texto_original: "comprei xyz",
  }, { mcp_registrar_compra: falhar });
  igual(compra.resultado.isError, true);
  const t = compra.resultado.content[0].text as string;
  verdade(t.startsWith("Nada foi gravado.") && t.includes("xyz") && t.includes("salvar_material"), t);
  igual(compra.chamadas.map((c) => c.funcao), ["mcp_registrar_compra", "mcp_registrar_falha"]);
  igual((compra.chamadas[1].args as any).p_ferramenta, "registrar_compra");

  const ver = await chamar("ver_estoque", { visao: "material", busca: "xyz" }, { mcp_ver_estoque: falhar });
  igual(ver.resultado.isError, true);
  verdade(
    (ver.resultado.content[0].text as string).startsWith("A consulta não foi feita."),
    "leitura com texto errado",
  );
});
