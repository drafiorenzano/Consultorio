// Ferramentas do módulo "documentos": orçamento (plano de tratamento),
// receita, atestado, termo de consentimento / orientações e a lista de
// documentos do paciente.
//
// As regras (números, versões, checagens de segurança da receita, o que vai
// em cada texto) moram nas funções do Postgres. Quando a função devolve
// `documento`, este módulo gera o PDF (documentos/pdf.ts), guarda no bucket
// privado, registra o arquivo (mcp_registrar_documento) e devolve um link
// temporário no lugar dos dados brutos.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  data,
  type Dependencias,
  erroComoTexto,
  falha,
  GRAVACAO,
  hora,
  LEITURA,
  type Modulo,
  NOTA_TEXTO_ORIGINAL,
  paciente_id,
  type Resultado,
  texto,
  textoOriginal,
} from "../comum.ts";
import { gerarPdf, sha256Bytes, type TipoDocumento } from "../documentos/pdf.ts";

/** Quanto tempo vale o link do PDF. */
const LINK_SEGUNDOS = 7 * 24 * 3600;
/** Máximo de links gerados numa listagem (cada link é uma chamada ao Storage). */
const MAX_LINKS = 15;

const REGIOES = [
  "boca",
  "arcada_superior",
  "arcada_inferior",
  "Q1",
  "Q2",
  "Q3",
  "Q4",
  "Q5",
  "Q6",
  "Q7",
  "Q8",
  "S1",
  "S2",
  "S3",
  "S4",
  "S5",
  "S6",
  "outra",
] as const;
const ALTERNATIVAS = ["A", "B", "C", "D"] as const;
const TIPOS = ["orcamento", "receita", "atestado", "termo", "orientacoes"] as const;

const MODELOS_RECEITA = [
  "dipirona_500: dor leve a moderada",
  "paracetamol_750: dor leve (alternativa à dipirona)",
  "ibuprofeno_600: dor com inflamação, até 3 dias",
  "nimesulida_100: inflamação, até 2 dias",
  "cetorolaco_10: dor pós-operatória forte, sublingual, até 2 dias",
  "dexametasona_4: 8 mg dose única 1 h antes de cirurgia de incluso",
  "amoxicilina_500: infecção com sinais sistêmicos, 7 dias",
  "metronidazol_250: junto com amoxicilina em infecção grave",
  "azitromicina_500: alérgico à penicilina, 5 dias",
  "clindamicina_300: alérgico à penicilina, 7 dias",
  "clorexidina_012: bochecho pós-operatório",
  "profilaxia_amoxicilina_2g / profilaxia_azitromicina_500: profilaxia antibiótica",
  "amoxicilina_pediatrica, profilaxia_amoxicilina_pediatrica, profilaxia_azitromicina_pediatrica: crianças (exigem peso_kg)",
];

// ---------------------------------------------------------------------------
// Esquemas
// ---------------------------------------------------------------------------

const itemOrcamento = z.object({
  procedimento_codigo: z.string().optional().describe("Código do catálogo (listar_procedimentos), ex.: canal_molar."),
  procedimento: z.string().optional().describe(
    "Nome como a Dra. disse, se não souber o código. Fora do catálogo entra só como texto e precisa de valor.",
  ),
  dente: z.number().int().optional().describe("FDI, ex.: 36."),
  dentes: z.array(z.number().int()).optional().describe(
    "Mesmo procedimento em vários dentes (vira um item por dente).",
  ),
  faces: z.string().optional().describe("Ex.: MO, MOD."),
  regiao: z.enum(REGIOES).optional().describe("Quando não é um dente: boca, arcada, quadrante (Q) ou sextante (S)."),
  quantidade: z.number().int().min(1).max(99).optional(),
  valor: z.number().nonnegative().optional().describe(
    "Valor unitário em reais só para este orçamento. Sem valor, usa o preço do catálogo.",
  ),
  fase: z.number().int().min(1).max(7).optional().describe(
    "1 urgência/preparo, 2 gengiva, 3 canal, 4 restaurações, 5 prótese/implante, 6 estética, 7 manutenção. Padrão: pela categoria.",
  ),
  alternativa: z.enum(ALTERNATIVAS).optional().describe(
    "Opções excludentes para o paciente escolher (ex.: A canal + coroa; B extração + implante). Sem alternativa = vale para todas.",
  ),
  explicacao: z.string().optional().describe("Explicação simples para o paciente (padrão: automática)."),
  descricao: z.string().optional().describe("Nome no orçamento, se diferente do catálogo."),
  observacao: z.string().optional(),
});

