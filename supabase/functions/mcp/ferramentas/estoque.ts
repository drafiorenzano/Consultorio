// Ferramentas do módulo "estoque": compras, movimentos (uso avulso, perda,
// vencido, contagem, desfazer), consultas e cadastro de materiais e kits.
//
// A regra fica no banco (migrations *_estoque*.sql): quantidades guardadas na
// unidade de uso, custo médio ponderado, lotes com saída pelo que vence
// primeiro e baixa automática do kit do procedimento quando o atendimento é
// gravado. Aqui só ficam os esquemas e as descrições para o ditado.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  data,
  type Dependencias,
  GRAVACAO,
  gravarComDados,
  LEITURA,
  type Modulo,
  textoOriginal,
  textoOriginalOpcional,
} from "../comum.ts";

export const CATEGORIAS_MATERIAL = [
  "anestesico",
  "agulha",
  "epi",
  "descartavel",
  "dentistica",
  "endodontia",
  "cirurgia",
  "periodontia",
  "protese",
  "implante",
  "esterilizacao",
  "clareamento",
  "profilaxia",
  "antissepsia",
  "radiologia",
  "instrumental",
  "outros",
] as const;

export const FORMAS_PAGAMENTO = [
  "pix",
  "dinheiro",
  "debito",
  "credito_vista",
  "credito_parcelado",
  "boleto",
  "transferencia",
] as const;

export const TIPOS_MOVIMENTO = [
  "uso",
  "perda",
  "vencido",
  "contagem",
  "entrada",
  "desfazer",
  "cancelar_compra",
] as const;

export const VISOES = [
  "resumo",
  "saldos",
  "material",
  "lista_compras",
  "compras_recentes",
  "vencimentos",
  "consumo",
  "custos",
] as const;

const material = () =>
  z.string().min(1).describe(
    'Como a Dra. falou (ex.: "articaína", "luva M", "resina A3", "gaze"). O sistema acha pelo nome ou sinônimo.',
  );
const unidade = (padrao: string) =>
  z.string().optional().describe(
    `Unidade dita (caixa, pacote, tubete, unidade, par, seringa, g, ml...). Sem unidade, vale a ${padrao}.`,
  );
const validade = () =>
  z.string()
    .regex(/^(\d{4}-\d{1,2}(-\d{1,2})?|\d{1,2}\/\d{4})$/, "Use AAAA-MM-DD, AAAA-MM ou MM/AAAA")
    .optional()
    .describe('Validade do lote. Só mês e ano (ex.: "03/2027") vale até o fim do mês.');
const preco = (o_que: string) => z.number().nonnegative().optional().describe(o_que);

// ---------------------------------------------------------------------------
// registrar_compra
// ---------------------------------------------------------------------------

const esquemaCompra = {
  fornecedor: z.string().optional().describe(
    "Loja ou distribuidor (ex.: Dental Cremer). Basta parte do nome; fornecedor novo é cadastrado sozinho.",
  ),
  data: data().optional().describe("Data da compra (AAAA-MM-DD). Sem data, hoje."),
  itens: z.array(z.object({
    material: material(),
    quantidade: z.number().positive().describe("Quanto comprou, na unidade dita."),
    unidade: unidade("unidade de compra do cadastro (ex.: caixa)"),
    preco_unitario: preco("Preço de cada unidade dita, em reais."),
    preco_total: preco("Preço total do item, em reais (se ela disse o total em vez do unitário)."),
    lote: z.string().optional().describe("Número do lote, se ela disser."),
    validade: validade(),
  })).min(1).describe("Um item por material."),
  frete: preco("Frete da nota, em reais (rateado nos itens)."),
  desconto: preco("Desconto da nota, em reais (rateado nos itens)."),
  valor_total: preco("Total da nota, se ela disser (serve de conferência; com um item sem preço, vira o preço dele)."),
  forma_pagamento: z.enum(FORMAS_PAGAMENTO).optional(),
  nota_fiscal: z.string().optional().describe("Número da nota fiscal ou do pedido."),
  observacao: z.string().optional(),
  texto_original: textoOriginal(),
};
type ArgsCompra = z.infer<z.ZodObject<typeof esquemaCompra>>;

