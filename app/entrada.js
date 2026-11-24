// Entrar no site: e-mail e senha, depois o código de 6 dígitos do app Senhas.
// O link que o Claude manda (#acesso=...) é um convite de uso único: cria a
// senha do site (ou troca, se ela esqueceu) e cadastra o código.

import { cadastrarCodigo, confirmarCodigo, entrar, fatores, sair, ultimoEmail } from "./auth.js";
import { convite, mostrar } from "./nucleo.js";
import { html } from "./base.js";

const AJUDA_LINK = "Peça ao Claude: “me manda o link do site”.";
const CHAVE_CONVITE = "consultorio.convite";

// ------------------------------------------------------------------
// Convite pelo link
// ------------------------------------------------------------------
/** Tira o código do convite da barra de endereço e guarda nesta aba. */
export function capturarConvite() {
  const m = location.hash.match(/acesso=([A-Za-z0-9_-]{32,128})/);
  if (!m) return;
  try {
    sessionStorage.setItem(CHAVE_CONVITE, m[1]);
  } catch (_) { /* sem armazenamento: segue só em memória */ }
  conviteEmMemoria = m[1];
  history.replaceState(null, "", location.pathname + location.search + "#/hoje");
}
let conviteEmMemoria = null;
export function convitePendente() {
  try {
    return sessionStorage.getItem(CHAVE_CONVITE) ?? conviteEmMemoria;
  } catch (_) {
    return conviteEmMemoria;
  }
}
function largarConvite() {
  conviteEmMemoria = null;
  try {
    sessionStorage.removeItem(CHAVE_CONVITE);
  } catch (_) { /* nada */ }
}

function moldura(titulo, subtitulo, corpo) {
  document.body.classList.add("sem-acesso");
  mostrar(html`
    <div class="entrada">
      <div class="nav-monograma" aria-hidden="true">AF</div>
      <h1>${titulo}</h1>
      ${subtitulo ? html`<p class="suave">${subtitulo}</p>` : ""}
      ${corpo}
    </div>
  `);
}

const erroEm = (id, texto) => {
  const caixa = document.getElementById(id);
  if (!caixa) return;
  caixa.textContent = texto;
  caixa.hidden = !texto;
};

/** Botão ocupado enquanto espera a resposta. */
async function ocupado(botao, f) {
  const original = botao.textContent;
  botao.disabled = true;
  botao.textContent = "Um momento…";
  try {
    return await f();
  } finally {
    botao.disabled = false;
    botao.textContent = original;
  }
}

/** Link do convite: criar (ou trocar) a senha e cadastrar o código. */
export async function telaConvite(depois) {
  const codigo = convitePendente();
  moldura("Bem-vinda ao site", "Carregando o convite…", "");
  let info;
  try {
    info = await convite("convite", codigo);
  } catch (e) {
    largarConvite();
    return telaEntrar(depois, `${e.message}`);
  }
  if (!info?.email) {
    largarConvite();
    return telaEntrar(depois, "Falta o e-mail do consultório no cadastro. Peça ao Claude para incluir.");
  }
  const trocar = info.conta_existe;
  moldura(
    trocar ? "Nova senha do site" : "Bem-vinda ao site",
    trocar
      ? "Este link troca a senha e o código de dois fatores."
      : "São dois passos: criar a senha e ligar o código no iPhone.",
    html`
      <form class="cartao" id="form-senha" novalidate>
        <p class="passo">Passo 1 de 2</p>
        <label class="forte" for="email">E-mail</label>
        <input id="email" class="busca" type="email" name="username" autocomplete="username" value="${info
          .email}" readonly>
        <label class="forte" for="senha">${trocar ? "Senha nova" : "Crie uma senha"}</label>
        <input id="senha" class="busca" type="password" name="new-password" autocomplete="new-password" minlength="10"
          maxlength="72" required autofocus>
        <label class="forte" for="senha2">Repita a senha</label>
        <input id="senha2" class="busca" type="password" autocomplete="new-password" minlength="10" maxlength="72" required>
        <p class="suave pequeno">Pelo menos 10 caracteres. O iPhone pode sugerir uma senha forte e guardar no app Senhas.</p>
        <p class="erro-caixa pequeno" id="erro-senha" hidden></p>
        <button class="botao botao-principal largo" type="submit">Continuar</button>
      </form>
    `,
  );
  document.getElementById("form-senha").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const senha = document.getElementById("senha").value;
    const senha2 = document.getElementById("senha2").value;
    if (senha.length < 10) return erroEm("erro-senha", "A senha precisa ter pelo menos 10 caracteres.");
    if (senha !== senha2) return erroEm("erro-senha", "As duas senhas não estão iguais.");
    erroEm("erro-senha", "");
    await ocupado(ev.submitter ?? ev.target.querySelector("button"), async () => {
      try {
        await convite("criar_conta", codigo, { senha });
        largarConvite();
        await entrar(info.email, senha);
        await telaCadastrarCodigo(depois, true);
      } catch (e) {
        erroEm("erro-senha", e.message);
      }
    });
  });
}

