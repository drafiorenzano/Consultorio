// deno-lint-ignore-file no-explicit-any
// Orçamento pelo site: regras do formulário (app/orcamento/dados.js) e do PDF
// (app/orcamento/pdf.js), sem banco nem navegador.

import {
  avisosParaTela,
  clinicaDe,
  contas,
  lerLocal,
  lerNumero,
  linhasDoForm,
  montarPedido,
  planoDaTela,
  planoDoOrcamento,
  porExtenso,
  rotuloLocal,
} from "../app/orcamento/dados.js";
import { calcular, nomeArquivo, normalizar } from "../app/orcamento/pdf.js";
import { igual, verdade } from "./util.ts";

const PACIENTE = "33333333-3333-4333-8333-333333333333";
const CAMPANHA = "77777777-7777-4777-8777-777777777777";

const BASE: any = {
  hoje: "2026-11-24",
  validade_dias: 30,
  cabecalho: {
    dentista: "Dra. Andressa Fiorenzano",
    especialidade: "Cirurgiã-dentista · Implantodontista",
    cro: "CRO-SP 175419",
    whatsapp: "21981772817",
    instagram: "@dra.andressafiorenzano",
    email: "dra.fiorenzano@gmail.com",
  },
  procedimentos: [
    { codigo: "consulta_avaliacao", nome: "Consulta de avaliação", grupo: "Diagnóstico", preco: 280, fase: 1 },
    { codigo: "resina_2_faces", nome: "Restauração em resina — 2 faces", grupo: "Restaurações", preco: 280, fase: 4 },
    { codigo: "implante_unitario", nome: "Implante unitário", grupo: "Implantes", preco: 1800, fase: 5 },
    { codigo: "canal_molar", nome: "Tratamento de canal — molar", grupo: "Endodontia", fase: 3 },
  ],
  campanhas: [{ id: CAMPANHA, nome: "Campanha RJ", periodo: "05 a 06/12/2026", precos: { implante_unitario: 1500 } }],
};

const linha = (x: Record<string, unknown>) => ({ qtd: "1", local: "", ...x });
const estado = (x: Record<string, unknown> = {}) => ({
  paciente_id: PACIENTE,
  itens: [],
  validade_dias: "30",
  campanha_id: "",
  desconto: "",
  desconto_tipo: "reais",
  parcelas: "0",
  observacoes: "",
  detalhar: false,
  apresentar: true,
  substituir: true,
  ...x,
});

Deno.test("orçamento site: dente, faces e região viram os campos do banco", () => {
  igual(lerLocal("36"), { dente: 36 });
  igual(lerLocal("36 mo"), { dente: 36, faces: "MO" });
  igual(lerLocal("Dente 46-MOD"), { dente: 46, faces: "MOD" });
  igual(lerLocal("55"), { dente: 55 });
  igual(lerLocal("Boca toda"), { regiao: "boca" });
  igual(lerLocal("arcada superior"), { regiao: "arcada_superior" });
  igual(lerLocal("quadrante 2"), { regiao: "Q2" });
  igual(lerLocal("s3"), { regiao: "S3" });
  // fora disso, fica o texto dela
  igual(lerLocal("11 e 21"), { regiao: "outra", observacao: "11 e 21" });
  igual(lerLocal("19"), { regiao: "outra", observacao: "19" });
  igual(lerLocal("36 superior"), { regiao: "outra", observacao: "36 superior" });
  igual(lerLocal("  "), {});
  igual(rotuloLocal({ dente: 36, faces: "MO" }), "Dente 36 (MO)");
  igual(rotuloLocal({ regiao: "boca" }), "Boca toda");
  igual(rotuloLocal({ regiao: "outra", observacao: "11 e 21" }), "11 e 21");
});

Deno.test("orçamento site: valores escritos do jeito brasileiro", () => {
  igual(lerNumero("1.234,56"), 1234.56);
  igual(lerNumero("280"), 280);
  igual(lerNumero("280,5"), 280.5);
  igual(lerNumero("R$ 1.800"), 1800);
  igual(lerNumero("0"), 0);
  igual(lerNumero(""), null);
  igual(lerNumero("abc"), null);
  igual(porExtenso("2026-12-05"), "05 de dezembro de 2026");
});