// ---------------------------------------------------------------------------
// movimentar_estoque
// ---------------------------------------------------------------------------

const esquemaMovimento = {
  data: data().optional().describe("Data dos movimentos (AAAA-MM-DD). Sem data, hoje."),
  movimentos: z.array(z.object({
    tipo: z.enum(TIPOS_MOVIMENTO).describe(
      "uso = gasto fora de atendimento registrado; perda = caiu, contaminou, quebrou; vencido = descarte por validade; " +
        "contagem = quanto há agora (o sistema lança a diferença; 0 se acabou); entrada = chegou sem compra (amostra, " +
        "doação); desfazer = anula um movimento (movimento_id); cancelar_compra = anula uma compra inteira (compra_id).",
    ),
    material: material().optional().describe("Obrigatório, menos em desfazer e cancelar_compra."),
    quantidade: z.number().nonnegative().optional().describe("Obrigatória, menos em desfazer e cancelar_compra."),
    unidade: unidade("unidade de uso do cadastro (ex.: tubete, par, unidade)"),
    lote: z.string().optional().describe("Lote, se ela disser (na contagem e na entrada, cria o lote)."),
    validade: validade(),
    motivo: z.string().optional().describe("Obrigatório em desfazer e cancelar_compra."),
    paciente_id: z.string().optional().describe("Só no uso: paciente em quem foi usado, se ela disser."),
    movimento_id: z.string().optional().describe("Desfazer: id do movimento (ver_estoque, visão material)."),
    compra_id: z.string().optional().describe("Cancelar compra: id da compra (ver_estoque, visão compras_recentes)."),
    preco_unitario: preco("Entrada ou contagem: preço de cada unidade dita, se ela souber."),
    preco_total: preco("Entrada ou contagem: preço total, se ela souber."),
  })).min(1),
  texto_original: textoOriginal(),
};
type ArgsMovimento = z.infer<z.ZodObject<typeof esquemaMovimento>>;

// ---------------------------------------------------------------------------
// ver_estoque
// ---------------------------------------------------------------------------

const esquemaVer = {
  visao: z.enum(VISOES).optional().describe("Sem visão, resumo."),
  busca: z.string().optional().describe(
    "Material ou parte do nome (saldos e consumo filtram; material exige). Ex.: resina, luva, articaína.",
  ),
  categoria: z.enum(CATEGORIAS_MATERIAL).optional().describe("Filtro da visão saldos."),
  dias: z.number().int().positive().max(730).optional().describe(
    "vencimentos: próximos N dias (padrão 60); compras_recentes: últimos N dias (padrão 60).",
  ),
  semanas: z.number().int().min(1).max(26).optional().describe("consumo: quantas semanas (padrão 4)."),
  procedimento_codigo: z.string().optional().describe(
    "custos: código do procedimento (listar_procedimentos), ou atendimento_base para o kit de todo atendimento.",
  ),
  incluir_inativos: z.boolean().optional(),
  texto_original: textoOriginalOpcional(),
};
type ArgsVer = z.infer<z.ZodObject<typeof esquemaVer>>;

// ---------------------------------------------------------------------------
// salvar_material
// ---------------------------------------------------------------------------

