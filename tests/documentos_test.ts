// deno-lint-ignore-file no-explicit-any
// Testes do módulo de documentos (orçamento, receita, atestado, termo), sem
// banco: o `rpc` é falso e o Storage é um objeto em memória.

import type { Arquivos } from "../supabase/functions/mcp/comum.ts";
import {
  cpfBR,
  dataBR,
  gerarPdf,
  limparTexto,
  type Orcamento,
  reais,
  telefoneBR,
} from "../supabase/functions/mcp/documentos/pdf.ts";
import { PDFDocument } from "pdf-lib";
import { igual, montar, verdade } from "./util.ts";

const PAC = "5ff40870-71c8-469a-a974-008d47f63555";

const CAB = {
  nome: "Dra. Andressa Fiorenzano",
  dentista: "Dra. Andressa Fiorenzano",
  especialidade: "Cirurgiã-dentista · Implantodontista",
  cro: "CRO-SP 175419",
  endereco: "Av. República do Líbano, 1673 – Moema",
  cidade: "São Paulo",
  uf: "SP",
  whatsapp: "21981772817",
  instagram: "@dra.andressafiorenzano",
  site: "https://andressafiorenzano.com.br",
};
const PACIENTE = { id: PAC, nome: "Mariana Costa Ribeiro", ficha: 1, cpf: "11600034594" };

const pagamento = (total: number) => ({
  a_vista: { valor: total * 0.95, desconto_pct: 5, economia: total * 0.05 },
  cartao: { parcelas: 6, valor_parcela: total / 6 },
  entrada_mais_parcelas: { entrada: total * 0.3, entrada_pct: 30, parcelas: 3, valor_parcela: total * 0.7 / 3 },
  destacar_parcela: total > 1000,
});

const ORCAMENTO: Orcamento = {
  numero: 7,
  versao: 2,
  status: "apresentado",
  emitido_em: "2026-11-02",
  validade: "2026-12-02",
  paciente: PACIENTE,
  cabecalho: CAB,
  profissional: "Dra. Andressa Fiorenzano",
  cro: "CRO-SP 175419",
  itens: [
    {
      ordem: 1,
      descricao: "Extração de siso",
      explicacao: "Remoção do dente do siso.",
      local: "Dente 18",
      quantidade: 1,
      valor_unitario: 350,
      valor_total: 350,
      fase: 1,
      status: "incluido",
      conta: true,
    },
    {
      ordem: 2,
      descricao: "Raspagem (por sextante)",
      local: "Sextante 1",
      quantidade: 2,
      valor_unitario: 220,
      valor_total: 440,
      fase: 2,
      status: "incluido",
      conta: true,
    },
    {
      ordem: 3,
      descricao: "Tratamento de canal — molar",
      local: "Dente 46",
      quantidade: 1,
      valor_unitario: 1100,
      valor_total: 1100,
      fase: 3,
      alternativa: "A",
      status: "incluido",
      conta: true,
    },
    {
      ordem: 4,
      descricao: "Coroa cerâmica",
      local: "Dente 46",
      quantidade: 1,
      valor_unitario: 1800,
      valor_total: 1800,
      fase: 5,
      alternativa: "A",
      status: "incluido",
      conta: true,
    },
    {
      ordem: 5,
      descricao: "Implante → coroa ≥ 2 etapas 😀",
      local: "Dente 46",
      quantidade: 1,
      valor_unitario: 3300,
      valor_total: 3300,
      fase: 5,
      alternativa: "B",
      status: "incluido",
      conta: true,
    },
  ],
  fases: [{ fase: 1, nome: "Urgência e preparo da boca", subtotal: 350 }, {
    fase: 2,
    nome: "Tratamento da gengiva",
    subtotal: 440,
  }],
  opcoes: [
    { alternativa: "A", subtotal: 3690, total: 3690, pagamento: pagamento(3690) },
    { alternativa: "B", subtotal: 4090, desconto: 409, total: 3681, pagamento: pagamento(3681) },
  ],
  desconto: { tipo: "percentual", valor: 10 },
  observacoes: "Paciente usa rivaroxabana.",
};

