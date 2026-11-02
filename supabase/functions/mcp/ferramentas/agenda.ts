// Ferramentas da agenda: consultas e reservas da sala (ela aluga por hora).
// As regras (conflito de horário, nada se apaga, remarcação ligada à
// anterior, avisos de sala) moram nas funções mcp_* da migração "agenda".

import { z } from "zod";
import {
  data,
  type Dependencias,
  GRAVACAO,
  gravarComDados,
  hora,
  LEITURA,
  type Modulo,
  paciente_id,
  textoOriginal,
  textoOriginalOpcional,
} from "../comum.ts";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

const duracao = () => z.number().int().min(10).max(480).describe("Duração em minutos.");
const procedimento = () =>
  z.string().describe("Código do catálogo (listar_procedimentos), ex.: implante_unitario. Opcional.");

const esquemaAgendar = {
  paciente_id: paciente_id(),
  data: data(),
  hora: hora().describe("Início, HH:MM."),
  duracao_min: duracao().optional().describe("Duração em minutos (padrão 60)."),
  procedimento_codigo: procedimento().optional(),
  motivo: z.string().optional().describe("O que vai ser feito, nas palavras da Dra. (se não houver código)."),
  observacao: z.string().optional().describe("Ex.: trazer tomografia, vem com a mãe."),
  confirmada: z.boolean().optional().describe("true se o paciente já confirmou."),
  texto_original: textoOriginal(),
};

const ACOES_CONSULTA = ["confirmar", "remarcar", "cancelar", "faltou", "reabrir", "alterar"] as const;

const esquemaAlterar = {
  acao: z.enum(ACOES_CONSULTA).describe(
    "confirmar (paciente confirmou), remarcar (novo dia/horário), cancelar (desmarcou), faltou (não veio), " +
      "reabrir (desfaz cancelamento ou falta), alterar (duração, procedimento, observação).",
  ),
  consulta_id: z.string().optional().describe("Id devolvido por ver_agenda. Ou use paciente_id (e data)."),
  paciente_id: paciente_id().optional(),
  data: data().optional().describe("Dia da consulta, quando o paciente tem mais de uma."),
  nova_data: data().optional().describe("remarcar: novo dia (se mudar)."),
  nova_hora: hora().optional().describe("remarcar: novo horário (se mudar)."),
  duracao_min: duracao().optional(),
  procedimento_codigo: procedimento().optional(),
  novo_motivo: z.string().optional().describe("alterar: novo motivo da consulta."),
  observacao: z.string().optional().describe("alterar: nova observação (vazia apaga a observação)."),
  motivo: z.string().optional().describe("Por que cancelou, faltou ou remarcou."),
  confirmada: z.boolean().optional().describe("remarcar: true se o novo horário já está confirmado."),
  texto_original: textoOriginal(),
};

const esquemaSala = {
  acao: z.enum(["reservar", "cancelar"]).optional().describe("Padrão: reservar."),
  data: data().optional().describe("Dia da reserva (ou da primeira, se repetir)."),
  hora_inicio: hora().optional(),
  hora_fim: hora().optional(),
  repetir_semanal_ate: data().optional().describe("Repete toda semana, no mesmo dia e horário, até esta data."),
  valor: z.number().min(0).optional().describe("Valor de cada reserva, em reais."),
  valor_hora: z.number().min(0).optional().describe("Ou o valor por hora (o total é calculado)."),
  local: z.string().optional().describe("Sala ou clínica, se ela alugar em mais de um lugar."),
  observacao: z.string().optional(),
  reserva_id: z.string().optional().describe("cancelar: id devolvido por ver_agenda."),
  motivo: z.string().optional().describe("cancelar: motivo."),
  texto_original: textoOriginal(),
};

const esquemaVer = {
  data: data().optional().describe("Um dia (padrão: hoje)."),
  data_inicio: data().optional().describe("Período: primeiro dia (até 2 meses)."),
  data_fim: data().optional().describe("Período: último dia."),
  paciente_id: paciente_id().optional().describe("Consultas de um paciente: próximas, histórico e faltas."),
  incluir_retornos: z.boolean().optional().describe("Lista quem tem retorno previsto sem consulta (padrão true)."),
  texto_original: textoOriginalOpcional(),
};

