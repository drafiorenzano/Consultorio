// App do iPad: agenda, pacientes e fichas do consultório, só leitura.
// Tudo vem da Edge Function "painel" (ver config.js), com o código de acesso
// guardado neste aparelho. Para gravar, a Dra. fala com o Claude.

import { API } from "./config.js";
import { CONDICOES } from "./condicoes.js";

// ------------------------------------------------------------------
// HTML seguro: tudo que entra em html`` é escapado, menos o que vem de cru().
// ------------------------------------------------------------------
class Cru {
  constructor(s) {
    this.s = s;
  }
  toString() {
    return this.s;
  }
}
const cru = (s) => new Cru(s);
const esc = (v) =>
  String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
function juntar(v) {
  if (v == null || v === false) return "";
  if (v instanceof Cru) return v.s;
  if (Array.isArray(v)) return v.map(juntar).join("");
  return esc(v);
}
function html(partes, ...valores) {
  let s = partes[0];
  valores.forEach((v, i) => (s += juntar(v) + partes[i + 1]));
  return cru(s);
}

// ------------------------------------------------------------------
// Formatos
// ------------------------------------------------------------------
const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];
const DIAS = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
const DIAS_CURTOS = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];

const deISO = (s) => {
  const [a, m, d] = String(s).slice(0, 10).split("-").map(Number);
  return new Date(a, m - 1, d);
};
const paraISO = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const hojeISO = () => paraISO(new Date());
const somarDias = (s, n) => {
  const d = deISO(s);
  d.setDate(d.getDate() + n);
  return paraISO(d);
};
const segundaDe = (s) => {
  const d = deISO(s);
  return somarDias(s, -((d.getDay() + 6) % 7));
};
const dataLonga = (s) => {
  const d = deISO(s);
  return `${DIAS[d.getDay()]}, ${d.getDate()} de ${MESES[d.getMonth()]}`;
};
const dataCurta = (s, ano = false) => {
  if (!s) return "";
  const d = deISO(s);
  const base = `${String(d.getDate()).padStart(2, "0")}/${String(d.getMonth() + 1).padStart(2, "0")}`;
  return ano || d.getFullYear() !== new Date().getFullYear() ? `${base}/${d.getFullYear()}` : base;
};
const minutos = (hhmm) => {
  const [h, m] = String(hhmm).split(":").map(Number);
  return h * 60 + m;
};
const duracao = (min) => {
  const h = Math.floor(min / 60), m = min % 60;
  return h ? `${h}h${m ? String(m).padStart(2, "0") : ""}` : `${m} min`;
};
const dinheiro = (v) =>
  v == null ? "" : Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const telefone = (t) => {
  const d = String(t ?? "").replace(/\D/g, "");
  if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`;
  if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`;
  return t ?? "";
};
const cpf = (c) => {
  const d = String(c ?? "").replace(/\D/g, "");
  return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : c ?? "";
};
const linkWhatsApp = (t) => {
  const d = String(t ?? "").replace(/\D/g, "");
  return d ? `https://wa.me/${d.length <= 11 ? "55" + d : d}` : null;
};
const texto = (v) => {
  if (v == null) return "";
  if (typeof v === "object") return Object.values(v).filter((x) => x != null && x !== "").map(texto).join(", ");
  return String(v);
};

const STATUS = {
  agendada: "A confirmar",
  confirmada: "Confirmada",
  realizada: "Realizada",
  faltou: "Faltou",
  cancelada: "Cancelada",
  remarcada: "Remarcada",
};
const chipStatus = (s) => html`<span class="etiqueta status status-${s}">${STATUS[s] ?? s}</span>`;

const ICONE_CONVERSA = cru(
  '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a9 9 0 0 0-7.8 13.5L3 21l4.6-1.2A9 9 0 1 0 12 3zm0 16.2c-1.4 0-2.8-.4-4-1.1l-.3-.2-2.7.7.7-2.6-.2-.3A7.2 7.2 0 1 1 12 19.2zm4-5.4c-.2-.1-1.3-.6-1.5-.7-.2-.1-.4-.1-.5.1l-.7.9c-.1.1-.3.2-.5.1a5.9 5.9 0 0 1-2.9-2.6c-.2-.4.2-.4.6-1.2.1-.1 0-.3 0-.4l-.7-1.6c-.2-.4-.4-.4-.5-.4h-.4a.8.8 0 0 0-.6.3 2.5 2.5 0 0 0-.8 1.9c0 1.1.8 2.2.9 2.3.1.2 1.6 2.5 3.9 3.5 1.5.6 2 .7 2.7.6.4-.1 1.3-.5 1.5-1.1.2-.5.2-1 .1-1.1l-.6-.4z"/></svg>',
);

function chipsAlertas(alertas, curto = false) {
  if (!alertas?.length) return "";
  return html`<span class="etiquetas">${
    alertas.map((a) =>
      html`<span class="etiqueta etiqueta-alerta" title="${a.descricao ?? a.tipo}">⚠ ${
        curto ? (a.tipo === "outro" ? a.descricao : a.tipo.replaceAll("_", " ")) : a.descricao ?? a.tipo
      }</span>`
    )
  }</span>`;
}

// ------------------------------------------------------------------
// Acesso e chamadas
// ------------------------------------------------------------------
const CHAVE = "consultorio.acesso";
const lerAcesso = () => {
  try {
    return localStorage.getItem(CHAVE);
  } catch (_) {
    return null;
  }
};
const guardarAcesso = (c) => {
  try {
    localStorage.setItem(CHAVE, c);
  } catch (_) { /* sem armazenamento: vale só nesta sessão */ }
  sessaoAcesso = c;
};
const esquecerAcesso = () => {
  try {
    localStorage.removeItem(CHAVE);
  } catch (_) { /* nada */ }
  sessaoAcesso = null;
};
let sessaoAcesso = lerAcesso();

// O link de acesso do iPad termina em #acesso=<código>: guarda e tira da barra.
function capturarAcessoDoLink() {
  const m = location.hash.match(/acesso=([A-Za-z0-9_-]{32,128})/);
  if (m) {
    guardarAcesso(m[1]);
    history.replaceState(null, "", location.pathname + location.search + "#/hoje");
  }
}
capturarAcessoDoLink();

class SemAcesso extends Error {}

async function api(acao, parametros = {}) {
  if (!sessaoAcesso) throw new SemAcesso("");
  let r;
  try {
    r = await fetch(API, {
      method: "POST",
      headers: { "content-type": "application/json", "x-acesso": sessaoAcesso },
      body: JSON.stringify({ acao, parametros }),
    });
  } catch (_) {
    throw new Error("Sem conexão com o servidor. Confira a internet e tente de novo.");
  }
  const corpo = await r.json().catch(() => ({}));
  if (r.status === 401) {
    esquecerAcesso();
    throw new SemAcesso(corpo.erro ?? "");
  }
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(corpo.erro ?? `Erro ${r.status}`);
  return corpo.dados;
}

// ------------------------------------------------------------------
// Navegação
// ------------------------------------------------------------------
const conteudo = () => document.getElementById("conteudo");
let geracao = 0;
let rotaAtual = "";