const RECEITA = {
  numero: 3,
  data: "2026-11-02",
  data_extenso: "2 de novembro de 2026",
  paciente: { ...PACIENTE, endereco: "Rua das Flores, 100, Moema, São Paulo-SP" },
  cabecalho: CAB,
  duas_vias: true,
  itens: [
    {
      nome: "Amoxicilina",
      concentracao: "500 mg",
      forma: "cápsula",
      via_texto: "Uso oral",
      quantidade: "21 cápsulas",
      posologia: "Tomar 1 cápsula a cada 8 horas, por 7 dias.",
      antibiotico: true,
    },
    {
      nome: "Digluconato de clorexidina",
      concentracao: "0,12%",
      via_texto: "Uso bucal (bochecho)",
      quantidade: "1 frasco",
      posologia: "Bochechar 15 ml.",
    },
  ],
};

const ATESTADO = {
  numero: 1,
  tipo: "repouso",
  titulo: "Atestado odontológico",
  data: "2026-11-02",
  texto: "Atesto, para os devidos fins, que Mariana Costa Ribeiro esteve em atendimento odontológico...",
  paciente: PACIENTE,
  cabecalho: CAB,
};

const TERMO = {
  numero: 2,
  tipo: "consentimento" as const,
  titulo: "Termo de consentimento para extração dentária",
  procedimento: "Extração (exodontia) do dente 38",
  secoes: Array.from({ length: 8 }, (_, i) => ({ titulo: `Seção ${i + 1}`, texto: "Texto da seção. ".repeat(30) })),
  declaracao: "Declaro que li este termo.",
  responsavel: { nome: "Fernanda Martins Prado", parentesco: "mãe" },
  data: "2026-11-02",
  paciente: PACIENTE,
  cabecalho: CAB,
};

/** Storage falso em memória. */
function storage(falhar = false) {
  const salvos = new Map<string, { bytes: Uint8Array; tipo: string }>();
  const arquivos: Arquivos = {
    salvar: (caminho, conteudo, tipo) => {
      if (falhar) return Promise.reject(new Error("Storage fora do ar"));
      salvos.set(caminho, { bytes: conteudo, tipo });
      return Promise.resolve();
    },
    link: (caminho, segundos) => Promise.resolve(`https://exemplo/assinado/${caminho}?s=${segundos}`),
  };
  return { arquivos, salvos };
}

const inicioPdf = (b: Uint8Array) => new TextDecoder().decode(b.slice(0, 5));
const resultado = (r: { corpo: unknown }) => (r.corpo as any).result;
const json = (r: { corpo: unknown }) => JSON.parse(resultado(r).content[0].text);

// ---------------------------------------------------------------------------

Deno.test("documentos: ferramentas registradas, com anotações e campos obrigatórios", async () => {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  const porNome = Object.fromEntries(((r.corpo as any).result.tools as any[]).map((t) => [t.name, t]));
  const nomes = [
    "montar_orcamento",
    "alterar_orcamento",
    "emitir_receita",
    "emitir_atestado",
    "emitir_termo",
    "ver_documentos",
  ];
  for (const n of nomes) verdade(porNome[n], `falta ${n}`);
  for (const n of nomes) igual(porNome[n].annotations.destructiveHint, false, n);
  igual(porNome.montar_orcamento.inputSchema.required.sort(), ["paciente_id", "texto_original"]);
  igual(porNome.alterar_orcamento.inputSchema.required.sort(), ["acao", "texto_original"]);
  igual(porNome.emitir_receita.inputSchema.required.sort(), ["medicamentos", "paciente_id", "texto_original"]);
  igual(porNome.emitir_atestado.inputSchema.required.sort(), ["paciente_id", "texto_original", "tipo"]);
  igual(porNome.emitir_termo.inputSchema.required.sort(), ["modelo", "paciente_id", "texto_original"]);
  igual(porNome.ver_documentos.inputSchema.required ?? [], []);
  verdade(porNome.emitir_receita.description.includes("amoxicilina_500"), "descrição sem os modelos");
});

