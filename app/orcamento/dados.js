// Regras do formulário de orçamento do site, sem tela (testadas em
// tests/orcamento_site_test.ts): ler o dente ou a região, montar o pedido para o
// banco (mcp_montar_orcamento, pelo painel_gravar) e montar o PDF a partir do que
// o banco gravou. A tela (tela.js) só desenha e chama estas funções.

import { MESES, normalizar } from "../base.js";

// ------------------------------------------------------------------
// Números e datas
// ------------------------------------------------------------------

/** "1.234,56", "1234,56", "1234.56" ou "280" em número; vazio = null; 0 vale. */
export function lerNumero(texto) {
  let t = String(texto ?? "").replace(/[R$\s]/g, "");
  if (!t) return null;
  if (t.includes(",")) t = t.replace(/\./g, "").replace(",", ".");
  else if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, "");
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : null;
}

/** 280 -> "280,00"; 1234.5 -> "1.234,50" (para o campo de valor). */
export const valorNoCampo = (n) =>
  n == null ? "" : Number(n).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

const centavos = (n) => Math.round(n * 100) / 100;

/** "2026-11-24" -> "24 de novembro de 2026" (como no gerador antigo). */
export function porExtenso(iso) {
  const [a, m, d] = String(iso ?? "").slice(0, 10).split("-").map(Number);
  if (!a || !m || !d) return "—";
  return `${String(d).padStart(2, "0")} de ${MESES[m - 1]} de ${a}`;
}

export function somarDiasISO(iso, dias) {
  const [a, m, d] = String(iso).slice(0, 10).split("-").map(Number);
  const dt = new Date(Date.UTC(a, m - 1, d + dias));
  return dt.toISOString().slice(0, 10);
}

// ------------------------------------------------------------------
// Dente / região
// ------------------------------------------------------------------

/** Numeração FDI: permanentes 11–48, decíduos 51–85. */
export function denteValido(n) {
  const q = Math.floor(n / 10), u = n % 10;
  return (q >= 1 && q <= 4 && u >= 1 && u <= 8) || (q >= 5 && q <= 8 && u >= 1 && u <= 5);
}

const REGIOES = {
  "boca": "boca",
  "boca toda": "boca",
  "toda a boca": "boca",
  "toda boca": "boca",
  "arcada superior": "arcada_superior",
  "superior": "arcada_superior",
  "arcada inferior": "arcada_inferior",
  "inferior": "arcada_inferior",
};

/** O mesmo texto que o banco usa no orçamento (orcamento_local). */
export function rotuloLocal({ dente, faces, regiao, observacao } = {}) {
  if (dente) return `Dente ${dente}${faces ? ` (${faces})` : ""}`;
  if (regiao === "boca") return "Boca toda";
  if (regiao === "arcada_superior") return "Arcada superior";
  if (regiao === "arcada_inferior") return "Arcada inferior";
  if (/^S[1-6]$/.test(regiao ?? "")) return `Sextante ${regiao.slice(1)}`;
  if (/^Q[1-8]$/.test(regiao ?? "")) return `Quadrante ${regiao.slice(1)}`;
  return observacao ?? "";
}

/**
 * O que ela escreveu em "Dente / região" vira os campos do banco:
 * "36" ou "36 MO" = dente (e faces); "boca toda", "arcada superior",
 * "quadrante 2", "S3" = região; qualquer outra coisa ("11 e 21", "região
 * posterior") fica como texto, do jeito que ela escreveu.
 */
export function lerLocal(texto) {
  const t = String(texto ?? "").trim().replace(/\s+/g, " ");
  if (!t) return {};
  const m = t.match(/^(?:dente\s*)?(\d{2})(?:\s*[-–/]?\s*\(?\s*([mdoivlpb]{1,5})\s*\)?)?$/i);
  if (m && denteValido(Number(m[1]))) {
    return m[2] ? { dente: Number(m[1]), faces: m[2].toUpperCase() } : { dente: Number(m[1]) };
  }
  const n = normalizar(t);
  if (REGIOES[n]) return { regiao: REGIOES[n] };
  const q = n.match(/^(?:q|quadrante)\s*([1-8])$/);
  if (q) return { regiao: `Q${q[1]}` };
  const s = n.match(/^(?:s|sextante)\s*([1-6])$/);
  if (s) return { regiao: `S${s[1]}` };
  return { regiao: "outra", observacao: t.slice(0, 120) };
}