function mostrar(v) {
  conteudo().innerHTML = String(v);
}

async function navegar({ silencioso = false } = {}) {
  const partes = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean).map(decodeURIComponent);
  const secao = partes[0] ?? "hoje";
  const telas = { hoje: telaHoje, agenda: telaAgenda, pacientes: telaPacientes, paciente: telaPaciente, estoque: telaEstoque, financeiro: telaFinanceiro };
  const tela = telas[secao] ?? telaHoje;
  const minha = ++geracao;
  rotaAtual = secao;
  document.querySelectorAll(".nav a").forEach((a) =>
    a.classList.toggle("ativo", a.dataset.secao === (secao === "paciente" ? "pacientes" : secao))
  );
  if (!sessaoAcesso) return telaEntrada();
  document.body.classList.remove("sem-acesso");
  if (!silencioso) mostrar(html`<p class="carregando">Carregando…</p>`);
  try {
    const v = await tela(...partes.slice(1));
    if (minha !== geracao || v == null) return;
    mostrar(v);
    if (!silencioso) {
      conteudo().focus({ preventScroll: true });
      window.scrollTo(0, 0);
    }
    depoisDeMostrar.splice(0).forEach((f) => f());
  } catch (e) {
    if (minha !== geracao) return;
    if (e instanceof SemAcesso) return telaEntrada(e.message);
    if (!silencioso) mostrar(html`<div class="erro-caixa">${e.message}</div>`);
  }
}
const depoisDeMostrar = [];

window.addEventListener("hashchange", () => {
  capturarAcessoDoLink();
  navegar();
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && ["hoje", "agenda"].includes(rotaAtual)) navegar({ silencioso: true });
});
setInterval(() => {
  if (document.visibilityState === "visible" && ["hoje", "agenda"].includes(rotaAtual) && !document.querySelector(".janela-fundo")) {
    navegar({ silencioso: true });
  }
}, 60_000);

// ------------------------------------------------------------------
// Entrada (código de acesso)
// ------------------------------------------------------------------
function telaEntrada(mensagem = "") {
  document.body.classList.add("sem-acesso");
  mostrar(html`
    <div class="entrada">
      <div class="nav-monograma" aria-hidden="true">AF</div>
      <h1>Consultório</h1>
      <p class="suave">Agenda e fichas, só para consulta.</p>
      <form class="cartao" id="form-acesso">
        <label for="codigo" class="forte">Código de acesso</label>
        <input id="codigo" class="busca" autocomplete="off" autocapitalize="off" spellcheck="false" required>
        ${mensagem ? html`<p class="erro-caixa pequeno">${mensagem}</p>` : ""}
        <button class="botao botao-principal" type="submit">Entrar</button>
        <p class="suave pequeno">O código vem no link de acesso do iPad. Se ele parou de funcionar, peça um novo ao Claude.</p>
      </form>
    </div>`);
  document.getElementById("form-acesso").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const c = document.getElementById("codigo").value.trim();
    if (!/^[A-Za-z0-9_-]{32,128}$/.test(c)) return telaEntrada("Esse código não parece completo. Copie o link inteiro.");
    guardarAcesso(c);
    location.hash = "#/hoje";
    navegar();
  });
}

// ------------------------------------------------------------------
// Janela (detalhe de uma consulta)
// ------------------------------------------------------------------
function abrirJanela(corpo) {
  fecharJanela();
  const fundo = document.createElement("div");
  fundo.className = "janela-fundo";
  fundo.innerHTML = String(html`<div class="janela cartao" role="dialog" aria-modal="true">${corpo}
    <div class="botoes" style="margin-top:16px;justify-content:flex-end"><button class="botao" data-fechar>Fechar</button></div></div>`);
  fundo.addEventListener("click", (e) => {
    if (e.target === fundo || e.target.closest("[data-fechar]") || e.target.closest("a[href^='#']")) fecharJanela();
  });
  document.body.appendChild(fundo);
  fundo.querySelector("[data-fechar]").focus();
}
function fecharJanela() {
  document.querySelector(".janela-fundo")?.remove();
}
document.addEventListener("keydown", (e) => e.key === "Escape" && fecharJanela());

function detalheConsulta(c) {
  const p = c.paciente ?? {};
  return html`
    <div class="linha"><div><h2>${p.nome}</h2><p class="suave" style="margin:4px 0 0">${dataLonga(c.data)}, ${c.inicio}–${c.fim} (${duracao(c.duracao_min)})</p></div>${
    chipStatus(c.status)
  }</div>
    ${p.alertas_saude?.length ? html`<div class="alertas-faixa"><strong>Alertas de saúde</strong><ul>${p.alertas_saude.map((a) => html`<li>${a.descricao}</li>`)}</ul></div>` : ""}
    <dl class="dados" style="margin-top:16px">
      ${c.motivo ? html`<div><dt>Motivo</dt><dd>${c.motivo}</dd></div>` : ""}
      ${c.observacao ? html`<div><dt>Observação</dt><dd>${c.observacao}</dd></div>` : ""}
      ${p.telefone ? html`<div><dt>Telefone</dt><dd><a href="tel:+55${p.telefone}">${telefone(p.telefone)}</a></dd></div>` : ""}
      ${c.motivo_status ? html`<div><dt>Motivo do status</dt><dd>${c.motivo_status}</dd></div>` : ""}
      ${p.primeira_vez ? html`<div><dt>Paciente</dt><dd>Primeira vez</dd></div>` : ""}
      ${c.sala_reservada === false ? html`<div><dt>Sala</dt><dd class="forte" style="color:var(--cor-alerta)">Sem reserva neste horário</dd></div>` : ""}
    </dl>
    <div class="botoes" style="margin-top:16px">
      <a class="botao botao-principal" href="#/paciente/${p.id}">Abrir ficha</a>
      ${c.link_whatsapp ? html`<a class="botao botao-whatsapp" href="${c.link_whatsapp}" target="_blank" rel="noopener">${ICONE_CONVERSA} Pedir confirmação</a>` : ""}
    </div>`;
}

