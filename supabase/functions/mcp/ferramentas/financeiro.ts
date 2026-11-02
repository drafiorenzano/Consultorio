// Ferramentas do módulo "financeiro": pagamentos e acordos, despesas,
// consultas, recibos do Receita Saúde, configuração e o pacote mensal do
// contador. As regras ficam no banco (migrations financeiro_*); aqui só os
// esquemas e, no pacote, a montagem dos CSV e o envio ao Storage.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  data,
  type Dependencias,
  falha,
  GRAVACAO,
  gravarComDados,
  LEITURA,
  type Modulo,
  NOTA_TEXTO_ORIGINAL,
  type Resultado,
  texto,
  textoOriginal,
} from "../comum.ts";
import { arquivosDoPacote, type PacoteDoBanco } from "../financeiro/csv.ts";

export const FORMAS = [
  "pix",
  "dinheiro",
  "debito",
  "credito_vista",
  "credito_parcelado",
  "boleto",
  "transferencia",
] as const;

export const CATEGORIAS = [
  "aluguel_sala",
  "materiais",
  "laboratorio",
  "cro",
  "contador",
  "inss",
  "impostos",
  "iss",
  "seguro",
  "software",
  "manutencao",
  "marketing",
  "outros",
] as const;

/** Validade dos links do pacote do contador. */
export const VALIDADE_LINK_SEGUNDOS = 7 * 24 * 60 * 60;

const centavos = (v: number) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6;
const reais = (descricao: string) =>
  z.number().positive().refine(centavos, "Use no máximo duas casas decimais.").describe(descricao);
const mes = () => z.string().regex(/^\d{4}-\d{2}$/, "Use AAAA-MM");
const forma = () => z.enum(FORMAS);
const categoria = () => z.enum(CATEGORIAS);
const motivo = () => z.string().min(3).describe("Motivo, nas palavras da Dra. (vai para o registro).");
const numero = () => z.number().int().positive();

// ---------------------------------------------------------------------
// registrar_pagamento
// ---------------------------------------------------------------------

const pagador = z.object({
  responsavel_id: z.string().optional().describe("Id de um responsável da ficha."),
  nome: z.string().optional().describe(
    "Nome de quem pagou (se for um responsável da ficha, é reconhecido pelo nome).",
  ),
  cpf: z.string().optional().describe("CPF de quem pagou, se não estiver na ficha (vai no recibo)."),
  e_o_paciente: z.boolean().optional().describe("true quando o próprio paciente pagou."),
});

const esquemaPagamento = {
  acao: z.enum(["pagamento", "combinar", "estornar", "cancelar_acordo"]).optional().describe(
    "pagamento (padrão): registra um valor recebido. combinar: cria um acordo com parcelas previstas. " +
      "estornar: desfaz um pagamento registrado. cancelar_acordo: cancela as parcelas que faltam de um acordo.",
  ),
  paciente_id: z.string().optional().describe("Id devolvido por buscar_paciente (pagamento e combinar)."),
  valor: reais("Valor pago, em reais (pagamento).").optional(),
  forma: forma().optional().describe(
    "Forma do pagamento (ou a forma prevista, em combinar). Cartão de crédito em mais de uma vez é credito_parcelado.",
  ),
  data: data().optional().describe("Data do pagamento (padrão hoje; no estorno, padrão a data do original)."),
  parcelas_cartao: z.number().int().min(1).max(24).optional().describe(
    "Em quantas vezes no cartão de crédito.",
  ),
  taxa: z.number().min(0).optional().describe("Taxa da maquininha em reais, se a Dra. disser."),
  taxa_percentual: z.number().min(0).max(30).optional().describe(
    "Taxa da maquininha em %, se a Dra. disser. Sem taxa, usa a da configuração.",
  ),
  pagador: pagador.optional().describe(
    "Quem pagou. Sem isto: o responsável pagador da ficha (se houver) ou o próprio paciente.",
  ),
  descricao: z.string().optional().describe("Do que é o pagamento (vai no recibo). Ex.: Restauração do 36."),
  atendimento_id: z.string().optional().describe("Id do atendimento pago, se houver."),
  orcamento_id: z.string().optional().describe("Id do orçamento aprovado, se houver."),
  parcela_id: z.string().optional().describe("Parcela do acordo que está sendo paga, se a Dra. disser qual."),
  quitar_parcela: z.boolean().optional().describe(
    "Padrão true: o pagamento quita as parcelas em aberto do paciente, da mais antiga para a mais nova. " +
      "Use false para um pagamento avulso, fora do acordo.",
  ),
  confirmar_duplicado: z.boolean().optional().describe(
    "Use true só depois que a Dra. confirmar que não é o mesmo pagamento já registrado.",
  ),
  valor_total: reais("Valor total do acordo (combinar).").optional(),
  parcelas: z.number().int().min(1).max(60).optional().describe("Número de parcelas do acordo (combinar)."),
  entrada: z.number().min(0).optional().describe("Valor de entrada, fora das parcelas (combinar)."),
  data_entrada: data().optional().describe("Quando a entrada vence (combinar; padrão hoje)."),
  dia: z.number().int().min(1).max(31).optional().describe("Dia do mês de vencimento das parcelas (combinar)."),
  primeiro_vencimento: data().optional().describe("Vencimento da primeira parcela (combinar)."),
  recebimento_id: z.string().optional().describe("Pagamento a estornar (ou use numero)."),
  numero: numero().optional().describe("Número do pagamento a estornar."),
  motivo: motivo().optional().describe("Por que estornar ou cancelar (estornar e cancelar_acordo)."),
  acordo_id: z.string().optional().describe("Acordo a cancelar (ou use acordo, o número)."),
  acordo: numero().optional().describe("Número do acordo a cancelar."),
  texto_original: textoOriginal(),
};
type ArgsPagamento = z.infer<z.ZodObject<typeof esquemaPagamento>>;