// ------------------------------------------------------------------
// E-mail e senha
// ------------------------------------------------------------------
export function telaEntrar(depois, mensagem = "") {
  moldura(
    "Consultório",
    "Agenda, pacientes e financeiro da Dra. Andressa.",
    html`
      <form class="cartao" id="form-entrar">
        <label class="forte" for="email">E-mail</label>
        <input id="email" class="busca" type="email" name="username" autocomplete="username" inputmode="email"
          value="${ultimoEmail()}" required ${ultimoEmail() ? "" : "autofocus"}>
        <label class="forte" for="senha">Senha</label>
        <input id="senha" class="busca" type="password" name="password" autocomplete="current-password" required ${ultimoEmail()
          ? "autofocus"
          : ""}>
        <p class="erro-caixa pequeno" id="erro-entrar" ${mensagem ? "" : "hidden"}>${mensagem}</p>
        <button class="botao botao-principal largo" type="submit">Entrar</button>
        <p class="suave pequeno">Primeira vez, esqueceu a senha ou trocou de celular? ${AJUDA_LINK}</p>
      </form>
    `,
  );
  document.getElementById("form-entrar").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const email = document.getElementById("email").value;
    const senha = document.getElementById("senha").value;
    if (!email || !senha) return erroEm("erro-entrar", "Preencha o e-mail e a senha.");
    await ocupado(ev.submitter ?? ev.target.querySelector("button"), async () => {
      try {
        await entrar(email, senha);
        await telaCodigo(depois);
      } catch (e) {
        erroEm("erro-entrar", e.message);
      }
    });
  });
}

// ------------------------------------------------------------------
// Código de 6 dígitos
// ------------------------------------------------------------------
function campoCodigo() {
  return html`
    <label class="forte" for="codigo">Código de 6 dígitos</label>
    <input id="codigo" class="busca codigo" inputmode="numeric" pattern="[0-9]{6}" maxlength="6"
      autocomplete="one-time-code" required autofocus>
  `;
}

/** Liga o campo do código: confirma sozinho ao chegar no 6º dígito. */
function ligarCodigo(form, confirmar) {
  const campo = form.querySelector("#codigo");
  let enviando = false;
  const enviar = async () => {
    const codigo = campo.value.replace(/\D/g, "");
    if (codigo.length !== 6 || enviando) return;
    enviando = true;
    await ocupado(form.querySelector("button[type=submit]"), () => confirmar(codigo));
    enviando = false;
  };
  campo.addEventListener("input", () => {
    campo.value = campo.value.replace(/\D/g, "").slice(0, 6);
    if (campo.value.length === 6) enviar();
  });
  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    enviar();
  });
}

