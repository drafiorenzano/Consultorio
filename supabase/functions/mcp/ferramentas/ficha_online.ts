// Ficha online: o paciente preenche cadastro e anamnese antes da consulta.
//
// ficha_online gera o link pessoal (mensagem pronta para o WhatsApp), lista e
// cancela; ver_ficha_online mostra o que o paciente respondeu ao lado do que
// já está na ficha; confirmar_ficha_online grava (ou descarta). Nada muda na
// ficha antes da confirmação. A página pública fica em app/ficha/ e fala com a
// Edge Function "ficha".

import { z } from "zod";
import { GRAVACAO, gravarComDados, LEITURA, type Modulo, textoOriginal, textoOriginalOpcional } from "../comum.ts";

const CAMPOS_IGNORAVEIS = [
  "nome",
  "nome_social",
  "data_nascimento",
  "sexo",
  "cpf",
  "rg",
  "telefone",
  "whatsapp",
  "email",
  "profissao",
  "estado_civil",
  "endereco",
  "contato_emergencia",
  "origem",
  "responsavel",
  "anamnese",
] as const;

const esquemaFicha = {
  acao: z.enum(["enviar", "listar", "cancelar"]).describe(
    "enviar: gera o link para o paciente; listar: fichas para revisar e links aguardando; cancelar: invalida o link.",
  ),
  paciente_id: z.string().optional().describe("enviar/cancelar: id devolvido por buscar_paciente."),
  ficha_online_id: z.string().optional().describe("cancelar: id devolvido por listar."),
  dias_validade: z.number().int().min(1).max(30).optional().describe("enviar: validade do link (padrão 7 dias)."),
  motivo: z.string().optional(),
  texto_original: textoOriginal(),
};

const esquemaVer = {
  paciente_id: z.string().optional().describe("Mostra a ficha online mais recente do paciente."),
  ficha_online_id: z.string().optional().describe("Ou o id devolvido por ficha_online (listar)."),
  texto_original: textoOriginalOpcional(),
};

const esquemaConfirmar = {
  paciente_id: z.string().optional(),
  ficha_online_id: z.string().optional(),
  acao: z.enum(["aplicar", "descartar"]).optional().describe("aplicar (padrão) grava na ficha; descartar não grava."),
  ignorar: z.array(z.enum(CAMPOS_IGNORAVEIS)).optional().describe(
    'Campos que NÃO devem ir para a ficha (ex.: ["cpf"] se o CPF conflitar; ["anamnese"] para gravar só o cadastro).',
  ),
  motivo: z.string().optional().describe("descartar: por quê."),
  texto_original: textoOriginal(),
};

export const modulo: Modulo = {
  nome: "ficha_online",
  instrucoes: [
    "Ficha online: para o paciente preencher cadastro e anamnese antes da consulta, use ficha_online (enviar) e " +
    "mostre o link_whatsapp para ela tocar e mandar (abre o WhatsApp com a mensagem pronta). Ao marcar a primeira " +
    "consulta de um paciente novo, ofereça mandar a ficha. Quando ela perguntar se alguém preencheu, ou ao abrir a " +
    "agenda do dia, veja ficha_online (listar). Para revisar: ver_ficha_online e mostre o que muda no cadastro e as " +
    'respostas "sim" e "não sei" da anamnese; só grave com confirmar_ficha_online depois que ela concordar.',
  ],
  registrar(servidor, deps) {
    servidor.registerTool(
      "ficha_online",
      {
        title: "Ficha online do paciente",
        description: "Gera o link pessoal para o paciente preencher a ficha (cadastro e anamnese) pelo celular antes " +
          "da consulta, com a mensagem pronta para o WhatsApp; lista as fichas respondidas para revisar e os links " +
          "aguardando; cancela um link. O link expira (7 dias por padrão) e vale para um envio só.",
        inputSchema: esquemaFicha,
        annotations: GRAVACAO,
      },
      (a: z.infer<z.ZodObject<typeof esquemaFicha>>) => gravarComDados(deps, "ficha_online", "mcp_ficha_online", a),
    );

    servidor.registerTool(
      "ver_ficha_online",
      {
        title: "Ver ficha online respondida",
        description: "Mostra o que o paciente respondeu na ficha online, ao lado do que já está na ficha: campos do " +
          'cadastro que mudam, respostas "sim" e "não sei" da anamnese, respostas abertas e os alertas de saúde que ' +
          "vão entrar. Não grava nada na ficha.",
        inputSchema: esquemaVer,
        annotations: LEITURA,
      },
      (a: z.infer<z.ZodObject<typeof esquemaVer>>) =>
        gravarComDados(deps, "ver_ficha_online", "mcp_ver_ficha_online", a, false),
    );

    servidor.registerTool(
      "confirmar_ficha_online",
      {
        title: "Confirmar ficha online",
        description: "Depois que a Dra. revisar: grava a ficha online no cadastro do paciente e numa nova versão da " +
          "anamnese (origem formulário, com os alertas de saúde), ou descarta. Dá para deixar campos de fora com ignorar.",
        inputSchema: esquemaConfirmar,
        annotations: GRAVACAO,
      },
      (a: z.infer<z.ZodObject<typeof esquemaConfirmar>>) =>
        gravarComDados(deps, "confirmar_ficha_online", "mcp_confirmar_ficha_online", a),
    );
  },
};
