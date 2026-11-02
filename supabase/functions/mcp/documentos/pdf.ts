// PDFs dos documentos do consultório: orçamento, receita, atestado, termo de
// consentimento e orientações. Gerados com pdf-lib e as fontes padrão do PDF
// (codificação WinAnsi: acentos do português funcionam; símbolos fora dela
// são trocados por equivalentes em `limparTexto`).
//
// A aparência toda (cores do site, fontes, tamanhos, textos fixos) mora em
// TEMA: para mudar o visual, mude só ele.

import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from "pdf-lib";

// ---------------------------------------------------------------------------
// Tema
// ---------------------------------------------------------------------------

export const TEMA = {
  cores: {
    verde: "#2C4A3E", // verde-floresta do site
    bege: "#F0EDE6",
    areia: "#D4C5A9",
    texto: "#2B2B2B",
    suave: "#6E6A63",
    branco: "#FFFFFF",
  },
  fontes: {
    titulo: StandardFonts.TimesRoman,
    tituloNegrito: StandardFonts.TimesRomanBold,
    texto: StandardFonts.Helvetica,
    negrito: StandardFonts.HelveticaBold,
    italico: StandardFonts.HelveticaOblique,
  },
  tamanhos: { nome: 19, titulo: 17, secao: 12.5, texto: 9.5, pequeno: 8, destaque: 15, rodape: 7.5 },
  pagina: { largura: 595.28, altura: 841.89, margem: 50, cabecalho: 74, rodape: 46 }, // A4, em pontos
  textos: {
    orcamentoIntro:
      "Este é o seu plano de tratamento, organizado em etapas. Cada item traz uma explicação simples do que será feito.",
    orcamentoComoFunciona: [
      "Os valores valem até a data de validade acima e incluem todas as sessões de cada procedimento.",
      "Se durante o tratamento aparecer algo que não estava previsto, conversamos antes de qualquer mudança.",
      "O tratamento pode ser feito por etapas, na ordem das fases.",
    ],
    orcamentoAceite: "Li e aceito o plano de tratamento acima e a forma de pagamento escolhida.",
    receitaAntibiotico:
      "Receita de antimicrobiano: válida por 10 dias a partir da data de emissão. A 1ª via fica retida na farmácia.",
    orientacoesContato: "Dúvidas ou qualquer sinal diferente do esperado: fale com a Dra. pelo WhatsApp",
  },
};

const FASES = [
  "Urgência e preparo da boca",
  "Tratamento da gengiva",
  "Tratamento de canal",
  "Restaurações",
  "Prótese e implante",
  "Estética",
  "Manutenção",
];

// ---------------------------------------------------------------------------
// Tipos dos dados (vêm das funções do banco)
// ---------------------------------------------------------------------------

export interface Cabecalho {
  nome?: string;
  dentista?: string;
  especialidade?: string;
  cro?: string;
  endereco?: string;
  cidade?: string;
  uf?: string;
  telefone?: string;
  whatsapp?: string;
  email?: string;
  instagram?: string;
  site?: string;
}

export interface Paciente {
  id?: string;
  nome: string;
  nome_civil?: string;
  cpf?: string;
  data_nascimento?: string;
  idade?: number;
  endereco?: string;
  telefone?: string;
  ficha?: number;
  responsavel?: { nome: string; cpf?: string; parentesco?: string };
}

export interface ItemOrcamento {
  ordem: number;
  descricao: string;
  explicacao?: string;
  local?: string;
  quantidade: number;
  valor_unitario: number;
  valor_total: number;
  fase: number;
  alternativa?: string;
  status: string;
  conta?: boolean;
}

export interface Pagamento {
  a_vista: { valor: number; desconto_pct: number; economia?: number };
  cartao?: { parcelas: number; valor_parcela: number };
  entrada_mais_parcelas?: { entrada: number; entrada_pct: number; parcelas: number; valor_parcela: number };
  destacar_parcela?: boolean;
}

export interface OpcaoOrcamento {
  alternativa?: string;
  subtotal: number;
  desconto?: number;
  total: number;
  pagamento: Pagamento;
}

export interface Orcamento {
  numero: number;
  versao: number;
  rotulo?: string;
  titulo?: string;
  status: string;
  status_texto?: string;
  emitido_em: string;
  validade: string;
  paciente: Paciente;
  cabecalho: Cabecalho;
  profissional?: string;
  cro?: string;
  itens: ItemOrcamento[];
  fases?: { fase: number; nome: string; subtotal: number }[];
  opcoes: OpcaoOrcamento[];
  total?: number;
  desconto?: { tipo: string; valor: number };
  aprovado_em?: string;
  aprovacao?: string;
  forma_escolhida?: string;
  observacoes?: string;
}

export interface ItemReceita {
  nome: string;
  concentracao?: string;
  forma?: string;
  via?: string;
  via_texto?: string;
  quantidade?: string;
  posologia: string;
  antibiotico?: boolean;
}

export interface Receita {
  numero: number;
  data: string;
  data_extenso?: string;
  paciente: Paciente;
  cabecalho: Cabecalho;
  itens: ItemReceita[];
  orientacoes?: string;
  peso_kg?: number;
  duas_vias?: boolean;
  profissional?: string;
  cro?: string;
}

