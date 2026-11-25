// Servidor MCP do consultório.
//
// Ferramentas de alto nível que o Claude da dentista usa para ler e
// gravar na base. Toda regra (validação, auditoria, "nada se apaga") mora nas
// funções do Postgres (supabase/migrations); aqui só traduzimos a chamada da
// IA para essas funções e devolvemos o resultado em texto.
//
// Este arquivo não depende do Deno nem do Supabase: recebe `rpc` e
// `acessoValido` prontos, para ser testado localmente (tests/).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";
import {
  data,
  type Dependencias,
  executar,
  GRAVACAO,
  hora,
  LEITURA,
  type Modulo,
  NOTA_TEXTO_ORIGINAL,
  paciente_id,
  textoOriginal,
} from "./comum.ts";
import { modulo as agenda } from "./ferramentas/agenda.ts";
import { modulo as calendario } from "./ferramentas/calendario.ts";
import { modulo as documentos } from "./ferramentas/documentos.ts";
import { modulo as estoque } from "./ferramentas/estoque.ts";
import { modulo as fichaOnline } from "./ferramentas/ficha_online.ts";
import { modulo as financeiro } from "./ferramentas/financeiro.ts";
import { modulo as ipad } from "./ferramentas/ipad.ts";
import { modulo as precos } from "./ferramentas/precos.ts";
import condicoes from "./catalogos/condicoes.json" with { type: "json" };
import perguntas from "./catalogos/anamnese.json" with { type: "json" };

export const VERSAO = "0.5.1";

export { type Arquivos, type Dependencias, ErroRpc, type Rpc } from "./comum.ts";

/** Módulos de ferramentas (cada um no seu arquivo em ferramentas/). */
export const MODULOS: Modulo[] = [agenda, calendario, documentos, estoque, fichaOnline, financeiro, ipad, precos];

const INSTRUCOES_BASE = `Ferramentas do prontuário do consultório odontológico da Dra. Andressa.
Quem fala com você é a própria dentista, quase sempre por ditado no celular, logo depois de atender.

Regras:
- Antes de gravar (cadastrar, atualizar, anamnese, odontograma, atendimento, preço), resuma em uma ou duas frases o que vai gravar e espere a Dra. confirmar. Se ela já disse "pode gravar", grave direto.
- Sempre passe em texto_original o pedido da Dra. palavra por palavra. Ele fica guardado na auditoria.
- Para qualquer registro de paciente, primeiro use buscar_paciente e use o id retornado. Se a busca devolver mais de um paciente ou só nomes parecidos, pergunte qual é antes de seguir. Nunca adivinhe.
- Dentes na numeração FDI (11–48 permanentes, 51–85 decíduos). Faces: M, D, O (posteriores) ou I (anteriores), V (= vestibular/bucal), L (inferiores) ou P (superiores). "Resina MO no 36" = dente 36, faces "MO".
- Procedimentos: use o procedimento_codigo do catálogo (listar_procedimentos); a resina certa (1 a 4 faces) e o tipo de extração são escolhidos sozinhos pelo dente e pelas faces. O que for feito num dente atualiza o odontograma sozinho.
- Anamnese: registre só o que a Dra. disse; "o resto tudo não" = demais_negativas. As respostas "sim" com risco viram alertas de saúde.
- Odontograma: inicial = o que o paciente já tem (cárie, restauração antiga, dente ausente); planejado = tratamento a fazer. O que foi feito aqui vem do registrar_atendimento.
- Se faltar algo essencial (dente, paciente), pergunte. Se faltar algo secundário (horário, cor da resina), grave sem e avise.
- Prontuário, anamnese e odontograma não se apagam. Corrija com um novo registro: atendimento com corrige_atendimento_id e motivo_correcao (repetindo o atendimento inteiro, já corrigido); odontograma com remover = true e motivo.
- Leia sempre os alertas_saude e os avisos que as ferramentas devolvem e repita para a Dra. os que importam (alergias, anticoagulante, gestação, bisfosfonato, pressão alta).
- Preços: só mude com salvar_procedimento depois de a Dra. confirmar o valor novo.
- Datas no formato AAAA-MM-DD, horários HH:MM, fuso de São Paulo.`;