Deno.test("documentos: instruções do módulo entram nas instruções do servidor", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "t", version: "1" },
  });
  const instr = (r.corpo as any).result.instructions as string;
  verdade(instr.includes("valor_necessario"), "instruções sem a regra de preço");
  verdade(instr.includes("confirmar_alertas"), "instruções sem a regra da receita");
});

Deno.test("montar_orcamento: separa texto_original, gera o PDF, guarda, registra e devolve o link", async () => {
  const { arquivos, salvos } = storage();
  const caminho = `${PAC}/orcamento-7-v2-20261102-101500-ab12.pdf`;
  const { mcp, chamadas } = await montar({
    mcp_montar_orcamento: () => ({
      status: "ok",
      orcamento: { numero: 7, total: 3690 },
      documento: {
        tipo: "orcamento",
        referencia_id: "11111111-1111-1111-1111-111111111111",
        paciente_id: PAC,
        titulo: "Orçamento nº 7 v2",
        caminho,
        solicitacao_id: "22222222-2222-2222-2222-222222222222",
        dados: ORCAMENTO,
      },
      avisos: [],
    }),
    mcp_registrar_documento: () => ({ status: "ok" }),
  }, arquivos);
  const r = await mcp("tools/call", {
    name: "montar_orcamento",
    arguments: {
      paciente_id: PAC,
      itens: [{ procedimento_codigo: "canal_molar", dente: 46, alternativa: "A" }],
      valores: [{ procedimento_codigo: "canal_molar", valor: 1100 }],
      texto_original: "monta o orçamento da Mari com canal no 46 por 1100",
    },
  });
  igual(resultado(r).isError, undefined);
  const c = chamadas.find((x) => x.funcao === "mcp_montar_orcamento")!;
  igual(c.args.p_texto_original, "monta o orçamento da Mari com canal no 46 por 1100");
  igual("texto_original" in (c.args.p_dados as any), false);
  igual((c.args.p_dados as any).valores, [{ procedimento_codigo: "canal_molar", valor: 1100 }]);

  const salvo = salvos.get(caminho)!;
  verdade(salvo, "PDF não foi guardado");
  igual(salvo.tipo, "application/pdf");
  igual(inicioPdf(salvo.bytes), "%PDF-");

  const reg = chamadas.find((x) => x.funcao === "mcp_registrar_documento")!;
  const d = reg.args.p_dados as any;
  igual(d.caminho, caminho);
  igual(d.tamanho_bytes, salvo.bytes.length);
  verdade(/^[0-9a-f]{64}$/.test(d.sha256), "sha256 inválido");
  igual(d.solicitacao_id, "22222222-2222-2222-2222-222222222222");

  const saida = json(r);
  igual(saida.documento, undefined, "dados brutos do PDF vazaram na resposta");
  verdade(saida.arquivo.link.startsWith("https://exemplo/assinado/"), "sem link");
  igual(saida.arquivo.link_valido_por, "7 dias");
});

Deno.test("montar_orcamento: valor_necessario passa direto, sem PDF", async () => {
  const { arquivos, salvos } = storage();
  const { mcp, chamadas } = await montar({
    mcp_montar_orcamento: () => ({ status: "valor_necessario", faltando: [{ procedimento_codigo: "canal_molar" }] }),
  }, arquivos);
  const r = await mcp("tools/call", { name: "montar_orcamento", arguments: { paciente_id: PAC, texto_original: "t" } });
  igual(json(r).status, "valor_necessario");
  igual(salvos.size, 0);
  igual(chamadas.some((x) => x.funcao === "mcp_registrar_documento"), false);
});

