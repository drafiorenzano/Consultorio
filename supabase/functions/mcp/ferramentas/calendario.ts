// Agenda no Calendário do iPhone/iPad: link de assinatura (iCal), só leitura.
// O link é servido pela Edge Function "calendario" (supabase/functions/calendario).

import { z } from "zod";
import { GRAVACAO, gravarComDados, type Modulo, textoOriginal } from "../comum.ts";

const esquema = {
  acao: z.enum(["gerar", "listar", "revogar"]).describe(
    "gerar: novo link de assinatura; listar: links ativos; revogar: tira o acesso de um link.",
  ),
  aparelho: z.string().optional().describe("gerar: onde vai usar (ex.: iPhone e iPad da Dra.)."),
  acesso_id: z.string().optional().describe("revogar: id devolvido por listar."),
  todos: z.boolean().optional().describe("revogar: true revoga todos os links de calendário."),
  texto_original: textoOriginal(),
};

export const modulo: Modulo = {
  nome: "calendario",
  instrucoes: [
    "Calendário do iPhone/iPad: se ela quiser ver a agenda no app Calendário, use acesso_calendario (gerar) e " +
    "mostre o link_assinar e o como_usar, uma vez só. É só leitura (primeiro nome e procedimento) e atualiza sozinho; " +
    "marcar, remarcar e cancelar continuam por aqui. Se o link vazar ou ela trocar de aparelho, revogue e gere outro.",
  ],
  registrar(servidor, deps) {
    servidor.registerTool(
      "acesso_calendario",
      {
        title: "Agenda no Calendário do iPhone",
        description: "Gera o link para assinar a agenda do consultório no app Calendário do iPhone/iPad (só leitura, " +
          "atualiza sozinho), lista os links ativos ou revoga um. O link só aparece na hora de gerar.",
        inputSchema: esquema,
        annotations: GRAVACAO,
      },
      (a: z.infer<z.ZodObject<typeof esquema>>) =>
        gravarComDados(deps, "acesso_calendario", "mcp_acesso_calendario", a),
    );
  },
};
