// Preços de campanha e calculadora de preço.
//
// Campanha (ex.: "Campanha RJ", 1 ou 2 dias em outra cidade): nome, datas,
// local e uma tabela de preços só dela. Os preços normais do catálogo não
// mudam; orçamento feito nos dias da campanha usa os preços dela sozinho.
//
// Calculadora: dado o preço (ou a margem que ela quer) e os custos, mostra o
// lucro no Pix, no débito e no crédito de 1x a 12x, com as taxas da
// maquininha (configurar_financeiro) e o imposto sobre o valor cobrado.

import { z } from "zod";
import {
  data,
  GRAVACAO,
  gravarComDados,
  LEITURA,
  type Modulo,
  textoOriginal,
  textoOriginalOpcional,
} from "../comum.ts";

const precoCampanha = z.object({
  procedimento_codigo: z.string().optional().describe("Código do catálogo (listar_procedimentos)."),
  procedimento: z.string().optional().describe("Nome como a Dra. disse, se não souber o código."),
  preco: z.number().nonnegative().nullable().optional().describe(
    "Preço na campanha. null tira o preço da campanha (volta ao normal).",
  ),
  remover: z.boolean().optional().describe("true tira este procedimento da tabela da campanha."),
});

const esquemaSalvar = {
  campanha: z.string().optional().describe("Campanha já criada (nome ou id) para mudar. Sem isso, cria pelo nome."),
  nome: z.string().optional().describe('Nome da campanha (ex.: "Campanha RJ"). Obrigatório para criar.'),
  inicio: data().optional().describe("Primeiro dia (obrigatório para criar)."),
  fim: data().optional().describe("Último dia (padrão: o mesmo do início)."),
  local: z.string().optional().describe("Onde vai atender (vai na confirmação por WhatsApp e no orçamento)."),
  cidade: z.string().optional(),
  observacao: z.string().optional(),
  precos: z.array(precoCampanha).optional().describe(
    "Preços da campanha. Só os ditos mudam; o que não estiver aqui fica com o preço normal.",
  ),
  cancelar: z.boolean().optional().describe("true cancela a campanha (nada se apaga)."),
  motivo: z.string().optional().describe("Motivo do cancelamento."),
  texto_original: textoOriginal(),
};
type ArgsSalvar = z.infer<z.ZodObject<typeof esquemaSalvar>>;

const esquemaVer = {
  campanha: z.string().optional().describe("Nome ou id. Sem isso: a campanha de hoje e a lista."),
  incluir_canceladas: z.boolean().optional(),
  texto_original: textoOriginalOpcional(),
};
type ArgsVer = z.infer<z.ZodObject<typeof esquemaVer>>;

const esquemaCalcular = {
  procedimento_codigo: z.string().optional().describe(
    "Código do catálogo: traz o preço atual e soma o custo dos materiais do kit do estoque.",
  ),
  procedimento: z.string().optional().describe("Nome como a Dra. disse, se não souber o código."),
  preco: z.number().positive().optional().describe(
    "Quanto ela pensa em cobrar. Sem isso: o preço da campanha (se pedida) ou o do catálogo.",
  ),
  campanha: z.string().optional().describe("Usar o preço desta campanha (nome)."),
  custos: z.array(z.object({
    descricao: z.string().describe("Ex.: laboratório, implante e componentes, auxiliar."),
    valor: z.number().nonnegative(),
  })).optional().describe("Custos que ela disser (somam ao kit do estoque)."),
  usar_kit: z.boolean().optional().describe(
    "Somar o custo dos materiais do kit do procedimento e do kit base (padrão: sim). " +
      "false se ela já disse o custo total de material.",
  ),
  horas_sala: z.number().positive().optional().describe("Horas de sala para o procedimento (entra no custo)."),
  valor_hora_sala: z.number().positive().optional().describe(
    "Valor da hora da sala. Sem isso, usa o da última reserva.",
  ),
  imposto_percentual: z.number().min(0).max(50).optional().describe(
    "Imposto sobre o valor cobrado. Padrão: o da configuração (6%).",
  ),
  margem_desejada: z.number().positive().max(89).optional().describe(
    "Margem de lucro que ela quer (%). Sem preço: sugere o preço; com preço: diz quanto cobrar em cada forma.",
  ),
  parcelas_max: z.number().int().min(1).max(12).optional().describe("Até quantas parcelas mostrar (padrão 12)."),
  texto_original: textoOriginalOpcional(),
};
type ArgsCalcular = z.infer<z.ZodObject<typeof esquemaCalcular>>;

export const modulo: Modulo = {
  nome: "precos",
  instrucoes: [
    "Campanhas (ex.: Campanha RJ): para atender por 1 ou 2 dias em outro lugar com preços próprios, crie com " +
    "salvar_campanha (nome, datas, local e os preços que mudam). Os preços normais não mudam. Nos dias da campanha " +
    'montar_orcamento usa os preços dela sozinho e avisa; se ela quiser o preço normal, repita com campanha "nenhuma". ' +
    "Para mudar ou tirar um preço depois, salvar_campanha com campanha e precos.",
    "Precificação: quando ela disser o que vai fazer, os custos e quanto pensa cobrar, use calcular_preco e responda " +
    "curto: lucro no Pix, no débito, no crédito à vista e nas parcelas que importam (ex.: 3x, 6x, 10x, 12x), com a " +
    "margem. Se ela disser a margem que quer, mostre o preço sugerido. Custos de material vêm do estoque; avise os " +
    "que estão sem custo. Calcular não grava preço: para mudar o preço do catálogo, salvar_procedimento depois que ela confirmar.",
  ],
  registrar(servidor, deps) {
    servidor.registerTool(
      "salvar_campanha",
      {
        title: "Salvar campanha",
        description: "Cria ou muda uma campanha de atendimento com preços próprios (ex.: Campanha RJ, 1 ou 2 dias): " +
          "nome, datas, local e a tabela de preços dela, sem mexer nos preços normais. Também cancela. " +
          "Orçamentos feitos nos dias da campanha usam esses preços.",
        inputSchema: esquemaSalvar,
        annotations: GRAVACAO,
      },
      (a: ArgsSalvar) => gravarComDados(deps, "salvar_campanha", "mcp_salvar_campanha", a),
    );

    servidor.registerTool(
      "ver_campanhas",
      {
        title: "Ver campanhas",
        description: "Mostra a campanha de hoje e as campanhas cadastradas; com campanha, a tabela de preços " +
          "(campanha x normal) e o resumo (consultas, orçamentos, aprovados, recebido).",
        inputSchema: esquemaVer,
        annotations: LEITURA,
      },
      (a: ArgsVer) => gravarComDados(deps, "ver_campanhas", "mcp_ver_campanhas", a, false),
    );

    servidor.registerTool(
      "calcular_preco",
      {
        title: "Calcular preço e lucro",
        description: "Calcula quanto sobra de um procedimento em cada forma de pagamento: Pix (só imposto), débito, " +
          "crédito à vista e parcelado até 12x (taxas da maquininha), descontando imposto e custos (kit do estoque, " +
          "sala e os custos ditos). Com margem_desejada, sugere o preço. Não grava nada.",
        inputSchema: esquemaCalcular,
        annotations: LEITURA,
      },
      (a: ArgsCalcular) => gravarComDados(deps, "calcular_preco", "mcp_calcular_preco", a, false),
    );
  },
};