// ---------------------------------------------------------------------
// registrar_despesa
// ---------------------------------------------------------------------

const esquemaDespesa = {
  acao: z.enum(["registrar", "lancar_fixas", "alterar_fixa", "encerrar_fixa", "estornar"]).optional().describe(
    "registrar (padrão): uma despesa paga (com recorrente, também vira despesa fixa). " +
      "lancar_fixas: lança no mês as despesas fixas cadastradas. alterar_fixa / encerrar_fixa: muda ou encerra uma fixa. " +
      "estornar: desfaz uma despesa lançada.",
  ),
  valor: reais("Valor em reais (registrar, alterar_fixa).").optional(),
  categoria: categoria().optional().describe("Categoria (registrar, alterar_fixa)."),
  data: data().optional().describe(
    "Data do pagamento (padrão hoje). Em encerrar_fixa, a data do fim; em estornar, a data do estorno.",
  ),
  competencia: mes().optional().describe("Mês a que a despesa se refere, se diferente do mês do pagamento."),
  descricao: z.string().optional(),
  fornecedor: z.string().optional().describe("Quem recebeu (laboratório, dental, coworking, contador...)."),
  fornecedor_documento: z.string().optional().describe("CPF ou CNPJ do fornecedor, se a Dra. tiver."),
  forma: forma().optional().describe("Como foi paga."),
  paciente_id: z.string().optional().describe("Paciente do serviço (sempre em laboratório)."),
  comprovante: z.string().optional().describe(
    "Onde está o comprovante (nota, recibo, foto). O livro-caixa precisa dele.",
  ),
  recorrente: z.union([z.boolean(), z.object({ dia: z.number().int().min(1).max(31).optional() })]).optional()
    .describe('Despesa fixa todo mês: true (no dia desta data) ou {"dia": 10}. Cadastra e já lança a deste mês.'),
  confirmar_duplicada: z.boolean().optional().describe(
    "Use true só depois que a Dra. confirmar que não é a mesma despesa já registrada.",
  ),
  mes: mes().optional().describe("Mês das fixas a lançar (lancar_fixas; padrão o mês atual)."),
  valores: z.array(z.object({ id: z.string(), valor: reais("Valor deste mês.") })).optional().describe(
    "Valor deste mês das fixas que variam (lancar_fixas). As outras usam o valor cadastrado.",
  ),
  ids: z.array(z.string()).optional().describe("Lançar só estas fixas (lancar_fixas; padrão todas as pendentes)."),
  fixa_id: z.string().optional().describe("Despesa fixa a alterar ou encerrar (veja ver_financeiro, visao despesas)."),
  dia: z.number().int().min(1).max(31).optional().describe("Novo dia de vencimento da fixa (alterar_fixa)."),
  despesa_id: z.string().optional().describe("Despesa a estornar (ou use numero)."),
  numero: numero().optional().describe("Número da despesa a estornar."),
  motivo: motivo().optional().describe("Por que estornar (estornar)."),
  texto_original: textoOriginal(),
};
type ArgsDespesa = z.infer<z.ZodObject<typeof esquemaDespesa>>;

