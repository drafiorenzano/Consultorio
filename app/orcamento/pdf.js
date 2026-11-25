// Desenha o orçamento (Plano de Tratamento) em PDF, com o mesmo visual do
// gerador que a Dra. já usava no site público (andressafiorenzano.com.br/orcamento,
// arquivo src/lib/pdf/planoTratamento.ts do repositório do site). As medidas e as
// cores são as de lá: mexeu em uma, confira a outra e a prévia da tela
// (estilo.css, bloco "orçamento").
//
// O documento é desenhado em milímetros sobre uma folha A4 de verdade (jsPDF),
// então sai idêntico no computador, no iPad e no celular. O jsPDF e as fontes só
// são baixados no primeiro PDF, para a tela abrir leve.

/** @typedef {{ descricao: string, regiao: string, qtd: number, valor: number }} ItemPlano */
/**
 * @typedef {{
 *   clinica: { nome: string, papel: string, cro: string, whatsapp: string, instagram: string, email: string },
 *   paciente: string, emissao: string, validade: string, itens: ItemPlano[], detalharPrecos: boolean,
 *   desconto: number, descontoRotulo: string, parcelas: number, observacoes: string
 * }} PlanoTratamento
 */

// ── paleta (mesma do site; as opacidades já vêm resolvidas) ──────
const COR = {
  ink: "#2c4a3e",
  inkSoft: "#3d5e51",
  warm: "#f0ede6",
  sand: "#d4c5a9",
  texto: "#1f2a24",
  muted: "#6b7570",
  linhaSuave: "#eaedec", // ink a 10% sobre branco
  croSobreInk: "#c8ccc4", // warm a 80% sobre ink
  contatoSobreInk: "#d3d5cd", // warm a 85% sobre ink
  bordaSobreInk: "#63776d", // warm a 28% sobre ink
};

// ── folha ────────────────────────────────────────────────────────
const PAGINA = { largura: 210, altura: 297 };
const MARGEM = 14; // padding lateral do documento
const UTIL = PAGINA.largura - MARGEM * 2;
const MM_PARA_PT = 72 / 25.4;

/** Caracteres que as fontes embutidas têm (ASCII, acentos do português e alguns sinais). */
const NAS_FONTES = new Set(
  "£§ª°·ºÀÁÂÃÄÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜàáâãäçèéêëìíîïñòóôõöùúûü–—•…€",
);
const temNaFonte = (c) => (c >= " " && c <= "~") || c === "\n" || NAS_FONTES.has(c);

/**
 * O PDF só desenha caracteres que existam na fonte embutida e, ao topar com um
 * que falta, engole o resto da linha (foi o que aconteceu com "R$ 4.500,00": o
 * Intl separa o símbolo do número com espaço não separável). Tudo o que vai para
 * o papel passa aqui: espaços especiais viram espaço, aspas curvas viram retas,
 * letra com acento que a fonte não tem perde o acento e o resto sai.
 */