export interface Atestado {
  numero: number;
  tipo: string;
  titulo: string;
  data: string;
  data_extenso?: string;
  texto: string;
  paciente: Paciente;
  cabecalho: Cabecalho;
  profissional?: string;
  cro?: string;
}

export interface Termo {
  numero: number;
  tipo: "consentimento" | "orientacoes";
  titulo: string;
  procedimento?: string;
  secoes: { titulo: string; texto: string }[];
  observacoes?: string;
  declaracao?: string;
  responsavel?: { nome: string; cpf?: string; parentesco?: string };
  data: string;
  data_extenso?: string;
  paciente: Paciente;
  cabecalho: Cabecalho;
  profissional?: string;
  cro?: string;
}

export type TipoDocumento = "orcamento" | "receita" | "atestado" | "termo" | "orientacoes";

// ---------------------------------------------------------------------------
// Formatação
// ---------------------------------------------------------------------------

// Caracteres além do Latin-1 que a codificação WinAnsi tem.
const WIN_ANSI_EXTRAS = new Set("€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ");
const TROCAS: Record<string, string> = {
  "→": "->",
  "←": "<-",
  "≤": "<=",
  "≥": ">=",
  "≈": "~",
  "×": "x",
  " ": " ",
  " ": " ",
  "‑": "-",
  "−": "-",
  "✓": "v",
  "…": "...",
};

/** Deixa o texto só com caracteres que as fontes padrão do PDF conseguem desenhar. */
export function limparTexto(texto: string): string {
  let saida = "";
  for (const c of texto.replace(/\r/g, "")) {
    if (c === "\n" || c === "\t") {
      saida += c === "\t" ? " " : c;
      continue;
    }
    if (c in TROCAS) {
      saida += TROCAS[c];
      continue;
    }
    const cod = c.codePointAt(0)!;
    if ((cod >= 0x20 && cod <= 0x7e) || (cod >= 0xa0 && cod <= 0xff) || WIN_ANSI_EXTRAS.has(c)) {
      saida += c;
      continue;
    }
    const base = c.normalize("NFD").replace(/\p{M}/gu, "");
    if (base && base !== c && [...base].every((b) => b.codePointAt(0)! <= 0xff)) saida += base;
    // o resto (emoji, símbolos raros) é descartado
  }
  return saida;
}

const MOEDA = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
export const reais = (v: number) => MOEDA.format(Number(v) || 0);