export async function telaCodigo(depois, mensagem = "") {
  moldura("Código de dois fatores", "Um momento…", "");
  let lista;
  try {
    lista = await fatores();
  } catch (e) {
    return telaEntrar(depois, e.message);
  }
  const fator = lista.find((f) => f.status === "verified");
  if (!fator) return telaCadastrarCodigo(depois, false);
  moldura(
    "Código de dois fatores",
    "Abra o app Senhas (ou o app de códigos) e digite o código do Consultório.",
    html`<form class="cartao" id="form-codigo">
      ${campoCodigo()}
      <p class="erro-caixa pequeno" id="erro-codigo" ${mensagem ? "" : "hidden"}>${mensagem}</p>
      <button class="botao botao-principal largo" type="submit">Confirmar</button>
      <p class="suave pequeno">No iPhone, o código costuma aparecer sozinho acima do teclado. Perdeu o celular? ${AJUDA_LINK}</p>
      <button class="botao-link pequeno" type="button" id="outra-conta">Sair e entrar com outra conta</button>
    </form>`,
  );
  const form = document.getElementById("form-codigo");
  ligarCodigo(form, async (codigo) => {
    try {
      await confirmarCodigo(fator.id, codigo);
      marcarEntradaRecente();
      depois();
    } catch (e) {
      erroEm("erro-codigo", e.message);
      form.querySelector("#codigo").select();
    }
  });
  document.getElementById("outra-conta").addEventListener("click", async () => {
    await sair();
    telaEntrar(depois);
  });
}

/** Link do app Senhas e QR (vêm do login como SVG). */
function imagemQr(qr) {
  const s = String(qr ?? "");
  const i = s.indexOf("<svg");
  if (i < 0) return s.startsWith("data:image/") ? s : "";
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(s.slice(i))}`;
}

export async function telaCadastrarCodigo(depois, doConvite) {
  moldura("Ligar o código", "Preparando…", "");
  let f;
  try {
    f = await cadastrarCodigo();
  } catch (e) {
    return telaEntrar(depois, e.message);
  }
  const segredo = String(f.totp?.secret ?? "").replace(/(.{4})/g, "$1 ").trim();
  const toque = matchMedia("(pointer: coarse)").matches;
  moldura(
    "Ligar o código",
    doConvite
      ? "Passo 2 de 2: o código de 6 dígitos que protege o site."
      : "Falta ligar o código de 6 dígitos que protege o site.",
    html`<form class="cartao" id="form-cadastro">
      <ol class="passos">
        <li>${
      toque
        ? html`Toque em <a class="botao botao-principal" href="${f.totp?.uri}">Adicionar ao app Senhas</a> e confirme no iPhone.`
        : html`No iPhone, abra a câmera e aponte para o quadrado abaixo. Toque no aviso e confirme no app Senhas.`
    }</li>
        <li>Volte aqui e digite o código que aparece para “Consultório”.</li>
      </ol>
      <div class="qr"><img src="${
      imagemQr(f.totp?.qr_code)
    }" alt="Código QR para o app Senhas" width="180" height="180"></div>
      <details class="pequeno"><summary>Prefere digitar a chave?</summary>
        <p class="suave">No app Senhas: Códigos de verificação, +, Inserir chave de configuração.</p>
        <p class="chave">${segredo}</p>
      </details>
      ${campoCodigo()}
      <p class="erro-caixa pequeno" id="erro-cadastro" hidden></p>
      <button class="botao botao-principal largo" type="submit">Confirmar</button>
      <p class="suave pequeno">Se o cadastro não terminar hoje, o site pede um link novo. ${AJUDA_LINK}</p>
    </form>`,
  );
  const form = document.getElementById("form-cadastro");
  ligarCodigo(form, async (codigo) => {
    try {
      await confirmarCodigo(f.id, codigo);
      marcarEntradaRecente();
      depois();
    } catch (e) {
      erroEm("erro-cadastro", e.message);
      form.querySelector("#codigo").select();
    }
  });
}

// Logo depois do código, um "sessão terminou" quer dizer que o código não
// vale para o site (cadastrado fora do prazo do convite): pede link novo.
let entrouEm = 0;
function marcarEntradaRecente() {
  entrouEm = Date.now();
}
export const acabouDeEntrar = () => Date.now() - entrouEm < 60_000;
export const MENSAGEM_LINK_NOVO =
  `Este código não vale mais para o site (o cadastro precisa terminar no mesmo dia do convite). ${AJUDA_LINK}`;
