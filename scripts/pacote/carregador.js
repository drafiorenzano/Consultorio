// Conector MCP do consultório, versão 0.5.2 (36 ferramentas).
//
// Este arquivo é o que vai publicado como index.js da função "mcp" (com o
// deno.json de supabase/functions/mcp). O código-fonte do servidor está em
// supabase/functions/mcp/; o pacote montado dele (scripts/pacote/montar.sh) fica
// no banco, na tabela pacote_conector, e é carregado aqui na partida. Só roda o
// pacote cujo SHA-256 é o de ESPERADO. Ver a migration *_pacote_conector.sql.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";
import { PDFDocument, rgb, StandardFonts } from "pdf-lib";

// Trocado pelo montar.sh a cada pacote novo.
const ESPERADO = "ba40f427d6cfcfe97dac230a11a9f870fd7253910972d948e0e848c20a52bbff";
const MODULOS = {
  "@modelcontextprotocol/sdk/server/mcp.js": { McpServer },
  "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js": { WebStandardStreamableHTTPServerTransport },
  "zod": { z },
  "pdf-lib": { PDFDocument, rgb, StandardFonts },
};
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

function cabecalhosDaChave() {
  const novas = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (novas) {
    try {
      const chave = JSON.parse(novas)?.default;
      if (chave) return { apikey: chave };
    } catch (_) {
      // cai para a chave antiga
    }
  }
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (antiga) return { apikey: antiga, Authorization: `Bearer ${antiga}` };
  throw new Error("Chave secreta do Supabase ausente no ambiente da função.");
}

async function sha256(texto) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function carregarPacote() {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/pacote_conector?select=parte,texto&sha256=eq.${ESPERADO}&order=parte`, {
    headers: cabecalhosDaChave(),
  });
  if (!r.ok) throw new Error(`Não consegui ler o pacote do conector: ${r.status}`);
  const partes = await r.json();
  if (!partes.length) throw new Error("O pacote do conector não está no banco (tabela pacote_conector).");
  const bytes = Uint8Array.from(atob(partes.map((p) => p.texto).join("")), (c) => c.charCodeAt(0));
  const fluxo = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  const texto = await new Response(fluxo).text();
  if ((await sha256(texto)) !== ESPERADO) throw new Error("O pacote do conector no banco não confere.");
  // Troca cada `import { a as b } from "m";` por `const { a: b } = __m["m"];`.
  const corpo = texto.replace(/^import \{([^}]*)\} from "([^"]+)";$/gm, (_, nomes, modulo) => {
    if (!(modulo in MODULOS)) throw new Error(`Módulo inesperado no pacote: ${modulo}`);
    const lista = nomes.split(",").map((s) => s.trim()).filter(Boolean).map((s) => s.replace(/\s+as\s+/, ": "));
    return `const { ${lista.join(", ")} } = __m[${JSON.stringify(modulo)}];`;
  });
  if (/^\s*(import|export)\b/m.test(corpo)) throw new Error("O pacote do conector tem import/export que não sei carregar.");
  return corpo;
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
await new AsyncFunction("__m", await carregarPacote())(MODULOS);
