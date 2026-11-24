// Chamadas à API do site (com o login da Dra.) e peças de tela comuns:
// área de conteúdo, janela por cima e aviso rápido.

import { API, LANCAR_PELO_SITE } from "./config.js";
import { esquecer, tokenValido } from "./auth.js";
import { html } from "./base.js";

/** Precisa entrar de novo (sessão terminou ou foi tirada). */
export class SemLogin extends Error {}
/** Entrou com a senha, falta o código de dois fatores. */
export class PrecisaCodigo extends Error {}

async function enviar(corpo, cabecalhos) {
  let r;
  try {
    r = await fetch(API, {
      method: "POST",
      headers: { "content-type": "application/json", ...cabecalhos },
      body: JSON.stringify(corpo),
    });
  } catch (_) {
    throw new Error("Sem conexão com o servidor. Confira a internet e tente de novo.");
  }
  return { r, corpo: await r.json().catch(() => ({})) };
}

/** Leitura (ou lançamento) com a sessão deste aparelho. */
export async function api(acao, parametros = {}) {
  let token;
  try {
    token = await tokenValido();
  } catch (e) {
    if (e.codigo === "rede") throw new Error(e.message);
    throw new SemLogin(e.message);
  }
  if (!token) throw new SemLogin("");
  const { r, corpo } = await enviar({ acao, parametros }, { authorization: `Bearer ${token}` });
  if (r.status === 401) {
    esquecer();
    throw new SemLogin(corpo.erro ?? "");
  }
  if (r.status === 403 && corpo.precisa_codigo) throw new PrecisaCodigo(corpo.erro ?? "");
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(corpo.erro ?? `Erro ${r.status}`);
  return corpo.dados;
}

/** Lançamento pelo site: as mesmas regras e o mesmo registro do Claude. */
export const gravar = (tipo, dados) => api("gravar", { tipo, dados });
export const podeLancar = () => LANCAR_PELO_SITE;

/** Convite (link do Claude): sem login, com o código do link. */
export async function convite(acao, codigo, parametros = {}) {
  const { r, corpo } = await enviar({ acao, parametros }, { "x-acesso": codigo });
  if (!r.ok) throw new Error(corpo.erro ?? `Erro ${r.status}`);
  return corpo.dados;
}

// ------------------------------------------------------------------
// Tela
// ------------------------------------------------------------------
export const conteudo = () => document.getElementById("conteudo");
/** Funções que rodam depois que a tela nova aparece (ligar botões etc.). */
export const depoisDeMostrar = [];

export function mostrar(v) {
  conteudo().innerHTML = String(v);
  conteudo().querySelectorAll(".numero b").forEach((b) => b.classList.toggle("longo", b.textContent.trim().length > 6));
  depoisDeMostrar.splice(0).forEach((f) => f());
}

// ------------------------------------------------------------------
// Janela por cima (detalhe, formulário)
// ------------------------------------------------------------------
let focoAntes = null;

/**
 * Abre uma janela. Sem rodape, mostra só "Fechar". Devolve o elemento da
 * janela (para ligar formulários).
 */
export function abrirJanela(corpo, { rodape, titulo = "Detalhe", larga = false } = {}) {
  fecharJanela();
  focoAntes = document.activeElement;
  const fundo = document.createElement("div");
  fundo.className = "janela-fundo";
  fundo.innerHTML = String(
    html`<div class="janela cartao ${
      larga ? "janela-larga" : ""
    }" role="dialog" aria-modal="true" aria-label="${titulo}">${corpo}
    ${
      rodape ??
        html`<div class="botoes janela-rodape"><button type="button" class="botao" data-fechar>Fechar</button></div>`
    }</div>`,
  );
  fundo.addEventListener("click", (e) => {
    if (e.target === fundo || e.target.closest("[data-fechar]") || e.target.closest("a[href^='#']")) fecharJanela();
  });
  document.body.appendChild(fundo);
  document.body.classList.add("com-janela");
  const janela = fundo.querySelector(".janela");
  (janela.querySelector("[autofocus]") ?? janela.querySelector("[data-fechar]") ?? janela).focus?.();
  return janela;
}

export function fecharJanela() {
  const aberta = document.querySelector(".janela-fundo");
  if (!aberta) return;
  aberta.remove();
  document.body.classList.remove("com-janela");
  if (focoAntes?.isConnected) focoAntes.focus?.({ preventScroll: true });
  focoAntes = null;
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") fecharJanela();
});

// ------------------------------------------------------------------
// Aviso rápido (canto da tela)
// ------------------------------------------------------------------
export function avisar(texto, tipo = "ok") {
  let caixa = document.getElementById("avisos");
  if (!caixa) {
    caixa = document.createElement("div");
    caixa.id = "avisos";
    caixa.className = "avisos";
    caixa.setAttribute("role", "status");
    caixa.setAttribute("aria-live", "polite");
    document.body.appendChild(caixa);
  }
  const item = document.createElement("div");
  item.className = `aviso aviso-${tipo}`;
  item.textContent = texto;
  caixa.appendChild(item);
  setTimeout(() => item.classList.add("saindo"), tipo === "erro" ? 7000 : 4000);
  setTimeout(() => item.remove(), tipo === "erro" ? 7600 : 4600);
}
