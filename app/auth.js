// Login da Dra. no Supabase Auth: e-mail, senha e código de dois fatores
// (TOTP, o mesmo que o app Senhas do iPhone mostra). Sem biblioteca: só as
// chamadas do Auth que o site usa. A sessão fica neste aparelho até ela sair,
// por no máximo 30 dias (a API confere).

import { CHAVE_PUBLICA, SUPABASE_URL } from "./config.js";

const CHAVE_SESSAO = "consultorio.sessao";
const CHAVE_EMAIL = "consultorio.email";

export class ErroLogin extends Error {
  constructor(mensagem, codigo) {
    super(mensagem);
    this.codigo = codigo;
  }
}

const guardado = (chave) => {
  try {
    return localStorage.getItem(chave);
  } catch (_) {
    return null;
  }
};
const guardar = (chave, valor) => {
  try {
    if (valor == null) localStorage.removeItem(chave);
    else localStorage.setItem(chave, valor);
  } catch (_) { /* sem armazenamento: vale só enquanto a página estiver aberta */ }
};

let sessao = (() => {
  try {
    return JSON.parse(guardado(CHAVE_SESSAO) ?? "null");
  } catch (_) {
    return null;
  }
})();

function gravarSessao(s) {
  sessao = s;
  guardar(CHAVE_SESSAO, s ? JSON.stringify(s) : null);
}

function traduzir(j, status) {
  const c = j.error_code ?? j.code ?? "";
  if (c === "invalid_credentials") return "E-mail ou senha incorretos.";
  if (c === "mfa_verification_failed" || c === "mfa_challenge_expired" || c === "mfa_verification_rejected") {
    return "Código incorreto ou vencido. Digite o código que aparece agora no app Senhas.";
  }
  if (c === "over_request_rate_limit" || c === "over_email_send_rate_limit" || status === 429) {
    return "Muitas tentativas seguidas. Espere alguns minutos e tente de novo.";
  }
  if (/refresh_token|session_not_found|session_expired|bad_jwt/.test(c)) return "Sua sessão terminou. Entre de novo.";
  if (c === "mfa_factor_name_conflict") return "Já existe um código cadastrado com esse nome. Tente de novo.";
  return j.msg ?? j.message ?? j.error_description ?? `Erro ${status} no login.`;
}

async function chamar(caminho, { metodo = "POST", corpo, token } = {}) {
  let r;
  try {
    r = await fetch(`${SUPABASE_URL}/auth/v1/${caminho}`, {
      method: metodo,
      headers: {
        apikey: CHAVE_PUBLICA,
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: corpo === undefined ? undefined : JSON.stringify(corpo),
    });
  } catch (_) {
    throw new ErroLogin("Sem conexão. Confira a internet e tente de novo.", "rede");
  }
  if (r.status === 204) return {};
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new ErroLogin(traduzir(j, r.status), j.error_code ?? j.code ?? String(r.status));
  return j;
}

function aceitarSessao(j) {
  const s = {
    access_token: j.access_token,
    refresh_token: j.refresh_token,
    expires_at: j.expires_at ?? Math.floor(Date.now() / 1000) + (j.expires_in ?? 3600),
  };
  gravarSessao(s);
  return s;
}

/** Declarações do token atual (aal, session_id, email...). */
export function declaracoes(token = sessao?.access_token) {
  try {
    const parte = String(token).split(".")[1];
    const b64 = parte.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parte.length / 4) * 4, "=");
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
  } catch (_) {
    return {};
  }
}

export const temSessao = () => Boolean(sessao?.refresh_token);
/** "aal2" depois do código de dois fatores; "aal1" só com a senha. */
export const nivel = () => declaracoes().aal ?? null;
export const ultimoEmail = () => guardado(CHAVE_EMAIL) ?? "";

export async function entrar(email, senha) {
  const j = await chamar("token?grant_type=password", { corpo: { email: email.trim(), password: senha } });
  aceitarSessao(j);
  guardar(CHAVE_EMAIL, email.trim().toLowerCase());
}

let renovando = null;
/** Token válido por mais um minuto pelo menos (renova se precisar). */
export async function tokenValido() {
  if (!sessao) return null;
  if (sessao.expires_at - 60 > Date.now() / 1000) return sessao.access_token;
  renovando ??= chamar("token?grant_type=refresh_token", { corpo: { refresh_token: sessao.refresh_token } })
    .then(aceitarSessao)
    .catch((e) => {
      if (e.codigo !== "rede") gravarSessao(null);
      throw e;
    })
    .finally(() => (renovando = null));
  return (await renovando).access_token;
}

/** Códigos de dois fatores (TOTP) da conta. */
export async function fatores() {
  const u = await chamar("user", { metodo: "GET", token: await tokenValido() });
  return (u.factors ?? []).filter((f) => f.factor_type === "totp");
}

/** Começa o cadastro do código: devolve {id, totp: {qr_code, secret, uri}}. */
export async function cadastrarCodigo() {
  const token = await tokenValido();
  for (const f of await fatores()) {
    if (f.status !== "verified") await chamar(`factors/${f.id}`, { metodo: "DELETE", token }).catch(() => {});
  }
  const quando = new Date().toLocaleDateString("pt-BR");
  return chamar("factors", {
    corpo: {
      factor_type: "totp",
      issuer: "Consultório",
      friendly_name: `Consultório (${quando} ${Date.now() % 10000})`,
    },
    token,
  });
}

/** Confere o código de 6 dígitos; a sessão passa a ter os dois fatores. */
export async function confirmarCodigo(fatorId, codigo) {
  const token = await tokenValido();
  const desafio = await chamar(`factors/${fatorId}/challenge`, { corpo: {}, token });
  const j = await chamar(`factors/${fatorId}/verify`, { corpo: { challenge_id: desafio.id, code: codigo }, token });
  aceitarSessao(j);
}

/** Sai deste aparelho (ou de todos). */
export async function sair(todos = false) {
  const token = sessao?.access_token;
  gravarSessao(null);
  if (token) await chamar(`logout?scope=${todos ? "global" : "local"}`, { token }).catch(() => {});
}

export const esquecer = () => gravarSessao(null);