// ------------------------------------------------------------------
// Agenda de um dia (lista)
// ------------------------------------------------------------------
function listaDoDia(dia, { links = new Map(), compacto = false } = {}) {
  const itens = [];
  (dia.reservas_sala ?? []).forEach((r) => itens.push({ t: minutos(r.inicio), ordem: 0, r }));
  (dia.consultas ?? []).forEach((c) => itens.push({ t: minutos(c.inicio), ordem: 1, c }));
  if (!compacto) (dia.horarios_livres ?? []).filter((l) => l.minutos >= 30).forEach((l) => itens.push({ t: minutos(l.inicio), ordem: 2, l }));
  itens.sort((a, b) => a.t - b.t || a.ordem - b.ordem);
  if (!itens.length) return html`<p class="vazio">${dia.mensagem ?? "Nada marcado."}</p>`;
  const linhas = itens.map((i) => {
    if (i.r) {
      return html`<li class="dia-sala">▦ Sala reservada ${i.r.inicio}–${i.r.fim}${i.r.local ? ` · ${i.r.local}` : ""}</li>`;
    }
    if (i.l) return html`<li class="dia-livre">Livre ${i.l.inicio}–${i.l.fim} (${duracao(i.l.minutos)})</li>`;
    const c = i.c, p = c.paciente ?? {};
    const link = links.get(c.id);
    return html`<li class="dia-item">
      <div class="dia-hora">${c.inicio}<small>${duracao(c.duracao_min)}</small></div>
      <div>
        <div class="linha"><a class="link-paciente" href="#/paciente/${p.id}">${p.nome}</a>${chipStatus(c.status)}</div>
        ${c.motivo ? html`<div class="suave">${c.motivo}</div>` : ""}
        ${
      compacto ? "" : html`<div class="etiquetas" style="margin-top:6px">
          ${p.primeira_vez ? html`<span class="etiqueta etiqueta-info">Primeira vez</span>` : ""}
          ${c.sala_reservada === false ? html`<span class="etiqueta etiqueta-alerta">Sem sala reservada</span>` : ""}
          ${c.observacao ? html`<span class="etiqueta">${c.observacao}</span>` : ""}
        </div>
        ${chipsAlertas(p.alertas_saude)}
        ${link ? html`<div class="botoes" style="margin-top:8px"><a class="botao botao-whatsapp" href="${link}" target="_blank" rel="noopener">${ICONE_CONVERSA} Pedir confirmação</a></div>` : ""}`
    }
      </div>
    </li>`;
  });
  return html`<ul class="dia-lista">${linhas}</ul>`;
}

const linksPorConsulta = (pendentes) => new Map((pendentes ?? []).filter((p) => p.link_whatsapp).map((p) => [p.consulta_id, p.link_whatsapp]));

// ------------------------------------------------------------------
// Hoje
// ------------------------------------------------------------------
async function telaHoje() {
  const d = await api("inicio");
  const cfg = d.configuracao ?? {};
  const h = minutos(d.agora ?? "12:00") / 60;
  const saudacao = h < 12 ? "Bom dia" : h < 18 ? "Boa tarde" : "Boa noite";
  const nome = (cfg.dentista_nome ?? "Dra.").split(" ").slice(0, 2).join(" ");
  const ativasHoje = (d.agenda_hoje.consultas ?? []).filter((c) => !["cancelada", "remarcada"].includes(c.status));
  const links = linksPorConsulta(d.pendentes_de_confirmacao);
  const n = d.numeros ?? {};
  return html`
    <div class="cabecalho"><div><h1>${saudacao}, ${nome}</h1><p>${dataLonga(d.hoje)}</p></div></div>
    <div class="numeros">
      <div class="numero"><b>${ativasHoje.length}</b><span>consultas hoje</span></div>
      <div class="numero"><b>${n.consultas_semana ?? 0}</b><span>nesta semana</span></div>
      <div class="numero"><b>${(d.pendentes_de_confirmacao ?? []).length}</b><span>a confirmar (7 dias)</span></div>
      <div class="numero"><b>${n.pacientes ?? 0}</b><span>pacientes</span></div>
      ${n.atendimentos_mes != null ? html`<div class="numero"><b>${n.atendimentos_mes}</b><span>atendimentos no mês</span></div>` : ""}
    </div>
    <div class="grade grade-2">
      <div>
        <section class="cartao"><h2>Hoje</h2>${listaDoDia(d.agenda_hoje, { links })}</section>
        <section class="cartao"><h2>Amanhã <span class="suave pequeno" style="font-family:var(--fonte-texto)">${dataLonga(d.agenda_amanha.data)}</span></h2>${listaDoDia(d.agenda_amanha, { links, compacto: true })}</section>
      </div>
      <div>
        ${blocoPendentes(d.pendentes_de_confirmacao)}
        ${blocoRetornos(d.retornos_sem_consulta)}
        ${blocosDeModulos(d)}
      </div>
    </div>`;
}

function blocoPendentes(pendentes) {
  return html`<section class="cartao"><h2>Para confirmar</h2>${
    pendentes?.length
      ? html`<ul class="lista">${
        pendentes.map((p) =>
          html`<li><div class="linha"><div><a class="link-paciente" href="#/paciente/${p.paciente_id}">${p.paciente}</a>
          <div class="suave pequeno">${p.dia_semana}, ${dataCurta(p.data)} às ${p.inicio}${p.motivo ? ` · ${p.motivo}` : ""}</div></div>
          ${p.link_whatsapp ? html`<a class="botao botao-whatsapp" href="${p.link_whatsapp}" target="_blank" rel="noopener">${ICONE_CONVERSA} WhatsApp</a>` : html`<span class="etiqueta etiqueta-aviso">sem telefone</span>`}</div></li>`
        )
      }</ul><p class="suave pequeno" style="margin:10px 0 0">O botão abre o WhatsApp com a mensagem pronta; é só enviar. Quando o paciente responder, diga ao Claude “fulano confirmou”.</p>`
      : html`<p class="vazio">Tudo confirmado nos próximos 7 dias.</p>`
  }</section>`;
}

function blocoRetornos(retornos) {
  if (!retornos?.length) return "";
  return html`<section class="cartao"><h2>Retornos sem consulta</h2><ul class="lista">${
    retornos.map((r) =>
      html`<li><div class="linha"><a class="link-paciente" href="#/paciente/${r.paciente_id}">${r.paciente}</a>
        <span class="etiqueta ${r.atrasado ? "etiqueta-alerta" : "etiqueta-aviso"}">${r.atrasado ? "desde" : "para"} ${dataCurta(r.retorno_previsto)}</span></div>
        ${r.proxima_etapa ? html`<div class="suave pequeno">${r.proxima_etapa}</div>` : ""}
        ${r.telefone ? html`<div class="pequeno"><a href="${linkWhatsApp(r.telefone)}" target="_blank" rel="noopener">${telefone(r.telefone)}</a></div>` : ""}</li>`
    )
  }</ul></section>`;
}

// Blocos que os módulos acrescentam ao início (estoque baixo, financeiro do mês…).
function blocosDeModulos(d) {
  const blocos = [];
  if (d.estoque_alertas?.length) {
    blocos.push(html`<section class="cartao"><h2>Estoque</h2><ul class="lista">${
      d.estoque_alertas.map((i) =>
        html`<li><div class="linha"><span class="forte">${i.nome}</span><span class="etiqueta ${i.zerado ? "etiqueta-alerta" : "etiqueta-aviso"}">${i.quantidade ?? 0} ${i.unidade ?? ""}</span></div>${
          i.mensagem ? html`<div class="suave pequeno">${i.mensagem}</div>` : ""
        }</li>`
      )
    }</ul><div class="botoes" style="margin-top:10px"><a class="botao" href="#/estoque">Ver estoque</a></div></section>`);
  }
  if (d.financeiro_mes) {
    const f = d.financeiro_mes;
    blocos.push(html`<section class="cartao"><h2>Financeiro do mês</h2><dl class="dados">
      ${f.recebido != null ? html`<div><dt>Recebido</dt><dd class="forte">${dinheiro(f.recebido)}</dd></div>` : ""}
      ${f.a_receber != null ? html`<div><dt>A receber</dt><dd>${dinheiro(f.a_receber)}</dd></div>` : ""}
      ${f.despesas != null ? html`<div><dt>Despesas</dt><dd>${dinheiro(f.despesas)}</dd></div>` : ""}
      ${f.resultado != null ? html`<div><dt>Resultado</dt><dd class="forte">${dinheiro(f.resultado)}</dd></div>` : ""}
    </dl><div class="botoes" style="margin-top:10px"><a class="botao" href="#/financeiro">Ver financeiro</a></div></section>`);
  }
  return blocos;
}

