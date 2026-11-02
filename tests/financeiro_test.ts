// deno-lint-ignore-file no-explicit-any
// Testes do módulo financeiro sem banco: esquemas das ferramentas, o que vai
// para cada função do Postgres, formato dos CSV e o pacote do contador com
// um Storage falso.

import type { Arquivos } from "../supabase/functions/mcp/comum.ts";
import { ErroRpc } from "../supabase/functions/mcp/comum.ts";
import {
  arquivosDoPacote,
  csvDespesas,
  csvRecebimentos,
  csvReceitaSaude,
  csvResumo,
  dataBR,
  documentoFormatado,
  type LinhaReceitaSaude,
  type PacoteDoBanco,
  semAcentos,
  valorBR,
} from "../supabase/functions/mcp/financeiro/csv.ts";
import { VALIDADE_LINK_SEGUNDOS } from "../supabase/functions/mcp/ferramentas/financeiro.ts";
import { igual, montar, verdade } from "./util.ts";

// Dados fictícios (CPFs válidos de teste).
const CPF_DRA = "222.333.444-05";
const CPF_PAGADOR = "11144477735";
const CPF_PACIENTE = "98765432100";

function linhaRs(i: number, extra: Partial<LinhaReceitaSaude> = {}): LinhaReceitaSaude {
  return {
    recebimento_id: `r${i}`,
    numero: i,
    data_pagamento: "2026-10-05",
    valor: 350,
    descricao: "Restauração em resina; dente 36",
    cpf_pagador: CPF_PAGADOR,
    cpf_beneficiario: CPF_PACIENTE,
    ...extra,
  };
}

function pacoteFicticio(extra: Partial<PacoteDoBanco> = {}): PacoteDoBanco {
  return {
    status: "ok",
    mes: "2026-10",
    profissional: { nome: "Dra. Teste", cro: "CRO-SP 00000", cpf: "22233344405", codigo_ocupacao: "226" },
    receita_saude: [linhaRs(1), linhaRs(2, { valor: 1800.5, data_pagamento: "2026-10-20", descricao: "Prótese" })],
    recebimentos: [{
      numero: 1,
      data_pagamento: "2026-10-05",
      data_atendimento: "2026-10-05",
      paciente: "Pedro Teste Financeiro",
      paciente_cpf: CPF_PACIENTE,
      pagador: "Carla Teste Financeiro",
      pagador_cpf: CPF_PAGADOR,
      descricao: "Restauração",
      forma: "credito_parcelado",
      parcela: "1/3",
      parcelas_cartao: 3,
      valor_bruto: 350,
      taxa: 20.83,
      valor_liquido: 329.17,
      data_credito_prevista: "2026-11-04",
      regime: "pf",
      recibo: "pendente",
    }],
    despesas: [{
      numero: 7,
      data: "2026-10-10",
      competencia: "2026-10",
      categoria: "laboratorio",
      descricao: "Coroa; prova",
      fornecedor: "Laboratório Fictício",
      fornecedor_documento: "11222333000181",
      valor: 420,
      forma: "pix",
      paciente: "Ana Teste Financeiro",
      origem: "manual",
    }],
    resumo: {
      mes: "2026-10",
      regime: "pf",
      recebido: { bruto: 2150.5, taxas: 20.83, liquido: 2129.67, pagamentos: 2, por_forma: [] },
      despesas: { total: 420, por_categoria: [{ categoria: "laboratorio", total: 420 }] },
      resultado: 1709.67,
      avisos: ["1 recibo pendente"],
    },
    problemas: ["1 despesa(s) sem comprovante anotado."],
    ...extra,
  };
}

function storageFalso() {
  const salvos = new Map<string, { conteudo: Uint8Array; tipo: string }>();
  const links: { caminho: string; segundos?: number }[] = [];
  const arquivos: Arquivos = {
    salvar: (caminho, conteudo, tipo) => {
      salvos.set(caminho, { conteudo, tipo });
      return Promise.resolve();
    },
    link: (caminho, segundos) => {
      links.push({ caminho, segundos });
      return Promise.resolve(`https://exemplo.supabase.co/storage/v1/object/sign/documentos/${caminho}?token=x`);
    },
  };
  return { arquivos, salvos, links };
}

async function chamar(mcp: any, name: string, args: Record<string, unknown>) {
  const r = await mcp("tools/call", { name, arguments: args });
  return (r.corpo as any).result ?? (r.corpo as any).error;
}