Deno.test("documento sem Storage: grava e avisa que o PDF não saiu", async () => {
  const { mcp } = await montar({
    mcp_emitir_atestado: () => ({
      status: "ok",
      documento: {
        tipo: "atestado",
        referencia_id: "r",
        paciente_id: PAC,
        titulo: "Atestado nº 1",
        caminho: `${PAC}/a.pdf`,
        dados: ATESTADO,
      },
    }),
  });
  const r = await mcp("tools/call", {
    name: "emitir_atestado",
    arguments: { paciente_id: PAC, tipo: "repouso", dias: 2, texto_original: "atestado de 2 dias" },
  });
  const saida = json(r);
  igual(saida.status, "ok");
  verdade(saida.arquivo.aviso.includes("PDF não foi gerado"), saida.arquivo.aviso);
});

Deno.test("falha no Storage: registro mantido, erro explicado, sem registrar arquivo", async () => {
  const { arquivos } = storage(true);
  const { mcp, chamadas } = await montar({
    mcp_emitir_receita: () => ({
      status: "ok",
      documento: {
        tipo: "receita",
        referencia_id: "r",
        paciente_id: PAC,
        titulo: "Receita nº 3",
        caminho: `${PAC}/r.pdf`,
        dados: RECEITA,
      },
    }),
  }, arquivos);
  const r = await mcp("tools/call", {
    name: "emitir_receita",
    arguments: { paciente_id: PAC, medicamentos: [{ modelo: "amoxicilina_500" }], texto_original: "amoxicilina" },
  });
  igual(resultado(r).isError, undefined);
  const saida = json(r);
  verdade(saida.arquivo.erro.includes("Storage fora do ar"), saida.arquivo.erro);
  verdade(saida.arquivo.erro.includes("regerar"), "sem orientação para gerar de novo");
  igual(chamadas.some((x) => x.funcao === "mcp_registrar_documento"), false);
});

Deno.test("emitir_receita: confirmacao_necessaria volta sem PDF; confirmar_alertas vai ao banco", async () => {
  const { arquivos, salvos } = storage();
  const { mcp, chamadas } = await montar({
    mcp_emitir_receita: (a) =>
      (a.p_dados as any).confirmar_alertas
        ? { status: "ok", receita: { numero: 1 } }
        : { status: "confirmacao_necessaria", alertas: ["Alergia a dipirona registrada"] },
  }, arquivos);
  const args = { paciente_id: PAC, medicamentos: [{ modelo: "dipirona_500" }], texto_original: "dipirona" };
  const r1 = await mcp("tools/call", { name: "emitir_receita", arguments: args });
  igual(json(r1).status, "confirmacao_necessaria");
  igual(salvos.size, 0);
  await mcp("tools/call", { name: "emitir_receita", arguments: { ...args, confirmar_alertas: true } });
  igual((chamadas.at(-1)!.args.p_dados as any).confirmar_alertas, true);
});

Deno.test("erro do banco na receita (controlado): isError e 'Nada foi gravado'", async () => {
  const { ErroRpc } = await import("../supabase/functions/mcp/comum.ts");
  const { mcp, chamadas } = await montar({
    mcp_emitir_receita: () => {
      throw new ErroRpc('"Alprazolam" é de controle especial (Portaria 344/98): não sai por aqui.');
    },
  });
  const r = await mcp("tools/call", {
    name: "emitir_receita",
    arguments: {
      paciente_id: PAC,
      medicamentos: [{ nome: "Alprazolam", posologia: "1 cp" }],
      texto_original: "alprazolam",
    },
  });
  igual(resultado(r).isError, true);
  verdade(resultado(r).content[0].text.startsWith("Nada foi gravado."), resultado(r).content[0].text);
  verdade(chamadas.some((c) => c.funcao === "mcp_registrar_falha"), "falha não registrada");
});