// ---------------------------------------------------------------------
// ver_financeiro, marcar_recibos, configurar_financeiro, pacote
// ---------------------------------------------------------------------

const esquemaVer = {
  visao: z.enum(["mes", "paciente", "a_receber", "inadimplentes", "recibos", "despesas", "configuracao"]).optional()
    .describe(
      "mes (padrão): resumo do mês (recebido, despesas, resultado, a receber, hora clínica, avisos). " +
        "paciente: pagamentos, acordos e saldo de um paciente. a_receber: parcelas em aberto. " +
        "inadimplentes: quem está com parcela atrasada. recibos: pagamentos sem recibo do Receita Saúde. " +
        "despesas: despesas do mês e despesas fixas. configuracao: CPF, regime, taxas.",
    ),
  mes: mes().optional().describe("Mês consultado (padrão o atual)."),
  paciente_id: z.string().optional().describe("Id do paciente (visao paciente)."),
  texto_original: z.string().optional().describe(NOTA_TEXTO_ORIGINAL),
};
type ArgsVer = z.infer<z.ZodObject<typeof esquemaVer>>;

const esquemaRecibos = {
  situacao: z.enum(["emitido", "cancelado"]).optional().describe("emitido (padrão) ou cancelado no Receita Saúde."),
  itens: z.array(z.object({
    recebimento_id: z.string().optional(),
    numero: numero().optional().describe("Número do pagamento."),
    codigo: z.string().optional().describe("Código do recibo no Receita Saúde, se a Dra. tiver."),
  })).optional().describe("Pagamentos, um a um (com o código do recibo, se houver)."),
  numeros: z.array(numero()).optional().describe("Números dos pagamentos, quando não há código."),
  mes: mes().optional().describe("Mês do lote (com todos_pendentes)."),
  todos_pendentes: z.boolean().optional().describe(
    "true marca como emitidos os recibos pendentes do mês que foram no último arquivo do pacote.",
  ),
  data_emissao: data().optional().describe("Quando os recibos foram emitidos (padrão hoje)."),
  observacao: z.string().optional(),
  texto_original: textoOriginal(),
};
type ArgsRecibos = z.infer<z.ZodObject<typeof esquemaRecibos>>;

const taxa = z.object({
  percentual: z.number().min(0).max(30).optional().describe("Percentual da taxa (à vista ou da 1ª parcela)."),
  fixo: z.number().min(0).optional().describe("Valor fixo por transação, em reais."),
  dias: z.number().int().min(0).max(60).optional().describe("Dias até o dinheiro cair na conta."),
  adicional_por_parcela: z.number().min(0).max(30).optional().describe(
    "Percentual a mais por parcela além da primeira (crédito parcelado).",
  ),
  por_parcelas: z.record(z.string().regex(/^\d{1,2}$/), z.number().min(0).max(30)).optional().describe(
    'Tabela por número de parcelas, ex.: {"2": 4.59, "3": 5.97}. Tem prioridade sobre o adicional.',
  ),
});

const esquemaConfig = {
  cpf_profissional: z.string().optional().describe("CPF da Dra. (obrigatório no lote do Receita Saúde)."),
  registro_profissional: z.string().max(15).optional().describe("Registro profissional como vai no recibo."),
  codigo_ocupacao: z.string().optional().describe("Código da ocupação no Receita Saúde (padrão 226)."),
  regime: z.enum(["pf", "pj"]).optional().describe("pf: Receita Saúde. pj: NFS-e emitida pelo contador."),
  pj_a_partir_de: data().optional().describe("Data em que os pagamentos passam a ser da pessoa jurídica."),
  cnpj: z.string().optional().describe("CNPJ da pessoa jurídica."),
  taxas: z.record(z.string(), taxa).optional().describe(
    "Taxas da maquininha por forma (pix, debito, credito_vista, credito_parcelado, boleto...). " +
      "Só os campos ditos mudam.",
  ),
  observacoes: z.string().optional(),
  texto_original: textoOriginal(),
};
type ArgsConfig = z.infer<z.ZodObject<typeof esquemaConfig>>;

const esquemaPacote = {
  mes: mes().optional().describe("Mês do pacote (padrão o mês passado)."),
  texto_original: textoOriginal(),
};
type ArgsPacote = z.infer<z.ZodObject<typeof esquemaPacote>>;