type Args<T extends z.ZodRawShape> = z.infer<z.ZodObject<T>>;

function registrar(servidor: McpServer, deps: Dependencias) {
  servidor.registerTool(
    "agendar_consulta",
    {
      title: "Agendar consulta",
      description: "Marca uma consulta. Recusa se bater com outra consulta. Devolve a agenda do dia com os " +
        "horários livres e avisa se a sala não está reservada nesse horário, se o paciente já tem outra " +
        "consulta ou se falta telefone. Para ver horários livres antes de marcar, use ver_agenda.",
      inputSchema: esquemaAgendar,
      annotations: GRAVACAO,
    },
    (a: Args<typeof esquemaAgendar>) => gravarComDados(deps, "agendar_consulta", "mcp_agendar_consulta", a),
  );

  servidor.registerTool(
    "alterar_consulta",
    {
      title: "Confirmar, remarcar ou desmarcar consulta",
      description: "Muda uma consulta marcada: confirmar, remarcar, cancelar, faltou, reabrir ou alterar. " +
        "Ache a consulta pelo consulta_id ou pelo paciente_id (a próxima dele; passe data se tiver mais de uma). " +
        "Nada se apaga: cancelar e faltou guardam o motivo, remarcar cria uma consulta nova ligada à antiga.",
      inputSchema: esquemaAlterar,
      annotations: GRAVACAO,
    },
    (a: Args<typeof esquemaAlterar>) => gravarComDados(deps, "alterar_consulta", "mcp_alterar_consulta", a),
  );

  servidor.registerTool(
    "reservar_sala",
    {
      title: "Reservar ou cancelar a sala",
      description: "Registra o aluguel da sala (por hora), uma vez ou toda semana até uma data, com o valor " +
        "(total ou por hora). Recusa se já houver reserva no horário. Cancelar diz quais consultas ficaram sem sala.",
      inputSchema: esquemaSala,
      annotations: GRAVACAO,
    },
    (a: Args<typeof esquemaSala>) => gravarComDados(deps, "reservar_sala", "mcp_reservar_sala", a),
  );

  servidor.registerTool(
    "ver_agenda",
    {
      title: "Ver agenda",
      description: "Mostra a agenda de um dia (padrão hoje) ou de um período: reservas da sala, consultas " +
        "(com alertas de saúde e se é primeira vez), horários livres dentro das reservas, consultas ainda não " +
        "confirmadas com link de WhatsApp com a mensagem pronta, e pacientes com retorno previsto sem consulta. " +
        "Com paciente_id, mostra as consultas do paciente.",
      inputSchema: esquemaVer,
      annotations: LEITURA,
    },
    (a: Args<typeof esquemaVer>) => gravarComDados(deps, "ver_agenda", "mcp_ver_agenda", a, false),
  );
}

export const modulo: Modulo = {
  nome: "agenda",
  instrucoes: [
    "Agenda: marque com agendar_consulta (padrão 60 minutos). Se ela não disse o horário, use ver_agenda e ofereça os horários livres.",
    'Datas como "amanhã" ou "terça que vem" viram AAAA-MM-DD; ao confirmar, diga o dia da semana e a data (ex.: "terça, 10/11, às 9h").',
    "Confirmar, remarcar, desmarcar ou marcar falta: alterar_consulta. Pergunte o motivo de cancelamento ou falta se ela não disser, mas não insista.",
    "A sala é alugada por hora: registre cada aluguel com reservar_sala (pode repetir toda semana). Se uma consulta cair fora da reserva, avise.",
    "Para confirmar consultas, ver_agenda traz pendentes_de_confirmacao com um link de WhatsApp com a mensagem pronta: mostre os links para ela tocar e enviar. Você não envia mensagens.",
    "Quando ela registra o atendimento no dia, a consulta vira realizada sozinha.",
  ],
  registrar,
};