// ---------------------------------------------------------------------
// Ferramentas
// ---------------------------------------------------------------------

Deno.test("financeiro: as seis ferramentas, com leitura x gravação certas", async () => {
  const { mcp } = await montar();
  const tools = ((await mcp("tools/list")).corpo as any).result.tools as any[];
  const porNome = Object.fromEntries(tools.map((t) => [t.name, t]));
  const esperado: Record<string, boolean> = {
    registrar_pagamento: false,
    registrar_despesa: false,
    ver_financeiro: true,
    marcar_recibos: false,
    configurar_financeiro: false,
    gerar_pacote_contador: false,
  };
  for (const [nome, leitura] of Object.entries(esperado)) {
    verdade(porNome[nome], `falta ${nome}`);
    igual(porNome[nome].annotations.readOnlyHint, leitura, `${nome} readOnlyHint`);
    igual(porNome[nome].annotations.destructiveHint, false, `${nome} destrutiva`);
  }
  igual(porNome.registrar_pagamento.inputSchema.properties.forma.enum, [
    "pix",
    "dinheiro",
    "debito",
    "credito_vista",
    "credito_parcelado",
    "boleto",
    "transferencia",
  ]);
  verdade(porNome.registrar_pagamento.inputSchema.required.includes("texto_original"), "texto_original obrigatório");
  verdade(
    !(porNome.ver_financeiro.inputSchema.required ?? []).includes("texto_original"),
    "leitura sem texto_original",
  );
});

Deno.test("financeiro: instruções do servidor falam de confirmação, estorno e recibos", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "teste", version: "1" },
  });
  const inst = (r.corpo as any).result.instructions as string;
  verdade(inst.includes("- Financeiro: antes de gravar"), "sem a linha do financeiro");
  verdade(inst.includes("quitar_parcela = false"), "sem a regra da parcela");
  verdade(inst.includes("estorne"), "sem a regra do estorno");
  verdade(inst.includes("Receita Saúde"), "sem a regra dos recibos");
});

Deno.test("registrar_pagamento: texto_original separado e o resto em p_dados", async () => {
  const { mcp, chamadas } = await montar({ mcp_registrar_pagamento: () => ({ status: "ok", recebimentos: [] }) });
  const res = await chamar(mcp, "registrar_pagamento", {
    paciente_id: "p1",
    valor: 350,
    forma: "credito_parcelado",
    parcelas_cartao: 3,
    pagador: { nome: "Carla Teste Financeiro" },
    texto_original: "a mãe do Pedro pagou 350 em 3x no cartão",
  });
  igual(res.isError, undefined);
  igual(chamadas.at(-1), {
    funcao: "mcp_registrar_pagamento",
    args: {
      p_dados: {
        paciente_id: "p1",
        valor: 350,
        forma: "credito_parcelado",
        parcelas_cartao: 3,
        pagador: { nome: "Carla Teste Financeiro" },
      },
      p_texto_original: "a mãe do Pedro pagou 350 em 3x no cartão",
    },
  });
});

Deno.test("registrar_pagamento: recusa forma desconhecida, valor negativo e centavos demais sem chamar o banco", async () => {
  const { mcp, chamadas } = await montar();
  for (
    const args of [
      { paciente_id: "p1", valor: 100, forma: "cheque", texto_original: "t" },
      { paciente_id: "p1", valor: -100, forma: "pix", texto_original: "t" },
      { paciente_id: "p1", valor: 1.234, forma: "pix", texto_original: "t" },
      { paciente_id: "p1", valor: 100, forma: "pix" },
    ]
  ) {
    const res = await chamar(mcp, "registrar_pagamento", args);
    verdade(res.isError === true || res.code, `deveria recusar ${JSON.stringify(args)}`);
  }
  igual(chamadas.filter((c) => c.funcao === "mcp_registrar_pagamento").length, 0);
});

Deno.test("registrar_pagamento: erro do banco vira 'Nada foi gravado.' e fica registrado", async () => {
  const { mcp, chamadas } = await montar({
    mcp_registrar_pagamento: () => {
      throw new ErroRpc("A data do pagamento está no futuro.", "Parcelas futuras: use acao combinar.");
    },
  });
  const res = await chamar(mcp, "registrar_pagamento", {
    paciente_id: "p1",
    valor: 90,
    forma: "pix",
    data: "2030-01-01",
    texto_original: "t",
  });
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("Nada foi gravado."), res.content[0].text);
  verdade(res.content[0].text.includes("acao combinar"), "dica não repassada");
  const f = chamadas.find((c) => c.funcao === "mcp_registrar_falha")!;
  igual(f.args.p_ferramenta, "registrar_pagamento");
  igual(f.args.p_texto_original, "t");
});

