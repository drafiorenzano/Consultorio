// Edge Function "painel": API do site do consultório (leituras e lançamentos).
// Publicar com verify_jwt = false: o login é conferido em handler.ts (token
// da conta dela com o segundo fator, e sessão válida em painel_autorizar);
// o convite usa o código do link no cabeçalho x-acesso.

import { criarHandlerPainel } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

function lerChaves(nome: string): string | null {
  const valor = Deno.env.get(nome);
  if (!valor) return null;
  try {
    return JSON.parse(valor)?.default ?? null;
  } catch (_) {
    return null;
  }
}

/** Cabeçalhos com a chave secreta (banco, Storage e administração do Auth). */
function cabecalhosSecretos(): Record<string, string> {
  const nova = lerChaves("SUPABASE_SECRET_KEYS");
  if (nova) return { apikey: nova };
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (antiga) return { apikey: antiga, Authorization: `Bearer ${antiga}` };
  throw new Error("Chave secreta do Supabase ausente no ambiente da função.");
}

/** Chave pública, para conferir o token da Dra. no Auth. */
function chavePublica(): string {
  const chave = lerChaves("SUPABASE_PUBLISHABLE_KEYS") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!chave) throw new Error("Chave pública do Supabase ausente no ambiente da função.");
  return chave;
}

async function rpc(funcao: string, argumentos: Record<string, unknown>): Promise<unknown> {
  const resposta = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${funcao}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosSecretos() },
    body: JSON.stringify(argumentos),
  });
  const corpo = await resposta.text();
  const json = corpo ? JSON.parse(corpo) : null;
  if (!resposta.ok) {
    console.error(`rpc ${funcao} falhou: ${resposta.status}`);
    throw new Error((json as { message?: string })?.message ?? `Erro ${resposta.status} no banco.`);
  }
  return json;
}

async function admin(metodo: string, caminho: string, corpo?: unknown): Promise<unknown> {
  const resposta = await fetch(`${SUPABASE_URL}/auth/v1/admin/${caminho}`, {
    method: metodo,
    headers: { "Content-Type": "application/json", ...cabecalhosSecretos() },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const texto = await resposta.text();
  const json = texto ? JSON.parse(texto) : null;
  if (!resposta.ok) {
    console.error(`auth admin ${metodo} ${caminho.split("/")[0]} falhou: ${resposta.status}`);
    const msg = (json as { msg?: string; message?: string })?.msg ?? (json as { message?: string })?.message;
    throw new Error(msg ? `Login: ${msg}` : `Erro ${resposta.status} no login.`);
  }
  return json;
}

async function assinar(caminhos: string[], segundos: number): Promise<Record<string, string>> {
  const resposta = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/documentos`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosSecretos() },
    body: JSON.stringify({ expiresIn: segundos, paths: caminhos }),
  });
  const corpo = await resposta.json().catch(() => null);
  if (!resposta.ok || !Array.isArray(corpo)) throw new Error(`Storage ${resposta.status}`);
  const links: Record<string, string> = {};
  for (const x of corpo as { path?: string; signedURL?: string; error?: string }[]) {
    if (x.path && x.signedURL && !x.error) links[x.path] = `${SUPABASE_URL}/storage/v1${x.signedURL}`;
  }
  return links;
}

/** Link de envio (uma vez) para um arquivo novo no bucket "documentos". */
async function envio(caminho: string): Promise<string> {
  const resposta = await fetch(`${SUPABASE_URL}/storage/v1/object/upload/sign/documentos/${caminho}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosSecretos() },
    body: "{}",
  });
  const corpo = await resposta.json().catch(() => null) as { url?: string } | null;
  if (!resposta.ok || !corpo?.url) throw new Error(`Storage ${resposta.status} ao preparar o envio.`);
  return `${SUPABASE_URL}/storage/v1${corpo.url}`;
}

/** Tamanho e tipo de um arquivo do bucket "documentos" (null se não existe). */
async function infoArquivo(caminho: string): Promise<{ tamanho: number; tipo: string } | null> {
  const i = caminho.lastIndexOf("/");
  const resposta = await fetch(`${SUPABASE_URL}/storage/v1/object/list/documentos`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...cabecalhosSecretos() },
    body: JSON.stringify({ prefix: caminho.slice(0, i), search: caminho.slice(i + 1), limit: 5, offset: 0 }),
  });
  const lista = await resposta.json().catch(() => null);
  if (!resposta.ok || !Array.isArray(lista)) throw new Error(`Storage ${resposta.status} ao conferir o arquivo.`);
  const item = (lista as { name?: string; metadata?: { size?: number; mimetype?: string } }[])
    .find((x) => x.name === caminho.slice(i + 1));
  if (!item?.metadata) return null;
  return { tamanho: Number(item.metadata.size ?? 0), tipo: String(item.metadata.mimetype ?? "") };
}

Deno.serve(criarHandlerPainel({
  rpc,
  assinar,
  envio,
  infoArquivo,
  auth: {
    usuario: async (token) => {
      const resposta = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        headers: { apikey: chavePublica(), Authorization: `Bearer ${token}` },
      });
      if (!resposta.ok) return null;
      const u = await resposta.json().catch(() => null) as { id?: string } | null;
      return u?.id ? { id: u.id } : null;
    },
    criarUsuario: async (email, senha) => {
      const u = await admin("POST", "users", { email, password: senha, email_confirm: true }) as { id?: string };
      if (!u?.id) throw new Error("O login não devolveu a conta criada.");
      return u.id;
    },
    trocarSenha: async (id, senha) => {
      await admin("PUT", `users/${encodeURIComponent(id)}`, { password: senha });
    },
    fatores: async (id) => {
      const lista = await admin("GET", `users/${encodeURIComponent(id)}/factors`);
      return Array.isArray(lista) ? (lista as { id: string }[]) : [];
    },
    apagarFator: async (id, fatorId) => {
      await admin("DELETE", `users/${encodeURIComponent(id)}/factors/${encodeURIComponent(fatorId)}`);
    },
  },
}));
