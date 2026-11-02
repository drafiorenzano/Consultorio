// Acesso ao app do iPad (só leitura): gerar o link, listar e revogar.

import { z } from "zod";
import { GRAVACAO, gravarComDados, type Modulo, textoOriginal } from "../comum.ts";

const esquema = {
  acao: z.enum(["gerar", "listar", "revogar"]).describe(
    "gerar: novo link de acesso para um aparelho; listar: aparelhos com acesso; revogar: tira o acesso.",
  ),
  aparelho: z.string().optional().describe("gerar: nome do aparelho (ex.: iPad do consultório)."),
  acesso_id: z.string().optional().describe("revogar: id devolvido por listar."),
  todos: z.boolean().optional().describe("revogar: true tira o acesso de todos os aparelhos."),
  texto_original: textoOriginal(),
};

export const modulo: Modulo = {
  nome: "ipad",
  instrucoes: [
    "App do iPad: se ela pedir o acesso do iPad, use acesso_ipad (gerar) e mostre o link uma vez só, com o como_usar. Se ela perder o aparelho, revogue.",
  ],
  registrar(servidor, deps) {
    servidor.registerTool(
      "acesso_ipad",
      {
        title: "Acesso do iPad",
        description: "Gera o link de acesso do app do iPad (agenda e fichas, só leitura), lista os aparelhos com " +
          "acesso ou revoga um acesso. O link só aparece na hora de gerar.",
        inputSchema: esquema,
        annotations: GRAVACAO,
      },
      (a: z.infer<z.ZodObject<typeof esquema>>) => gravarComDados(deps, "acesso_ipad", "mcp_acesso_ipad", a),
    );
  },
};