Deno.test("registrar_despesa: categoria e recorrente vão em p_dados; categoria desconhecida é recusada", async () => {
  const { mcp, chamadas } = await montar();
  await chamar(mcp, "registrar_despesa", {
    valor: 1200,
    categoria: "aluguel_sala",
    recorrente: { dia: 10 },
    forma: "pix",
    texto_original: "aluguel da sala 1200 todo dia 10",
  });
  igual(chamadas.at(-1), {
    funcao: "mcp_registrar_despesa",
    args: {
      p_dados: { valor: 1200, categoria: "aluguel_sala", forma: "pix", recorrente: { dia: 10 } },
      p_texto_original: "aluguel da sala 1200 todo dia 10",
    },
  });
  const res = await chamar(mcp, "registrar_despesa", { valor: 50, categoria: "padaria", texto_original: "t" });
  verdade(res.isError === true || res.code, "deveria recusar categoria desconhecida");
  igual(chamadas.filter((c) => c.funcao === "mcp_registrar_despesa").length, 1);
});

Deno.test("ver_financeiro, marcar_recibos e configurar_financeiro chamam a função certa", async () => {
  const { mcp, chamadas } = await montar();
  await chamar(mcp, "ver_financeiro", { visao: "inadimplentes" });
  igual(chamadas.at(-1), {
    funcao: "mcp_ver_financeiro",
    args: { p_dados: { visao: "inadimplentes" }, p_texto_original: null },
  });
  await chamar(mcp, "marcar_recibos", { mes: "2026-10", todos_pendentes: true, texto_original: "já mandei o lote" });
  igual(chamadas.at(-1)!.funcao, "mcp_marcar_recibos");
  igual(chamadas.at(-1)!.args.p_dados, { mes: "2026-10", todos_pendentes: true });
  await chamar(mcp, "configurar_financeiro", {
    cpf_profissional: CPF_DRA,
    taxas: { credito_parcelado: { por_parcelas: { "2": 4.59, "3": 5.97 } } },
    texto_original: "meu CPF e a taxa do parcelado",
  });
  igual(chamadas.at(-1)!.funcao, "mcp_configurar_financeiro");
  igual(chamadas.at(-1)!.args.p_dados, {
    cpf_profissional: CPF_DRA,
    taxas: { credito_parcelado: { por_parcelas: { "2": 4.59, "3": 5.97 } } },
  });
  const res = await chamar(mcp, "ver_financeiro", { visao: "mes", mes: "10/2026" });
  verdade(res.isError === true || res.code, "deveria recusar mês fora de AAAA-MM");
});

// ---------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------

Deno.test("csv: formatação de data, valor, documento e texto ASCII", () => {
  igual(dataBR("2026-10-05"), "05/10/2026");
  igual(valorBR(350), "350,00");
  igual(valorBR(1800.5), "1800,50");
  igual(valorBR(-90), "-90,00");
  igual(valorBR(null), "");
  igual(documentoFormatado("11144477735"), "111.444.777-35");
  igual(documentoFormatado("11222333000181"), "11.222.333/0001-81");
  igual(semAcentos('Manutenção; ortodôntica\n"nº 2"'), "Manutencao ortodontica 'no 2'");
  igual(semAcentos("a".repeat(300)).length, 255);
});

Deno.test("csv do Receita Saúde: 16 campos, sem cabeçalho, ASCII e CRLF", () => {
  const [arq, ...resto] = csvReceitaSaude([linhaRs(1)], {
    cpf: CPF_DRA,
    registro: "CRO-SP 00000",
    codigo_ocupacao: "226",
  });
  igual(resto.length, 0);
  verdade(arq.endsWith("\r\n"), "sem CRLF no fim");
  verdade(/^[\x20-\x7e\r\n]*$/.test(arq), "caractere fora do ASCII");
  const campos = arq.trimEnd().split(";");
  igual(campos.length, 16);
  igual(campos, [
    "05/10/2026",
    "R01.001.001",
    "226",
    "350,00",
    "",
    "Restauracao em resina dente 36",
    "PF",
    CPF_PAGADOR,
    CPF_PACIENTE,
    "",
    "",
    "",
    "",
    "S",
    "22233344405",
    "CRO-SP 00000",
  ]);
});

