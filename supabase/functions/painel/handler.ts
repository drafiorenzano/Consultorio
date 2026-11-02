// API só de leitura do app do iPad. Sem dependências do Deno nem do
// Supabase, para testar localmente (tests/painel_test.ts).
//
// POST {acao, parametros} com o código de acesso no cabeçalho x-acesso.
// As leituras moram em public.painel(acao, parametros) no Postgres.

export interface DependenciasPainel {
  rpc: (funcao: string, argumentos: Record<string, unknown>) => Promise<unknown>;
  /** Diz se o SHA-256 (hex) do código é um acesso válido do escopo painel. */
  acessoValido: (sha256: string) => Promise<boolean>;
  /** Link temporário para um arquivo do Storage (documentos em PDF). */
  assinar?: (caminho: string, segundos: number) => Promise<string>;
}

export const ACOES = new Set(["inicio", "agenda", "pacientes", "paciente", "estoque", "financeiro", "documentos"]);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, x-acesso, authorization, apikey",
  "Access-Control-Max-Age": "86400",
};

export async function sha256Hex(texto: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

/** Troca cada {"arquivo": "caminho"} por um link temporário em "link". */
async function assinarArquivos(valor: unknown, deps: DependenciasPainel, limite = { n: 100 }): Promise<unknown> {
  if (Array.isArray(valor)) {
    const saida = [];
    for (const v of valor) saida.push(await assinarArquivos(v, deps, limite));
    return saida;
  }
  if (valor && typeof valor === "object") {
    const obj: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(valor)) obj[k] = await assinarArquivos(v, deps, limite);
    if (typeof obj.arquivo === "string" && deps.assinar && limite.n-- > 0) {
      try {
        obj.link = await deps.assinar(obj.arquivo, 3600);
      } catch (_) {
        // sem link, o app mostra o documento sem botão de abrir
      }
    }
    return obj;
  }
  return valor;
}

export function criarHandlerPainel(deps: DependenciasPainel) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (req.method !== "POST") return json({ erro: "Use POST." }, 405);

    const codigo = req.headers.get("x-acesso") ?? "";
    if (!/^[A-Za-z0-9_-]{32,128}$/.test(codigo) || !(await deps.acessoValido(await sha256Hex(codigo)))) {
      return json({ erro: "Código de acesso inválido ou revogado." }, 401);
    }

    let pedido: { acao?: unknown; parametros?: unknown };
    try {
      pedido = await req.json();
    } catch (_) {
      return json({ erro: "Pedido inválido." }, 400);
    }
    const acao = typeof pedido.acao === "string" ? pedido.acao : "";
    if (!ACOES.has(acao)) return json({ erro: "Ação desconhecida." }, 400);
    const parametros = pedido.parametros && typeof pedido.parametros === "object" ? pedido.parametros : {};

    try {
      const dados = await deps.rpc("painel", { p_acao: acao, p_params: parametros });
      if (dados === null) return json({ erro: "Ação ainda não disponível." }, 404);
      return json({ dados: await assinarArquivos(dados, deps) });
    } catch (e) {
      return json({ erro: e instanceof Error ? e.message : String(e) }, 400);
    }
  };
}