export function instrucoes(): string {
  const extras = MODULOS.flatMap((m) => m.instrucoes).map((l) => `- ${l}`);
  return [INSTRUCOES_BASE, ...extras].join("\n");
}

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

type Condicao = { codigo: string; nome: string; tipo: string; usa_faces: boolean };
type Pergunta = { codigo: string; grupo: string; texto: string; tipo: string; detalhe?: string };

const CONDICOES = (condicoes as Condicao[]).map((c) => c.codigo) as [string, ...string[]];
const PERGUNTAS = (perguntas as Pergunta[]).map((p) => p.codigo) as [string, ...string[]];

const REGIOES_DENTES = REGIOES.filter((r) => r !== "boca" && r !== "outra") as unknown as [string, ...string[]];

const CATEGORIAS = [
  "diagnostico",
  "prevencao",
  "dentistica",
  "endodontia",
  "periodontia",
  "cirurgia",
  "protese",
  "implante",
  "estetica",
  "disfuncao",
  "outros",
] as const;

const CAMPOS_LIMPAVEIS = [
  "nome_social",
  "apelido",
  "data_nascimento",
  "sexo",
  "cpf",
  "rg",
  "telefone",
  "email",
  "endereco",
  "profissao",
  "estado_civil",
  "contato_emergencia",
  "origem",
  "convenio",
  "observacoes",
] as const;

/** Lista das perguntas para a descrição da ferramenta, agrupada. */
export function textoPerguntas(): string {
  const grupos = new Map<string, string[]>();
  for (const p of perguntas as Pergunta[]) {
    const linha = `${p.codigo}${p.tipo === "sim_nao" ? "" : " (resposta aberta)"}: ${p.texto}`;
    grupos.set(p.grupo, [...(grupos.get(p.grupo) ?? []), linha]);
  }
  return [...grupos].map(([g, linhas]) => `${g}:\n${linhas.join("\n")}`).join("\n");
}

/** Lista das condições do odontograma para a descrição da ferramenta. */
export function textoCondicoes(): string {
  const nomes: Record<string, string> = {
    estado: "Estado",
    achado: "Achados (só camada inicial)",
    trabalho: "Tratamentos (inicial = já existe; planejado = a fazer)",
    ausencia: "Ausência (planejado = extração)",
  };
  const grupos = new Map<string, string[]>();
  for (const c of condicoes as Condicao[]) {
    grupos.set(c.tipo, [...(grupos.get(c.tipo) ?? []), `${c.codigo}${c.usa_faces ? " (com faces)" : ""}`]);
  }
  return [...grupos].map(([t, cods]) => `${nomes[t] ?? t}: ${cods.join(", ")}`).join("\n");
}

const alerta = z.object({
  tipo: z.enum(TIPOS_ALERTA),
  descricao: z.string().min(2).describe("Ex.: alergia a dipirona; usa varfarina."),
});

const responsavel = z.object({
  nome: z.string(),
  cpf: z.string().optional(),
  parentesco: z.string().optional(),
  telefone: z.string().optional(),
  e_pagador: z.boolean().optional().describe("É quem paga (padrão: sim)."),
});

// Campos da ficha usados no cadastro e na atualização.
const camposFicha = {
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
  consentimento_lgpd: z.boolean().optional().describe("O paciente aceitou o aviso de privacidade."),
  consentimento_imagem: z.boolean().optional().describe("O paciente autorizou uso de imagem."),
};

