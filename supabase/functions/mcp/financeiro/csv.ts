// Arquivos CSV do pacote mensal do contador.
//
// - Lote do Receita Saúde: layout fixo da Receita (16 campos separados por
//   ";", sem cabeçalho, até 1.000 linhas por arquivo, todas do mesmo ano).
//   O conteúdo sai só em ASCII (sem acentos), então a codificação do arquivo
//   não faz diferença na importação.
// - Planilhas completas (recebimentos, despesas/livro-caixa e resumo): UTF-8
//   com BOM, ";" e cabeçalho, para abrir direto no Excel.

export const LIMITE_LOTE_RECEITA_SAUDE = 1000;
const CRLF = "\r\n";
const BOM = "﻿";

/** Código fixo do rendimento no lote do Receita Saúde. */
const CODIGO_RENDIMENTO = "R01.001.001";
/** CBO da família dos cirurgiões-dentistas, usado quando a configuração não diz outro. */
const OCUPACAO_PADRAO = "226";

export interface Profissional {
  nome?: string;
  cro?: string;
  cpf?: string;
  registro?: string;
  codigo_ocupacao?: string;
}

/** Linha pendente do Receita Saúde, como vem de mcp_pacote_contador. */
export interface LinhaReceitaSaude {
  recebimento_id: string;
  numero: number;
  data_pagamento: string;
  valor: number;
  descricao: string;
  cpf_pagador: string;
  cpf_beneficiario: string;
}

export interface LinhaRecebimento {
  numero: number;
  data_pagamento: string;
  data_atendimento?: string | null;
  paciente: string;
  paciente_cpf?: string | null;
  pagador?: string | null;
  pagador_cpf?: string | null;
  descricao?: string | null;
  forma: string;
  parcela?: string | null;
  parcelas_cartao?: number | null;
  valor_bruto: number;
  taxa?: number | null;
  valor_liquido: number;
  data_credito_prevista?: string | null;
  regime?: string | null;
  recibo?: string | null;
  recibo_codigo?: string | null;
  estorno_de?: number | null;
  motivo_estorno?: string | null;
}

export interface LinhaDespesa {
  numero: number;
  data: string;
  competencia?: string | null;
  categoria: string;
  descricao?: string | null;
  fornecedor?: string | null;
  fornecedor_documento?: string | null;
  valor: number;
  forma?: string | null;
  paciente?: string | null;
  comprovante?: string | null;
  origem?: string | null;
  estorno_de?: number | null;
  motivo_estorno?: string | null;
}

type Numero = number | string | null | undefined;

export interface Resumo {
  mes?: string;
  regime?: string;
  recebido?: {
    bruto?: Numero;
    taxas?: Numero;
    liquido?: Numero;
    pagamentos?: Numero;
    por_forma?: { forma: string; bruto: Numero; taxas?: Numero; liquido?: Numero }[];
  };
  a_receber?: { vence_no_mes?: Numero; atrasado_hoje?: Numero; proximos_30_dias?: Numero; total_em_aberto?: Numero };
  despesas?: { total?: Numero; por_categoria?: { categoria: string; total: Numero }[] };
  resultado?: Numero;
  recibos_receita_saude?: { pendentes?: Numero; valor_pendente?: Numero; a_cancelar?: Numero };
  hora_clinica?: { custos_fixos?: Numero; horas_atendidas?: Numero; atendimentos?: Numero; valor_hora?: Numero };
  avisos?: string[];
}

/** O que mcp_pacote_contador devolve. */
export interface PacoteDoBanco {
  status: string;
  mes: string;
  profissional?: Profissional;
  receita_saude?: LinhaReceitaSaude[];
  recebimentos?: LinhaRecebimento[];
  despesas?: LinhaDespesa[];
  resumo?: Resumo;
  problemas?: string[];
}

export interface ArquivoGerado {
  nome: string;
  conteudo: string;
  linhas: number;
  descricao: string;
}

// ---------------------------------------------------------------------
// Formatação
// ---------------------------------------------------------------------

const FORMAS: Record<string, string> = {
  pix: "PIX",
  dinheiro: "Dinheiro",
  debito: "Cartão de débito",
  credito_vista: "Cartão de crédito à vista",
  credito_parcelado: "Cartão de crédito parcelado",
  boleto: "Boleto",
  transferencia: "Transferência",
};