const valores = z.array(z.object({
  procedimento_codigo: z.string(),
  valor: z.number().nonnegative(),
})).optional().describe(
  "Valores que a Dra. disse para procedimentos sem preço no catálogo (resposta a valor_necessario).",
);

const condicoesPagamento = z.object({
  desconto_a_vista_pct: z.number().min(0).max(50).optional(),
  cartao_parcelas_max: z.number().int().min(1).max(24).optional(),
  entrada_pct: z.number().min(0).max(100).optional().describe("0 tira a opção de entrada + parcelas."),
  entrada_parcelas_max: z.number().int().min(1).max(24).optional(),
  parcela_minima: z.number().positive().optional(),
}).optional().describe("Só se a Dra. pedir condições diferentes do padrão (5% à vista, até 6x no cartão, 30% + 3x).");

const descontos = {
  desconto_percentual: z.number().min(0).max(100).optional().describe("Desconto em % sobre o total."),
  desconto_valor: z.number().nonnegative().optional().describe("Desconto em reais (use um ou outro)."),
};

const esquemaMontar = {
  paciente_id: paciente_id(),
  itens: z.array(itemOrcamento).optional().describe(
    "Itens ditados. Um item no mesmo dente de um plano do odontograma ajusta esse plano (valor, alternativa, fase, procedimento).",
  ),
  incluir_odontograma: z.boolean().optional().describe(
    "Incluir os planos (camada planejado) do odontograma. Padrão: sim.",
  ),
  valores,
  ...descontos,
  validade_dias: z.number().int().min(1).max(180).optional().describe("Padrão: 30 dias."),
  pagamento: condicoesPagamento,
  titulo: z.string().optional().describe('Padrão: "Plano de tratamento".'),
  observacoes: z.string().optional().describe("Vai no PDF, para o paciente."),
  apresentar: z.boolean().optional().describe(
    "true quando já vai ser entregue ao paciente (começa a contar o acompanhamento).",
  ),
  separado: z.boolean().optional().describe(
    "true para um orçamento à parte; sem isso, um orçamento em aberto do paciente vira versão nova.",
  ),
  campanha: z.string().optional().describe(
    'Preços de campanha: nome da campanha, ou "nenhuma" para os preços normais. Sem isso: a campanha de hoje, se houver.',
  ),
  texto_original: textoOriginal(),
};
type ArgsMontar = z.infer<z.ZodObject<typeof esquemaMontar>>;