Deno.test("csv do Receita Saúde: divide em 1.000 linhas e por ano; sem CPF da Dra. é erro", () => {
  const linhas = Array.from({ length: 1001 }, (_, i) => linhaRs(i + 1));
  linhas.push(linhaRs(2000, { data_pagamento: "2027-01-02" }));
  const arqs = csvReceitaSaude(linhas, { cpf: CPF_DRA });
  igual(arqs.map((a) => a.split("\r\n").length - 1), [1000, 1, 1]);
  verdade(arqs[2].startsWith("02/01/2027"), "o ano novo deveria ir em arquivo próprio");
  let erro = "";
  try {
    csvReceitaSaude([linhaRs(1)], {});
  } catch (e) {
    erro = (e as Error).message;
  }
  verdade(erro.includes("CPF da Dra."), "deveria exigir o CPF da Dra.");
});

Deno.test("planilhas completas: BOM, cabeçalho, ';', CPF formatado e nada vira fórmula", () => {
  const rec = csvRecebimentos(pacoteFicticio().recebimentos!);
  verdade(rec.startsWith("﻿Número;Data do pagamento;"), "sem BOM ou cabeçalho");
  const linha = rec.split("\r\n")[1].split(";");
  igual(linha[0], "1");
  igual(linha[4], "987.654.321-00");
  igual(linha[8], "Cartão de crédito parcelado");
  igual(linha[11], "350,00");
  igual(linha[13], "329,17");
  const desp = csvDespesas(pacoteFicticio().despesas!);
  verdade(desp.includes('"Coroa; prova"'), "texto com ';' deveria ir entre aspas");
  verdade(desp.includes("11.222.333/0001-81"), "CNPJ sem formatação");
  verdade(desp.includes(";Laboratório;"), "categoria sem rótulo");
  const perigoso = csvDespesas([{
    numero: 1,
    data: "2026-10-01",
    categoria: "outros",
    descricao: "=HYPERLINK(1)",
    valor: 1,
  }]);
  verdade(perigoso.includes(";'=HYPERLINK(1);"), "fórmula não neutralizada");
  const resumo = csvResumo("2026-10", pacoteFicticio().resumo!, ["Falta comprovante"]);
  verdade(resumo.includes("Mês;10/2026\r\n"), "mês do resumo");
  verdade(resumo.includes("Despesas: Laboratório;420,00"), "categoria do resumo");
  verdade(resumo.includes("Pendência;Falta comprovante"), "pendência do resumo");
});

Deno.test("arquivosDoPacote: sem CPF da Dra. não gera o lote, mas gera as planilhas", () => {
  const p = pacoteFicticio({ profissional: { nome: "Dra. Teste" } });
  const { arquivos, lote, avisos } = arquivosDoPacote(p);
  igual(arquivos.map((a) => a.nome), [
    "recebimentos-2026-10.csv",
    "despesas-livro-caixa-2026-10.csv",
    "resumo-2026-10.csv",
  ]);
  igual(lote, null);
  verdade(avisos[0].includes("CPF da Dra."), "sem aviso do CPF");
});

// ---------------------------------------------------------------------
// gerar_pacote_contador
// ---------------------------------------------------------------------