Deno.test("orçamento site: o pedido manda o código do catálogo e só o valor que ela mudou", () => {
  const r: any = montarPedido(
    estado({
      itens: [
        linha({
          codigo: "resina_2_faces",
          nome_base: "Restauração em resina — 2 faces",
          descricao: "Restauração em resina — 2 faces",
          local: "36 MO",
          valor: "280,00",
        }),
        linha({
          codigo: "implante_unitario",
          nome_base: "Implante unitário",
          descricao: "Implante unitário",
          local: "46",
          valor: "1.650,00",
        }),
        linha({ descricao: "Clareamento especial", local: "11 e 21", qtd: "2", valor: "100" }),
        linha({ descricao: "", valor: "" }),
      ],
      desconto: "10",
      desconto_tipo: "pct",
      parcelas: "10",
      observacoes: "  Inclui retornos.  ",
    }),
    BASE,
  );
  igual(r.erros, undefined);
  igual(r.dados.itens, [
    { procedimento_codigo: "resina_2_faces", dente: 36, faces: "MO", quantidade: 1 },
    // texto livre fica na fase 4 (restaurações), antes do implante (fase 5), como o banco ordena
    { procedimento: "Clareamento especial", valor: 100, regiao: "outra", observacao: "11 e 21", quantidade: 2 },
    { procedimento_codigo: "implante_unitario", valor: 1650, dente: 46, quantidade: 1 },
  ]);
  igual(r.dados.incluir_odontograma, false);
  igual(r.dados.campanha, "nenhuma");
  igual(r.dados.desconto_percentual, 10);
  igual(r.dados.pagamento, { desconto_a_vista_pct: 0, entrada_pct: 0, cartao_parcelas_max: 10, parcela_minima: 1 });
  igual(r.dados.observacoes, "Inclui retornos.");
  igual(r.dados.apresentar, true);
  igual("separado" in r.dados, false);
  verdade(r.dados.texto_original.startsWith("Pelo site: orçamento com 3 procedimentos"), r.dados.texto_original);
  igual(r.total, 1917); // (280 + 1650 + 2 x 100) - 10%
});

Deno.test("orçamento site: campanha escolhida vai pelo id e o preço dela não conta como mudado", () => {
  const r: any = montarPedido(
    estado({
      campanha_id: CAMPANHA,
      itens: [
        linha({
          codigo: "implante_unitario",
          nome_base: "Implante unitário",
          descricao: "Implante unitário",
          valor: "1.500,00",
        }),
      ],
    }),
    BASE,
  );
  igual(r.dados.campanha, CAMPANHA);
  igual(r.dados.itens, [{ procedimento_codigo: "implante_unitario", quantidade: 1 }]);
  igual(r.dados.pagamento.cartao_parcelas_max, 1);
});

Deno.test("orçamento site: paciente com orçamento em aberto escolhe versão nova ou à parte", () => {
  const base = { ...BASE, paciente: { id: PACIENTE, nome: "X", aberto: { numero: 3, versao: 1 } } };
  const itens = [
    linha({
      codigo: "consulta_avaliacao",
      nome_base: "Consulta de avaliação",
      descricao: "Consulta de avaliação",
      valor: "280,00",
    }),
  ];
  igual((montarPedido(estado({ itens }), base) as any).dados.separado, false);
  igual((montarPedido(estado({ itens, substituir: false }), base) as any).dados.separado, true);
});

Deno.test("orçamento site: o que falta aparece antes de mandar", () => {
  const r: any = montarPedido(
    estado({
      paciente_id: "",
      itens: [
        linha({
          codigo: "canal_molar",
          nome_base: "Tratamento de canal — molar",
          descricao: "Tratamento de canal — molar",
          valor: "",
        }),
        linha({ descricao: "Placa", valor: "100", qtd: "0" }),
      ],
      desconto: "5000",
      validade_dias: "365",
    }),
    BASE,
  );
  verdade(r.erros.includes("Escolha o paciente."), "pede o paciente");
  verdade(r.erros.some((e: string) => e.includes("Falta o valor") && e.includes("canal")), "pede o valor do canal");
  verdade(r.erros.some((e: string) => e.includes("quantidade")), "quantidade 0");
  verdade(r.erros.some((e: string) => e.includes("validade")), "validade");
  verdade(r.erros.some((e: string) => e.includes("desconto passa")), "desconto maior que o total");
  igual((montarPedido(estado({ itens: [] }), BASE) as any).erros, ["Adicione pelo menos um procedimento."]);
});