const esquemaAlterar = {
  paciente_id: z.string().optional().describe("Id do paciente (usa o orçamento em aberto dele)."),
  orcamento_id: z.string().optional(),
  numero: z.number().int().optional().describe("Número do orçamento, se o paciente tiver mais de um."),
  acao: z.enum(["apresentar", "aprovar", "recusar", "acompanhamento", "editar"]),
  alternativa: z.enum(ALTERNATIVAS).optional().describe("aprovar: a alternativa escolhida pelo paciente."),
  itens: z.array(z.number().int()).optional().describe(
    "aprovar: números (ordem) dos itens aprovados, para aprovação parcial. Sem itens nem alternativa = tudo.",
  ),
  forma_pagamento: z.string().optional().describe('aprovar: como vai pagar (ex.: "cartão em 6x").'),
  motivo: z.string().optional().describe("recusar: o motivo, se o paciente disse."),
  nota: z.string().optional().describe("acompanhamento: o que foi conversado no contato."),
  data: data().optional().describe("AAAA-MM-DD, se não foi hoje."),
  adicionar: z.array(itemOrcamento).optional().describe("editar: itens novos."),
  remover: z.array(z.number().int()).optional().describe("editar: números (ordem) dos itens a tirar."),
  alterar: z.array(z.object({
    ordem: z.number().int(),
    valor: z.number().nonnegative().optional(),
    quantidade: z.number().int().min(1).max(99).optional(),
    fase: z.number().int().min(1).max(7).optional(),
    alternativa: z.string().optional().describe('A a D, ou "" para tirar a alternativa.'),
    explicacao: z.string().optional(),
    descricao: z.string().optional(),
    observacao: z.string().optional(),
  })).optional().describe("editar: mudanças em itens existentes."),
  valores,
  ...descontos,
  sem_desconto: z.boolean().optional().describe("editar: tira o desconto."),
  validade_dias: z.number().int().min(1).max(180).optional(),
  pagamento: condicoesPagamento,
  titulo: z.string().optional(),
  observacoes: z.string().optional(),
  texto_original: textoOriginal(),
};
type ArgsAlterar = z.infer<z.ZodObject<typeof esquemaAlterar>>;

const esquemaReceita = {
  paciente_id: paciente_id(),
  medicamentos: z.array(z.object({
    modelo: z.string().optional().describe("Código do modelo (lista na descrição). Preferível ao nome."),
    nome: z.string().optional().describe("Fora dos modelos: nome genérico (DCB)."),
    concentracao: z.string().optional().describe("Ex.: 500 mg."),
    forma: z.string().optional().describe("Ex.: comprimido, cápsula, suspensão oral."),
    via: z.enum(["oral", "sublingual", "bochecho", "topica"]).optional(),
    quantidade: z.string().optional().describe("Ex.: 21 cápsulas; 1 caixa. Muda a do modelo."),
    posologia: z.string().optional().describe("Como tomar. Muda a do modelo (ex.: outro número de dias)."),
  })).min(1),
  peso_kg: z.number().positive().optional().describe("Obrigatório nos modelos pediátricos (a dose é calculada)."),
  orientacoes: z.string().optional(),
  data: data().optional().describe("AAAA-MM-DD. Padrão: hoje."),
  confirmar_alertas: z.boolean().optional().describe(
    "Só depois de ler os alertas para a Dra. e ela mandar manter a receita.",
  ),
  texto_original: textoOriginal(),
};
type ArgsReceita = z.infer<z.ZodObject<typeof esquemaReceita>>;

const esquemaAtestado = {
  paciente_id: paciente_id(),
  tipo: z.enum(["comparecimento", "repouso", "acompanhante"]).describe(
    "comparecimento = declaração de que esteve aqui (com horário); repouso = dias de afastamento; acompanhante = para quem acompanhou.",
  ),
  data: data().optional().describe("Dia do atendimento. Padrão: hoje."),
  hora_inicio: hora().optional().describe("Padrão: o horário do atendimento registrado no dia."),
  hora_fim: hora().optional(),
  dias: z.number().int().min(1).max(30).optional().describe("repouso: quantos dias."),
  a_partir_de: data().optional().describe("repouso: início, se não for o dia do atendimento."),
  cid: z.string().optional().describe("Só se o paciente autorizar (ex.: K08.1)."),
  cid_autorizado: z.boolean().optional().describe("true só quando o paciente autorizou pôr o CID."),
  acompanhante_nome: z.string().optional().describe(
    "acompanhante: nome de quem acompanhou (menor: padrão é o responsável).",
  ),
  finalidade: z.string().optional().describe('Ex.: "apresentar no trabalho". Normalmente não precisa.'),
  texto_original: textoOriginal(),
};
type ArgsAtestado = z.infer<z.ZodObject<typeof esquemaAtestado>>;