const CATEGORIAS: Record<string, string> = {
  aluguel_sala: "Aluguel de sala",
  materiais: "Materiais",
  laboratorio: "Laboratório",
  cro: "CRO",
  contador: "Contador",
  inss: "INSS",
  impostos: "Impostos (DAS/DARF)",
  iss: "ISS",
  seguro: "Seguro",
  software: "Software",
  manutencao: "Manutenção",
  marketing: "Marketing",
  outros: "Outros",
};

const ORIGENS: Record<string, string> = {
  manual: "Manual",
  recorrente: "Despesa fixa",
  reserva_sala: "Reserva de sala",
  compra: "Compra de material",
};

const RECIBOS: Record<string, string> = {
  pendente: "Pendente",
  emitido: "Emitido",
  cancelar: "Cancelar (pagamento estornado)",
  cancelado: "Cancelado",
  nao_se_aplica: "Não se aplica",
  nfse_contador: "NFS-e pelo contador",
};

const REGIMES: Record<string, string> = {
  pf: "Pessoa física",
  pj: "Pessoa jurídica",
  pf_e_pj: "Pessoa física e jurídica (mês da virada)",
};

export const rotuloForma = (f?: string | null) => (f ? FORMAS[f] ?? f : "");
export const rotuloCategoria = (c?: string | null) => (c ? CATEGORIAS[c] ?? c : "");
export const rotuloOrigem = (o?: string | null) => (o ? ORIGENS[o] ?? o : "");
export const rotuloRecibo = (r?: string | null) => (r ? RECIBOS[r] ?? r : "");
export const rotuloRegime = (r?: string | null) => (r ? REGIMES[r] ?? r : "");

/** AAAA-MM-DD -> DD/MM/AAAA. */
export function dataBR(iso?: string | null): string {
  if (!iso) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : iso;
}

/** AAAA-MM -> MM/AAAA. */
export function mesBR(mes?: string | null): string {
  if (!mes) return "";
  const m = /^(\d{4})-(\d{2})/.exec(mes);
  return m ? `${m[2]}/${m[1]}` : mes;
}

/** 1800.5 -> "1800,50" (vírgula decimal, sem separador de milhar). */
export function valorBR(valor: Numero): string {
  if (valor === null || valor === undefined || valor === "") return "";
  const n = typeof valor === "number" ? valor : Number(valor);
  if (!Number.isFinite(n)) return "";
  return n.toFixed(2).replace(".", ",");
}

export const digitos = (s?: string | null) => (s ?? "").replace(/\D/g, "");

/** CPF ou CNPJ com pontuação (o Excel não come os zeros da frente). */
export function documentoFormatado(doc?: string | null): string {
  const d = digitos(doc);
  if (d.length === 11) return `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}`;
  if (d.length === 14) return `${d.slice(0, 2)}.${d.slice(2, 5)}.${d.slice(5, 8)}/${d.slice(8, 12)}-${d.slice(12)}`;
  return doc ?? "";
}

/** Texto só com ASCII imprimível, sem ";" nem quebra de linha, para o lote da Receita. */
export function semAcentos(texto?: string | null, max = 255): string {
  return (texto ?? "")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/"/g, "'")
    .replace(/[;\r\n\t]/g, " ")
    .replace(/[^ -~]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max)
    .trim();
}