const esquemaMaterial = {
  codigo: z.string().optional().describe("Código do material a alterar (ver_estoque). Sem código, procura pelo nome."),
  nome: z.string().optional().describe("Nome do material (com código, renomeia)."),
  novo: z.boolean().optional().describe("true quando é mesmo um material novo, parecido com um existente."),
  categoria: z.enum(CATEGORIAS_MATERIAL).optional().describe("Obrigatória para cadastrar um novo."),
  grupo: z.string().optional().describe(
    "Grupo de itens que se substituem (ex.: resina_composta, luva_procedimento, fio_sutura). Vazio tira do grupo.",
  ),
  padrao_do_grupo: z.boolean().optional().describe("true: é o que o kit usa quando ela não diz qual (ex.: luva M)."),
  variantes: z.array(z.string()).optional().describe(
    'Palavras que escolhem este item dentro do grupo quando ditas no atendimento (ex.: ["a2"], ["luva m", "medio"]).',
  ),
  unidade_compra: z.string().optional().describe("Como compra (caixa, pacote, frasco, seringa, rolo...)."),
  unidade_uso: z.string().optional().describe(
    "Como gasta (tubete, unidade, par, g, ml, gota...). Não muda depois de haver movimentos.",
  ),
  fator: z.number().positive().optional().describe("Quantas unidades de uso vêm em cada unidade de compra (ex.: 50)."),
  estoque_minimo: z.number().nonnegative().optional().describe("Abaixo disso entra nos avisos e na lista de compras."),
  estoque_minimo_unidade: z.string().optional().describe("Unidade do mínimo dito (ex.: caixa). Sem unidade, a de uso."),
  prazo_entrega_dias: z.number().int().min(0).max(90).optional().describe(
    "Dias que o fornecedor leva para entregar (padrão 5).",
  ),
  preco_unidade_compra: z.number().nonnegative().optional().describe(
    "Ajusta à mão o custo médio (por unidade de compra). Normalmente vem das compras.",
  ),
  controla_validade: z.boolean().optional().describe("true: avisa quando falta a validade na compra."),
  sinonimos_adicionar: z.array(z.string()).optional().describe("Outras formas como a Dra. fala esse material."),
  sinonimos_remover: z.array(z.string()).optional(),
  observacao: z.string().optional(),
  ativo: z.boolean().optional().describe("false tira das listas (nada é apagado)."),
  kit: z.object({
    procedimento_codigo: z.string().min(1).describe(
      "Código do procedimento (listar_procedimentos, ex.: exodontia_permanente, resina_2_faces), " +
        "ou atendimento_base para o kit de biossegurança de todo atendimento.",
    ),
    itens: z.array(z.object({
      material: material().describe(
        "Material ou grupo (ex.: resina_composta, luva_procedimento: usa a variante dita no atendimento).",
      ),
      quantidade: z.number().positive().describe("Quanto gasta em cada procedimento."),
      unidade: unidade("unidade de uso"),
      fixo: z.boolean().optional().describe(
        "true: sempre este item, mesmo sendo de um grupo (ex.: sempre fio de seda).",
      ),
      observacao: z.string().optional(),
    })).optional().describe("Linhas a incluir ou mudar (a quantidade dita substitui a anterior)."),
    modo: z.enum(["acrescentar", "substituir"]).optional().describe(
      "acrescentar (padrão) mexe só nas linhas ditas; substituir troca o kit inteiro pelas linhas ditas.",
    ),
    remover: z.array(z.string()).optional().describe("Materiais ou grupos a tirar do kit."),
    anestesia_tubetes: z.number().nonnegative().optional().describe(
      "Tubetes típicos, só para a estimativa de custo (a baixa usa o que foi dito no atendimento).",
    ),
    ativo: z.boolean().optional().describe("false desliga a baixa automática desse kit."),
  }).optional().describe("Kit do procedimento: o que é gasto e baixado sozinho a cada atendimento."),
  texto_original: textoOriginal(),
};
type ArgsMaterial = z.infer<z.ZodObject<typeof esquemaMaterial>>;

// ---------------------------------------------------------------------------
// Módulo
// ---------------------------------------------------------------------------