/** Monta os CSV do mês, guarda no Storage, registra o pacote e devolve os links. */
export async function gerarPacoteContador(deps: Dependencias, a: ArgsPacote): Promise<Resultado> {
  const ferramenta = "gerar_pacote_contador";
  const { texto_original, ...dados } = a;
  const argumentos = { p_dados: dados, p_texto_original: texto_original ?? null };
  try {
    const pacote = await deps.rpc("mcp_pacote_contador", argumentos) as PacoteDoBanco;
    if (!pacote || typeof pacote !== "object" || pacote.status !== "ok") {
      return { content: [{ type: "text", text: texto(pacote) }] };
    }
    const { arquivos, lote, avisos } = arquivosDoPacote(pacote);
    const rs = pacote.receita_saude ?? [];
    const receitaSaude = {
      recibos_no_arquivo: lote?.length ?? 0,
      valor_no_arquivo: Math.round((lote ? rs : []).reduce((s, l) => s + Number(l.valor), 0) * 100) / 100,
    };
    const problemas = pacote.problemas ?? [];
    if (!deps.arquivos) {
      return {
        content: [{
          type: "text",
          text: texto({
            status: "sem_arquivos",
            mes: pacote.mes,
            mensagem: "O armazenamento de arquivos não está disponível agora: os CSV não foram gerados " +
              "e o pacote não foi registrado. Tente de novo mais tarde.",
            receita_saude: receitaSaude,
            resumo: pacote.resumo,
            problemas,
            avisos,
          }),
        }],
      };
    }

    const salvos: { nome: string; caminho: string; linhas: number; descricao: string; link: string }[] = [];
    const codificador = new TextEncoder();
    for (const arq of arquivos) {
      const caminho = `contador/${pacote.mes}/${arq.nome}`;
      await deps.arquivos.salvar(caminho, codificador.encode(arq.conteudo), "text/csv");
      const link = await deps.arquivos.link(caminho, VALIDADE_LINK_SEGUNDOS);
      salvos.push({ nome: arq.nome, caminho, linhas: arq.linhas, descricao: arq.descricao, link });
    }

    const registro = await deps.rpc("mcp_registrar_pacote_contador", {
      p_dados: {
        mes: pacote.mes,
        arquivos: salvos.map(({ nome, caminho, linhas }) => ({ nome, caminho, linhas })),
        resumo: { ...pacote.resumo, problemas, ...(lote ? { lote_receita_saude: lote } : {}) },
      },
      p_texto_original: texto_original ?? null,
    }) as { pacote_id?: string } | null;

    const arquivoRs = salvos.filter((s) => s.nome.startsWith("receita-saude-")).map((s) => s.nome);
    const proximos = [
      ...(arquivoRs.length > 0
        ? [
          `Envie ${arquivoRs.join(" e ")} no Receita Saúde (emissão de recibos em lote). Quando a Receita aceitar, ` +
          `marque os recibos com marcar_recibos (mes = ${pacote.mes}, todos_pendentes = true).`,
        ]
        : []),
      "Mande os links das planilhas ao contador. Eles valem 7 dias; para links novos, gere o pacote de novo.",
    ];
    return {
      content: [{
        type: "text",
        text: texto({
          status: "ok",
          mes: pacote.mes,
          pacote_id: registro?.pacote_id ?? null,
          arquivos: salvos.map(({ nome, descricao, linhas, link }) => ({ nome, descricao, linhas, link })),
          links_validos_por: "7 dias",
          receita_saude: receitaSaude,
          resumo: pacote.resumo,
          problemas,
          avisos,
          proximos_passos: proximos,
        }),
      }],
    };
  } catch (e) {
    return falha(deps, ferramenta, argumentos, true, e);
  }
}

