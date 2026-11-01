// Servidor MCP do consultório (etapa 0).
//
// Três ferramentas de alto nível que o Claude da dentista usa para ler e
// gravar na base. Toda regra (validação, auditoria, "nada se apaga") mora nas
// funções do Postgres (supabase/migrations); aqui só traduzimos a chamada da
// IA para essas funções e devolvemos o resultado em texto.
//
// Este arquivo não depende do Deno nem do Supabase: recebe `rpc` e
// `acessoValido` prontos, para ser testado localmente (tests/).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";

export const VERSAO = "0.1.0";

export type Rpc = (funcao: string, argumentos: Record<string, unknown>) => Promise<unknown>;

export interface Dependencias {
  /** Chama uma função do Postgres (PostgREST /rpc). Lança ErroRpc em caso de erro. */
  rpc: Rpc;
  /** Diz se o SHA-256 (hex) do token da URL é um acesso válido. */
  acessoValido: (tokenSha256: string) => Promise<boolean>;
}

export class ErroRpc extends Error {
  constructor(message: string, readonly dica?: string, readonly codigo?: string) {
    super(message);
    this.name = "ErroRpc";
  }
}

const INSTRUCOES = `Ferramentas do prontuário do consultório odontológico da Dra. Andressa.
Quem fala com você é a própria dentista, quase sempre por ditado no celular, logo depois de atender.

Regras:
- Antes de gravar (cadastrar_paciente, registrar_atendimento), resuma em uma ou duas frases o que vai gravar e espere a Dra. confirmar.
- Sempre passe em texto_original o pedido da Dra. palavra por palavra. Ele fica guardado na auditoria.
- Para registrar atendimento, primeiro use buscar_paciente e use o id retornado. Se a busca devolver mais de um paciente ou só nomes parecidos, pergunte qual é antes de seguir. Nunca adivinhe.
- Dentes na numeração FDI (11–48 permanentes, 51–85 decíduos). Faces: M, D, O (posteriores) ou I (anteriores), V (= vestibular/bucal), L (inferiores) ou P (superiores). "Resina MO no 36" = dente 36, faces "MO".
- Se faltar algo essencial (dente, paciente), pergunte. Se faltar algo secundário (horário, cor da resina), grave sem e avise.
- Atendimentos não podem ser alterados nem apagados. Para corrigir, registre um novo atendimento com corrige_atendimento_id e motivo_correcao.
- Leia sempre os alertas_saude e os avisos que as ferramentas devolvem e repita para a Dra. os que importam (alergias, anticoagulante, gestação).
- Datas no formato AAAA-MM-DD, horários HH:MM, fuso de São Paulo.`;

const NOTA_TEXTO_ORIGINAL = "O pedido da Dra., palavra por palavra (vai para a auditoria).";

const TIPOS_ALERTA = [
  "alergia",
  "anticoagulante",
  "antiagregante",
  "bisfosfonato",
  "gestacao",
  "amamentacao",
  "cardiopatia",
  "profilaxia_antibiotica",
  "diabetes",
  "hipertensao",
  "coagulopatia",
  "imunossupressao",
  "radioterapia_cabeca_pescoco",
  "epilepsia",
  "outro",
] as const;

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

const data = () => z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Use AAAA-MM-DD");
const hora = () => z.string().regex(/^\d{1,2}:\d{2}$/, "Use HH:MM");

type Resultado = { content: { type: "text"; text: string }[]; isError?: boolean };

function texto(valor: unknown): string {
  return JSON.stringify(valor, null, 1);
}

async function executar(
  deps: Dependencias,
  ferramenta: string,
  funcao: string,
  argumentos: Record<string, unknown>,
  grava: boolean,
): Promise<Resultado> {
  try {
    const resposta = await deps.rpc(funcao, argumentos);
    return { content: [{ type: "text", text: texto(resposta) }] };
  } catch (e) {
    const erro = e instanceof ErroRpc ? e : new ErroRpc(e instanceof Error ? e.message : String(e));
    // Guarda a tentativa que falhou (a transação dela foi desfeita).
    try {
      await deps.rpc("mcp_registrar_falha", {
        p_ferramenta: ferramenta,
        p_argumentos: argumentos.p_dados ?? argumentos,
        p_texto_original: argumentos.p_texto_original ?? null,
        p_erro: erro.message,
      });
    } catch (_) {
      // Sem registro da falha não é motivo para esconder o erro original.
    }
    const partes = [
      grava ? "Nada foi gravado." : "A busca não foi feita.",
      erro.message,
      erro.dica ?? "",
    ].filter(Boolean);
    return { isError: true, content: [{ type: "text", text: partes.join(" ") }] };
  }
}