const esquemaTermo = {
  paciente_id: paciente_id(),
  modelo: z.string().describe(
    "Termos de consentimento: exodontia, endodontia, implante, protese, clareamento, cirurgia. " +
      "Orientações: pos_exodontia, pos_implante, clareamento_cuidados. Aceita também extração, siso, canal...",
  ),
  tipo: z.enum(["consentimento", "orientacoes"]).optional().describe(
    'Para desempatar (ex.: "implante" + orientacoes = pós-operatório de implante). Padrão: consentimento.',
  ),
  dentes: z.array(z.number().int()).optional().describe("Dentes do procedimento (vão no texto do termo)."),
  procedimento: z.string().optional().describe("Descrição do tratamento, se diferente da padrão do modelo."),
  observacoes: z.string().optional().describe("Algo próprio do caso (ex.: dente próximo ao nervo)."),
  data: data().optional(),
  texto_original: textoOriginal(),
};
type ArgsTermo = z.infer<z.ZodObject<typeof esquemaTermo>>;

const esquemaVer = {
  paciente_id: z.string().optional().describe("Sem paciente: orçamentos esperando contato e últimos documentos."),
  tipo: z.enum(TIPOS).optional(),
  regerar: z.object({ tipo: z.enum(TIPOS), numero: z.number().int() }).optional().describe(
    "Gera de novo o PDF de um documento já emitido (precisa do paciente_id).",
  ),
  texto_original: z.string().optional().describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsVer = z.infer<z.ZodObject<typeof esquemaVer>>;

// ---------------------------------------------------------------------------
// PDF: gerar, guardar, registrar e devolver o link
// ---------------------------------------------------------------------------

interface DocumentoParaPdf {
  tipo: TipoDocumento;
  referencia_id: string;
  paciente_id: string;
  titulo: string;
  caminho: string;
  solicitacao_id?: string | null;
  dados: unknown;
}

type Arquivo = { titulo?: string; link?: string; link_valido_por?: string; aviso?: string; erro?: string };

export async function publicarPdf(deps: Dependencias, doc: DocumentoParaPdf): Promise<Arquivo> {
  if (!deps.arquivos) {
    return {
      titulo: doc.titulo,
      aviso: "O registro foi gravado, mas o PDF não foi gerado: armazenamento indisponível.",
    };
  }
  try {
    const bytes = await gerarPdf(doc.tipo, doc.dados);
    await deps.arquivos.salvar(doc.caminho, bytes, "application/pdf");
    await deps.rpc("mcp_registrar_documento", {
      p_dados: {
        tipo: doc.tipo,
        referencia_id: doc.referencia_id,
        caminho: doc.caminho,
        titulo: doc.titulo,
        tamanho_bytes: bytes.length,
        sha256: await sha256Bytes(bytes),
        solicitacao_id: doc.solicitacao_id ?? null,
      },
    });
    const link = await deps.arquivos.link(doc.caminho, LINK_SEGUNDOS);
    return { titulo: doc.titulo, link, link_valido_por: "7 dias" };
  } catch (e) {
    return {
      titulo: doc.titulo,
      erro: `O registro foi gravado, mas o PDF falhou (${erroComoTexto(e).message}). ` +
        "Tente de novo com ver_documentos e regerar.",
    };
  }
}

/** Troca cada `arquivo: {caminho}` da listagem por um link temporário. */
async function linksDaListagem(deps: Dependencias, valor: unknown, conta = { n: 0 }): Promise<void> {
  if (Array.isArray(valor)) {
    for (const v of valor) await linksDaListagem(deps, v, conta);
    return;
  }
  if (!valor || typeof valor !== "object") return;
  const obj = valor as Record<string, unknown>;
  for (const [k, v] of Object.entries(obj)) {
    if (k === "arquivo" && v && typeof v === "object" && typeof (v as { caminho?: unknown }).caminho === "string") {
      const arq = v as { caminho?: string; link?: string; gerado_em?: string };
      if (deps.arquivos && conta.n < MAX_LINKS) {
        conta.n++;
        try {
          arq.link = await deps.arquivos.link(arq.caminho!, LINK_SEGUNDOS);
        } catch (_) {
          arq.link = undefined;
        }
      }
      delete arq.caminho;
    } else {
      await linksDaListagem(deps, v, conta);
    }
  }
}

/** Chama a função do banco e, se vier um documento, publica o PDF. */
async function chamar(
  deps: Dependencias,
  ferramenta: string,
  funcao: string,
  argumentos: Record<string, unknown>,
  grava: boolean,
): Promise<Resultado> {
  let resposta: unknown;
  try {
    resposta = await deps.rpc(funcao, argumentos);
  } catch (e) {
    return falha(deps, ferramenta, argumentos, grava, e);
  }
  if (resposta && typeof resposta === "object" && !Array.isArray(resposta)) {
    const r = resposta as Record<string, unknown>;
    const doc = r.documento as DocumentoParaPdf | undefined;
    if (doc && typeof doc === "object" && doc.caminho) {
      delete r.documento;
      r.arquivo = await publicarPdf(deps, doc);
    }
    await linksDaListagem(deps, r);
  }
  return { content: [{ type: "text", text: texto(resposta) }] };
}

function comDados(args: Record<string, unknown> & { texto_original?: string }) {
  const { texto_original, ...dados } = args;
  return { p_dados: dados, p_texto_original: texto_original ?? null };
}

// ---------------------------------------------------------------------------
// Módulo
// ---------------------------------------------------------------------------

export const modulo: Modulo = {
  nome: "documentos",
  instrucoes: [
    "Orçamento: use montar_orcamento, que junta os planos do odontograma (camada planejado) e o que a Dra. ditar. " +
    "Se voltar valor_necessario, pergunte o valor à Dra. e chame de novo com valores; nunca invente preço nem use a faixa de mercado.",
    "O orçamento nasce como rascunho; quando for entregue ao paciente, use apresentar (no montar ou em alterar_orcamento). " +
    "Mudança depois de apresentado vira versão nova. Aprovação pode ser de tudo, de uma alternativa (A/B) ou de itens; " +
    "os itens aprovados viram realizados sozinhos quando o atendimento é registrado.",
    "Receita, atestado e termo saem em PDF com link válido por 7 dias: mande o link à Dra. " +
    "Se vier confirmacao_necessaria, leia os alertas para a Dra. e só repita com confirmar_alertas = true se ela mantiver.",
    "Medicamento de controle especial (ansiolítico, opioide, anticonvulsivante) não sai pelo sistema: é no talão em papel.",
    "CID no atestado só com autorização do paciente (cid_autorizado). Termo de consentimento: imprimir e colher assinatura antes do procedimento.",
    "Acompanhamento de orçamentos (contato em 7, 21 e 45 dias): ver_documentos sem paciente mostra quem está na hora; " +
    "anote cada contato com alterar_orcamento acao acompanhamento.",
  ],
  registrar(servidor: McpServer, deps: Dependencias) {
    servidor.registerTool(
      "montar_orcamento",
      {
        title: "Montar orçamento (plano de tratamento)",
        description: "Monta o orçamento do paciente a partir dos planos do odontograma e dos itens ditados, em fases " +
          "(1 urgência, 2 gengiva, 3 canal, 4 restaurações, 5 prótese/implante, 6 estética, 7 manutenção), com valor " +
          "congelado, alternativas A/B, desconto e condições de pagamento (à vista, cartão, entrada + parcelas). " +
          "Gera o PDF para o paciente e devolve o link. Procedimento sem preço: devolve valor_necessario sem gravar. " +
          "Se o paciente já tem orçamento em aberto, este vira a versão nova dele (use separado para outro orçamento).",
        inputSchema: esquemaMontar,
        annotations: GRAVACAO,
      },
      (a: ArgsMontar) => chamar(deps, "montar_orcamento", "mcp_montar_orcamento", comDados(a), true),
    );

    servidor.registerTool(
      "alterar_orcamento",
      {
        title: "Alterar orçamento",
        description:
          "Muda o estado de um orçamento: apresentar (entregue ao paciente), aprovar (tudo, uma alternativa " +
          "ou itens pela numeração), recusar, acompanhamento (anota o contato de follow-up) e editar (tirar, pôr ou " +
          "mudar itens, desconto, validade). Editar um orçamento já apresentado cria a versão nova. " +
          "Apresentar, aprovar e editar geram PDF novo.",
        inputSchema: esquemaAlterar,
        annotations: GRAVACAO,
      },
      (a: ArgsAlterar) => chamar(deps, "alterar_orcamento", "mcp_alterar_orcamento", comDados(a), true),
    );

    servidor.registerTool(
      "emitir_receita",
      {
        title: "Emitir receita",
        description:
          "Emite receita (receita comum) em PDF, com número, a partir dos modelos ou de medicamento ditado. " +
          "Confere alergias (penicilina, dipirona, anti-inflamatório), anticoagulante + anti-inflamatório, gestação, " +
          "amamentação, problema renal e criança sem peso: havendo risco, devolve confirmacao_necessaria sem gravar. " +
          "Antibiótico sai em 2 vias (validade 10 dias). Controlados são recusados (talão em papel). Modelos:\n" +
          MODELOS_RECEITA.join("\n"),
        inputSchema: esquemaReceita,
        annotations: GRAVACAO,
      },
      (a: ArgsReceita) => chamar(deps, "emitir_receita", "mcp_emitir_receita", comDados(a), true),
    );

    servidor.registerTool(
      "emitir_atestado",
      {
        title: "Emitir atestado ou declaração",
        description: "Emite em PDF: declaração de comparecimento (com horário), atestado de repouso (dias) ou " +
          "declaração de acompanhante. O horário vem do atendimento registrado no dia, se a Dra. não disser. " +
          "CID só com autorização do paciente.",
        inputSchema: esquemaAtestado,
        annotations: GRAVACAO,
      },
      (a: ArgsAtestado) => chamar(deps, "emitir_atestado", "mcp_emitir_atestado", comDados(a), true),
    );

    servidor.registerTool(
      "emitir_termo",
      {
        title: "Emitir termo de consentimento ou orientações",
        description:
          "Gera em PDF o termo de consentimento livre e esclarecido do tratamento (seções do Manual do CFO: " +
          "técnica, objetivos, benefícios, riscos, alternativas, riscos de não tratar, limitações, conduta no insucesso, " +
          "declaração e assinaturas; menor de idade assina o responsável) ou as orientações pós-operatórias para o paciente.",
        inputSchema: esquemaTermo,
        annotations: GRAVACAO,
      },
      (a: ArgsTermo) => chamar(deps, "emitir_termo", "mcp_emitir_termo", comDados(a), true),
    );

    servidor.registerTool(
      "ver_documentos",
      {
        title: "Ver documentos",
        description: "Com paciente: lista orçamentos (status, total, próximo contato), receitas, atestados e termos, " +
          "com link novo para cada PDF. Sem paciente: orçamentos com contato de acompanhamento na hora, orçamentos " +
          "vencendo e últimos documentos. Com regerar {tipo, numero}: gera o PDF de novo.",
        inputSchema: esquemaVer,
        annotations: { ...LEITURA, readOnlyHint: false },
      },
      (a: ArgsVer) => chamar(deps, "ver_documentos", "mcp_ver_documentos", comDados(a), Boolean(a.regerar)),
    );
  },
};