// ------------------------------------------------------------------
// Catálogo e campanhas
// ------------------------------------------------------------------

/** Preço do procedimento na campanha escolhida (ou o normal). */
export function precoDe(proc, campanha) {
  if (!proc) return null;
  const daCampanha = campanha?.precos?.[proc.codigo];
  return daCampanha != null ? Number(daCampanha) : proc.preco != null ? Number(proc.preco) : null;
}

/** Campanha que já vem escolhida: a do orçamento que vai ser substituído, ou a de hoje. */
export function campanhaInicial(base, substituir) {
  const aberto = base?.paciente?.aberto;
  if (substituir && aberto?.campanha_id) return aberto.campanha_id;
  return (base?.campanhas ?? []).find((c) => c.hoje)?.id ?? "";
}

/** Grupos do catálogo na ordem em que aparecem (como a tabela do site antigo). */
export function agrupar(procedimentos) {
  const grupos = [];
  for (const p of procedimentos ?? []) {
    let g = grupos.find((x) => x.grupo === p.grupo);
    if (!g) grupos.push(g = { grupo: p.grupo, itens: [] });
    g.itens.push(p);
  }
  return grupos;
}

// ------------------------------------------------------------------
// Estado do formulário -> pedido ao banco
// ------------------------------------------------------------------

/**
 * @typedef {{ codigo?: string, nome_base?: string, preco_base?: number|null, descricao: string,
 *   local: string, qtd: string|number, valor: string|number }} LinhaForm
 */

const linhaVazia = (l) => !String(l.descricao ?? "").trim() && lerNumero(l.valor) == null && !l.codigo;

/** Fase em que o banco põe o item (para a prévia sair na mesma ordem do PDF). */
function faseDa(linha, base) {
  const proc = linha.codigo
    ? base.procedimentos.find((p) => p.codigo === linha.codigo)
    : base.procedimentos.find((p) => normalizar(p.nome) === normalizar(linha.descricao));
  return proc?.fase ?? 4;
}

/** Linhas válidas, cada uma com o que o banco vai receber, na ordem do banco. */
export function linhasDoForm(estado, base) {
  return (estado.itens ?? [])
    .map((l, i) => ({ l, i }))
    .filter(({ l }) => !linhaVazia(l))
    .map(({ l, i }) => {
      const local = lerLocal(l.local);
      return {
        indice: i,
        linha: l,
        local,
        fase: faseDa(l, base),
        descricao: String(l.descricao ?? "").trim(),
        qtd: Number(String(l.qtd ?? "").trim() || 1),
        valor: lerNumero(l.valor),
      };
    })
    .sort((a, b) => a.fase - b.fase || (a.local.dente ?? 999) - (b.local.dente ?? 999) || a.indice - b.indice);
}

/** Subtotal, desconto e total como o banco calcula (orcamento_opcao). */
export function contas(estado, linhas) {
  const subtotal = centavos(linhas.reduce((s, x) => s + (x.valor ?? 0) * (Number.isInteger(x.qtd) ? x.qtd : 0), 0));
  const bruto = lerNumero(estado.desconto) ?? 0;
  const desconto = estado.desconto_tipo === "pct"
    ? centavos(subtotal * Math.min(bruto, 100) / 100)
    : Math.min(bruto, subtotal);
  return { subtotal, desconto, total: centavos(subtotal - desconto) };
}

/**
 * Confere o formulário e monta o pedido para painel_gravar tipo "orcamento".
 * Devolve { erros } ou { dados }.
 */