export const normalizar = (txt) =>
  Array.from(
    String(txt ?? "")
      .replace(/\r\n?/g, "\n")
      .replace(/[  -   　\t]/g, " ") // espaços especiais
      .replace(/[​-‍﻿]/g, "") // invisíveis colados de outros apps
      .replace(/[‘’´`]/g, "'")
      .replace(/[“”]/g, '"')
      .replace(/[−‐‑]/g, "-") // sinais de menos e hífens especiais
      .replace(/×/g, "x")
      .replace(/²/g, "2")
      .replace(/³/g, "3"),
  ).map((c) => {
    if (temNaFonte(c)) return c;
    const base = c.normalize("NFD").replace(/[̀-ͯ]/g, "");
    return Array.from(base).every(temNaFonte) ? base : "";
  }).join("");

const formatador = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const brl = { format: (valor) => normalizar(formatador.format(valor)) };

const FAMILIA = {
  leve: ["Outfit", "leve"],
  normal: ["Outfit", "normal"],
  medio: ["Outfit", "medio"],
  titulo: ["TenorSans", "normal"],
};

// ── jsPDF e fontes, baixados na primeira vez ─────────────────────
let carregando = null;
function carregarJsPDF() {
  if (globalThis.jspdf?.jsPDF) return Promise.resolve(globalThis.jspdf.jsPDF);
  carregando ??= new Promise((ok, falhou) => {
    const s = document.createElement("script");
    s.src = new URL("./jspdf.umd.min.js", import.meta.url).href;
    s.onload = () => (globalThis.jspdf?.jsPDF ? ok(globalThis.jspdf.jsPDF) : falhou(new Error("jsPDF não carregou.")));
    s.onerror = () => {
      carregando = null;
      falhou(new Error("Não consegui baixar o gerador de PDF. Confira a internet e tente de novo."));
    };
    document.head.appendChild(s);
  });
  return carregando;
}

/** Prepara o gerador (jsPDF + fontes). Chame antes de gerarPlanoTratamento. */
export async function prepararPdf() {
  const [jsPDF, fontes] = await Promise.all([carregarJsPDF(), import("./fontes.js")]);
  return { jsPDF, fontes };
}

/** Camada fina sobre o jsPDF: tudo em milímetros, como no CSS. */
class Folha {
  constructor({ jsPDF, fontes }) {
    this.espacoEntreLetras = 0;
    this.doc = new jsPDF({ unit: "mm", format: "a4", compress: true });
    this.doc.addFileToVFS("TenorSans.ttf", fontes.tenorSans);
    this.doc.addFont("TenorSans.ttf", "TenorSans", "normal");
    this.doc.addFileToVFS("Outfit-300.ttf", fontes.outfit300);
    this.doc.addFont("Outfit-300.ttf", "Outfit", "leve");
    this.doc.addFileToVFS("Outfit-400.ttf", fontes.outfit400);
    this.doc.addFont("Outfit-400.ttf", "Outfit", "normal");
    this.doc.addFileToVFS("Outfit-500.ttf", fontes.outfit500);
    this.doc.addFont("Outfit-500.ttf", "Outfit", "medio");
  }

  fonte(peso, tamanhoMm, cor, espacamentoEm = 0) {
    const [familia, estilo] = FAMILIA[peso];
    this.doc.setFont(familia, estilo);
    this.doc.setFontSize(tamanhoMm * MM_PARA_PT);
    this.doc.setTextColor(cor);
    this.espacoEntreLetras = espacamentoEm * tamanhoMm;
    this.doc.setCharSpace(this.espacoEntreLetras);
    return this;
  }

  /** Largura real do texto: o jsPDF não soma o espaçamento entre letras. */
  largura(txt) {
    const limpo = normalizar(txt);
    return this.doc.getTextWidth(limpo) + this.espacoEntreLetras * Math.max(0, limpo.length - 1);
  }

  /** Escreve a partir do topo da linha (como o CSS raciocina). */
  texto(txt, x, yTopo, alinhamento = "esq") {
    const limpo = normalizar(txt);
    const destino = alinhamento === "dir" ? x - this.largura(limpo) : x;
    this.doc.text(limpo, destino, yTopo, { baseline: "top" });
    return this;
  }

  /** Quebra o texto na largura pedida e devolve as linhas. */
  quebrar(txt, larguraMax) {
    return normalizar(txt)
      .split("\n")
      .flatMap((paragrafo) => paragrafo.trim() === "" ? [""] : this.doc.splitTextToSize(paragrafo, larguraMax));
  }

  linha(x1, y1, x2, y2, cor, espessura = 0.2) {
    this.doc.setDrawColor(cor);
    this.doc.setLineWidth(espessura);
    this.doc.line(x1, y1, x2, y2);
    return this;
  }

  retangulo(x, y, largura, altura, cor) {
    this.doc.setFillColor(cor);
    this.doc.rect(x, y, largura, altura, "F");
    return this;
  }
}

// ── cálculo (a mesma conta que a tela mostra) ────────────────────
/** @param {PlanoTratamento} plano */
export function calcular(plano) {
  const subtotal = plano.itens.reduce((soma, i) => soma + i.qtd * i.valor, 0);
  const desconto = Math.min(plano.desconto, subtotal);
  const total = Math.max(0, subtotal - desconto);
  const parcelado = plano.parcelas > 1 && total > 0;
  return { subtotal, desconto, total, temDesconto: desconto > 0, parcelado };
}

// ── blocos do documento ──────────────────────────────────────────

/** Faixa verde com identidade e contatos. Devolve onde ela termina. */
function faixaTopo(f, plano, resumida) {
  const topo = resumida ? 8 : 14;
  let y = topo;

  const alturaNome = resumida ? 4.6 : 6 * 1.1;
  const alturaCro = 2.9 * 1.3;
  const alturaTipo = 4.2 * 1.15;
  const fim = resumida ? topo + alturaNome + 8 : topo + alturaNome + 1.5 + alturaCro + 3 + 3 + alturaTipo + 10;

  f.retangulo(0, 0, PAGINA.largura, fim, COR.ink);

  f.fonte("titulo", resumida ? 4.2 : 6, COR.warm).texto(plano.clinica.nome, MARGEM, y);
  y += alturaNome;

  if (resumida) {
    f.fonte("leve", 2.9, COR.contatoSobreInk).texto(
      "Plano de Tratamento · continuação",
      PAGINA.largura - MARGEM,
      topo + 1,
      "dir",
    );
    return fim;
  }

  y += 1.5;
  f.fonte("normal", 2.9, COR.croSobreInk, 0.18).texto(
    [plano.clinica.papel, plano.clinica.cro].filter(Boolean).join(" · ").toUpperCase(),
    MARGEM,
    y,
  );
  y += alturaCro + 3;

  const rotulo = "Plano de Tratamento";
  f.fonte("titulo", 4.2, COR.warm);
  const larguraRotulo = f.largura(rotulo);
  f.linha(MARGEM, y, MARGEM + larguraRotulo, y, COR.bordaSobreInk, 0.15);
  f.texto(rotulo, MARGEM, y + 3);

  // contatos, alinhados à direita
  let yContato = topo + 0.5;
  f.fonte("leve", 3, COR.contatoSobreInk);
  [plano.clinica.whatsapp, plano.clinica.instagram, plano.clinica.email].filter(Boolean).forEach((linha) => {
    f.texto(linha, PAGINA.largura - MARGEM, yContato, "dir");
    yContato += 3 * 1.3 + 1.2;
  });

  return fim;
}

/** Paciente, emissão e validade. */
function cabecalhoPaciente(f, plano, y) {
  const gap = 6;
  const colunas = (UTIL - gap * 2) / 3.75;
  const larguraPaciente = colunas * 1.75;
  const xEmissao = MARGEM + larguraPaciente + gap + colunas;
  const xValidade = MARGEM + UTIL;

  const rotulo = (txt, x, alinhamento) =>
    f.fonte("normal", 2.6, COR.muted, 0.2).texto(txt.toUpperCase(), x, y, alinhamento);

  rotulo("Paciente", MARGEM, "esq");
  rotulo("Emissão", xEmissao, "dir");
  rotulo("Válido até", xValidade, "dir");

  const yValor = y + 2.6 * 1.3 + 1.2;

  // nome comprido quebra na largura da própria coluna (sem isso ele
  // atravessava a folha e passava por cima da data de emissão)
  f.fonte("titulo", 5.2, COR.ink);
  const alturaLinhaNome = 5.2 * 1.25;
  const linhasNome = f.quebrar(plano.paciente || "—", larguraPaciente);
  linhasNome.forEach((linha, i) => f.texto(linha, MARGEM, yValor + i * alturaLinhaNome));

  f.fonte("titulo", 3.9, COR.ink)
    .texto(plano.emissao, xEmissao, yValor + 0.8, "dir")
    .texto(plano.validade, xValidade, yValor + 0.8, "dir");

  const fim = yValor + linhasNome.length * alturaLinhaNome + 6;
  f.linha(MARGEM, fim, MARGEM + UTIL, fim, COR.sand);
  return fim;
}

function colunas(detalhar) {
  const qtd = 18;
  const val = 30;
  const sub = 32;
  const numericas = detalhar ? qtd + val + sub : qtd;
  const restante = UTIL - numericas;
  const desc = restante * 0.61;
  const reg = restante - desc;

  const lista = [
    { chave: "desc", titulo: "Procedimento", x: MARGEM, largura: desc - 4, direita: false },
    { chave: "reg", titulo: "Dente / região", x: MARGEM + desc, largura: reg - 10, direita: false },
    { chave: "qtd", titulo: "Qtd.", x: MARGEM + desc + reg + qtd, largura: qtd - 8, direita: true },
  ];
  if (detalhar) {
    lista.push(
      { chave: "val", titulo: "Valor unit.", x: MARGEM + desc + reg + qtd + val, largura: val - 6, direita: true },
      { chave: "sub", titulo: "Subtotal", x: MARGEM + UTIL, largura: sub - 6, direita: true },
    );
  }
  return lista;
}

/** Uma linha da tabela ocupa a altura do texto mais longo que couber. */
function alturaLinha(f, item, cols) {
  const desc = cols.find((c) => c.chave === "desc");
  const reg = cols.find((c) => c.chave === "reg");
  f.fonte("normal", 3.4, COR.ink);
  const linhasDesc = f.quebrar(item.descricao || "—", desc.largura).length;
  f.fonte("leve", 3.4, COR.muted);
  const linhasReg = f.quebrar(item.regiao || "—", reg.largura).length;
  return Math.max(linhasDesc, linhasReg) * (3.4 * 1.35) + 3 * 2;
}

// ── documento ────────────────────────────────────────────────────
/**
 * @param {PlanoTratamento} plano
 * @param {{ jsPDF: any, fontes: any }} gerador o que prepararPdf() devolve
 */
export function gerarPlanoTratamento(plano, gerador) {
  const f = new Folha(gerador);
  const { subtotal, desconto, total, temDesconto, parcelado } = calcular(plano);
  const cols = colunas(plano.detalharPrecos);

  // o rodapé legal mora no pé da folha; o conteúdo nunca invade essa faixa
  const textoLegal = "Este orçamento é uma estimativa baseada na avaliação clínica realizada. " +
    "Alterações no quadro clínico identificadas durante o tratamento podem implicar " +
    "revisão do plano e dos valores, sempre comunicada previamente ao paciente.";
  f.fonte("leve", 2.7, COR.muted);
  const linhasLegal = f.quebrar(textoLegal, 130);
  const alturaLegal = linhasLegal.length * (2.7 * 1.6);
  const yRodape = PAGINA.altura - 12 - alturaLegal;
  const limiteConteudo = yRodape - 10;

  let pagina = 1;
  let y = faixaTopo(f, plano, false) + 10;

  const novaPagina = () => {
    f.doc.addPage();
    pagina++;
    y = faixaTopo(f, plano, true) + 10;
  };
  /** Avisa quando teve de virar a página (quem desenha tabela repete o cabeçalho). */
  const garantirEspaco = (altura) => {
    if (y + altura <= limiteConteudo) return false;
    novaPagina();
    return true;
  };

  y = cabecalhoPaciente(f, plano, y) + 8;

  // ── tabela ──
  const desenharCabecalhoTabela = () => {
    f.fonte("normal", 2.6, COR.muted, 0.18);
    cols.forEach((c) => f.texto(c.titulo.toUpperCase(), c.x, y, c.direita ? "dir" : "esq"));
    const fim = y + 2.6 * 1.3 + 2.5;
    f.linha(MARGEM, fim, MARGEM + UTIL, fim, COR.sand);
    y = fim;
  };
  desenharCabecalhoTabela();

  if (plano.itens.length === 0) {
    f.fonte("leve", 3.4, COR.muted).texto("Nenhum procedimento adicionado.", MARGEM, y + 5);
    y += 5 + 3.4 * 1.35;
  }

  plano.itens.forEach((item) => {
    const altura = alturaLinha(f, item, cols);
    if (garantirEspaco(altura)) desenharCabecalhoTabela();

    const yTexto = y + 3;
    const passoLinha = 3.4 * 1.35;

    cols.forEach((c) => {
      if (c.chave === "desc") {
        f.fonte("normal", 3.4, COR.ink);
        f.quebrar(item.descricao || "—", c.largura).forEach((linha, i) => f.texto(linha, c.x, yTexto + i * passoLinha));
      } else if (c.chave === "reg") {
        f.fonte("leve", 3.4, COR.muted);
        f.quebrar(item.regiao || "—", c.largura).forEach((linha, i) => f.texto(linha, c.x, yTexto + i * passoLinha));
      } else {
        const valor = c.chave === "qtd"
          ? String(item.qtd)
          : c.chave === "val"
          ? brl.format(item.valor)
          : brl.format(item.qtd * item.valor);
        f.fonte("leve", 3.4, COR.texto).texto(valor, c.x, yTexto, "dir");
      }
    });

    y += altura;
    f.linha(MARGEM, y, MARGEM + UTIL, y, COR.linhaSuave, 0.15);
  });

  // ── observações + somas ──
  y += 8;

  const larguraSomas = 78;
  const xSomas = MARGEM + UTIL - larguraSomas;
  const larguraObs = UTIL - larguraSomas - 8;

  const obs = String(plano.observacoes ?? "").trim();
  f.fonte("leve", 3.2, COR.texto);
  const linhasObs = obs ? f.quebrar(obs, larguraObs) : ["—"];

  const alturaObs = 2.6 * 1.3 + 1.5 + linhasObs.length * (3.2 * 1.65);
  const alturaSomas = (temDesconto ? 2 * (3.4 * 1.3 + 3) : 0) +
    1 +
    (3.5 * 2 + 5 * 1.2) +
    (parcelado ? 2.5 + 3.1 * 1.3 + 2 : 0);

  garantirEspaco(Math.max(alturaObs, alturaSomas));

  // observações
  let yObs = y;
  f.fonte("normal", 2.6, COR.muted, 0.2).texto("OBSERVAÇÕES", MARGEM, yObs);
  yObs += 2.6 * 1.3 + 1.5;
  f.fonte("leve", 3.2, COR.texto);
  linhasObs.forEach((linha) => {
    f.texto(linha, MARGEM, yObs);
    yObs += 3.2 * 1.65;
  });

  // somas
  let ySoma = y;
  const somaSimples = (rotulo, valor, cor) => {
    ySoma += 1.5;
    f.fonte("leve", 3.4, cor)
      .texto(rotulo, xSomas, ySoma)
      .texto(valor, MARGEM + UTIL, ySoma, "dir");
    ySoma += 3.4 * 1.3 + 1.5;
  };

  if (temDesconto) {
    somaSimples("Valor do tratamento", brl.format(subtotal), COR.texto);
    somaSimples(plano.descontoRotulo, `– ${brl.format(desconto)}`, COR.inkSoft);
  }

  // destaque: valor a pagar (ou o valor da parcela, quando parcelado)
  ySoma += 1;
  const alturaDestaque = 3.5 * 2 + 5 * 1.2;
  f.retangulo(xSomas, ySoma, larguraSomas, alturaDestaque, COR.warm);
  const yDestaque = ySoma + 3.5;
  f.fonte("titulo", 5, COR.ink).texto(
    parcelado ? "Parcelado em" : temDesconto ? "Valor a pagar" : "Total",
    xSomas + 4,
    yDestaque,
  );

  const valorDestaque = brl.format(parcelado ? total / plano.parcelas : total);
  f.fonte("titulo", 5, COR.ink);
  const larguraValor = f.largura(valorDestaque);
  f.texto(valorDestaque, xSomas + larguraSomas - 4, yDestaque, "dir");
  if (parcelado) {
    f.fonte("leve", 3.4, COR.inkSoft).texto(
      `${plano.parcelas}x`,
      xSomas + larguraSomas - 4 - larguraValor - 1.5,
      yDestaque + 1.4,
      "dir",
    );
  }
  ySoma += alturaDestaque;

  if (parcelado) {
    ySoma += 2;
    f.linha(xSomas, ySoma, MARGEM + UTIL, ySoma, COR.sand, 0.15);
    ySoma += 2.5;
    f.fonte("leve", 3.1, COR.muted)
      .texto("Valor total", xSomas, ySoma)
      .texto(brl.format(total), MARGEM + UTIL, ySoma, "dir");
  }

  // ── rodapé legal (última página) ──
  f.linha(MARGEM, yRodape - 10, MARGEM + UTIL, yRodape - 10, COR.sand);
  f.fonte("leve", 2.7, COR.muted);
  linhasLegal.forEach((linha, i) => f.texto(linha, MARGEM, yRodape + i * (2.7 * 1.6)));

  if (pagina > 1) {
    const paginas = f.doc.getNumberOfPages();
    for (let p = 1; p <= paginas; p++) {
      f.doc.setPage(p);
      f.fonte("leve", 2.6, COR.muted).texto(`${p} / ${paginas}`, PAGINA.largura - MARGEM, PAGINA.altura - 8, "dir");
    }
  }

  f.doc.setProperties({
    title: normalizar(`Plano de Tratamento — ${plano.paciente || "paciente"}`),
    subject: "Plano de Tratamento",
    author: normalizar(plano.clinica.nome),
    creator: normalizar(plano.clinica.nome),
  });

  return f.doc;
}

/** "Orçamento - Maria Silva.pdf": o que aparece no WhatsApp. */
export function nomeArquivo(paciente) {
  const limpo = String(paciente ?? "").trim().replace(/[\\/:*?"<>|]/g, "").replace(/\s+/g, " ");
  return `Orçamento${limpo ? ` - ${limpo}` : ""}.pdf`;
}
