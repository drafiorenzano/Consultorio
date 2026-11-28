// Acesso ao site do consultório (celular, iPad e computador): gerar o convite
// (link de uso único que cria a conta ou troca a senha e o código), listar e revogar.

import { z } from "zod";
import { GRAVACAO, gravarComDados, type Modulo, textoOriginal } from "../comum.ts";

const esquema = {
  acao: z.enum(["gerar", "listar", "revogar"]).describe(
    "gerar: convite novo para entrar no site (cria a conta ou troca a senha e o código de 2 fatores); " +
      "listar: contas do site, aparelhos conectados e convites pendentes; revogar: cancela um convite, desliga a " +
      "conta de outra pessoa (email) ou, com todos = true, tira o site de todos os aparelhos.",
  ),
  aparelho: z.string().optional().describe("gerar: para quem ou onde é o convite (ex.: iPad da Dra.)."),
  email: z.string().optional().describe(
    "Conta de OUTRA pessoa (não a Dra.). gerar: e-mail da conta própria dessa pessoa (sem email, o convite é da " +
      "conta da Dra.); revogar: e-mail da conta a desligar.",
  ),
  pessoa: z.string().optional().describe("gerar com email: nome de quem vai usar a conta (ex.: Guilherme)."),
  acesso_id: z.string().optional().describe("revogar: id devolvido por listar."),
  todos: z.boolean().optional().describe("revogar: true tira o acesso de todos os aparelhos."),
  texto_original: textoOriginal(),
};

export const modulo: Modulo = {
  nome: "ipad",
  instrucoes: [
    "Site do consultório (celular, iPad e computador): entra com e-mail, senha e código de 2 fatores (app Senhas " +
    "do iPhone). A conta nasce, e a senha e o código são trocados, só por um convite: se pedirem o site, login, " +
    'senha, acesso, "esqueci a senha" ou "troquei de celular", use acesso_ipad (gerar) e mostre o link uma vez ' +
    "só, com o como_usar. Quem abre o link cria a senha e cadastra o código; um convite novo troca os dois. " +
    "Perdeu o aparelho: acesso_ipad (revogar, todos = true). Outra pessoa pode ter conta própria, separada da " +
    "dela (ex.: Guilherme): acesso_ipad (gerar, email, pessoa); isso não mexe na senha nem no código da Dra. " +
    'Para tirar essa pessoa ("tira o acesso do Guilherme ao site"): acesso_ipad (revogar, email; use listar para ' +
    "achar o e-mail). Sem email, o convite é sempre da conta da Dra.",
  ],
  registrar(servidor, deps) {
    servidor.registerTool(
      "acesso_ipad",
      {
        title: "Acesso ao site",
        description: "Site do consultório (celular, iPad e computador): mostra o dia, a agenda, as fichas e o " +
          "financeiro, lança recebimentos, despesas e estoque e guarda exames na ficha. Entra com e-mail, senha e " +
          "código de 2 fatores. gerar cria o convite (link de uso único, vale 7 dias) que cria a conta ou troca a " +
          "senha e o código (com email e pessoa, de uma conta separada para outra pessoa); listar mostra as contas " +
          "e os convites; revogar cancela convites, desliga a conta de outra pessoa ou tira o site de todos os " +
          "aparelhos. O link só aparece na hora de gerar.",
        inputSchema: esquema,
        annotations: GRAVACAO,
      },
      (a: z.infer<z.ZodObject<typeof esquema>>) => gravarComDados(deps, "acesso_ipad", "mcp_acesso_ipad", a),
    );
  },
};