export function dataBR(iso?: string): string {
  if (!iso) return "";
  const [a, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${a}`;
}

export function telefoneBR(t?: string): string {
  if (!t) return "";
  const d = t.replace(/\D/g, "").replace(/^55(?=\d{10,11}$)/, "");
  if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`;
  if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`;
  return t;
}

export function cpfBR(c?: string): string {
  if (!c) return "";
  const d = c.replace(/\D/g, "");
  return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : c;
}

function cor(hex: string) {
  const n = parseInt(hex.replace("#", ""), 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

// ---------------------------------------------------------------------------
// Folha: páginas com cabeçalho, quebra automática e rodapé
// ---------------------------------------------------------------------------

interface Fontes {
  titulo: PDFFont;
  tituloNegrito: PDFFont;
  texto: PDFFont;
  negrito: PDFFont;
  italico: PDFFont;
}

interface OpcoesTexto {
  fonte?: PDFFont;
  tamanho?: number;
  cor?: string;
  x?: number;
  largura?: number;
  entrelinha?: number;
  alinhar?: "esquerda" | "direita" | "centro";
}

const P = TEMA.pagina;
const ESQ = P.margem;
const DIR = P.largura - P.margem;
const LARGURA = DIR - ESQ;

class Folha {
  paginas: PDFPage[] = [];
  pagina!: PDFPage;
  y = 0;

  constructor(
    readonly doc: PDFDocument,
    readonly f: Fontes,
    readonly cab: Cabecalho,
    readonly rotulo: { titulo: string; detalhe?: string },
  ) {}

  nova() {
    this.pagina = this.doc.addPage([P.largura, P.altura]);
    this.paginas.push(this.pagina);
    this.desenharCabecalho();
    this.y = P.altura - P.cabecalho - 26;
  }

  /** Garante espaço vertical; se não couber, vai para a próxima página. */
  espaco(altura: number) {
    if (this.y - altura < P.rodape + 14) this.nova();
  }

  pular(altura: number) {
    this.y -= altura;
  }

  largura(texto: string, fonte: PDFFont, tamanho: number) {
    return fonte.widthOfTextAtSize(limparTexto(texto), tamanho);
  }

  /** Quebra o texto em linhas que cabem na largura. */
  linhas(texto: string, fonte: PDFFont, tamanho: number, largura: number): string[] {
    const saida: string[] = [];
    for (const paragrafo of limparTexto(texto).split("\n")) {
      let atual = "";
      for (const palavra of paragrafo.split(/ +/)) {
        const tentativa = atual ? `${atual} ${palavra}` : palavra;
        if (fonte.widthOfTextAtSize(tentativa, tamanho) <= largura || !atual) {
          atual = tentativa;
        } else {
          saida.push(atual);
          atual = palavra;
        }
      }
      saida.push(atual);
    }
    return saida;
  }

  /** Escreve texto com quebra de linha e de página. Devolve a altura usada. */
  texto(texto: string, o: OpcoesTexto = {}): number {
    const fonte = o.fonte ?? this.f.texto;
    const tamanho = o.tamanho ?? TEMA.tamanhos.texto;
    const x = o.x ?? ESQ;
    const largura = o.largura ?? DIR - x;
    const passo = tamanho * (o.entrelinha ?? 1.4);
    const linhas = this.linhas(texto, fonte, tamanho, largura);
    for (const linha of linhas) {
      this.espaco(passo);
      const w = fonte.widthOfTextAtSize(linha, tamanho);
      const xx = o.alinhar === "direita" ? x + largura - w : o.alinhar === "centro" ? x + (largura - w) / 2 : x;
      this.pagina.drawText(linha, {
        x: xx,
        y: this.y - tamanho,
        size: tamanho,
        font: fonte,
        color: cor(o.cor ?? TEMA.cores.texto),
      });
      this.y -= passo;
    }
    return linhas.length * passo;
  }

  /** Texto numa posição fixa da linha atual, sem mexer no y. */
  em(texto: string, x: number, y: number, o: OpcoesTexto = {}) {
    const fonte = o.fonte ?? this.f.texto;
    const tamanho = o.tamanho ?? TEMA.tamanhos.texto;
    const t = limparTexto(texto);
    const w = fonte.widthOfTextAtSize(t, tamanho);
    const xx = o.alinhar === "direita" ? x - w : o.alinhar === "centro" ? x - w / 2 : x;
    this.pagina.drawText(t, { x: xx, y, size: tamanho, font: fonte, color: cor(o.cor ?? TEMA.cores.texto) });
  }

  caixa(x: number, y: number, w: number, h: number, fundo?: string, borda?: string) {
    this.pagina.drawRectangle({
      x,
      y,
      width: w,
      height: h,
      color: fundo ? cor(fundo) : undefined,
      borderColor: borda ? cor(borda) : undefined,
      borderWidth: borda ? 0.8 : 0,
    });
  }

  traco(x1: number, x2: number, y: number, espessura = 0.6, c = TEMA.cores.areia) {
    this.pagina.drawLine({ start: { x: x1, y }, end: { x: x2, y }, thickness: espessura, color: cor(c) });
  }

  /** Título de seção com fio cor de areia embaixo. */
  secao(titulo: string) {
    this.espaco(40);
    this.pular(8);
    this.texto(titulo, { fonte: this.f.titulo, tamanho: TEMA.tamanhos.secao, cor: TEMA.cores.verde, entrelinha: 1.25 });
    this.traco(ESQ, DIR, this.y - 1);
    this.pular(10);
  }

  /** Rótulo pequeno em caixa alta, espaçado (à maneira do site). */
  rotuloEspacado(texto: string, x: number, y: number, tamanho: number, c: string, alinhar: "esquerda" | "direita") {
    const t = limparTexto(texto.toUpperCase());
    const espaco = tamanho * 0.18;
    const largura = [...t].reduce((s, ch) => s + this.f.negrito.widthOfTextAtSize(ch, tamanho) + espaco, -espaco);
    let xx = alinhar === "direita" ? x - largura : x;
    for (const ch of t) {
      this.pagina.drawText(ch, { x: xx, y, size: tamanho, font: this.f.negrito, color: cor(c) });
      xx += this.f.negrito.widthOfTextAtSize(ch, tamanho) + espaco;
    }
  }

  private desenharCabecalho() {
    const topo = P.altura;
    this.caixa(0, topo - P.cabecalho, P.largura, P.cabecalho, TEMA.cores.verde);
    this.caixa(0, topo - P.cabecalho - 3, P.largura, 3, TEMA.cores.areia);
    const nome = this.cab.dentista ?? this.cab.nome ?? "";
    this.em(nome, ESQ, topo - 36, { fonte: this.f.titulo, tamanho: TEMA.tamanhos.nome, cor: TEMA.cores.bege });
    const linha2 = [this.cab.especialidade, this.cab.cro].filter(Boolean).join("  ·  ");
    this.em(linha2, ESQ, topo - 53, { tamanho: TEMA.tamanhos.pequeno, cor: TEMA.cores.areia });
    this.rotuloEspacado(this.rotulo.titulo, DIR, topo - 34, 8.5, TEMA.cores.areia, "direita");
    if (this.rotulo.detalhe) {
      this.em(this.rotulo.detalhe, DIR, topo - 50, {
        tamanho: TEMA.tamanhos.pequeno + 0.5,
        cor: TEMA.cores.bege,
        alinhar: "direita",
      });
    }
  }

  /** Rodapé com contatos e número da página (no fim, quando já se sabe o total). */
  finalizar() {
    const c = this.cab;
    const endereco = [c.endereco, [c.cidade, c.uf].filter(Boolean).join("/")].filter(Boolean).join(" · ");
    const contatos = [
      c.whatsapp ? `WhatsApp ${telefoneBR(c.whatsapp)}` : c.telefone ? telefoneBR(c.telefone) : "",
      c.instagram ?? "",
      (c.site ?? "").replace(/^https?:\/\//, ""),
    ].filter(Boolean).join("  ·  ");
    const total = this.paginas.length;
    this.paginas.forEach((p, i) => {
      this.pagina = p;
      this.traco(ESQ, DIR, P.rodape - 6, 0.5);
      this.em(endereco, P.largura / 2, P.rodape - 20, {
        tamanho: TEMA.tamanhos.rodape,
        cor: TEMA.cores.suave,
        alinhar: "centro",
      });
      this.em(contatos, P.largura / 2, P.rodape - 31, {
        tamanho: TEMA.tamanhos.rodape,
        cor: TEMA.cores.suave,
        alinhar: "centro",
      });
      if (total > 1) {
        this.em(`${i + 1}/${total}`, DIR, P.rodape - 20, {
          tamanho: TEMA.tamanhos.rodape,
          cor: TEMA.cores.suave,
          alinhar: "direita",
        });
      }
    });
  }
}

async function novoDocumento(titulo: string, cab: Cabecalho, rotulo: { titulo: string; detalhe?: string }) {
  const doc = await PDFDocument.create();
  doc.setTitle(limparTexto(titulo));
  doc.setAuthor(limparTexto(cab.dentista ?? cab.nome ?? "Consultório"));
  doc.setCreator("Consultório (servidor MCP)");
  doc.setProducer("pdf-lib");
  doc.setLanguage("pt-BR");
  const f: Fontes = {
    titulo: await doc.embedFont(TEMA.fontes.titulo),
    tituloNegrito: await doc.embedFont(TEMA.fontes.tituloNegrito),
    texto: await doc.embedFont(TEMA.fontes.texto),
    negrito: await doc.embedFont(TEMA.fontes.negrito),
    italico: await doc.embedFont(TEMA.fontes.italico),
  };
  const folha = new Folha(doc, f, cab, rotulo);
  folha.nova();
  return { doc, f, folha };
}

/** Caixa bege com pares rótulo: valor (dados do paciente). */
function blocoPaciente(folha: Folha, linhas: [string, string][]) {
  const f = folha.f;
  const tam = TEMA.tamanhos.texto;
  const visiveis = linhas.filter(([, v]) => v);
  const altura = visiveis.length * tam * 1.55 + 16;
  folha.espaco(altura + 6);
  folha.caixa(ESQ, folha.y - altura, LARGURA, altura, TEMA.cores.bege);
  let y = folha.y - 12 - tam;
  for (const [rotulo, valor] of visiveis) {
    folha.em(rotulo, ESQ + 12, y, { fonte: f.negrito, tamanho: tam, cor: TEMA.cores.verde });
    folha.em(valor, ESQ + 12 + folha.largura(rotulo, f.negrito, tam) + 5, y, { tamanho: tam });
    y -= tam * 1.55;
  }
  folha.pular(altura + 10);
}

/** Local, data e linha de assinatura. */
function assinatura(
  folha: Folha,
  cidade: string,
  dataExtenso: string,
  nome: string,
  detalhe?: string,
  x = ESQ,
  largura = 230,
) {
  folha.pular(18);
  folha.espaco(90);
  if (cidade || dataExtenso) {
    folha.texto(`${[cidade, dataExtenso].filter(Boolean).join(", ")}.`, { x, largura: DIR - x });
  }
  folha.pular(34);
  assinaturaLinha(folha, nome, detalhe, x, largura);
}

function assinaturaLinha(
  folha: Folha,
  nome: string,
  detalhe: string | undefined,
  x: number,
  largura: number,
  y = folha.y,
) {
  folha.traco(x, x + largura, y, 0.7, TEMA.cores.texto);
  folha.em(nome, x + largura / 2, y - 12, { tamanho: TEMA.tamanhos.texto, alinhar: "centro" });
  if (detalhe) {
    folha.em(detalhe, x + largura / 2, y - 23, {
      tamanho: TEMA.tamanhos.pequeno,
      cor: TEMA.cores.suave,
      alinhar: "centro",
    });
  }
}

// ---------------------------------------------------------------------------
// Orçamento
// ---------------------------------------------------------------------------

function itensDaFase(folha: Folha, itens: ItemOrcamento[]) {
  const f = folha.f;
  const tam = TEMA.tamanhos.texto;
  const colLocal = ESQ + 300;
  const larguraDesc = 290;
  for (const it of itens) {
    const desc = folha.linhas(it.descricao, f.negrito, tam, larguraDesc);
    const expl = it.explicacao ? folha.linhas(it.explicacao, f.texto, TEMA.tamanhos.pequeno, larguraDesc) : [];
    const altura = desc.length * tam * 1.35 + expl.length * TEMA.tamanhos.pequeno * 1.35 + (it.quantidade > 1 ? 4 : 0) +
      8;
    folha.espaco(altura);
    const topo = folha.y;
    let y = topo - tam;
    for (const l of desc) {
      folha.em(l, ESQ, y, { fonte: f.negrito, tamanho: tam });
      y -= tam * 1.35;
    }
    for (const l of expl) {
      folha.em(l, ESQ, y + 1, { tamanho: TEMA.tamanhos.pequeno, cor: TEMA.cores.suave });
      y -= TEMA.tamanhos.pequeno * 1.35;
    }
    if (it.local) folha.em(it.local, colLocal, topo - tam, { tamanho: tam, cor: TEMA.cores.suave });
    folha.em(reais(it.valor_total), DIR, topo - tam, { fonte: f.negrito, tamanho: tam, alinhar: "direita" });
    if (it.quantidade > 1) {
      folha.em(`${it.quantidade} x ${reais(it.valor_unitario)}`, DIR, topo - tam * 2.35, {
        tamanho: TEMA.tamanhos.pequeno,
        cor: TEMA.cores.suave,
        alinhar: "direita",
      });
    }
    folha.y = Math.min(y, topo - tam * 2.4) - 4;
    folha.traco(ESQ, DIR, folha.y + 3, 0.3, TEMA.cores.bege);
  }
}

function porFase(itens: ItemOrcamento[]) {
  const grupos = new Map<number, ItemOrcamento[]>();
  for (const it of [...itens].sort((a, b) => a.fase - b.fase || a.ordem - b.ordem)) {
    grupos.set(it.fase, [...(grupos.get(it.fase) ?? []), it]);
  }
  return grupos;
}

function linhaTotal(folha: Folha, rotulo: string, valor: string, forte = false) {
  const tam = forte ? TEMA.tamanhos.texto + 1.5 : TEMA.tamanhos.texto;
  folha.espaco(tam * 1.8);
  const fonte = forte ? folha.f.negrito : folha.f.texto;
  const c = forte ? TEMA.cores.verde : TEMA.cores.texto;
  folha.em(rotulo, DIR - 130, folha.y - tam, { fonte, tamanho: tam, cor: c, alinhar: "direita" });
  folha.em(valor, DIR, folha.y - tam, { fonte, tamanho: tam, cor: c, alinhar: "direita" });
  folha.pular(tam * 1.7);
}

/** Três cartões lado a lado: à vista, cartão, entrada + parcelas. */
function cartoesPagamento(folha: Folha, op: OpcaoOrcamento) {
  const f = folha.f;
  const pg = op.pagamento;
  type Cartao = { titulo: string; grande: string; pequeno: string[] };
  const cartoes: Cartao[] = [];
  const economia = pg.a_vista.economia && pg.a_vista.economia > 0
    ? [`economia de ${reais(pg.a_vista.economia)} (${String(pg.a_vista.desconto_pct).replace(".", ",")}%)`]
    : [];
  cartoes.push({
    titulo: "À vista",
    grande: reais(pg.a_vista.valor),
    pequeno: ["Pix, dinheiro ou débito", ...economia],
  });
  if (pg.cartao && pg.cartao.parcelas > 1) {
    const parcela = `${pg.cartao.parcelas}x de ${reais(pg.cartao.valor_parcela)}`;
    cartoes.push(
      pg.destacar_parcela
        ? { titulo: "Cartão de crédito", grande: parcela, pequeno: [`total ${reais(op.total)}`] }
        : { titulo: "Cartão de crédito", grande: reais(op.total), pequeno: [`em até ${parcela}`] },
    );
  } else if (pg.cartao) {
    cartoes.push({ titulo: "Cartão de crédito", grande: reais(op.total), pequeno: ["à vista no crédito"] });
  }
  const e = pg.entrada_mais_parcelas;
  if (e) {
    cartoes.push({
      titulo: "Entrada + parcelas",
      grande: `${e.parcelas}x de ${reais(e.valor_parcela)}`,
      pequeno: [`entrada de ${reais(e.entrada)} (${String(e.entrada_pct).replace(".", ",")}%)`, "e parcelas mensais"],
    });
  }

  const gap = 10;
  const w = (LARGURA - gap * (cartoes.length - 1)) / cartoes.length;
  const h = 78;
  folha.espaco(h + 8);
  const topo = folha.y;
  cartoes.forEach((c, i) => {
    const x = ESQ + i * (w + gap);
    folha.caixa(x, topo - h, w, h, TEMA.cores.bege, TEMA.cores.areia);
    folha.rotuloEspacado(c.titulo, x + 10, topo - 16, 7, TEMA.cores.verde, "esquerda");
    let tam = TEMA.tamanhos.destaque;
    while (tam > 9 && f.tituloNegrito.widthOfTextAtSize(limparTexto(c.grande), tam) > w - 20) tam -= 0.5;
    folha.em(c.grande, x + 10, topo - 40, { fonte: f.tituloNegrito, tamanho: tam, cor: TEMA.cores.verde });
    c.pequeno.forEach((l, k) =>
      folha.em(l, x + 10, topo - 55 - k * 10, { tamanho: TEMA.tamanhos.pequeno - 0.5, cor: TEMA.cores.suave })
    );
  });
  folha.y = topo - h - 10;
}

export async function pdfOrcamento(o: Orcamento): Promise<Uint8Array> {
  const versao = o.versao > 1 ? ` · versão ${o.versao}` : "";
  const { doc, f, folha } = await novoDocumento(o.rotulo ?? `Orçamento nº ${o.numero}`, o.cabecalho, {
    titulo: "Plano de tratamento",
    detalhe: `Orçamento nº ${o.numero}${versao}`,
  });

  folha.texto(o.titulo && o.titulo !== "Plano de tratamento" ? o.titulo : "Plano de tratamento e orçamento", {
    fonte: f.titulo,
    tamanho: TEMA.tamanhos.titulo,
    cor: TEMA.cores.verde,
  });
  if (o.status === "rascunho") {
    folha.texto("Rascunho: sujeito a alteração.", {
      fonte: f.italico,
      tamanho: TEMA.tamanhos.pequeno,
      cor: TEMA.cores.suave,
    });
  }
  folha.pular(6);
  const aprovado = ["aprovado", "parcial", "concluido"].includes(o.status);
  blocoPaciente(folha, [
    ["Paciente:", o.paciente.nome + (o.paciente.ficha ? `   (ficha ${o.paciente.ficha})` : "")],
    ["Responsável:", o.paciente.responsavel?.nome ?? ""],
    ["Emitido em:", dataBR(o.emitido_em)],
    [
      aprovado ? "Aprovado em:" : "Válido até:",
      aprovado ? `${dataBR(o.aprovado_em)}${o.aprovacao === "parcial" ? " (em parte)" : ""}` : dataBR(o.validade),
    ],
  ]);
  folha.texto(TEMA.textos.orcamentoIntro, { tamanho: TEMA.tamanhos.texto, cor: TEMA.cores.suave });

  const contam = o.itens.filter((i) => i.conta !== false && i.status !== "cancelado");
  const varias = o.opcoes.length > 1;
  const comuns = varias ? contam.filter((i) => !i.alternativa) : contam;
  const nomes = new Map((o.fases ?? []).map((x) => [x.fase, x.nome]));

  for (const [fase, itens] of porFase(comuns)) {
    folha.secao(`Fase ${fase} · ${nomes.get(fase) ?? FASES[fase - 1] ?? ""}`);
    itensDaFase(folha, itens);
    if (porFase(comuns).size > 1) {
      linhaTotal(folha, "Subtotal da fase", reais(itens.reduce((s, i) => s + Number(i.valor_total), 0)));
    }
  }

  if (varias) {
    folha.secao("Opções de tratamento");
    folha.texto("Há mais de um caminho possível. Escolha uma das opções abaixo; os itens das outras não entram.", {
      tamanho: TEMA.tamanhos.texto,
      cor: TEMA.cores.suave,
    });
    for (const op of o.opcoes) {
      const itens = contam.filter((i) => i.alternativa === op.alternativa);
      folha.espaco(80);
      folha.pular(6);
      folha.texto(`Opção ${op.alternativa}`, {
        fonte: f.negrito,
        tamanho: TEMA.tamanhos.texto + 1,
        cor: TEMA.cores.verde,
      });
      itensDaFase(folha, itens);
      linhaTotal(
        folha,
        `Subtotal da opção ${op.alternativa}`,
        reais(itens.reduce((s, i) => s + Number(i.valor_total), 0)),
      );
    }
  }

  folha.secao("Investimento");
  for (const op of o.opcoes) {
    if (varias) {
      folha.espaco(110);
      folha.texto(`Tratamento com a opção ${op.alternativa}`, { fonte: f.negrito, cor: TEMA.cores.verde });
    }
    if (op.desconto) {
      linhaTotal(folha, "Soma dos itens", reais(op.subtotal));
      const pct = o.desconto?.tipo === "percentual" ? ` (${String(o.desconto.valor).replace(".", ",")}%)` : "";
      linhaTotal(folha, `Desconto${pct}`, `- ${reais(op.desconto)}`);
    }
    linhaTotal(folha, "Total", reais(op.total), true);
    folha.pular(4);
    cartoesPagamento(folha, op);
  }
  if (o.forma_escolhida) {
    folha.texto(`Forma de pagamento escolhida: ${o.forma_escolhida}.`, { fonte: f.negrito });
  }

  if (o.observacoes) {
    folha.secao("Observações");
    folha.texto(o.observacoes);
  }

  folha.secao("Como funciona");
  for (const l of [`Este orçamento vale até ${dataBR(o.validade)}.`, ...TEMA.textos.orcamentoComoFunciona]) {
    folha.texto(`•  ${l}`, { tamanho: TEMA.tamanhos.texto, x: ESQ + 4 });
  }

  // Aceite
  folha.espaco(150);
  folha.secao("Aceite");
  folha.texto(TEMA.textos.orcamentoAceite);
  if (varias) folha.texto("Opção escolhida:  (   ) " + o.opcoes.map((x) => x.alternativa).join("    (   ) "));
  folha.texto("Forma de pagamento: ____________________________________________");
  folha.pular(40);
  const y = folha.y;
  const quem = o.paciente.responsavel?.nome ?? o.paciente.nome;
  assinaturaLinha(folha, quem, o.paciente.responsavel ? "Responsável" : "Paciente", ESQ, 220, y);
  assinaturaLinha(folha, o.profissional ?? o.cabecalho.dentista ?? "", o.cro ?? o.cabecalho.cro, DIR - 220, 220, y);
  folha.y = y - 34;
  folha.texto("Data: ____/____/________", { tamanho: TEMA.tamanhos.pequeno, cor: TEMA.cores.suave });

  folha.finalizar();
  return doc.save();
}

// ---------------------------------------------------------------------------
// Receita
// ---------------------------------------------------------------------------

function viaDaReceita(folha: Folha, r: Receita, via?: string) {
  const f = folha.f;
  const tam = TEMA.tamanhos.texto + 0.5;
  folha.texto("Receituário", { fonte: f.titulo, tamanho: TEMA.tamanhos.titulo, cor: TEMA.cores.verde });
  if (via) folha.texto(via, { fonte: f.italico, tamanho: TEMA.tamanhos.pequeno, cor: TEMA.cores.suave });
  folha.pular(6);
  blocoPaciente(folha, [
    ["Paciente:", r.paciente.nome],
    ["Endereço:", r.paciente.endereco ?? ""],
    ["Peso:", r.peso_kg ? `${String(r.peso_kg).replace(".", ",")} kg` : ""],
  ]);

  const grupos = new Map<string, ItemReceita[]>();
  for (const it of r.itens) {
    grupos.set(it.via_texto ?? "Uso oral", [...(grupos.get(it.via_texto ?? "Uso oral") ?? []), it]);
  }
  let n = 0;
  for (const [viaTexto, itens] of grupos) {
    folha.espaco(30);
    folha.pular(6);
    folha.texto(viaTexto, { fonte: f.negrito, tamanho: tam, cor: TEMA.cores.verde });
    folha.pular(2);
    for (const it of itens) {
      n++;
      const nome = `${n}. ${[it.nome, it.concentracao].filter(Boolean).join(" ")}${it.forma ? `, ${it.forma}` : ""}`;
      folha.espaco(tam * 4);
      const yNome = folha.y - tam;
      folha.em(nome, ESQ + 4, yNome, { fonte: f.negrito, tamanho: tam });
      if (it.quantidade) {
        folha.em(it.quantidade, DIR, yNome, { tamanho: tam, alinhar: "direita" });
        const ini = ESQ + 10 + folha.largura(nome, f.negrito, tam);
        const fim = DIR - folha.largura(it.quantidade, f.texto, tam) - 6;
        if (fim > ini) {
          folha.pagina.drawLine({
            start: { x: ini, y: yNome + 1 },
            end: { x: fim, y: yNome + 1 },
            thickness: 0.6,
            color: cor(TEMA.cores.areia),
            dashArray: [1, 2.5],
          });
        }
      }
      folha.pular(tam * 1.5);
      folha.texto(it.posologia, { x: ESQ + 18, tamanho: tam, entrelinha: 1.45 });
      folha.pular(6);
    }
  }
  if (r.orientacoes) {
    folha.pular(4);
    folha.texto("Orientações", { fonte: f.negrito, tamanho: tam, cor: TEMA.cores.verde });
    folha.texto(r.orientacoes, { tamanho: tam });
  }
  if (r.duas_vias) {
    folha.pular(6);
    folha.texto(TEMA.textos.receitaAntibiotico, {
      fonte: f.italico,
      tamanho: TEMA.tamanhos.pequeno,
      cor: TEMA.cores.suave,
    });
  }
  // assinatura no pé da página, como no receituário de papel
  const pe = P.rodape + 120;
  if (folha.y - 110 > pe) folha.y = pe + 90;
  assinatura(
    folha,
    r.cabecalho.cidade ?? "",
    r.data_extenso ?? dataBR(r.data),
    r.profissional ?? r.cabecalho.dentista ?? "",
    r.cro ?? r.cabecalho.cro,
    DIR - 240,
    240,
  );
}

export async function pdfReceita(r: Receita): Promise<Uint8Array> {
  const { doc, folha } = await novoDocumento(`Receita nº ${r.numero}`, r.cabecalho, {
    titulo: "Receita",
    detalhe: `Nº ${r.numero} · ${dataBR(r.data)}`,
  });
  if (r.duas_vias) {
    viaDaReceita(folha, r, "1ª via: farmácia");
    folha.nova();
    viaDaReceita(folha, r, "2ª via: paciente");
  } else {
    viaDaReceita(folha, r);
  }
  folha.finalizar();
  return doc.save();
}

// ---------------------------------------------------------------------------
// Atestado / declaração
// ---------------------------------------------------------------------------

export async function pdfAtestado(a: Atestado): Promise<Uint8Array> {
  const { doc, f, folha } = await novoDocumento(`${a.titulo} nº ${a.numero}`, a.cabecalho, {
    titulo: a.tipo === "repouso" ? "Atestado" : "Declaração",
    detalhe: `Nº ${a.numero} · ${dataBR(a.data)}`,
  });
  folha.pular(40);
  folha.texto(a.titulo, {
    fonte: f.titulo,
    tamanho: TEMA.tamanhos.titulo + 3,
    cor: TEMA.cores.verde,
    alinhar: "centro",
  });
  folha.traco(P.largura / 2 - 40, P.largura / 2 + 40, folha.y - 4, 1);
  folha.pular(40);
  folha.texto(a.texto, { tamanho: TEMA.tamanhos.texto + 2.5, entrelinha: 1.8, x: ESQ + 20, largura: LARGURA - 40 });
  folha.pular(50);
  assinatura(
    folha,
    a.cabecalho.cidade ?? "",
    a.data_extenso ?? dataBR(a.data),
    a.profissional ?? a.cabecalho.dentista ?? "",
    a.cro ?? a.cabecalho.cro,
    P.largura / 2 - 130,
    260,
  );
  folha.finalizar();
  return doc.save();
}

// ---------------------------------------------------------------------------
// Termo de consentimento e orientações
// ---------------------------------------------------------------------------

export async function pdfTermo(t: Termo): Promise<Uint8Array> {
  const consentimento = t.tipo === "consentimento";
  const { doc, f, folha } = await novoDocumento(t.titulo, t.cabecalho, {
    titulo: consentimento ? "Consentimento" : "Orientações",
    detalhe: `Nº ${t.numero} · ${dataBR(t.data)}`,
  });
  folha.texto(t.titulo, { fonte: f.titulo, tamanho: TEMA.tamanhos.titulo, cor: TEMA.cores.verde });
  folha.pular(6);
  const resp = t.responsavel;
  blocoPaciente(
    folha,
    consentimento
      ? [
        ["Paciente:", t.paciente.nome],
        ["CPF:", cpfBR(t.paciente.cpf)],
        ["Nascimento:", dataBR(t.paciente.data_nascimento)],
        [
          "Responsável:",
          resp
            ? `${resp.nome}${resp.parentesco ? ` (${resp.parentesco})` : ""}${
              resp.cpf ? `, CPF ${cpfBR(resp.cpf)}` : ""
            }`
            : "",
        ],
        ["Profissional:", `${t.profissional ?? t.cabecalho.dentista ?? ""}, ${t.cro ?? t.cabecalho.cro ?? ""}`],
        ["Procedimento:", t.procedimento ?? ""],
      ]
      : [["Paciente:", t.paciente.nome], ["Data:", dataBR(t.data)]],
  );

  for (const s of t.secoes) {
    folha.espaco(46);
    folha.pular(4);
    if (consentimento) {
      folha.texto(s.titulo, { fonte: f.negrito, tamanho: TEMA.tamanhos.texto + 0.5, cor: TEMA.cores.verde });
      folha.texto(s.texto, { tamanho: TEMA.tamanhos.texto, entrelinha: 1.45 });
    } else {
      // orientações: cartões com fio verde à esquerda
      const linhas = folha.linhas(s.texto, f.texto, TEMA.tamanhos.texto + 0.5, LARGURA - 24);
      const h = (linhas.length + 1) * (TEMA.tamanhos.texto + 0.5) * 1.5 + 12;
      folha.espaco(h + 6);
      folha.caixa(ESQ, folha.y - h, LARGURA, h, TEMA.cores.bege);
      folha.caixa(ESQ, folha.y - h, 3, h, TEMA.cores.verde);
      folha.pular(8);
      folha.texto(s.titulo, { fonte: f.negrito, tamanho: TEMA.tamanhos.texto + 1, cor: TEMA.cores.verde, x: ESQ + 14 });
      folha.texto(s.texto, { tamanho: TEMA.tamanhos.texto + 0.5, x: ESQ + 14, largura: LARGURA - 24, entrelinha: 1.5 });
      folha.pular(8);
    }
  }

  if (t.observacoes) {
    folha.espaco(40);
    folha.pular(6);
    folha.texto(consentimento ? "Observações sobre o caso" : "Observações", {
      fonte: f.negrito,
      tamanho: TEMA.tamanhos.texto + 0.5,
      cor: TEMA.cores.verde,
    });
    folha.texto(t.observacoes);
  }

  if (consentimento) {
    folha.espaco(170);
    folha.pular(10);
    folha.texto("Declaração", { fonte: f.negrito, tamanho: TEMA.tamanhos.texto + 0.5, cor: TEMA.cores.verde });
    if (t.declaracao) folha.texto(t.declaracao, { entrelinha: 1.45 });
    folha.pular(10);
    folha.texto(`${t.cabecalho.cidade ?? ""}, ${t.data_extenso ?? dataBR(t.data)}.`);
    folha.pular(44);
    const y = folha.y;
    assinaturaLinha(folha, resp?.nome ?? t.paciente.nome, resp ? "Responsável legal" : "Paciente", ESQ, 220, y);
    assinaturaLinha(folha, t.profissional ?? t.cabecalho.dentista ?? "", t.cro ?? t.cabecalho.cro, DIR - 220, 220, y);
    folha.y = y - 30;
  } else {
    const contato = t.cabecalho.whatsapp ?? t.cabecalho.telefone;
    if (contato) {
      folha.pular(10);
      folha.texto(`${TEMA.textos.orientacoesContato} ${telefoneBR(contato)}.`, {
        fonte: f.negrito,
        cor: TEMA.cores.verde,
      });
    }
  }
  folha.finalizar();
  return doc.save();
}

// ---------------------------------------------------------------------------

/** Gera o PDF do tipo pedido a partir dos dados que o banco devolveu. */
export function gerarPdf(tipo: TipoDocumento, dados: unknown): Promise<Uint8Array> {
  switch (tipo) {
    case "orcamento":
      return pdfOrcamento(dados as Orcamento);
    case "receita":
      return pdfReceita(dados as Receita);
    case "atestado":
      return pdfAtestado(dados as Atestado);
    case "termo":
    case "orientacoes":
      return pdfTermo(dados as Termo);
  }
  return Promise.reject(new Error(`Tipo de documento desconhecido: ${tipo}`));
}

export async function sha256Bytes(bytes: Uint8Array): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>);
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