// ------------------------------------------------------------------
// Agenda (semana)
// ------------------------------------------------------------------
async function telaAgenda(inicio) {
  const seg = segundaDe(inicio && /^\d{4}-\d{2}-\d{2}$/.test(inicio) ? inicio : hojeISO());
  const d = await api("agenda", { inicio: seg, fim: somarDias(seg, 6) });
  const dias = (d.dias ?? []).filter((dia, i) => i < 6 || dia.consultas?.length || dia.reservas_sala?.length);
  const links = linksPorConsulta(d.pendentes_de_confirmacao);
  const fimSemana = somarDias(seg, 6);
  const titulo = deISO(seg).getMonth() === deISO(fimSemana).getMonth()
    ? `${deISO(seg).getDate()} a ${deISO(fimSemana).getDate()} de ${MESES[deISO(seg).getMonth()]}`
    : `${dataCurta(seg)} a ${dataCurta(fimSemana)}`;
  const consultas = new Map();
  dias.forEach((dia) => (dia.consultas ?? []).forEach((c) => consultas.set(c.id, { ...c, link_whatsapp: links.get(c.id) })));
  depoisDeMostrar.push(() => {
    conteudo().querySelectorAll("[data-consulta]").forEach((b) =>
      b.addEventListener("click", () => abrirJanela(detalheConsulta(consultas.get(b.dataset.consulta))))
    );
  });

  const estreito = matchMedia("(max-width: 700px)").matches;
  return html`
    <div class="cabecalho">
      <div><h1>Agenda</h1><p>${titulo}</p></div>
      <div class="semana-barra">
        <a class="botao" href="#/agenda/${somarDias(seg, -7)}" aria-label="Semana anterior">‹</a>
        <a class="botao" href="#/agenda/${segundaDe(hojeISO())}">Esta semana</a>
        <a class="botao" href="#/agenda/${somarDias(seg, 7)}" aria-label="Próxima semana">›</a>
      </div>
    </div>
    ${estreito ? listaDaSemana(dias, links) : gradeDaSemana(dias, d.hoje ?? hojeISO())}
    <div class="grade grade-2" style="margin-top:16px"><div>${blocoPendentes(d.pendentes_de_confirmacao)}</div><div></div></div>`;
}

function listaDaSemana(dias, links) {
  return dias.map((dia) =>
    html`<section class="cartao"><h2>${dataLonga(dia.data)}</h2>${listaDoDia(dia, { links })}</section>`
  );
}

function gradeDaSemana(dias, hoje) {
  let ini = 8 * 60, fim = 18 * 60;
  dias.forEach((dia) => {
    [...(dia.reservas_sala ?? []), ...(dia.consultas ?? [])].forEach((x) => {
      ini = Math.min(ini, Math.floor(minutos(x.inicio) / 60) * 60);
      fim = Math.max(fim, Math.ceil(minutos(x.fim) / 60) * 60);
    });
  });
  const PX = 1.25; // pixels por minuto
  const TOPO = 12; // folga para o rótulo da primeira e da última hora
  const yMin = (m) => (m - ini) * PX + TOPO;
  const y = (hhmm) => yMin(minutos(hhmm));
  const altura = (fim - ini) * PX + 2 * TOPO;
  const horas = [];
  for (let m = ini; m <= fim; m += 60) horas.push(m);
  const agora = new Date();
  const agoraMin = agora.getHours() * 60 + agora.getMinutes();

  const cabecalhos = dias.map((dia) => {
    const dt = deISO(dia.data);
    return html`<div class="semana-cab ${dia.data === hoje ? "hoje" : ""}">${DIAS_CURTOS[dt.getDay()]}<b>${dt.getDate()}</b></div>`;
  });
  const colunas = dias.map((dia) =>
    html`<div class="semana-col" style="height:${altura}px">
      ${horas.map((m) => html`<div class="semana-linha" style="top:${yMin(m)}px"></div>`)}
      ${(dia.reservas_sala ?? []).map((r) =>
      html`<div class="semana-reserva" style="top:${y(r.inicio)}px;height:${y(r.fim) - y(r.inicio)}px" title="Sala ${r.inicio}–${r.fim}"></div>`
    )}
      ${
      dia.data === hoje && agoraMin > ini && agoraMin < fim ? html`<div class="semana-agora" style="top:${yMin(agoraMin)}px"></div>` : ""
    }
      ${(dia.consultas ?? []).map((c) => {
      const h = Math.max(y(c.fim) - y(c.inicio), 24);
      return html`<button class="semana-consulta ${c.status} ${c.sala_reservada === false ? "sem-sala" : ""}" data-consulta="${c.id}"
          style="top:${y(c.inicio)}px;height:${h - 2}px">
          <b>${c.paciente?.alertas_saude?.length ? "⚠ " : ""}${c.paciente?.apelido ?? c.paciente?.nome}</b>
          ${h > 44 ? html`<span>${c.inicio} · ${c.motivo ?? ""}</span>` : ""}
        </button>`;
    })}
    </div>`
  );
  return html`
    <div class="semana" style="--dias:${dias.length}">
      <div class="semana-cab"></div>${cabecalhos}
      <div class="semana-horas" style="height:${altura}px">${horas.map((m) => html`<span style="top:${yMin(m)}px">${String(m / 60).padStart(2, "0")}h</span>`)}</div>
      ${colunas}
    </div>
    <div class="legenda">
      <span><i style="background:var(--cor-areia-suave);border-top:2px solid var(--cor-areia)"></i>sala reservada</span>
      <span><i style="background:var(--cor-aviso)"></i>a confirmar</span>
      <span><i style="background:var(--cor-ok)"></i>confirmada</span>
      <span><i style="background:var(--cor-marca)"></i>realizada</span>
      <span><i style="background:var(--cor-alerta)"></i>faltou</span>
      <span><i style="border:2px dashed var(--cor-alerta)"></i>fora da reserva da sala</span>
    </div>`;
}

// ------------------------------------------------------------------
// Pacientes
// ------------------------------------------------------------------
let ultimaBusca = "";
async function telaPacientes() {
  const lista = await api("pacientes", { busca: ultimaBusca });
  depoisDeMostrar.push(() => {
    const campo = document.getElementById("busca");
    let espera;
    campo.addEventListener("input", () => {
      clearTimeout(espera);
      espera = setTimeout(async () => {
        ultimaBusca = campo.value.trim();
        try {
          const nova = await api("pacientes", { busca: ultimaBusca });
          document.getElementById("lista-pacientes").innerHTML = String(tabelaPacientes(nova));
          ligarLinhas();
        } catch (e) {
          if (e instanceof SemAcesso) telaEntrada(e.message);
        }
      }, 250);
    });
    ligarLinhas();
  });
  return html`
    <div class="cabecalho"><div><h1>Pacientes</h1><p>${lista.length} ${lista.length === 1 ? "paciente" : "pacientes"}${ultimaBusca ? " encontrados" : ""}</p></div></div>
    <input id="busca" class="busca" type="search" placeholder="Buscar por nome, apelido, telefone ou CPF" value="${ultimaBusca}" autocomplete="off">
    <div class="cartao" style="margin-top:16px" id="lista-pacientes">${tabelaPacientes(lista)}</div>`;
}