/** Célula de planilha: aspas quando precisa e sem virar fórmula no Excel. */
function celula(valor: unknown): string {
  if (valor === null || valor === undefined) return "";
  let s = String(valor);
  if (/^[=+\-@]/.test(s) && !/^-?\d+(,\d+)?$/.test(s)) s = `'${s}`;
  return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function planilha(cabecalho: string[], linhas: unknown[][]): string {
  return BOM + [cabecalho, ...linhas].map((l) => l.map(celula).join(";")).join(CRLF) + CRLF;
}

// ---------------------------------------------------------------------
// Arquivos
// ---------------------------------------------------------------------

/**
 * Arquivos do lote do Receita Saúde (um por bloco de até 1.000 linhas do
 * mesmo ano). Lança erro sem o CPF da Dra., que a Receita exige.
 */
export function csvReceitaSaude(linhas: LinhaReceitaSaude[], profissional: Profissional): string[] {
  const cpf = digitos(profissional.cpf);
  if (cpf.length !== 11) throw new Error("Falta o CPF da Dra. para o lote do Receita Saúde.");
  const ocupacao = semAcentos(profissional.codigo_ocupacao, 10) || OCUPACAO_PADRAO;
  const registro = semAcentos(profissional.registro, 15);
  const porAno = new Map<string, string[]>();
  for (const l of linhas) {
    const campos = [
      dataBR(l.data_pagamento),
      CODIGO_RENDIMENTO,
      ocupacao,
      valorBR(l.valor),
      "",
      semAcentos(l.descricao, 255),
      "PF",
      digitos(l.cpf_pagador),
      digitos(l.cpf_beneficiario),
      "",
      "",
      "",
      "",
      "S",
      cpf,
      registro,
    ];
    const ano = l.data_pagamento.slice(0, 4);
    if (!porAno.has(ano)) porAno.set(ano, []);
    porAno.get(ano)!.push(campos.join(";"));
  }
  const arquivos: string[] = [];
  for (const ano of [...porAno.keys()].sort()) {
    const doAno = porAno.get(ano)!;
    for (let i = 0; i < doAno.length; i += LIMITE_LOTE_RECEITA_SAUDE) {
      arquivos.push(doAno.slice(i, i + LIMITE_LOTE_RECEITA_SAUDE).join(CRLF) + CRLF);
    }
  }
  return arquivos;
}

export function csvRecebimentos(linhas: LinhaRecebimento[]): string {
  return planilha(
    [
      "Número",
      "Data do pagamento",
      "Data do atendimento",
      "Paciente",
      "CPF do paciente",
      "Pagador",
      "CPF do pagador",
      "Descrição",
      "Forma",
      "Parcela do acordo",
      "Parcelas no cartão",
      "Valor bruto",
      "Taxa",
      "Valor líquido",
      "Crédito previsto",
      "Regime",
      "Recibo",
      "Código do recibo",
      "Estorno do nº",
      "Motivo do estorno",
    ],
    linhas.map((r) => [
      r.numero,
      dataBR(r.data_pagamento),
      dataBR(r.data_atendimento),
      r.paciente,
      documentoFormatado(r.paciente_cpf),
      r.pagador,
      documentoFormatado(r.pagador_cpf),
      r.descricao,
      rotuloForma(r.forma),
      r.parcela,
      r.parcelas_cartao,
      valorBR(r.valor_bruto),
      valorBR(r.taxa),
      valorBR(r.valor_liquido),
      dataBR(r.data_credito_prevista),
      rotuloRegime(r.regime),
      rotuloRecibo(r.recibo),
      r.recibo_codigo,
      r.estorno_de,
      r.motivo_estorno,
    ]),
  );
}

export function csvDespesas(linhas: LinhaDespesa[]): string {
  return planilha(
    [
      "Número",
      "Data",
      "Competência",
      "Categoria",
      "Descrição",
      "Fornecedor",
      "CPF/CNPJ do fornecedor",
      "Valor",
      "Forma",
      "Paciente",
      "Comprovante",
      "Origem",
      "Estorno do nº",
      "Motivo do estorno",
    ],
    linhas.map((d) => [
      d.numero,
      dataBR(d.data),
      mesBR(d.competencia),
      rotuloCategoria(d.categoria),
      d.descricao,
      d.fornecedor,
      documentoFormatado(d.fornecedor_documento),
      valorBR(d.valor),
      rotuloForma(d.forma),
      d.paciente,
      d.comprovante,
      rotuloOrigem(d.origem),
      d.estorno_de,
      d.motivo_estorno,
    ]),
  );
}

/** Resumo do mês em duas colunas (item; valor). */
export function csvResumo(mes: string, resumo: Resumo, problemas: string[] = []): string {
  const r = resumo;
  const linhas: unknown[][] = [
    ["Mês", mesBR(mes)],
    ["Regime", rotuloRegime(r.regime)],
    ["Recebido bruto", valorBR(r.recebido?.bruto)],
    ["Taxas de cartão", valorBR(r.recebido?.taxas)],
    ["Recebido líquido", valorBR(r.recebido?.liquido)],
    ["Pagamentos no mês", r.recebido?.pagamentos ?? 0],
  ];
  for (const f of r.recebido?.por_forma ?? []) {
    linhas.push([`Recebido em ${rotuloForma(f.forma)} (bruto)`, valorBR(f.bruto)]);
  }
  linhas.push(["Despesas", valorBR(r.despesas?.total)]);
  for (const c of r.despesas?.por_categoria ?? []) {
    linhas.push([`Despesas: ${rotuloCategoria(c.categoria)}`, valorBR(c.total)]);
  }
  linhas.push(
    ["Resultado (recebido líquido menos despesas)", valorBR(r.resultado)],
    ["A receber: vence no mês", valorBR(r.a_receber?.vence_no_mes ?? 0)],
    ["A receber: atrasado hoje", valorBR(r.a_receber?.atrasado_hoje ?? 0)],
    ["A receber: total em aberto", valorBR(r.a_receber?.total_em_aberto ?? 0)],
    ["Recibos do Receita Saúde pendentes", r.recibos_receita_saude?.pendentes ?? 0],
    ["Valor dos recibos pendentes", valorBR(r.recibos_receita_saude?.valor_pendente ?? 0)],
    ["Recibos a cancelar (pagamento estornado)", r.recibos_receita_saude?.a_cancelar ?? 0],
    ["Custos fixos do mês (sem materiais, laboratório e impostos)", valorBR(r.hora_clinica?.custos_fixos)],
    ["Horas atendidas registradas", valorBR(r.hora_clinica?.horas_atendidas)],
    ["Hora clínica estimada", valorBR(r.hora_clinica?.valor_hora)],
  );
  for (const a of r.avisos ?? []) linhas.push(["Aviso", a]);
  for (const p of problemas) linhas.push(["Pendência", p]);
  return planilha(["Item", "Valor"], linhas);
}

/**
 * Monta os arquivos do pacote a partir do que o banco devolveu. `lote` são
 * os recebimentos que foram no arquivo do Receita Saúde (null quando o
 * arquivo não foi gerado).
 */
export function arquivosDoPacote(pacote: PacoteDoBanco): {
  arquivos: ArquivoGerado[];
  lote: string[] | null;
  avisos: string[];
} {
  const mes = pacote.mes;
  const rs = pacote.receita_saude ?? [];
  const recebimentos = pacote.recebimentos ?? [];
  const despesas = pacote.despesas ?? [];
  const arquivos: ArquivoGerado[] = [];
  const avisos: string[] = [];
  let lote: string[] | null = null;

  if (rs.length > 0) {
    if (digitos(pacote.profissional?.cpf).length === 11) {
      const partes = csvReceitaSaude(rs, pacote.profissional ?? {});
      partes.forEach((conteudo, i) => {
        const linhas = conteudo.split(CRLF).length - 1;
        arquivos.push({
          nome: partes.length === 1 ? `receita-saude-${mes}.csv` : `receita-saude-${mes}-${i + 1}.csv`,
          conteudo,
          linhas,
          descricao: `Lote para emitir ${linhas} recibo(s) no Receita Saúde.`,
        });
      });
      lote = rs.map((l) => l.recebimento_id);
    } else {
      avisos.push(
        "O arquivo do Receita Saúde não foi gerado porque falta o CPF da Dra. (configurar_financeiro). " +
          "As planilhas do contador foram geradas.",
      );
    }
  }
  const resumo = csvResumo(mes, pacote.resumo ?? {}, pacote.problemas ?? []);
  arquivos.push(
    {
      nome: `recebimentos-${mes}.csv`,
      conteudo: csvRecebimentos(recebimentos),
      linhas: recebimentos.length,
      descricao: "Todos os pagamentos do mês, com taxas, recibos e estornos.",
    },
    {
      nome: `despesas-livro-caixa-${mes}.csv`,
      conteudo: csvDespesas(despesas),
      linhas: despesas.length,
      descricao: "Despesas do mês para o livro-caixa, com fornecedor e comprovante.",
    },
    {
      nome: `resumo-${mes}.csv`,
      conteudo: resumo,
      // Sem contar o cabeçalho nem a quebra de linha final.
      linhas: resumo.split(CRLF).length - 2,
      descricao: "Resumo do mês: recebido, despesas, resultado, a receber e pendências.",
    },
  );
  return { arquivos, lote, avisos };
}