export function montarPedido(estado, base) {
  const erros = [];
  if (!estado.paciente_id) erros.push("Escolha o paciente.");
  const linhas = linhasDoForm(estado, base);
  if (!linhas.length) erros.push("Adicione pelo menos um procedimento.");
  const campanha = (base.campanhas ?? []).find((c) => c.id === estado.campanha_id) ?? null;

  const itens = [];
  for (const x of linhas) {
    const nome = x.descricao || x.linha.nome_base || "";
    const rotulo = nome || `linha ${x.indice + 1}`;
    if (!nome) erros.push(`Falta o nome do procedimento na ${rotulo}.`);
    if (x.valor == null) erros.push(`Falta o valor de “${rotulo}”.`);
    if (!Number.isInteger(x.qtd) || x.qtd < 1 || x.qtd > 99) erros.push(`A quantidade de “${rotulo}” vai de 1 a 99.`);
    const item = {};
    const proc = x.linha.codigo ? base.procedimentos.find((p) => p.codigo === x.linha.codigo) : null;
    if (proc) {
      item.procedimento_codigo = proc.codigo;
      if (nome && nome !== proc.nome) item.descricao = nome;
      // Valor só quando ela mudou: assim o banco aplica a mesma regra de preço
      // do Claude (campanha, troca de resina pelo número de faces etc.).
      const preco = precoDe(proc, campanha);
      if (x.valor != null && (preco == null || x.valor !== preco)) item.valor = x.valor;
    } else {
      item.procedimento = nome;
      if (x.valor != null) item.valor = x.valor;
    }
    Object.assign(item, x.local);
    item.quantidade = x.qtd;
    itens.push(item);
  }

  const validade = Number(String(estado.validade_dias ?? "").trim() || base.validade_dias || 30);
  if (!Number.isInteger(validade) || validade < 1 || validade > 180) erros.push("A validade vai de 1 a 180 dias.");
  const parcelas = Number(String(estado.parcelas ?? "").trim() || 0);
  if (!Number.isInteger(parcelas) || parcelas < 0 || parcelas > 24) erros.push("Parcelar vai de 0 a 24 vezes.");
  const desconto = lerNumero(estado.desconto);
  if (String(estado.desconto ?? "").trim() && desconto == null) erros.push("Desconto inválido.");
  if (estado.desconto_tipo === "pct" && desconto > 100) erros.push("O desconto vai até 100%.");
  const { subtotal, total } = contas(estado, linhas);
  if (estado.desconto_tipo !== "pct" && desconto > subtotal) erros.push("O desconto passa do valor do tratamento.");
  if (erros.length) return { erros };

  const dados = {
    paciente_id: estado.paciente_id,
    itens,
    incluir_odontograma: false,
    validade_dias: validade,
    campanha: campanha?.id ?? "nenhuma",
    // O PDF do site mostra o total (ou "Nx de"), sem desconto à vista nem
    // entrada: o registro guarda as mesmas condições que o paciente vê.
    pagamento: {
      desconto_a_vista_pct: 0,
      entrada_pct: 0,
      cartao_parcelas_max: Math.max(1, parcelas),
      parcela_minima: 1,
    },
    apresentar: Boolean(estado.apresentar),
    texto_original: `Pelo site: orçamento com ${itens.length} ${
      itens.length === 1 ? "procedimento" : "procedimentos"
    }, total de ${total.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}`,
  };
  if (desconto > 0) dados[estado.desconto_tipo === "pct" ? "desconto_percentual" : "desconto_valor"] = desconto;
  const obs = String(estado.observacoes ?? "").trim();
  if (obs) dados.observacoes = obs.slice(0, 2000);
  if (base.paciente?.aberto) dados.separado = !estado.substituir;
  return { dados, subtotal, total };
}

// ------------------------------------------------------------------
// PDF (o mesmo desenho do gerador antigo)
// ------------------------------------------------------------------

const telefoneDoPdf = (t) => {
  let d = String(t ?? "").replace(/\D/g, "");
  if (d.length === 13 && d.startsWith("55")) d = d.slice(2);
  if (d.length === 11) return `+55 ${d.slice(0, 2)} ${d.slice(2, 7)}-${d.slice(7)}`;
  if (d.length === 10) return `+55 ${d.slice(0, 2)} ${d.slice(2, 6)}-${d.slice(6)}`;
  return t ?? "";
};

