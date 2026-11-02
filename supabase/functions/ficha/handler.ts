// API pública da ficha online (o paciente preenche antes da consulta).
// Sem dependências do Deno nem do Supabase, para testar localmente
// (tests/ficha_test.ts).
//
// POST {acao, codigo, respostas}:
//   exemplo  -> as perguntas, sem código e sem gravar nada (para a Dra. ver);
//   abrir    -> primeiro nome, próxima consulta e as perguntas;
//   enviar   -> guarda as respostas como pendentes (uma vez só).
// O código vem do link (depois de "#c="); aqui só o SHA-256 dele vai ao banco.
// As regras (expiração, envio único, validação) moram no Postgres:
// ficha_online_exemplo, ficha_online_abrir e ficha_online_enviar.

export class ErroBanco extends Error {
  constructor(message: string, readonly codigo?: string) {
    super(message);
    this.name = "ErroBanco";
  }
}

export interface DependenciasFicha {
  rpc: (funcao: string, argumentos: Record<string, unknown>) => Promise<unknown>;
}

export const LIMITE_BYTES = 100_000;

const CABECALHOS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Max-Age": "86400",
  "Cache-Control": "no-store",
  "X-Robots-Tag": "noindex",
  "Referrer-Policy": "no-referrer",
};

export async function sha256Hex(texto: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CABECALHOS, "Content-Type": "application/json; charset=utf-8" },
  });
}

const LINK_INVALIDO = "Link inválido. Confira se abriu o link inteiro que recebeu pelo WhatsApp.";
const FALHA = "Não consegui falar com o consultório agora. Tente de novo em alguns minutos.";

/** Erros de validação (RAISE no Postgres, código P0001) vão para o paciente; o resto vira mensagem genérica. */
function erroParaPaciente(e: unknown): Response {
  if (e instanceof ErroBanco && e.codigo === "P0001") return json({ erro: e.message }, 400);
  console.error(`ficha: ${e instanceof Error ? e.message : e}`);
  return json({ erro: FALHA }, 503);
}

export function criarHandlerFicha(deps: DependenciasFicha) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CABECALHOS });
    if (req.method !== "POST") return json({ erro: "Use POST." }, 405);

    const bruto = await req.text();
    if (new TextEncoder().encode(bruto).length > LIMITE_BYTES) return json({ erro: "Ficha grande demais." }, 413);
    let pedido: { acao?: unknown; codigo?: unknown; respostas?: unknown };
    try {
      pedido = JSON.parse(bruto);
    } catch (_) {
      return json({ erro: "Pedido inválido." }, 400);
    }
    if (!pedido || typeof pedido !== "object") return json({ erro: "Pedido inválido." }, 400);

    try {
      if (pedido.acao === "exemplo") {
        return json({ dados: await deps.rpc("ficha_online_exemplo", {}) });
      }
      if (pedido.acao !== "abrir" && pedido.acao !== "enviar") return json({ erro: "Ação desconhecida." }, 400);

      const codigo = typeof pedido.codigo === "string" ? pedido.codigo : "";
      if (!/^[A-Za-z0-9_-]{32,128}$/.test(codigo)) return json({ erro: LINK_INVALIDO }, 404);
      const hash = await sha256Hex(codigo);

      if (pedido.acao === "abrir") {
        const dados = await deps.rpc("ficha_online_abrir", { p_token_sha256: hash });
        return dados === null ? json({ erro: LINK_INVALIDO }, 404) : json({ dados });
      }

      const respostas = pedido.respostas;
      if (!respostas || typeof respostas !== "object" || Array.isArray(respostas)) {
        return json({ erro: "Faltaram as respostas." }, 400);
      }
      const dados = await deps.rpc("ficha_online_enviar", { p_token_sha256: hash, p_respostas: respostas });
      return dados === null ? json({ erro: LINK_INVALIDO }, 404) : json({ dados });
    } catch (e) {
      return erroParaPaciente(e);
    }
  };
}
