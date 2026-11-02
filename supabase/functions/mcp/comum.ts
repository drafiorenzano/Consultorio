// Peças comuns a todas as ferramentas do servidor MCP: tipos das
// dependências, a chamada ao banco com registro de falha, esquemas
// repetidos e o formato de um módulo de ferramentas.
//
// Cada módulo (ferramentas/*.ts) exporta um `Modulo` com as linhas que ele
// acrescenta às instruções e a função que registra as ferramentas dele.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

export type Rpc = (funcao: string, argumentos: Record<string, unknown>) => Promise<unknown>;

/** Arquivos gerados pelo servidor (PDF, CSV), guardados no Storage privado. */
export interface Arquivos {
  /** Grava (ou substitui) o arquivo no bucket de documentos. */
  salvar: (caminho: string, conteudo: Uint8Array, tipo: string) => Promise<void>;
  /** Link temporário para baixar o arquivo. */
  link: (caminho: string, segundos?: number) => Promise<string>;
}

export interface Dependencias {
  /** Chama uma função do Postgres (PostgREST /rpc). Lança ErroRpc em caso de erro. */
  rpc: Rpc;
  /** Diz se o SHA-256 (hex) do token da URL é um acesso válido. */
  acessoValido: (tokenSha256: string) => Promise<boolean>;
  /** Storage de documentos. Ausente nos testes que não geram arquivo. */
  arquivos?: Arquivos;
}

export class ErroRpc extends Error {
  constructor(message: string, readonly dica?: string, readonly codigo?: string) {
    super(message);
    this.name = "ErroRpc";
  }
}

export interface Modulo {
  nome: string;
  /** Linhas acrescentadas às regras das instruções do servidor (cada uma vira "- linha"). */
  instrucoes: string[];
  registrar: (servidor: McpServer, deps: Dependencias) => void;
}

export const NOTA_TEXTO_ORIGINAL = "O pedido da Dra., palavra por palavra (vai para a auditoria).";

export const data = () => z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Use AAAA-MM-DD");
export const hora = () => z.string().regex(/^\d{1,2}:\d{2}$/, "Use HH:MM");
export const paciente_id = () => z.string().describe("Id devolvido por buscar_paciente.");
export const textoOriginal = () => z.string().min(1).describe(NOTA_TEXTO_ORIGINAL);
export const textoOriginalOpcional = () => z.string().optional().describe(NOTA_TEXTO_ORIGINAL);

export const LEITURA = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
export const GRAVACAO = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };

export type Resultado = { content: { type: "text"; text: string }[]; isError?: boolean };

export function texto(valor: unknown): string {
  return JSON.stringify(valor, null, 1);
}

export function erroComoTexto(e: unknown): ErroRpc {
  return e instanceof ErroRpc ? e : new ErroRpc(e instanceof Error ? e.message : String(e));
}

/** Guarda a tentativa que falhou (a transação dela foi desfeita) e devolve o erro como resultado. */
export async function falha(
  deps: Dependencias,
  ferramenta: string,
  argumentos: Record<string, unknown>,
  grava: boolean,
  e: unknown,
): Promise<Resultado> {
  const erro = erroComoTexto(e);
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
    grava ? "Nada foi gravado." : "A consulta não foi feita.",
    erro.message,
    erro.dica ?? "",
  ].filter(Boolean);
  return { isError: true, content: [{ type: "text", text: partes.join(" ") }] };
}

/** Chama a função do banco e devolve a resposta em texto (ou o erro, registrado). */
export async function executar(
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
    return falha(deps, ferramenta, argumentos, grava, e);
  }
}

/** Atalho para a ferramenta mais comum: separa texto_original e manda o resto em p_dados. */
export function gravarComDados(
  deps: Dependencias,
  ferramenta: string,
  funcao: string,
  args: Record<string, unknown> & { texto_original?: string },
  grava = true,
): Promise<Resultado> {
  const { texto_original, ...dados } = args;
  return executar(deps, ferramenta, funcao, { p_dados: dados, p_texto_original: texto_original ?? null }, grava);
}