const esquemaBusca = {
  busca: z.string().optional().describe("Nome, apelido, CPF, telefone ou número da ficha, como a Dra. disse."),
  paciente_id: z.string().optional().describe("Id do paciente, se já souber (abre a ficha completa)."),
  incluir_arquivados: z.boolean().optional().describe("Incluir pacientes arquivados na busca."),
  texto_original: z.string().optional().describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsBusca = z.infer<z.ZodObject<typeof esquemaBusca>>;

const esquemaCadastro = {
  nome: z.string().min(3).describe("Nome completo."),
  ...camposFicha,
  alertas_saude: z.array(alerta).optional().describe(
    "Alergias, medicamentos de risco e condições que mudam a conduta.",
  ),
  observacoes: z.string().optional(),
  responsavel: responsavel.optional().describe("Responsável legal, obrigatório para menores de 18 anos."),
  confirmar_homonimo: z.boolean().optional().describe("Use true só depois que a Dra. confirmar que é outra pessoa."),
  texto_original: textoOriginal(),
};
type ArgsCadastro = z.infer<z.ZodObject<typeof esquemaCadastro>>;

const esquemaAtualizacao = {
  paciente_id: paciente_id(),
  nome: z.string().min(3).optional().describe("Nome completo corrigido."),
  ...camposFicha,
  observacoes: z.string().optional().describe(
    "Substitui todas as observações. Para só anotar algo, use observacoes_acrescentar.",
  ),
  observacoes_acrescentar: z.string().optional().describe("Acrescenta uma linha datada às observações."),
  arquivar: z.boolean().optional().describe("true arquiva (some das buscas, prontuário guardado); false desarquiva."),
  responsavel: responsavel.optional().describe("Inclui um responsável ou atualiza o de mesmo nome."),
  alertas_adicionar: z.array(alerta).optional(),
  alertas_remover: z.array(z.string()).optional().describe(
    'Trecho do alerta a tirar (ex.: "dipirona"). Alertas que vieram da anamnese mudam pela anamnese.',
  ),
  limpar: z.array(z.enum(CAMPOS_LIMPAVEIS)).optional().describe("Campos a apagar da ficha."),
  texto_original: textoOriginal(),
};
type ArgsAtualizacao = z.infer<z.ZodObject<typeof esquemaAtualizacao>>;

const esquemaAnamnese = {
  paciente_id: paciente_id(),
  respostas: z.array(z.object({
    pergunta: z.enum(PERGUNTAS),
    resposta: z.union([z.string(), z.boolean(), z.number()]).optional().describe(
      "sim, nao ou nao_sabe nas perguntas de sim/não; texto livre nas de resposta aberta.",
    ),
    detalhe: z.string().optional().describe('O que a pessoa contou (ex.: "dipirona, urticária"; "Xarelto 20 mg").'),
  })).optional(),
  demais_negativas: z.boolean().optional().describe(
    'true quando a Dra. disse "o resto tudo não": marca não em todas as perguntas de sim/não ainda sem resposta.',
  ),
  pressao_arterial: z.string().optional().describe('Ex.: 120x80 ou "12 por 8".'),
  frequencia_cardiaca: z.number().optional().describe("Batimentos por minuto."),
  observacoes: z.string().optional(),
  origem: z.enum(["ditado", "formulario", "papel"]).optional().describe("Padrão: ditado."),
  assinada: z.boolean().optional().describe("true quando o paciente assinou a ficha de anamnese impressa."),
  texto_original: textoOriginal(),
};
type ArgsAnamnese = z.infer<z.ZodObject<typeof esquemaAnamnese>>;

const esquemaOdontograma = {
  paciente_id: paciente_id(),
  data: data().optional().describe("AAAA-MM-DD. Padrão: hoje."),
  marcas: z.array(z.object({
    dente: z.number().int().optional().describe("FDI, ex.: 36."),
    dentes: z.array(z.number().int()).optional().describe("Vários dentes com a mesma marca, ex.: [18, 28, 38, 48]."),
    regiao: z.enum(REGIOES_DENTES).optional().describe("Todos os dentes de uma arcada, quadrante (Q) ou sextante (S)."),
    condicao: z.enum(CONDICOES).optional().describe("Opcional quando vem procedimento_codigo."),
    faces: z.string().optional().describe("Ex.: O, MOD. Só para condições com faces."),
    camada: z.enum(["inicial", "planejado"]).optional().describe("Padrão: inicial."),
    detalhe: z.string().optional().describe("Ex.: amálgama; metalocerâmica; mobilidade grau 2."),
    procedimento_codigo: z.string().optional().describe(
      "Para o planejado: procedimento do catálogo (vai para o orçamento).",
    ),
    remover: z.boolean().optional().describe("true para desfazer uma marca feita por engano."),
    motivo: z.string().optional().describe("Obrigatório ao remover."),
  })).min(1),
  texto_original: textoOriginal(),
};
type ArgsOdontograma = z.infer<z.ZodObject<typeof esquemaOdontograma>>;

const esquemaAtendimento = {
  paciente_id: paciente_id(),
  data: data().optional().describe("AAAA-MM-DD. Padrão: hoje."),
  hora_inicio: hora().optional(),
  hora_fim: hora().optional(),
  procedimentos: z.array(z.object({
    procedimento_codigo: z.string().optional().describe(
      "Código do catálogo (listar_procedimentos), ex.: resina_2_faces.",
    ),
    procedimento: z.string().min(2).optional().describe(
      'Nome como a Dra. disse, se não souber o código (ex.: "restauração em resina"). O sistema tenta ligar ao catálogo.',
    ),
    dente: z.number().int().optional().describe("FDI, ex.: 36."),
    faces: z.string().optional().describe("Ex.: MO, MOD, V. Só com dente."),
    regiao: z.enum(REGIOES).optional().describe("Quando não é um dente: boca, arcada, quadrante (Q) ou sextante (S)."),
    etapa: z.enum(["concluido", "parcial"]).optional().describe(
      "parcial = continua em outra sessão (ex.: canal sessão 1); só o concluído vai para o odontograma.",
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
  corrige_atendimento_id: z.string().optional().describe(
    "Só para correção: id do atendimento corrigido. A correção substitui o original: repita tudo, já corrigido.",
  ),
  motivo_correcao: z.string().optional().describe("Obrigatório junto com corrige_atendimento_id."),
  texto_original: textoOriginal(),
};
type ArgsAtendimento = z.infer<z.ZodObject<typeof esquemaAtendimento>>;

const esquemaListaProcedimentos = {
  busca: z.string().optional().describe("Parte do nome (ex.: resina, canal, implante). Vazio lista tudo."),
  categoria: z.enum(CATEGORIAS).optional(),
  incluir_inativos: z.boolean().optional(),
  texto_original: z.string().optional().describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsListaProcedimentos = z.infer<z.ZodObject<typeof esquemaListaProcedimentos>>;

const esquemaProcedimento = {
  codigo: z.string().optional().describe(
    "Código do procedimento a alterar. Sem código, procura pelo nome ou inclui um novo.",
  ),
  nome: z.string().optional().describe("Nome como vai no orçamento."),
  preco: z.number().nonnegative().nullable().optional().describe("Preço da Dra. em reais. null tira o preço."),
  grupo: z.string().optional().describe("Seção do orçamento (ex.: Restaurações, Implantes)."),
  categoria: z.enum(CATEGORIAS).optional().describe("Obrigatória para incluir um novo."),
  aplica_a: z.enum(["boca", "arcada", "sextante", "dente", "dente_faces", "regiao"]).optional(),
  sinonimos_adicionar: z.array(z.string()).optional().describe("Outras formas como a Dra. fala esse procedimento."),
  condicao_odontograma: z.enum(CONDICOES).optional().describe("O que ele vira no odontograma quando feito num dente."),
  detalhe_odontograma: z.string().optional(),
  ativo: z.boolean().optional().describe("false tira do catálogo (nada é apagado)."),
  publicar_no_site: z.boolean().optional(),
  observacao: z.string().optional(),
  texto_original: textoOriginal(),
};
type ArgsProcedimento = z.infer<z.ZodObject<typeof esquemaProcedimento>>;

export function criarServidor(deps: Dependencias): McpServer {
  const servidor = new McpServer(
    { name: "consultorio", title: "Consultório", version: VERSAO },
    { instructions: instrucoes() },
  );

  servidor.registerTool(
    "buscar_paciente",
    {
      title: "Buscar paciente",
      description:
        "Procura um paciente por nome, apelido, CPF, telefone ou número da ficha, ou abre a ficha pelo id. " +
        "Com uma correspondência exata, devolve a ficha completa: alertas de saúde, anamnese, odontograma, " +
        "responsáveis e últimos atendimentos. Com várias ou só nomes parecidos, devolve a lista: confirme com a Dra. qual é.",
      inputSchema: esquemaBusca,
      annotations: LEITURA,
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
      annotations: GRAVACAO,
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
    "atualizar_paciente",
    {
      title: "Atualizar ficha do paciente",
      description: "Muda dados da ficha: contato, documentos, endereço (completa o que já existe), observações, " +
        "consentimentos, responsável e alertas de saúde; também arquiva ou desarquiva. Só mude o que a Dra. disse. " +
        "O antes e o depois ficam na auditoria.",
      inputSchema: esquemaAtualizacao,
      annotations: GRAVACAO,
    },
    (a: ArgsAtualizacao) => {
      const { texto_original, paciente_id, ...dados } = a;
      return executar(deps, "atualizar_paciente", "mcp_atualizar_paciente", {
        p_paciente_id: paciente_id,
        p_dados: dados,
        p_texto_original: texto_original,
      }, true);
    },
  );

  servidor.registerTool(
    "registrar_anamnese",
    {
      title: "Registrar anamnese",
      description:
        "Grava respostas da anamnese (questionário de saúde), pressão e frequência cardíaca. Pode ser em partes: " +
        'cada chamada cria uma versão nova que mantém as respostas anteriores. Respostas "sim" de risco viram ' +
        "alertas de saúde na ficha. Devolve as perguntas ainda pendentes. Perguntas (código: texto):\n" +
        textoPerguntas(),
      inputSchema: esquemaAnamnese,
      annotations: GRAVACAO,
    },
    (a: ArgsAnamnese) => {
      const { texto_original, ...dados } = a;
      return executar(deps, "registrar_anamnese", "mcp_registrar_anamnese", {
        p_dados: dados,
        p_texto_original: texto_original,
      }, true);
    },
  );

  servidor.registerTool(
    "registrar_odontograma",
    {
      title: "Registrar odontograma",
      description:
        "Marca no odontograma o que o paciente já tem (camada inicial: achados da avaliação e trabalhos antigos) " +
        "e o que está planejado (camada planejado, de preferência com procedimento_codigo, para o orçamento). " +
        "Marcas que deixam de valer são encerradas sozinhas (ex.: dente ausente encerra tudo no dente). " +
        "O que foi feito no consultório vem do registrar_atendimento. Para desfazer um engano, use remover = true com motivo. " +
        "Condições:\n" + textoCondicoes(),
      inputSchema: esquemaOdontograma,
      annotations: GRAVACAO,
    },
    (a: ArgsOdontograma) => {
      const { texto_original, ...dados } = a;
      return executar(deps, "registrar_odontograma", "mcp_registrar_odontograma", {
        p_dados: dados,
        p_texto_original: texto_original,
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
        "Cada procedimento é ligado ao catálogo (resina pelo número de faces, extração pelo tipo de dente) e, " +
        "se concluído num dente, atualiza o odontograma. " +
        "O registro não pode ser alterado depois; para corrigir, chame de novo com corrige_atendimento_id e motivo_correcao. " +
        "Use antes buscar_paciente para obter o paciente_id.",
      inputSchema: esquemaAtendimento,
      annotations: GRAVACAO,
    },
    (a: ArgsAtendimento) => {
      const { texto_original, ...dados } = a;
      return executar(deps, "registrar_atendimento", "mcp_registrar_atendimento", {
        p_dados: dados,
        p_texto_original: texto_original,
      }, true);
    },
  );

  servidor.registerTool(
    "listar_procedimentos",
    {
      title: "Listar procedimentos",
      description:
        "Mostra o catálogo de procedimentos da Dra. com código e preço. Itens sem preço trazem só a faixa de mercado " +
        "como referência: não diga que é o preço dela. Em dia de campanha, traz também o preco_campanha.",
      inputSchema: esquemaListaProcedimentos,
      annotations: LEITURA,
    },
    (a: ArgsListaProcedimentos) =>
      executar(deps, "listar_procedimentos", "mcp_listar_procedimentos", {
        p_busca: a.busca ?? null,
        p_categoria: a.categoria ?? null,
        p_incluir_inativos: a.incluir_inativos ?? false,
        p_texto_original: a.texto_original ?? null,
      }, false),
  );

  servidor.registerTool(
    "salvar_procedimento",
    {
      title: "Salvar procedimento ou preço",
      description: "Inclui um procedimento no catálogo ou altera um existente (preço, nome, sinônimos, ativo). " +
        "Antes de mudar preço, confirme o valor com a Dra. A mudança fica na auditoria.",
      inputSchema: esquemaProcedimento,
      annotations: GRAVACAO,
    },
    (a: ArgsProcedimento) => {
      const { texto_original, ...dados } = a;
      return executar(deps, "salvar_procedimento", "mcp_salvar_procedimento", {
        p_dados: dados,
        p_texto_original: texto_original,
      }, true);
    },
  );

  for (const m of MODULOS) m.registrar(servidor, deps);

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