export const modulo: Modulo = {
  nome: "financeiro",
  instrucoes: [
    "Financeiro: antes de gravar pagamento, acordo, despesa, recibo ou configuração, resuma o que vai gravar " +
    "(valor, forma, quem pagou, data) e espere a Dra. confirmar. Valores em reais (350.5), datas AAAA-MM-DD, mês AAAA-MM.",
    "Pagamento de paciente com acordo quita as parcelas em aberto, da mais antiga para a mais nova; " +
    "se for um pagamento à parte, use quitar_parcela = false. Taxa da maquininha: só informe se a Dra. disser; " +
    "sem ela, vale a da configuração.",
    "Lançamento financeiro não se edita nem se apaga: para corrigir, estorne (acao estornar) e registre de novo. " +
    'Com status "confirmacao_necessaria" (lançamento parecido já existe), pergunte à Dra. e só repita com ' +
    "confirmar_duplicado / confirmar_duplicada = true se ela disser que é outro.",
    "Recibos: enquanto a Dra. atende como pessoa física, cada pagamento precisa de recibo no Receita Saúde. " +
    "gerar_pacote_contador monta o arquivo do lote e as planilhas do contador; depois que a Dra. enviar o lote, " +
    "marque com marcar_recibos. Na fase de pessoa jurídica (a partir de 01/12/2026, ver configuração) quem emite " +
    "a NFS-e é o contador.",
  ],
  registrar(servidor: McpServer, deps: Dependencias) {
    servidor.registerTool(
      "registrar_pagamento",
      {
        title: "Registrar pagamento",
        description: "Registra um valor recebido de um paciente (PIX, dinheiro, cartão, boleto, transferência), " +
          "com taxa da maquininha, pagador e recibo do Receita Saúde pendente. Também combina um acordo com parcelas " +
          "(acao combinar), estorna um pagamento (acao estornar) e cancela um acordo (acao cancelar_acordo). " +
          "Não grava pagamento em data futura: parcelas futuras se combinam com acao combinar.",
        inputSchema: esquemaPagamento,
        annotations: GRAVACAO,
      },
      (a: ArgsPagamento) => gravarComDados(deps, "registrar_pagamento", "mcp_registrar_pagamento", a),
    );

    servidor.registerTool(
      "registrar_despesa",
      {
        title: "Registrar despesa",
        description: "Registra uma despesa paga do consultório (aluguel de sala, materiais, laboratório, CRO, " +
          "contador, INSS, impostos, seguro, software...), cadastra despesas fixas mensais e lança as fixas do mês. " +
          "Laboratório vai sempre com o paciente. Reservas de sala e compras de material entram sozinhas pela agenda " +
          "e pelo estoque: corrija lá, não aqui.",
        inputSchema: esquemaDespesa,
        annotations: GRAVACAO,
      },
      (a: ArgsDespesa) => gravarComDados(deps, "registrar_despesa", "mcp_registrar_despesa", a),
    );

    servidor.registerTool(
      "ver_financeiro",
      {
        title: "Ver financeiro",
        description: "Consulta o financeiro: resumo do mês com resultado e hora clínica, situação de um paciente " +
          "(pagamentos, acordos e saldo), parcelas a receber, inadimplentes, recibos pendentes, despesas e configuração.",
        inputSchema: esquemaVer,
        annotations: LEITURA,
      },
      (a: ArgsVer) => gravarComDados(deps, "ver_financeiro", "mcp_ver_financeiro", a, false),
    );

    servidor.registerTool(
      "marcar_recibos",
      {
        title: "Marcar recibos do Receita Saúde",
        description: "Anota que os recibos de pagamentos foram emitidos (ou cancelados) no Receita Saúde: um a um, " +
          "pelos números, ou todos os do último lote do mês. Recibo cancelado volta a ficar pendente.",
        inputSchema: esquemaRecibos,
        annotations: GRAVACAO,
      },
      (a: ArgsRecibos) => gravarComDados(deps, "marcar_recibos", "mcp_marcar_recibos", a),
    );

    servidor.registerTool(
      "configurar_financeiro",
      {
        title: "Configurar financeiro",
        description: "Muda os dados do financeiro: CPF e registro da Dra. para os recibos, regime (pessoa física ou " +
          "jurídica) e a data da virada, CNPJ e as taxas da maquininha por forma de pagamento.",
        inputSchema: esquemaConfig,
        annotations: GRAVACAO,
      },
      (a: ArgsConfig) => gravarComDados(deps, "configurar_financeiro", "mcp_configurar_financeiro", a),
    );

    servidor.registerTool(
      "gerar_pacote_contador",
      {
        title: "Gerar pacote do contador",
        description: "Gera o pacote do mês para o contador: o arquivo do lote do Receita Saúde (recibos pendentes) " +
          "e planilhas de recebimentos, despesas (livro-caixa) e resumo, com links para baixar por 7 dias. " +
          "Aponta o que falta (CPF, comprovantes, recibos a cancelar). Pode gerar de novo o mesmo mês.",
        inputSchema: esquemaPacote,
        annotations: GRAVACAO,
      },
      (a: ArgsPacote) => gerarPacoteContador(deps, a),
    );
  },
};