Deno.test("atestado: tipo inválido é recusado antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("tools/call", {
    name: "emitir_atestado",
    arguments: { paciente_id: PAC, tipo: "ferias", texto_original: "t" },
  });
  const res = resultado(r) ?? (r.corpo as any).error;
  verdade(res.isError === true || (r.corpo as any).error, "deveria recusar");
  igual(chamadas.filter((c) => c.funcao === "mcp_emitir_atestado").length, 0);
});

Deno.test("ver_documentos: troca cada arquivo.caminho por link; regerar gera o PDF de novo", async () => {
  const { arquivos, salvos } = storage();
  const { mcp } = await montar({
    mcp_ver_documentos: (a) =>
      (a.p_dados as any).regerar
        ? {
          status: "ok",
          documento: {
            tipo: "termo",
            referencia_id: "t",
            paciente_id: PAC,
            titulo: "Termo",
            caminho: `${PAC}/termo-2.pdf`,
            dados: TERMO,
          },
        }
        : {
          paciente: { nome: "Mariana" },
          receitas: [{ numero: 1, arquivo: { caminho: `${PAC}/receita-1.pdf`, gerado_em: "2026-11-02 10:00" } }],
          termos: [{ numero: 2 }],
        },
    mcp_registrar_documento: () => ({ status: "ok" }),
  }, arquivos);
  const r = await mcp("tools/call", { name: "ver_documentos", arguments: { paciente_id: PAC } });
  const saida = json(r);
  igual(saida.receitas[0].arquivo.caminho, undefined);
  verdade(saida.receitas[0].arquivo.link.includes("receita-1.pdf"), "sem link na listagem");
  const r2 = await mcp("tools/call", {
    name: "ver_documentos",
    arguments: { paciente_id: PAC, regerar: { tipo: "termo", numero: 2 } },
  });
  verdade(json(r2).arquivo.link.includes("termo-2.pdf"), "regerar sem link");
  igual(inicioPdf(salvos.get(`${PAC}/termo-2.pdf`)!.bytes), "%PDF-");
});

Deno.test("PDFs: todos os tipos geram arquivo válido, com quebra de página", async () => {
  const orc = await gerarPdf("orcamento", ORCAMENTO);
  const rec = await gerarPdf("receita", RECEITA);
  const ate = await gerarPdf("atestado", ATESTADO);
  const ter = await gerarPdf("termo", TERMO);
  const ori = await gerarPdf("orientacoes", { ...TERMO, tipo: "orientacoes", secoes: TERMO.secoes.slice(0, 3) });
  for (const b of [orc, rec, ate, ter, ori]) igual(inicioPdf(b), "%PDF-");
  const paginas = async (b: Uint8Array) => (await PDFDocument.load(b)).getPageCount();
  igual(await paginas(rec), 2, "receita de antibiótico deveria ter 2 vias");
  verdade(await paginas(ter) >= 2, "termo longo deveria quebrar página");
  // rascunho, aprovado e opção única também geram
  await gerarPdf("orcamento", { ...ORCAMENTO, status: "rascunho", opcoes: [ORCAMENTO.opcoes[0]] });
  await gerarPdf("orcamento", {
    ...ORCAMENTO,
    status: "aprovado",
    aprovado_em: "2026-11-03",
    forma_escolhida: "cartão 6x",
  });
});

Deno.test("formatação: texto WinAnsi, reais, datas, telefone e CPF", () => {
  igual(limparTexto("Implante → coroa ≥ 2 etapas 😀"), "Implante -> coroa >= 2 etapas ");
  igual(limparTexto("ação · “aspas” — travessão"), "ação · “aspas” — travessão");
  igual(limparTexto("R$ 10"), "R$ 10");
  verdade(/^R\$\s1\.234,50$/.test(reais(1234.5)), reais(1234.5));
  igual(dataBR("2026-11-02"), "02/11/2026");
  igual(telefoneBR("21981772817"), "(21) 98177-2817");
  igual(cpfBR("11600034594"), "116.000.345-94");
});