function ligarLinhas() {
  document.querySelectorAll("tr[data-paciente]").forEach((tr) =>
    tr.addEventListener("click", (e) => {
      if (!e.target.closest("a")) location.hash = `#/paciente/${tr.dataset.paciente}`;
    })
  );
}

function tabelaPacientes(lista) {
  if (!lista.length) return html`<p class="vazio">Ninguém com esse nome.</p>`;
  return html`<table class="tabela">
    <thead><tr><th>Nome</th><th class="col-opcional">Telefone</th><th class="col-opcional">Última visita</th><th>Próxima consulta</th></tr></thead>
    <tbody>${
    lista.map((p) =>
      html`<tr class="clicavel" data-paciente="${p.id}">
      <td><a class="link-paciente" href="#/paciente/${p.id}">${p.nome}</a>${p.apelido ? html` <span class="suave">(${p.apelido})</span>` : ""}
        <div class="suave pequeno">Ficha ${p.ficha}${p.idade != null ? ` · ${p.idade} anos` : ""}${p.arquivado ? " · arquivado" : ""}</div>
        ${chipsAlertas(p.alertas_saude, true)}</td>
      <td class="col-opcional">${telefone(p.telefone)}</td>
      <td class="col-opcional">${p.ultima_visita ? dataCurta(p.ultima_visita, true) : html`<span class="suave">—</span>`}</td>
      <td>${p.proxima_consulta ? `${dataCurta(p.proxima_consulta.data)} às ${p.proxima_consulta.inicio}` : html`<span class="suave">—</span>`}</td>
    </tr>`
    )
  }</tbody></table>`;
}

// ------------------------------------------------------------------
// Ficha do paciente
// ------------------------------------------------------------------
const cacheFicha = new Map();
async function telaPaciente(id, aba = "resumo") {
  if (!id) return telaPacientes();
  let p = cacheFicha.get(id);
  if (!p || Date.now() - p._em > 60_000) {
    p = await api("paciente", { id });
    p._em = Date.now();
    cacheFicha.set(id, p);
  }
  const abas = [
    ["resumo", "Resumo"],
    ["anamnese", "Anamnese"],
    ["odontograma", "Odontograma"],
    ["atendimentos", `Atendimentos${p.total_atendimentos ? ` (${p.total_atendimentos})` : ""}`],
    ["consultas", "Consultas"],
    ...(p.orcamentos ? [["orcamentos", "Orçamentos"]] : []),
    ...(p.documentos ? [["documentos", "Documentos"]] : []),
    ...(p.financeiro ? [["financeiro", "Financeiro"]] : []),
  ];
  const telas = { resumo: abaResumo, anamnese: abaAnamnese, odontograma: abaOdontograma, atendimentos: abaAtendimentos, consultas: abaConsultas, orcamentos: abaOrcamentos, documentos: abaDocumentos, financeiro: abaFinanceiro };
  const corpo = (telas[aba] ?? abaResumo)(p);
  const zap = linkWhatsApp(p.telefone);
  return html`
    <p style="margin:0 0 10px"><a class="suave pequeno" href="#/pacientes">‹ Pacientes</a></p>
    <div class="ficha-topo">
      <div>
        <h1>${p.nome}</h1>
        <p class="suave" style="margin:6px 0 0">Ficha ${p.ficha}${p.idade != null ? ` · ${p.idade} anos` : ""}${p.apelido ? ` · “${p.apelido}”` : ""}${p.arquivado_em ? " · arquivado" : ""}</p>
      </div>
      <div class="botoes">
        ${p.telefone ? html`<a class="botao" href="tel:+55${p.telefone}">${telefone(p.telefone)}</a>` : ""}
        ${zap ? html`<a class="botao botao-whatsapp" href="${zap}" target="_blank" rel="noopener">${ICONE_CONVERSA} WhatsApp</a>` : ""}
      </div>
    </div>
    ${
    p.alertas_saude?.length
      ? html`<div class="alertas-faixa"><strong>⚠ Alertas de saúde</strong><ul>${p.alertas_saude.map((a) => html`<li>${a.descricao}</li>`)}</ul></div>`
      : ""
  }
    <nav class="abas">${abas.map(([k, nome]) => html`<a href="#/paciente/${p.id}/${k}" class="${k === aba ? "ativo" : ""}">${nome}</a>`)}</nav>
    ${corpo}`;
}

function campo(rotulo, valor) {
  if (valor == null || valor === "" || (Array.isArray(valor) && !valor.length)) return "";
  return html`<div><dt>${rotulo}</dt><dd>${valor}</dd></div>`;
}

function abaResumo(p) {
  const prox = p.consultas?.proximas ?? [];
  const sexo = { f: "Feminino", m: "Masculino", F: "Feminino", M: "Masculino" }[p.sexo] ?? p.sexo;
  return html`
    <div class="grade grade-2">
      <section class="cartao"><h2>Dados</h2><dl class="dados">
        ${campo("Nascimento", p.data_nascimento ? `${dataCurta(p.data_nascimento, true)}${p.idade != null ? ` (${p.idade} anos)` : ""}` : null)}
        ${campo("Sexo", sexo)}
        ${campo("Nome social", p.nome_social)}
        ${campo("CPF", p.cpf ? cpf(p.cpf) : null)}
        ${campo("RG", p.rg)}
        ${campo("Telefone", p.telefone ? telefone(p.telefone) : null)}
        ${campo("E-mail", p.email)}
        ${campo("Endereço", texto(p.endereco))}
        ${campo("Profissão", p.profissao)}
        ${campo("Estado civil", p.estado_civil)}
        ${campo("Contato de emergência", texto(p.contato_emergencia))}
        ${campo("Como conheceu", p.origem)}
        ${campo("Cadastro", p.cadastrado_em ? dataCurta(p.cadastrado_em, true) : null)}
        ${campo("Consentimento LGPD", p.consentimento_lgpd_em ? dataCurta(p.consentimento_lgpd_em, true) : "não registrado")}
        ${campo("Uso de imagem", p.consentimento_imagem_em ? dataCurta(p.consentimento_imagem_em, true) : null)}
      </dl>
      ${p.observacoes ? html`<h3 style="margin-top:16px">Observações</h3><p style="margin:6px 0 0">${p.observacoes}</p>` : ""}
      ${
    p.responsaveis?.length
      ? html`<h3 style="margin-top:16px">Responsáveis</h3><ul class="lista">${
        p.responsaveis.map((r) =>
          html`<li><span class="forte">${r.nome}</span>${r.parentesco ? ` (${r.parentesco})` : ""}${r.e_pagador ? html` <span class="etiqueta">paga</span>` : ""}
          <div class="suave pequeno">${[r.telefone ? telefone(r.telefone) : "", r.cpf ? `CPF ${cpf(r.cpf)}` : ""].filter(Boolean).join(" · ")}</div></li>`
        )
      }</ul>`
      : ""
  }
      </section>
      <div>
        <section class="cartao"><h2>Próximas consultas</h2>${
    prox.length
      ? html`<ul class="lista">${prox.map((c) => html`<li><div class="linha"><span>${dataLonga(c.data)}, ${c.inicio}</span>${chipStatus(c.status)}</div>${c.motivo ? html`<div class="suave pequeno">${c.motivo}</div>` : ""}</li>`)}</ul>`
      : html`<p class="vazio">Nenhuma consulta marcada.</p>`
  }</section>
        ${
    p.ultimos_atendimentos?.[0]
      ? html`<section class="cartao"><h2>Último atendimento</h2><p class="suave pequeno" style="margin:0">${dataCurta(p.ultimos_atendimentos[0].data, true)}</p>
          <p style="margin:6px 0 0">${p.ultimos_atendimentos[0].evolucao}</p>
          ${p.ultimos_atendimentos[0].proxima_etapa ? html`<p class="pequeno" style="margin:8px 0 0"><span class="forte">Próxima etapa:</span> ${p.ultimos_atendimentos[0].proxima_etapa}</p>` : ""}</section>`
      : ""
  }
      </div>
    </div>`;
}