/** Cabeçalho do consultório (configuração do banco) no formato do PDF. */
export function clinicaDe(cab = {}) {
  return {
    nome: cab.dentista ?? cab.nome ?? "",
    papel: cab.especialidade ?? "",
    cro: cab.cro ?? "",
    whatsapp: telefoneDoPdf(cab.whatsapp ?? cab.telefone),
    instagram: cab.instagram ?? "",
    email: cab.email ?? "",
  };
}

const rotuloDesconto = (tipo, valor) =>
  tipo === "percentual" || tipo === "pct" ? `Desconto (${String(Number(valor)).replace(".", ",")}%)` : "Desconto";

/** Prévia da tela: o que vai sair no PDF, antes de gravar. */
export function planoDaTela(estado, base, nomePaciente) {
  const linhas = linhasDoForm(estado, base);
  const { desconto } = contas(estado, linhas);
  const campanha = (base.campanhas ?? []).find((c) => c.id === estado.campanha_id);
  const dias = Number(String(estado.validade_dias ?? "").trim() || base.validade_dias || 30);
  const hoje = base.hoje;
  const obs = [
    String(estado.observacoes ?? "").trim(),
    campanha ? `Valores da ${campanha.nome} (${campanha.periodo}).` : "",
  ]
    .filter(Boolean).join(" ");
  return {
    clinica: clinicaDe(base.cabecalho),
    paciente: nomePaciente ?? "",
    emissao: porExtenso(hoje),
    validade: dias >= 1 ? porExtenso(somarDiasISO(hoje, dias)) : "—",
    itens: linhas.map((x) => ({
      descricao: x.descricao || x.linha.nome_base || "",
      regiao: rotuloLocal(x.local),
      qtd: Number.isInteger(x.qtd) && x.qtd > 0 ? x.qtd : 1,
      valor: x.valor ?? 0,
    })),
    detalharPrecos: Boolean(estado.detalhar),
    desconto,
    descontoRotulo: rotuloDesconto(estado.desconto_tipo, lerNumero(estado.desconto) ?? 0),
    parcelas: Number(String(estado.parcelas ?? "").trim() || 0),
    observacoes: obs,
  };
}

/** PDF a partir do orçamento gravado (orcamento_json): o arquivo é o registro. */
export function planoDoOrcamento(orc, { detalhar = false } = {}) {
  const opcao = orc.opcoes?.[0] ?? {};
  const maxCartao = Number(orc.condicoes?.cartao_parcelas_max ?? 1);
  const parcelas = maxCartao > 1 ? Number(opcao.pagamento?.cartao?.parcelas ?? 0) : 0;
  return {
    clinica: clinicaDe(orc.cabecalho),
    paciente: orc.paciente?.nome ?? "",
    emissao: porExtenso(orc.emitido_em),
    validade: porExtenso(orc.validade),
    itens: (orc.itens ?? []).filter((i) => i.conta !== false).map((i) => ({
      descricao: i.descricao ?? "",
      regiao: i.local ?? (i.regiao === "outra" ? i.observacao ?? "" : ""),
      qtd: Number(i.quantidade ?? 1),
      valor: Number(i.valor_unitario ?? 0),
    })),
    detalharPrecos: Boolean(detalhar),
    desconto: Number(opcao.desconto ?? 0),
    descontoRotulo: rotuloDesconto(orc.desconto?.tipo, orc.desconto?.valor ?? 0),
    parcelas: parcelas > 1 ? parcelas : 0,
    observacoes: orc.observacoes ?? "",
  };
}

/** Avisos do banco escritos para o Claude, ditos para ela. */
export function avisosParaTela(avisos) {
  return (avisos ?? [])
    .filter((a) => a && !/não está no catálogo: entra no orçamento só como texto/.test(a))
    .map((a) =>
      String(a)
        .replace(/ Para usar só os preços normais, chame de novo com campanha "nenhuma"\./, "")
        .replace(/ Diga qual em itens \(com o dente\) para entrar\./, "")
        .replace(/ \(ex\.: arcada_superior, S1, Q2\)/, " (ex.: arcada superior, quadrante 2)")
    );
}