const esquemaBusca = {
  busca: z.string().optional().describe("Nome, apelido, CPF, telefone ou número da ficha, como a Dra. disse."),
  paciente_id: z.string().optional().describe("Id do paciente, se já souber (abre a ficha completa)."),
  incluir_arquivados: z.boolean().optional().describe("Incluir pacientes arquivados na busca."),
  texto_original: z.string().optional().describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsBusca = z.infer<z.ZodObject<typeof esquemaBusca>>;

const esquemaCadastro = {
  nome: z.string().min(3).describe("Nome completo."),
  nome_social: z.string().optional(),
  apelido: z.string().optional().describe("Como a Dra. chama o paciente no dia a dia (ex.: Mari)."),
  data_nascimento: data().optional().describe("AAAA-MM-DD. Se ela disser só a idade, pergunte a data."),
  sexo: z.enum(["feminino", "masculino", "outro", "nao_informado"]).optional(),
  cpf: z.string().optional().describe("Com ou sem pontuação."),
  rg: z.string().optional(),
  telefone: z.string().optional().describe("Com DDD."),
  whatsapp: z.boolean().optional().describe("O telefone é WhatsApp (padrão: sim)."),
  email: z.string().optional(),
  endereco: z.object({
    logradouro: z.string().optional(),
    numero: z.string().optional(),
    complemento: z.string().optional(),
    bairro: z.string().optional(),
    cidade: z.string().optional(),
    uf: z.string().optional(),
    cep: z.string().optional(),
  }).optional(),
  profissao: z.string().optional(),
  estado_civil: z.string().optional(),
  contato_emergencia: z.object({
    nome: z.string().optional(),
    parentesco: z.string().optional(),
    telefone: z.string().optional(),
  }).optional(),
  origem: z.string().optional().describe("Como conheceu o consultório (indicação, Instagram...)."),
  convenio: z.string().optional(),
  alertas_saude: z.array(z.object({
    tipo: z.enum(TIPOS_ALERTA),
    descricao: z.string().min(2).describe("Ex.: alergia a dipirona; usa varfarina."),
  })).optional().describe("Alergias, medicamentos de risco e condições que mudam a conduta."),
  observacoes: z.string().optional(),
  responsavel: z.object({
    nome: z.string(),
    cpf: z.string().optional(),
    parentesco: z.string().optional(),
    telefone: z.string().optional(),
    e_pagador: z.boolean().optional().describe("É quem paga (padrão: sim)."),
  }).optional().describe("Responsável legal, obrigatório para menores de 18 anos."),
  consentimento_lgpd: z.boolean().optional().describe("O paciente aceitou o aviso de privacidade."),
  consentimento_imagem: z.boolean().optional().describe("O paciente autorizou uso de imagem."),
  confirmar_homonimo: z.boolean().optional().describe("Use true só depois que a Dra. confirmar que é outra pessoa."),
  texto_original: z.string().min(1).describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsCadastro = z.infer<z.ZodObject<typeof esquemaCadastro>>;

const esquemaAtendimento = {
  paciente_id: z.string().describe("Id devolvido por buscar_paciente."),
  data: data().optional().describe("AAAA-MM-DD. Padrão: hoje."),
  hora_inicio: hora().optional(),
  hora_fim: hora().optional(),
  procedimentos: z.array(z.object({
    procedimento: z.string().min(2).describe("Ex.: Restauração em resina composta; Exodontia simples; Profilaxia."),
    dente: z.number().int().optional().describe("FDI, ex.: 36."),
    faces: z.string().optional().describe("Ex.: MO, MOD, V. Só com dente."),
    regiao: z.enum(REGIOES).optional().describe("Quando não é um dente: boca, arcada, quadrante (Q) ou sextante (S)."),
    etapa: z.enum(["concluido", "parcial"]).optional().describe(
      "parcial = continua em outra sessão (ex.: canal sessão 1).",
    ),
    observacao: z.string().optional().describe("Ex.: cor A2; sessão 1 de 2."),
  })).optional().describe("Um item por procedimento e por dente."),
  evolucao: z.string().min(5).describe(
    "Texto da evolução como iria no prontuário: técnico, objetivo, terceira pessoa, com o que foi feito e como.",
  ),
  anestesia: z.array(z.object({
    anestesico: z.string().describe("Ex.: articaína 4%; lidocaína 2%."),
    vasoconstritor: z.string().optional().describe("Ex.: epinefrina 1:100.000."),
    tubetes: z.number().optional(),
    tecnica: z.string().optional().describe("Ex.: bloqueio do alveolar inferior; infiltrativa."),
  })).optional(),
  materiais: z.array(z.object({
    material: z.string(),
    quantidade: z.number().optional(),
    unidade: z.string().optional(),
    detalhe: z.string().optional().describe("Marca, cor, lote."),
  })).optional().describe("Materiais que a Dra. citou (vai alimentar o estoque depois)."),
  intercorrencias: z.string().optional(),
  orientacoes: z.string().optional().describe("Orientações dadas ao paciente."),
  proxima_etapa: z.string().optional(),
  retorno_previsto: data().optional().describe("AAAA-MM-DD."),
  retorno_em_dias: z.number().int().positive().optional().describe("Alternativa a retorno_previsto (ex.: 15)."),
  corrige_atendimento_id: z.string().optional().describe("Só para correção: id do atendimento corrigido."),
  motivo_correcao: z.string().optional().describe("Obrigatório junto com corrige_atendimento_id."),
  texto_original: z.string().min(1).describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsAtendimento = z.infer<z.ZodObject<typeof esquemaAtendimento>>;

export function criarServidor(deps: Dependencias): McpServer {
  const servidor = new McpServer(
    { name: "consultorio", title: "Consultório", version: VERSAO },
    { instructions: INSTRUCOES },
  );

  servidor.registerTool(
    "buscar_paciente",
    {
      title: "Buscar paciente",
      description:
        "Procura um paciente por nome, apelido, CPF, telefone ou número da ficha, ou abre a ficha pelo id. " +
        "Com uma correspondência exata, devolve a ficha completa (alertas de saúde, responsáveis e últimos atendimentos). " +
        "Com várias ou só nomes parecidos, devolve a lista: confirme com a Dra. qual é.",
      inputSchema: esquemaBusca,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    (a: ArgsBusca) =>
      executar(deps, "buscar_paciente", "mcp_buscar_paciente", {
        p_busca: a.busca ?? null,
        p_paciente_id: a.paciente_id ?? null,
        p_texto_original: a.texto_original ?? null,
        p_incluir_arquivados: a.incluir_arquivados ?? false,
      }, false),
  );

  servidor.registerTool(
    "cadastrar_paciente",
    {
      title: "Cadastrar paciente",
      description: "Abre a ficha de um paciente novo. Só o nome completo é obrigatório; o resto pode vir depois. " +
        "Valida CPF, telefone e data, e avisa o que ficou faltando. Se já existir alguém com nome parecido, " +
        "não grava e devolve status confirmacao_necessaria: pergunte à Dra. e, se for outra pessoa, chame de novo com confirmar_homonimo = true.",
      inputSchema: esquemaCadastro,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    (a: ArgsCadastro) => {
      const { texto_original, confirmar_homonimo, ...dados } = a;
      return executar(deps, "cadastrar_paciente", "mcp_cadastrar_paciente", {
        p_dados: dados,
        p_texto_original: texto_original,
        p_confirmar_homonimo: confirmar_homonimo ?? false,
      }, true);
    },
  );

  servidor.registerTool(
    "registrar_atendimento",
    {
      title: "Registrar atendimento",
      description:
        "Grava a evolução clínica de um atendimento no prontuário: procedimentos por dente/faces ou região, " +
        "anestesia, materiais citados, intercorrências, orientações, próxima etapa e retorno. " +
        "O registro não pode ser alterado depois; para corrigir, chame de novo com corrige_atendimento_id e motivo_correcao. " +
        "Use antes buscar_paciente para obter o paciente_id.",
      inputSchema: esquemaAtendimento,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    (a: ArgsAtendimento) => {
      const { texto_original, ...dados } = a;
      return executar(deps, "registrar_atendimento", "mcp_registrar_atendimento", {
        p_dados: dados,
        p_texto_original: texto_original,
      }, true);
    },
  );

  return servidor;
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, accept, mcp-protocol-version, mcp-session-id, authorization",
};

export async function sha256Hex(valor: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(valor));
  return Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Token da URL: .../mcp/<token> (o Supabase entrega o caminho a partir do nome da função). */
export function tokenDaUrl(url: string): string | null {
  const partes = new URL(url).pathname.split("/").filter(Boolean);
  const i = partes.lastIndexOf("mcp");
  const token = i >= 0 ? partes[i + 1] : partes[0];
  return token && /^[A-Za-z0-9_-]{32,128}$/.test(token) ? token : null;
}

export function criarHandler(deps: Dependencias): (req: Request) => Promise<Response> {
  // Cache curto dos tokens já conferidos, para não ir ao banco a cada mensagem.
  const cache = new Map<string, { valido: boolean; ate: number }>();

  async function autorizado(token: string): Promise<boolean> {
    const hash = await sha256Hex(token);
    const agora = Date.now();
    const visto = cache.get(hash);
    if (visto && visto.ate > agora) return visto.valido;
    const valido = await deps.acessoValido(hash);
    if (cache.size > 1000) cache.clear();
    cache.set(hash, { valido, ate: agora + (valido ? 5 * 60_000 : 60_000) });
    return valido;
  }

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    const token = tokenDaUrl(req.url);
    if (!token || !(await autorizado(token))) {
      return new Response("Not found", { status: 404, headers: CORS });
    }
    if (req.method !== "POST") {
      // Sem sessão nem fluxo SSE: o MCP stateless só usa POST.
      return new Response("Method not allowed", { status: 405, headers: { ...CORS, Allow: "POST, OPTIONS" } });
    }

    const servidor = criarServidor(deps);
    const transporte = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await servidor.connect(transporte);
    const resposta = await transporte.handleRequest(req);
    const headers = new Headers(resposta.headers);
    for (const [k, v] of Object.entries(CORS)) headers.set(k, v);
    return new Response(resposta.body, { status: resposta.status, headers });
  };
}