function abaAnamnese(p) {
  const a = p.anamnese;
  if (!a?.registrada) return html`<section class="cartao"><p class="vazio">Anamnese ainda não registrada. Dite ao Claude, por exemplo: “anamnese da Ana: hipertensa, toma losartana, o resto tudo não”.</p></section>`;
  return html`
    <div class="grade grade-2">
      <section class="cartao"><h2>Respostas “sim”</h2>${
    a.positivas?.length
      ? html`<ul class="lista">${a.positivas.map((x) => html`<li><span class="forte">${x.texto}</span>${x.detalhe ? html`<div class="suave">${x.detalhe}</div>` : ""}</li>`)}</ul>`
      : html`<p class="vazio">Nenhuma.</p>`
  }
      ${
    a.respostas_abertas?.length
      ? html`<h3 style="margin-top:18px">Outras respostas</h3><ul class="lista">${a.respostas_abertas.map((x) => html`<li><span class="suave pequeno">${x.texto}</span><div>${x.resposta}</div></li>`)}</ul>`
      : ""
  }</section>
      <section class="cartao"><h2>Sinais e registro</h2><dl class="dados">
        ${campo("Pressão arterial", a.pressao_arterial)}
        ${campo("Frequência cardíaca", a.frequencia_cardiaca)}
        ${campo("Respostas “não”", a.negativas)}
        ${campo("Sem resposta", a.pendentes?.length ? `${a.pendentes.length} pergunta(s)` : null)}
        ${campo("Versão", a.versao)}
        ${campo("Atualizada em", a.atualizada_em ? dataCurta(a.atualizada_em, true) : null)}
        ${campo("Assinada pelo paciente", a.assinada ? "sim" : "não")}
      </dl></section>
    </div>`;
}