function registrar(servidor: McpServer, deps: Dependencias) {
  servidor.registerTool(
    "registrar_compra",
    {
      title: "Registrar compra de material",
      description: "Registra uma compra de material: fornecedor, itens com quantidade e preço e, se ela disser, " +
        'lote e validade. Ex.: "comprei duas caixas de articaína a 180 cada na Dental Cremer" = fornecedor ' +
        "Dental Cremer, itens [{material: articaína, quantidade: 2, unidade: caixa, preco_unitario: 180}]. " +
        "Sem unidade, a quantidade é na unidade de compra do cadastro. Atualiza o saldo e o custo médio; frete e " +
        "desconto são rateados nos itens. Se algum material não estiver no cadastro, nada é gravado e voltam nomes " +
        "parecidos. Avisa preço acima do anterior e validade curta. Para anular, use movimentar_estoque (cancelar_compra).",
      inputSchema: esquemaCompra,
      annotations: GRAVACAO,
    },
    (a: ArgsCompra) => gravarComDados(deps, "registrar_compra", "mcp_registrar_compra", a),
  );

  servidor.registerTool(
    "movimentar_estoque",
    {
      title: "Movimentar ou ajustar estoque",
      description: "Lança no estoque o que não vem de compra nem de atendimento: uso avulso, perda, vencido, " +
        "contagem (quanto há na prateleira; o sistema lança a diferença), entrada sem compra (amostra, doação), " +
        "desfazer um movimento errado ou cancelar uma compra. O gasto dos atendimentos já sai sozinho pelo kit do " +
        'procedimento: não lance de novo. Ex.: "contei 3 caixas de luva M" = contagem, quantidade 3, unidade caixa; ' +
        '"perdi dois tubetes de lidocaína" = perda, quantidade 2; "joguei fora a resina A1 vencida" = vencido. ' +
        "Sem unidade, a quantidade é na unidade de uso (tubete, par, unidade). Saídas tiram do lote que vence primeiro. " +
        "Nada se apaga: desfazer e cancelar_compra lançam o contrário e pedem motivo.",
      inputSchema: esquemaMovimento,
      annotations: GRAVACAO,
    },
    (a: ArgsMovimento) => gravarComDados(deps, "movimentar_estoque", "mcp_movimentar_estoque", a),
  );

  servidor.registerTool(
    "ver_estoque",
    {
      title: "Ver estoque",
      description: "Consulta o estoque. Visões: resumo (padrão: abaixo do mínimo, vencimentos e avisos); saldos " +
        "(filtra por busca ou categoria); material (um só: lotes, consumo, quanto dura, últimos movimentos com id, " +
        "compras e kits); lista_compras (o que comprar, quanto, último preço e fornecedor); compras_recentes (com " +
        "compra_id); vencimentos (lotes que vencem nos próximos dias); consumo (gasto por semana, com custo); custos " +
        "(custo de material por procedimento; com procedimento_codigo, o detalhe do kit). " +
        'Ex.: "o que eu preciso comprar?" = lista_compras; "quanto tem de resina?" = saldos, busca resina; ' +
        '"quanto custa o material de um canal de molar?" = custos, procedimento_codigo canal_molar.',
      inputSchema: esquemaVer,
      annotations: LEITURA,
    },
    (a: ArgsVer) => gravarComDados(deps, "ver_estoque", "mcp_ver_estoque", a, false),
  );

  servidor.registerTool(
    "salvar_material",
    {
      title: "Salvar material ou kit",
      description: "Cadastra ou altera um material (nome, categoria, sinônimos, unidade de compra, unidade de uso e " +
        "quantas vêm em cada, estoque mínimo, prazo de entrega, validade, ativo) e/ou o kit de um procedimento, que é " +
        'baixado sozinho a cada atendimento. Ex.: "o mínimo de articaína é 2 caixas" = nome articaína, estoque_minimo 2, ' +
        'estoque_minimo_unidade caixa; "no kit da extração vão 4 gazes" = kit {procedimento_codigo: ' +
        "exodontia_permanente, itens [{material: gaze, quantidade: 4}]}. Material novo precisa de categoria, " +
        "unidade de compra, unidade de uso e fator. Nada é apagado; o antes e o depois ficam na auditoria.",
      inputSchema: esquemaMaterial,
      annotations: GRAVACAO,
    },
    (a: ArgsMaterial) => gravarComDados(deps, "salvar_material", "mcp_salvar_material", a),
  );
}

export const modulo: Modulo = {
  nome: "estoque",
  instrucoes: [
    "Estoque: o gasto de cada atendimento sai sozinho pelo kit do procedimento (mais o kit base de biossegurança); " +
    "anestésico, tubetes, cor da resina e fio ditos no registrar_atendimento ajustam a baixa. Não lance esse gasto de novo.",
    "Estoque: compras com registrar_compra; perda, vencido, contagem, uso avulso e correções com movimentar_estoque. " +
    "Antes de gravar, resuma os itens e quantidades e espere a Dra. confirmar, como nos demais registros.",
    "Estoque: material fora do cadastro não é gravado. Pergunte categoria, unidade de compra, unidade de uso e quantas " +
    "vêm em cada, cadastre com salvar_material e registre de novo.",
    "Estoque: repita para a Dra. os avisos de estoque baixo, validade perto do fim e preço acima do anterior.",
  ],
  registrar,
};