Deno.test("gerar_pacote_contador: grava os CSV no Storage, devolve links e registra o lote", async () => {
  const st = storageFalso();
  const { mcp, chamadas } = await montar({
    mcp_pacote_contador: () => pacoteFicticio(),
    mcp_registrar_pacote_contador: () => ({ status: "ok", pacote_id: "pc1", mes: "2026-10" }),
  }, st.arquivos);
  const res = await chamar(mcp, "gerar_pacote_contador", {
    mes: "2026-10",
    texto_original: "gera o pacote de outubro",
  });
  igual(res.isError, undefined);
  const corpo = JSON.parse(res.content[0].text);
  igual(corpo.status, "ok");
  igual(corpo.pacote_id, "pc1");
  igual(corpo.arquivos.map((a: any) => a.nome), [
    "receita-saude-2026-10.csv",
    "recebimentos-2026-10.csv",
    "despesas-livro-caixa-2026-10.csv",
    "resumo-2026-10.csv",
  ]);
  verdade(corpo.arquivos.every((a: any) => a.link.startsWith("https://")), "link faltando");
  igual(corpo.receita_saude, { recibos_no_arquivo: 2, valor_no_arquivo: 2150.5 });
  verdade(corpo.proximos_passos[0].includes("marcar_recibos"), "sem o próximo passo dos recibos");

  igual([...st.salvos.keys()], corpo.arquivos.map((a: any) => `contador/2026-10/${a.nome}`));
  for (const s of st.salvos.values()) igual(s.tipo, "text/csv");
  igual(st.links.map((l) => l.segundos), [
    VALIDADE_LINK_SEGUNDOS,
    VALIDADE_LINK_SEGUNDOS,
    VALIDADE_LINK_SEGUNDOS,
    VALIDADE_LINK_SEGUNDOS,
  ]);
  const lote = new TextDecoder().decode(st.salvos.get("contador/2026-10/receita-saude-2026-10.csv")!.conteudo);
  igual(lote.split("\r\n").length - 1, 2);

  igual(chamadas[0], {
    funcao: "mcp_pacote_contador",
    args: { p_dados: { mes: "2026-10" }, p_texto_original: "gera o pacote de outubro" },
  });
  const reg = chamadas.find((c) => c.funcao === "mcp_registrar_pacote_contador")!;
  const dados = reg.args.p_dados as any;
  igual(dados.mes, "2026-10");
  igual(dados.resumo.lote_receita_saude, ["r1", "r2"]);
  igual(dados.resumo.problemas, ["1 despesa(s) sem comprovante anotado."]);
  igual(dados.arquivos[0], {
    nome: "receita-saude-2026-10.csv",
    caminho: "contador/2026-10/receita-saude-2026-10.csv",
    linhas: 2,
  });
  igual(reg.args.p_texto_original, "gera o pacote de outubro");
});

Deno.test("gerar_pacote_contador: sem lote do Receita Saúde não manda lote_receita_saude", async () => {
  const st = storageFalso();
  const { mcp, chamadas } = await montar({
    mcp_pacote_contador: () => pacoteFicticio({ receita_saude: [] }),
  }, st.arquivos);
  const res = await chamar(mcp, "gerar_pacote_contador", { texto_original: "pacote do mês passado" });
  const corpo = JSON.parse(res.content[0].text);
  igual(corpo.arquivos.length, 3);
  igual(corpo.proximos_passos.length, 1);
  const reg = chamadas.find((c) => c.funcao === "mcp_registrar_pacote_contador")!;
  igual("lote_receita_saude" in (reg.args.p_dados as any).resumo, false);
});

Deno.test("gerar_pacote_contador: sem Storage avisa e não registra o pacote", async () => {
  const { mcp, chamadas } = await montar({ mcp_pacote_contador: () => pacoteFicticio() });
  const res = await chamar(mcp, "gerar_pacote_contador", { mes: "2026-10", texto_original: "t" });
  igual(res.isError, undefined);
  const corpo = JSON.parse(res.content[0].text);
  igual(corpo.status, "sem_arquivos");
  verdade(corpo.mensagem.includes("não foram gerados"), corpo.mensagem);
  igual(chamadas.some((c) => c.funcao === "mcp_registrar_pacote_contador"), false);
});

Deno.test("gerar_pacote_contador: falha no Storage vira erro registrado e o pacote não é registrado", async () => {
  const arquivos: Arquivos = {
    salvar: () => Promise.reject(new Error("Storage fora do ar")),
    link: () => Promise.resolve("x"),
  };
  const { mcp, chamadas } = await montar({ mcp_pacote_contador: () => pacoteFicticio() }, arquivos);
  const res = await chamar(mcp, "gerar_pacote_contador", { mes: "2026-10", texto_original: "t" });
  igual(res.isError, true);
  verdade(res.content[0].text.includes("Storage fora do ar"), res.content[0].text);
  igual(chamadas.some((c) => c.funcao === "mcp_registrar_pacote_contador"), false);
  igual(chamadas.at(-1)!.funcao, "mcp_registrar_falha");
  igual(chamadas.at(-1)!.args.p_ferramenta, "gerar_pacote_contador");
});

Deno.test("gerar_pacote_contador: erro do banco (mês futuro) é repassado", async () => {
  const { mcp } = await montar({
    mcp_pacote_contador: () => {
      throw new ErroRpc("O mês 12/2026 ainda não começou.");
    },
  }, storageFalso().arquivos);
  const res = await chamar(mcp, "gerar_pacote_contador", { mes: "2026-12", texto_original: "t" });
  igual(res.isError, true);
  verdade(res.content[0].text.includes("ainda não começou"), res.content[0].text);
});