// ---------- odontograma ----------
const SUPERIOR = [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28];
const INFERIOR = [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
const DEC_SUP = [55, 54, 53, 52, 51, 61, 62, 63, 64, 65];
const DEC_INF = [85, 84, 83, 82, 81, 71, 72, 73, 74, 75];
const SIGLAS = {
  implante: "IMP", tratamento_canal: "CAN", coroa: "CO", pino_nucleo: "NUC", protese_fixa_pilar: "PIL",
  protese_fixa_pontico: "PON", protese_removivel: "PR", canal_indicado: "CAN?", extracao_indicada: "EXO",
  raiz_residual: "RR", incluso: "INC", semi_incluso: "SI", mobilidade: "MOB", lesao_periapical: "LP",
  faceta: "FAC", recessao: "REC", sensibilidade: "SEN", giroversao: "GIR", extruido: "EXT", diastema: "DIA",
  deciduo_retido: "DR", desgaste: "DES", fratura: "FX", restauracao: "R", restauracao_provisoria: "RP",
  selante: "SEL", carie: "C", lesao_cervical: "LC", mancha_branca: "MB", restauracao_insatisfatoria: "RI",
};

function corDaMarca(m) {
  const tipo = CONDICOES[m.condicao]?.tipo;
  if (m.camada === "planejado") return "var(--dente-planejado)";
  if (tipo === "achado") return "var(--dente-achado)";
  if (tipo === "ausencia") return "var(--dente-ausente)";
  return m.camada === "realizado" ? "var(--dente-feito)" : "var(--dente-trabalho)";
}

function desenharDente(n, x, y, S, marcas, emCima) {
  const c = S * 0.42, i = (S - c) / 2;
  const q = Math.floor(n / 10);
  const superior = [1, 2, 5, 6].includes(q);
  const direitaDoPaciente = [1, 4, 5, 8].includes(q);
  const pol = (pts) => pts.map((p) => p.join(",")).join(" ");
  const faces = {
    cima: pol([[x, y], [x + S, y], [x + S - i, y + i], [x + i, y + i]]),
    baixo: pol([[x, y + S], [x + S, y + S], [x + S - i, y + S - i], [x + i, y + S - i]]),
    esq: pol([[x, y], [x + i, y + i], [x + i, y + S - i], [x, y + S]]),
    dir: pol([[x + S, y], [x + S - i, y + i], [x + S - i, y + S - i], [x + S, y + S]]),
  };
  const lado = (letra) => ({
    V: superior ? "cima" : "baixo",
    B: superior ? "cima" : "baixo",
    L: superior ? "baixo" : "cima",
    P: superior ? "baixo" : "cima",
    O: "centro",
    I: "centro",
    M: direitaDoPaciente ? "dir" : "esq",
    D: direitaDoPaciente ? "esq" : "dir",
  })[letra];
  const preenchido = {};
  const inteiros = [];
  for (const m of marcas) {
    if (m.faces && CONDICOES[m.condicao]?.faces !== false) {
      for (const f of m.faces.toUpperCase()) if (lado(f)) preenchido[lado(f)] = corDaMarca(m);
    } else inteiros.push(m);
  }
  const ausente = inteiros.find((m) => m.condicao === "ausente");
  const anel = inteiros.find((m) => ["coroa", "protese_fixa_pilar", "faceta"].includes(m.condicao));
  const siglas = inteiros.filter((m) => m.condicao !== "ausente" || m.camada === "planejado")
    .map((m) => ({ s: m.condicao === "ausente" ? "EXO" : SIGLAS[m.condicao] ?? m.condicao.slice(0, 3).toUpperCase(), cor: corDaMarca(m) }));
  const estilo = (k) => (preenchido[k] ? `fill:${preenchido[k]}` : "");
  const ySigla = emCima ? y + S + 13 : y - 6;
  const yNum = emCima ? y - 7 : y + S + 16;
  return html`<g class="dente" data-dente="${n}" role="button" aria-label="Dente ${n}">
    <rect x="${x - 3}" y="${y - 3}" width="${S + 6}" height="${S + 6}" fill="transparent"/>
    <polygon class="face" points="${faces.cima}" style="${estilo("cima")}"/>
    <polygon class="face" points="${faces.baixo}" style="${estilo("baixo")}"/>
    <polygon class="face" points="${faces.esq}" style="${estilo("esq")}"/>
    <polygon class="face" points="${faces.dir}" style="${estilo("dir")}"/>
    <rect class="face" x="${x + i}" y="${y + i}" width="${c}" height="${c}" style="${estilo("centro")}"/>
    ${anel ? html`<rect x="${x - 2}" y="${y - 2}" width="${S + 4}" height="${S + 4}" rx="6" fill="none" stroke="${corDaMarca(anel)}" stroke-width="3"/>` : ""}
    ${
    ausente
      ? html`<path d="M${x + 3} ${y + 3}L${x + S - 3} ${y + S - 3}M${x + S - 3} ${y + 3}L${x + 3} ${y + S - 3}" stroke="${corDaMarca(ausente)}" stroke-width="3" stroke-linecap="round"/>`
      : ""
  }
    ${siglas.length ? html`<text class="sigla" x="${x + S / 2}" y="${ySigla}" fill="${siglas[0].cor}">${siglas.slice(0, 2).map((s) => s.s).join(" ")}</text>` : ""}
    <text class="num ${marcas.length ? "marcado" : ""}" x="${x + S / 2}" y="${yNum}">${n}</text>
  </g>`;
}

function svgOdontograma(odonto, idade) {
  const porDente = new Map((odonto ?? []).map((o) => [o.dente, o]));
  const temDeciduos = (odonto ?? []).some((o) => o.dente >= 51) || (idade != null && idade < 13);
  const S = 44, G = 7, MEIO = 20, M = 10;
  const largura = M * 2 + 16 * S + 15 * G + MEIO;
  const centro = largura / 2;
  const xDe = (idx, total) => {
    const metade = total / 2;
    return idx < metade ? centro - MEIO / 2 - (metade - idx) * (S + G) + G : centro + MEIO / 2 + (idx - metade) * (S + G);
  };
  const linhas = [];
  let y = 22;
  const linha = (dentes, emCima) => {
    const total = dentes.length;
    linhas.push(dentes.map((n, idx) => desenharDente(n, xDe(idx, total), y, S, porDente.get(n)?.marcas ?? [], emCima)));
    y += S + 38;
  };
  linha(SUPERIOR, true);
  if (temDeciduos) linha(DEC_SUP, true);
  const yMeio = y - 22;
  if (temDeciduos) linha(DEC_INF, false);
  linha(INFERIOR, false);
  const altura = y - 10;
  return html`<svg class="odonto-svg" viewBox="0 0 ${largura} ${altura}" role="img" aria-label="Odontograma">
    <line x1="${largura / 2}" y1="8" x2="${largura / 2}" y2="${altura - 8}" stroke="var(--cor-linha)" stroke-dasharray="4 4"/>
    <line x1="${M}" y1="${yMeio}" x2="${largura - M}" y2="${yMeio}" stroke="var(--cor-linha)" stroke-dasharray="4 4"/>
    ${linhas}
  </svg>`;
}

function abaOdontograma(p) {
  const odonto = p.odontograma ?? [];
  depoisDeMostrar.push(() => {
    const svg = conteudo().querySelector(".odonto-svg");
    const detalhe = document.getElementById("odonto-detalhe");
    const porDente = new Map(odonto.map((o) => [o.dente, o]));
    svg?.addEventListener("click", (e) => {
      const g = e.target.closest(".dente");
      if (!g) return;
      svg.querySelectorAll(".sel").forEach((x) => x.classList.remove("sel"));
      g.classList.add("sel");
      const n = Number(g.dataset.dente);
      const o = porDente.get(n);
      detalhe.innerHTML = String(html`<span class="forte">Dente ${n}:</span> ${o?.resumo ?? "sem registro (hígido ou não examinado)"}`);
    });
  });
  return html`
    <section class="cartao">
      <div class="odonto-rolagem">${svgOdontograma(odonto, p.idade)}</div>
      <div class="odonto-legenda">
        <span><i style="background:var(--dente-achado)"></i>achado</span>
        <span><i style="background:var(--dente-trabalho)"></i>trabalho existente</span>
        <span><i style="background:var(--dente-feito)"></i>feito no consultório</span>
        <span><i style="background:var(--dente-planejado)"></i>planejado</span>
        <span><i style="background:var(--dente-ausente)"></i>ausente (X)</span>
      </div>
      <p id="odonto-detalhe" class="odonto-detalhe suave">Toque num dente para ver o detalhe.</p>
    </section>
    <section class="cartao"><h2>Por dente</h2>${
    odonto.length
      ? html`<table class="tabela"><tbody>${odonto.map((o) => html`<tr><td class="forte" style="width:64px">${o.dente}</td><td>${o.resumo}</td></tr>`)}</tbody></table>`
      : html`<p class="vazio">Odontograma ainda vazio.</p>`
  }</section>`;
}

// ---------- atendimentos ----------
function abaAtendimentos(p) {
  const lista = p.ultimos_atendimentos ?? [];
  if (!lista.length) return html`<section class="cartao"><p class="vazio">Nenhum atendimento registrado.</p></section>`;
  return html`${lista.map((a) => cartaoAtendimento(a))}${
    p.total_atendimentos > lista.length ? html`<p class="suave pequeno">Mostrando os ${lista.length} mais recentes de ${p.total_atendimentos}.</p>` : ""
  }`;
}

function cartaoAtendimento(a) {
  const anest = (a.anestesia ?? []).map((x) => [x.anestesico, x.vasoconstritor, x.tubetes ? `${x.tubetes} tubete(s)` : "", x.tecnica].filter(Boolean).join(", "));
  const mat = (a.materiais ?? []).map((x) => [x.material, x.detalhe, x.lote ? `lote ${x.lote}` : ""].filter(Boolean).join(" "));
  return html`<article class="cartao atendimento">
    <h3>${dataLonga(a.data)} <span class="suave pequeno">${a.hora_inicio ? `${a.hora_inicio}${a.hora_fim ? `–${a.hora_fim}` : ""}` : ""}</span></h3>
    ${a.corrige_atendimento_id ? html`<div class="correcao">Correção de um registro anterior${a.motivo_correcao ? `: ${a.motivo_correcao}` : ""}.</div>` : ""}
    ${a.corrigido_por?.length ? html`<div class="correcao">Este registro foi corrigido depois (veja o registro mais recente).</div>` : ""}
    ${
    a.procedimentos?.length
      ? html`<ul class="procs">${
        a.procedimentos.map((x) =>
          html`<li><span class="forte">${x.procedimento}</span>${x.dente ? ` · dente ${x.dente}` : ""}${x.faces ? ` ${x.faces}` : ""}${x.regiao ? ` · ${x.regiao}` : ""}${
            x.etapa && x.etapa !== "concluido" ? ` · ${x.etapa.replaceAll("_", " ")}` : ""
          }${x.observacao ? html` <span class="suave">(${x.observacao})</span>` : ""}</li>`
        )
      }</ul>`
      : ""
  }
    <p>${a.evolucao}</p>
    <dl class="dados" style="margin-top:12px">
      ${campo("Anestesia", anest.join("; "))}
      ${campo("Materiais", mat.join("; "))}
      ${campo("Intercorrências", a.intercorrencias)}
      ${campo("Orientações", a.orientacoes)}
      ${campo("Próxima etapa", a.proxima_etapa)}
      ${campo("Retorno previsto", a.retorno_previsto ? dataCurta(a.retorno_previsto, true) : null)}
    </dl>
    <p class="suave pequeno">${a.profissional ?? ""}${a.registrado_em ? ` · registrado em ${dataCurta(a.registrado_em.slice(0, 10), true)} ${a.registrado_em.slice(11)}` : ""}</p>
  </article>`;
}

// ---------- consultas ----------
function abaConsultas(p) {
  const c = p.consultas ?? {};
  const item = (x) =>
    html`<li><div class="linha"><span>${dataLonga(x.data)}, ${x.inicio}</span>${chipStatus(x.status)}</div>${
      x.motivo ? html`<div class="suave pequeno">${x.motivo}</div>` : ""
    }${x.motivo_status ? html`<div class="suave pequeno">Motivo: ${x.motivo_status}</div>` : ""}</li>`;
  return html`<div class="grade grade-2">
    <section class="cartao"><h2>Próximas</h2>${c.proximas?.length ? html`<ul class="lista">${c.proximas.map(item)}</ul>` : html`<p class="vazio">Nenhuma marcada.</p>`}</section>
    <section class="cartao"><h2>Histórico</h2>${c.faltas ? html`<p class="etiqueta etiqueta-alerta">${c.faltas} falta(s)</p>` : ""}${
    c.historico?.length ? html`<ul class="lista">${c.historico.map(item)}</ul>` : html`<p class="vazio">Sem histórico.</p>`
  }</section>
  </div>`;
}

// ---------- módulos (orçamentos, documentos, financeiro do paciente) ----------
function listaGenerica(itens, vazio) {
  if (!itens?.length) return html`<p class="vazio">${vazio}</p>`;
  return html`<ul class="lista">${
    itens.map((x) =>
      html`<li><div class="linha"><div><span class="forte">${x.titulo ?? x.descricao ?? x.tipo ?? "Item"}</span>
      <div class="suave pequeno">${[x.data ? dataCurta(x.data, true) : "", x.numero ? `nº ${x.numero}` : "", x.forma ?? ""].filter(Boolean).join(" · ")}</div></div>
      <div class="botoes">${x.status ? html`<span class="etiqueta">${String(x.status).replaceAll("_", " ")}</span>` : ""}${
        x.valor != null || x.valor_total != null ? html`<span class="forte">${dinheiro(x.valor ?? x.valor_total)}</span>` : ""
      }${x.link ? html`<a class="botao" href="${x.link}" target="_blank" rel="noopener">Abrir PDF</a>` : ""}</div></div></li>`
    )
  }</ul>`;
}
const abaOrcamentos = (p) => html`<section class="cartao">${listaGenerica(p.orcamentos, "Nenhum orçamento.")}</section>`;
const abaDocumentos = (p) => html`<section class="cartao">${listaGenerica(p.documentos, "Nenhum documento emitido.")}</section>`;
function abaFinanceiro(p) {
  const f = p.financeiro ?? {};
  return html`<section class="cartao"><dl class="dados">
      ${campo("Total orçado", f.total_orcado != null ? dinheiro(f.total_orcado) : null)}
      ${campo("Recebido", f.recebido != null ? dinheiro(f.recebido) : null)}
      ${campo("Saldo devedor", f.saldo != null ? dinheiro(f.saldo) : null)}
    </dl></section>
    <section class="cartao"><h2>Pagamentos</h2>${listaGenerica(f.recebimentos, "Nenhum pagamento registrado.")}</section>`;
}

// ------------------------------------------------------------------
// Estoque e financeiro (preenchidos pelos módulos)
// ------------------------------------------------------------------
async function telaEstoque() {
  const d = await api("estoque");
  if (!d) return emBreve("Estoque", "Aqui aparecem os materiais, o que está acabando e as últimas compras.");
  return telaEstoqueCompleta(d);
}
async function telaFinanceiro() {
  const d = await api("financeiro", {});
  if (!d) return emBreve("Financeiro", "Aqui aparecem os recebimentos, as despesas e o resumo do mês.");
  return telaFinanceiroCompleta(d);
}
const emBreve = (titulo, texto) => html`<div class="cabecalho"><div><h1>${titulo}</h1></div></div><section class="cartao"><p class="vazio">${texto}</p></section>`;

function telaEstoqueCompleta(d) {
  const itens = d.itens ?? [];
  return html`<div class="cabecalho"><div><h1>Estoque</h1><p>${itens.length} materiais</p></div></div>
    <section class="cartao"><table class="tabela"><thead><tr><th>Material</th><th>Quantidade</th><th class="col-opcional">Mínimo</th><th class="col-opcional">Último preço</th></tr></thead><tbody>${
    itens.map((i) =>
      html`<tr><td class="forte">${i.nome}${i.categoria ? html`<div class="suave pequeno">${i.categoria}</div>` : ""}</td>
      <td><span class="etiqueta ${i.zerado ? "etiqueta-alerta" : i.baixo ? "etiqueta-aviso" : "etiqueta-ok"}">${i.quantidade ?? 0} ${i.unidade ?? ""}</span></td>
      <td class="col-opcional">${i.minimo ?? ""}</td><td class="col-opcional">${i.ultimo_preco != null ? dinheiro(i.ultimo_preco) : ""}</td></tr>`
    )
  }</tbody></table></section>`;
}

function telaFinanceiroCompleta(d) {
  const r = d.resumo ?? {};
  return html`<div class="cabecalho"><div><h1>Financeiro</h1><p>${d.periodo ?? ""}</p></div></div>
    <div class="numeros">
      ${r.recebido != null ? html`<div class="numero"><b>${dinheiro(r.recebido)}</b><span>recebido</span></div>` : ""}
      ${r.a_receber != null ? html`<div class="numero"><b>${dinheiro(r.a_receber)}</b><span>a receber</span></div>` : ""}
      ${r.despesas != null ? html`<div class="numero"><b>${dinheiro(r.despesas)}</b><span>despesas</span></div>` : ""}
      ${r.resultado != null ? html`<div class="numero"><b>${dinheiro(r.resultado)}</b><span>resultado</span></div>` : ""}
    </div>
    <div class="grade grade-2">
      <section class="cartao"><h2>Recebimentos</h2>${listaGenerica(d.recebimentos, "Nenhum recebimento no período.")}</section>
      <section class="cartao"><h2>Despesas</h2>${listaGenerica(d.despesas, "Nenhuma despesa no período.")}</section>
    </div>`;
}

// ------------------------------------------------------------------
if ("serviceWorker" in navigator && location.protocol === "https:") {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
navegar();