Deno.test("orçamento site: a prévia sai na mesma ordem e com as mesmas contas do banco", () => {
  const e = estado({
    itens: [
      linha({
        codigo: "implante_unitario",
        nome_base: "Implante unitário",
        descricao: "Implante unitário",
        local: "46",
        valor: "1800",
      }),
      linha({ descricao: "Clareamento especial", valor: "100" }),
      linha({
        codigo: "resina_2_faces",
        nome_base: "Restauração em resina — 2 faces",
        descricao: "Restauração em resina — 2 faces",
        local: "36 MO",
        valor: "280",
      }),
      linha({
        codigo: "consulta_avaliacao",
        nome_base: "Consulta de avaliação",
        descricao: "Consulta de avaliação",
        local: "boca toda",
        valor: "280",
      }),
    ],
    desconto: "12,5",
    desconto_tipo: "pct",
    parcelas: "6",
    campanha_id: CAMPANHA,
    observacoes: "Inclui retornos.",
  });
  // fase 1 (consulta), fase 4 com dente antes de sem dente, depois fase 5
  igual(linhasDoForm(e, BASE).map((x: any) => x.descricao), [
    "Consulta de avaliação",
    "Restauração em resina — 2 faces",
    "Clareamento especial",
    "Implante unitário",
  ]);
  igual(contas(e, linhasDoForm(e, BASE)), { subtotal: 2460, desconto: 307.5, total: 2152.5 });
  const plano: any = planoDaTela(e, BASE, "Maria");
  igual(plano.emissao, "24 de novembro de 2026");
  igual(plano.validade, "24 de dezembro de 2026");
  igual(plano.itens[0].regiao, "Boca toda");
  igual(plano.itens[1].regiao, "Dente 36 (MO)");
  igual(plano.descontoRotulo, "Desconto (12,5%)");
  igual(plano.observacoes, "Inclui retornos. Valores da Campanha RJ (05 a 06/12/2026).");
  igual(plano.clinica.whatsapp, "+55 21 98177-2817");
  igual(calcular(plano).total, 2152.5);
});

Deno.test("orçamento site: o PDF sai do que o banco gravou", () => {
  const orc = {
    id: "o1",
    numero: 4,
    versao: 1,
    emitido_em: "2026-11-24",
    validade: "2026-12-09",
    paciente: { nome: "Maria da Silva" },
    cabecalho: BASE.cabecalho,
    itens: [
      {
        descricao: "Consulta de avaliação",
        local: "Boca toda",
        regiao: "boca",
        quantidade: 1,
        valor_unitario: 280,
        conta: true,
      },
      {
        descricao: "Restauração em resina — 2 faces",
        local: "Dente 36 (MO)",
        quantidade: 1,
        valor_unitario: 280,
        conta: true,
      },
      {
        descricao: "Clareamento",
        regiao: "outra",
        observacao: "11 e 21",
        quantidade: 2,
        valor_unitario: 100,
        conta: true,
      },
      { descricao: "Recusado", quantidade: 1, valor_unitario: 999, conta: false },
    ],
    opcoes: [{ subtotal: 760, desconto: 76, total: 684, pagamento: { cartao: { parcelas: 10, valor_parcela: 68.4 } } }],
    desconto: { tipo: "percentual", valor: 10 },
    condicoes: { cartao_parcelas_max: 10 },
    observacoes: "",
  };
  const plano: any = planoDoOrcamento(orc, { detalhar: true });
  igual(plano.paciente, "Maria da Silva");
  igual(plano.emissao, "24 de novembro de 2026");
  igual(plano.validade, "09 de dezembro de 2026");
  igual(plano.itens.map((i: any) => i.regiao), ["Boca toda", "Dente 36 (MO)", "11 e 21"]);
  igual(plano.parcelas, 10);
  igual(plano.descontoRotulo, "Desconto (10%)");
  igual(calcular(plano), { subtotal: 760, desconto: 76, total: 684, temDesconto: true, parcelado: true });
  igual(planoDoOrcamento({ ...orc, condicoes: { cartao_parcelas_max: 1 } }).parcelas, 0);
  igual(clinicaDe(BASE.cabecalho).papel, "Cirurgiã-dentista · Implantodontista");
});

Deno.test("orçamento site: o PDF não engole o resto da linha com caractere que a fonte não tem", () => {
  igual(normalizar("R$ 4.500,00"), "R$ 4.500,00");
  igual(normalizar("“Dente” 36 – Ŵ ½ 🙂 ok"), '"Dente" 36 – W   ok');
  igual(normalizar("Açúcar, coração, pão, 2ª"), "Açúcar, coração, pão, 2ª");
  igual(nomeArquivo("Maria / Silva"), "Orçamento - Maria Silva.pdf");
});

Deno.test("orçamento site: avisos para o Claude ficam em palavras dela", () => {
  igual(
    avisosParaTela([
      '"Clareamento especial" não está no catálogo: entra no orçamento só como texto.',
      'Preços da Campanha RJ (05 a 06/12/2026) onde a campanha tem preço; o resto pelo preço normal. Para usar só os preços normais, chame de novo com campanha "nenhuma".',
      'Faltou o dente em "Implante unitário".',
    ]),
    [
      "Preços da Campanha RJ (05 a 06/12/2026) onde a campanha tem preço; o resto pelo preço normal.",
      'Faltou o dente em "Implante unitário".',
    ],
  );
});
