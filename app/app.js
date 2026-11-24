// Site do consultório: agenda, pacientes, orçamentos, documentos, estoque,
// financeiro, preços e a atividade do Claude. Tudo vem da Edge Function
// "painel" com o login da Dra. (e-mail, senha e código de dois fatores).
// Pelo site ela também lança recebimentos, despesas e o estoque (lancar.js);
// o resto continua pelo Claude.

import { CONDICOES } from "./condicoes.js";
import { nivel, temSessao } from "./auth.js";
import { abrirJanela, api, conteudo, depoisDeMostrar, mostrar, podeLancar, PrecisaCodigo, SemLogin } from "./nucleo.js";
import {
  acabouDeEntrar,
  capturarConvite,
  convitePendente,
  MENSAGEM_LINK_NOVO,
  telaCodigo,
  telaConvite,
  telaEntrar,
} from "./entrada.js";
import { telaAgendaMes, telaAjustes, telaAtividade, telaDocumentos, telaOrcamentos, telaPrecos } from "./telas.js";
import { escolherLancamento, estornar, lancarDespesa, lancarEstoque, lancarRecebimento } from "./lancar.js";
import { barrinhasSemanas, graficoDozeMeses, ligarGraficoDozeMeses } from "./grafico.js";
import {
  abaDocumentos,
  campo,
  chipsAlertas,
  chipStatus,
  COR_ORCAMENTO,
  cpf,
  cru,
  dataCurta,
  dataLonga,
  deISO,
  DIAS_CURTOS,
  dinheiro,
  duracao,
  emBreve,
  hojeISO,
  html,
  ICONE_CONVERSA,
  linkWhatsApp,
  listaGenerica,
  mesCurto,
  MESES,
  minutos,
  normalizar,
  segundaDe,
  somarDias,
  STATUS_ITEM,
  telefone,
  texto,
  valorOrcamento,
} from "./base.js";

// ------------------------------------------------------------------
// Navegação
// ------------------------------------------------------------------
let geracao = 0;
let rotaAtual = "";

const TELAS = {
  hoje: telaHoje,
  agenda: telaAgendaRota,
  pacientes: telaPacientes,
  paciente: telaPaciente,
  orcamentos: telaOrcamentos,
  documentos: telaDocumentos,
  estoque: telaEstoque,
  financeiro: telaFinanceiro,
  precos: telaPrecos,
  atividade: telaAtividade,
  ajustes: telaAjustes,
};
const NOMES = {
  hoje: "Hoje",
  agenda: "Agenda",
  pacientes: "Pacientes",
  paciente: "Paciente",
  orcamentos: "Orçamentos",
  documentos: "Documentos",
  estoque: "Estoque",
  financeiro: "Financeiro",
  precos: "Preços",
  atividade: "Atividade",
  ajustes: "Ajustes",
};

/** Abre a tela do endereço atual (#/secao/...), conferindo o login antes. */
async function navegar({ silencioso = false } = {}) {
  const partes = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean).map(decodeURIComponent);
  const secao = TELAS[partes[0]] ? partes[0] : "hoje";
  const minha = ++geracao;
  rotaAtual = secao;
  fecharMais();
  document.querySelectorAll(".nav a[data-secao], .mais-painel a[data-secao]").forEach((a) =>
    a.classList.toggle("ativo", a.dataset.secao === (secao === "paciente" ? "pacientes" : secao))
  );
  document.querySelector(".nav-mais")?.classList.toggle(
    "ativo",
    !["hoje", "agenda", "pacientes", "paciente", "financeiro"].includes(secao),
  );
  if (convitePendente()) return telaConvite(entrouAgora);
  if (!temSessao()) return telaEntrar(entrouAgora);
  if (nivel() !== "aal2") return telaCodigo(entrouAgora);
  document.body.classList.remove("sem-acesso");
  document.title = `${NOMES[secao]} · Consultório`;
  if (!silencioso) mostrar(html`<p class="carregando">Carregando…</p>`);
  try {
    const v = await TELAS[secao](...partes.slice(1));
    if (minha !== geracao || v == null) {
      depoisDeMostrar.splice(0);
      return;
    }
    mostrar(v);
    if (!silencioso) {
      conteudo().focus({ preventScroll: true });
      window.scrollTo(0, 0);
    }
  } catch (e) {
    depoisDeMostrar.splice(0);
    if (minha !== geracao) return;
    if (e instanceof SemLogin) return telaEntrar(entrouAgora, acabouDeEntrar() ? MENSAGEM_LINK_NOVO : e.message);
    if (e instanceof PrecisaCodigo) return telaCodigo(entrouAgora);
    if (!silencioso) mostrar(html`<div class="erro-caixa">${e.message}</div>`);
  }
}
const entrouAgora = () => navegar();
/** Recarrega a tela atual (depois de um lançamento). */
const recarregar = () => {
  cacheFicha.clear();
  navegar({ silencioso: true });
};

window.addEventListener("hashchange", () => {
  capturarConvite();
  navegar();
});
document.addEventListener("visibilitychange", () => {
  if (
    document.visibilityState === "visible" && ["hoje", "agenda"].includes(rotaAtual) &&
    !document.querySelector(".janela-fundo")
  ) {
    navegar({ silencioso: true });
  }
});
setInterval(() => {
  if (
    document.visibilityState === "visible" && ["hoje", "agenda"].includes(rotaAtual) &&
    !document.querySelector(".janela-fundo")
  ) {
    navegar({ silencioso: true });
  }
}, 60_000);

// ------------------------------------------------------------------
// Menu "Mais" (celular) e botão de lançar
// ------------------------------------------------------------------
function fecharMais() {
  const painel = document.getElementById("mais-painel");
  if (painel) painel.hidden = true;
  document.querySelector(".nav-mais")?.setAttribute("aria-expanded", "false");
}
document.querySelector(".nav-mais")?.addEventListener("click", (e) => {
  const painel = document.getElementById("mais-painel");
  painel.hidden = !painel.hidden;
  e.currentTarget.setAttribute("aria-expanded", String(!painel.hidden));
});
document.getElementById("mais-painel")?.addEventListener("click", (e) => {
  if (e.target === e.currentTarget || e.target.closest("a")) fecharMais();
});

const ACOES_LANCAR = {
  recebimento: () => lancarRecebimento({ depois: recarregar }),
  despesa: () => lancarDespesa({ depois: recarregar }),
  estoque: async () => {
    const d = await api("estoque").catch(() => null);
    lancarEstoque({ materiais: d?.materiais ?? [], depois: recarregar });
  },
};
document.querySelectorAll("[data-lancar]").forEach((b) => {
  b.hidden = !podeLancar();
  b.addEventListener("click", () => {
    fecharMais();
    escolherLancamento(ACOES_LANCAR);
  });
});
/** Liga botões [data-lancar-tipo] da tela atual. */
function ligarLancar(extras = {}) {
  conteudo().querySelectorAll("[data-lancar-tipo]").forEach((b) =>
    b.addEventListener("click", () => (extras[b.dataset.lancarTipo] ?? ACOES_LANCAR[b.dataset.lancarTipo])())
  );
}

// ------------------------------------------------------------------
// Janela (detalhe de uma consulta)
// ------------------------------------------------------------------
function detalheConsulta(c) {
  const p = c.paciente ?? {};
  return html`
    <div
      class="linha"><div><h2>${p.nome}</h2><p class="suave" style="margin:4px 0 0">${dataLonga(c.data)}, ${c.inicio}–${c
        .fim} (${duracao(c.duracao_min)})</p></div>${chipStatus(c.status)}</div>
    ${p.alertas_saude?.length
      ? html`<div class="alertas-faixa"><strong>Alertas de saúde</strong><ul>${
        p.alertas_saude.map((a) => html`<li>${a.descricao}</li>`)
      }</ul></div>`
      : ""}
    <dl class="dados" style="margin-top:16px">
      ${c.motivo
        ? html`
          <div>
            <dt>Motivo</dt>
            <dd>${c.motivo}</dd>
          </div>
        `
        : ""}
      ${c.observacao
        ? html`
          <div>
            <dt>Observação</dt>
            <dd>${c.observacao}</dd>
          </div>
        `
        : ""}
      ${p.telefone
        ? html`
          <div>
            <dt>Telefone</dt>
            <dd><a href="tel:+55${p.telefone}">${telefone(p.telefone)}</a></dd>
          </div>
        `
        : ""}
      ${c.motivo_status
        ? html`
          <div>
            <dt>Motivo do status</dt>
            <dd>${c.motivo_status}</dd>
          </div>
        `
        : ""}
      ${p.primeira_vez
        ? html`
          <div>
            <dt>Paciente</dt>
            <dd>Primeira vez</dd>
          </div>
        `
        : ""}
      ${c.sala_reservada === false
        ? html`
          <div>
            <dt>Sala</dt>
            <dd class="forte" style="color:var(--cor-alerta)">Sem reserva neste horário</dd>
          </div>
        `
        : ""}
    </dl>
    <div class="botoes" style="margin-top:16px">
      <a class="botao botao-principal" href="#/paciente/${p.id}">Abrir ficha</a>
      ${c.link_whatsapp
        ? html`<a class="botao botao-whatsapp" href="${c.link_whatsapp}" target="_blank" rel="noopener">${ICONE_CONVERSA} Pedir confirmação</a>`
        : ""}
    </div>
  `;
}

// ------------------------------------------------------------------
// Agenda de um dia (lista)
// ------------------------------------------------------------------
function listaDoDia(dia, { links = new Map(), compacto = false } = {}) {
  const itens = [];
  (dia.reservas_sala ?? []).forEach((r) => itens.push({ t: minutos(r.inicio), ordem: 0, r }));
  (dia.consultas ?? []).forEach((c) => itens.push({ t: minutos(c.inicio), ordem: 1, c }));
  if (!compacto) {
    (dia.horarios_livres ?? []).filter((l) => l.minutos >= 30).forEach((l) =>
      itens.push({ t: minutos(l.inicio), ordem: 2, l })
    );
  }
  itens.sort((a, b) => a.t - b.t || a.ordem - b.ordem);
  if (!itens.length) return html`<p class="vazio">${dia.mensagem ?? "Nada marcado."}</p>`;
  const linhas = itens.map((i) => {
    if (i.r) {
      return html`<li class="dia-sala">▦ Sala reservada ${i.r.inicio}–${i.r.fim}${
        i.r.local ? ` · ${i.r.local}` : ""
      }</li>`;
    }
    if (i.l) return html`<li class="dia-livre">Livre ${i.l.inicio}–${i.l.fim} (${duracao(i.l.minutos)})</li>`;
    const c = i.c, p = c.paciente ?? {};
    const link = links.get(c.id);
    return html`
      <li class="dia-item">
        <div class="dia-hora">${c.inicio}<small>${duracao(c.duracao_min)}</small></div>
        <div>
              <div class="linha"><a class="link-paciente" href="#/paciente/${p.id}">${p.nome}</a>${chipStatus(
                c.status,
              )}</div>
              ${c.motivo ? html`<div class="suave">${c.motivo}</div>` : ""}
              ${compacto ? "" : html`<div class="etiquetas" style="margin-top:6px">
          ${p.primeira_vez ? html`<span class="etiqueta etiqueta-info">Primeira vez</span>` : ""}
          ${c.sala_reservada === false ? html`<span class="etiqueta etiqueta-alerta">Sem sala reservada</span>` : ""}
          ${c.observacao ? html`<span class="etiqueta">${c.observacao}</span>` : ""}
        </div>
        ${chipsAlertas(p.alertas_saude)}
        ${
                link
                  ? html`
                    <div class="botoes"
                      style="margin-top:8px"><a class="botao botao-whatsapp" href="${link}" target="_blank" rel="noopener">${ICONE_CONVERSA} Pedir confirmação</a></div>
                  `
                  : ""
              }`}
            </div>
      </li>
    `;
  });
  return html`<ul class="dia-lista">${linhas}</ul>`;
}

const linksPorConsulta = (pendentes) =>
  new Map((pendentes ?? []).filter((p) => p.link_whatsapp).map((p) => [p.consulta_id, p.link_whatsapp]));

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
  depoisDeMostrar.push(() => ligarLancar());
  return html`
    <div class="cabecalho"><div><h1>${saudacao}, ${nome}</h1><p>${dataLonga(d.hoje)}</p></div>${atalhosLancar()}</div>
    <div class="numeros">
      <div class="numero"><b>${ativasHoje.length}</b><span>consultas hoje</span></div>
      <div class="numero"><b>${n.consultas_semana ?? 0}</b><span>nesta semana</span></div>
      <div class="numero"><b>${(d.pendentes_de_confirmacao ?? []).length}</b><span>a confirmar (7 dias)</span></div>
      <div class="numero"><b>${n.pacientes ?? 0}</b><span>pacientes</span></div>
      ${n.atendimentos_mes != null
        ? html`<div class="numero"><b>${n.atendimentos_mes}</b><span>atendimentos no mês</span></div>`
        : ""}
    </div>
    <div class="grade grade-2">
      <div>
        <section class="cartao"><h2>Hoje</h2>${listaDoDia(d.agenda_hoje, { links })}</section>
        <section
          class="cartao"><h2>Amanhã <span class="suave pequeno" style="font-family:var(--fonte-texto)">${dataLonga(
            d.agenda_amanha.data,
          )}</span></h2>${listaDoDia(d.agenda_amanha, { links, compacto: true })}</section>
      </div>
      <div>
        ${blocoFichasOnline(d.fichas_online)}
        ${blocoPendentes(d.pendentes_de_confirmacao)}
        ${blocoRetornos(d.retornos_sem_consulta)}
        ${blocosDeModulos(d)}
        ${blocoRascunhos(d.orcamentos_rascunho)}
        ${blocoCampanhas(d.campanhas)}
      </div>
    </div>
  `;
}

/** Botões de lançar no topo das telas (se o site puder lançar). */
function atalhosLancar(tipos = ["recebimento", "despesa", "estoque"]) {
  if (!podeLancar()) return "";
  const nomes = { recebimento: "Recebimento", despesa: "Despesa", estoque: "Estoque" };
  return html`<div class="botoes atalhos" aria-label="Lançar">${
    tipos.map((t, i) =>
      html`<button type="button" class="botao ${i === 0 ? "botao-principal" : ""}" data-lancar-tipo="${t}">+ ${
        nomes[t]
      }</button>`
    )
  }</div>`;
}

function blocoFichasOnline(fichas) {
  if (!fichas?.length) return "";
  return html`
    <section class="cartao aviso-faixa">
      <h2>Fichas online para revisar</h2>
      <ul class="lista">${fichas.map((f) =>
        html`
          <li>
            <div
              class="linha"><a class="link-paciente" href="#/paciente/${f.paciente_id}">${f
                .paciente}</a><span class="suave pequeno">enviada ${dataCurta(f.enviada_em)}</span></div>
          </li>
        `
      )}</ul>
      <p class="suave pequeno"
        style="margin:10px 0 0">O paciente preencheu a ficha pelo link. Peça ao Claude: “mostra a ficha online da fulana” para revisar e confirmar.</p>
    </section>
  `;
}

function blocoRascunhos(rascunhos) {
  if (!rascunhos?.length) return "";
  return html`
    <section class="cartao">
      <h2>Orçamentos em rascunho</h2>
      <ul class="lista">${rascunhos.map((o) =>
        html`
          <li>
            <div class="linha"><div><a class="link-paciente" href="#/paciente/${o.paciente_id}/orcamentos">${o
              .paciente}</a>
                <div class="suave pequeno">${o.titulo ?? ""}</div></div><span class="forte">${valorOrcamento(
                  o,
                )}</span></div>
          </li>
        `
      )}</ul>
      <div class="botoes" style="margin-top:10px"><a class="botao" href="#/orcamentos">Ver orçamentos</a></div>
    </section>
  `;
}

function blocoCampanhas(campanhas) {
  if (!campanhas?.length) return "";
  return html`
    <section class="cartao">
      <h2>Campanhas</h2>
      <ul class="lista">${campanhas.map((c) =>
        html`
          <li>
            <div class="linha"><span class="forte">${c.nome}</span><span class="etiqueta ${c.situacao === "em_andamento"
              ? "etiqueta-ok"
              : "etiqueta-info"}">${String(c.situacao ?? "").replaceAll("_", " ")}</span></div>
            <div class="suave pequeno">${[c.periodo, c.local, c.cidade].filter(Boolean).join(" · ")}${c.precos_especiais
              ? ` · ${c.precos_especiais} preços especiais`
              : ""}</div>
          </li>
        `
      )}</ul>
      <div class="botoes" style="margin-top:10px"><a class="botao" href="#/precos">Ver preços</a></div>
    </section>
  `;
}

function blocoPendentes(pendentes) {
  return html`<section class="cartao"><h2>Para confirmar</h2>${
    pendentes?.length
      ? html`
        <ul class="lista">${pendentes.map((p) =>
          html`
            <li>
              <div class="linha"><div><a class="link-paciente" href="#/paciente/${p.paciente_id}">${p.paciente}</a>
                      <div class="suave pequeno">${p.dia_semana}, ${dataCurta(p.data)} às ${p.inicio}${p.motivo
                        ? ` · ${p.motivo}`
                        : ""}</div></div>
                      ${p.link_whatsapp
                        ? html`<a class="botao botao-whatsapp" href="${p.link_whatsapp}" target="_blank" rel="noopener">${ICONE_CONVERSA} WhatsApp</a>`
                        : html`<span class="etiqueta etiqueta-aviso">sem telefone</span>`}</div>
            </li>
          `
        )}</ul>
        <p class="suave pequeno"
          style="margin:10px 0 0">O botão abre o WhatsApp com a mensagem pronta; é só enviar. Quando o paciente responder, diga ao Claude “fulano confirmou”.</p>
      `
      : html`<p class="vazio">Tudo confirmado nos próximos 7 dias.</p>`
  }</section>`;
}

function blocoRetornos(retornos) {
  if (!retornos?.length) return "";
  return html`
    <section class="cartao">
      <h2>Retornos sem consulta</h2>
      <ul class="lista">${retornos.map((r) =>
        html`<li><div class="linha"><a class="link-paciente" href="#/paciente/${r.paciente_id}">${r.paciente}</a>
        <span class="etiqueta ${r.atrasado ? "etiqueta-alerta" : "etiqueta-aviso"}">${r.atrasado ? "desde" : "para"} ${
          dataCurta(r.retorno_previsto)
        }</span></div>
        ${r.proxima_etapa ? html`<div class="suave pequeno">${r.proxima_etapa}</div>` : ""}
        ${
          r.telefone
            ? html`<div class="pequeno"><a href="${linkWhatsApp(r.telefone)}" target="_blank" rel="noopener">${
              telefone(r.telefone)
            }</a></div>`
            : ""
        }</li>`
      )}</ul>
    </section>
  `;
}

// Blocos que os módulos acrescentam ao início (orçamentos, estoque, financeiro).
function blocosDeModulos(d) {
  const blocos = [];
  if (d.orcamentos_acompanhar?.length) {
    blocos.push(html`
      <section class="cartao">
        <h2>Orçamentos para acompanhar</h2>
        <ul class="lista">${d.orcamentos_acompanhar.map((o) =>
          html`<li><div class="linha"><div><a class="link-paciente" href="#/paciente/${o.paciente_id}/orcamentos">${o.paciente}</a>
        <div class="suave pequeno">${[o.titulo, valorOrcamento(o)].filter(Boolean).join(" · ")}</div></div>
        <span class="etiqueta ${o.em_atraso ? "etiqueta-alerta" : "etiqueta-aviso"}">contato ${
            dataCurta(o.proximo_contato)
          }</span></div>
        ${
            o.telefone
              ? html`<div class="pequeno"><a href="${linkWhatsApp(o.telefone)}" target="_blank" rel="noopener">${
                telefone(o.telefone)
              }</a></div>`
              : ""
          }</li>`
        )}</ul>
        <p class="suave pequeno"
          style="margin:10px 0 0">Depois de falar com o paciente, conte ao Claude (“liguei pra fulana sobre o orçamento”).</p>
      </section>
    `);
  }
  if (d.estoque_alertas?.length) {
    blocos.push(html`
      <section class="cartao">
        <h2>Estoque acabando</h2>
        <ul class="lista">${d.estoque_alertas.map((i) =>
          html`<li><div class="linha"><span class="forte">${i.nome}</span><span class="etiqueta ${
            i.zerado ? "etiqueta-alerta" : "etiqueta-aviso"
          }">${i.quantidade ?? "0"}</span></div>${
            i.mensagem ? html`<div class="suave pequeno">${i.mensagem}</div>` : ""
          }</li>`
        )}</ul>
        <div class="botoes" style="margin-top:10px"><a class="botao" href="#/estoque">Ver estoque</a></div>
      </section>
    `);
  }
  if (d.financeiro_mes) {
    const f = d.financeiro_mes;
    blocos.push(html`
      <section class="cartao">
        <h2>Financeiro do mês</h2>
        <dl class="dados">
            ${f.recebido != null
              ? html`
                <div>
                  <dt>Recebido</dt>
                  <dd class="forte">${dinheiro(f.recebido)}</dd>
                </div>
              `
              : ""}
            ${f.a_receber
              ? html`
                <div>
                  <dt>Ainda a receber no mês</dt>
                  <dd>${dinheiro(f.a_receber)}</dd>
                </div>
              `
              : ""}
            ${f.despesas != null
              ? html`
                <div>
                  <dt>Despesas</dt>
                  <dd>${dinheiro(f.despesas)}</dd>
                </div>
              `
              : ""}
            ${f.resultado != null
              ? html`
                <div>
                  <dt>Resultado</dt>
                  <dd class="forte">${dinheiro(f.resultado)}</dd>
                </div>
              `
              : ""}
          </dl>
        <div class="botoes" style="margin-top:10px"><a class="botao" href="#/financeiro">Ver financeiro</a></div>
      </section>
    `);
  }
  return blocos;
}

// ------------------------------------------------------------------
// Agenda (semana)
// ------------------------------------------------------------------
function telaAgendaRota(a, b) {
  if (a === "mes") return telaAgendaMes(b, (c) => abrirJanela(detalheConsulta(c), { titulo: "Consulta" }));
  return telaAgenda(a);
}

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
  dias.forEach((dia) =>
    (dia.consultas ?? []).forEach((c) => consultas.set(c.id, { ...c, link_whatsapp: links.get(c.id) }))
  );
  depoisDeMostrar.push(() => {
    conteudo().querySelectorAll("[data-consulta]").forEach((b) =>
      b.addEventListener(
        "click",
        () => abrirJanela(detalheConsulta(consultas.get(b.dataset.consulta)), { titulo: "Consulta" }),
      )
    );
  });

  const estreito = matchMedia("(max-width: 700px)").matches;
  return html`
    <div class="cabecalho">
      <div>
        <h1>Agenda</h1>
        <p>${titulo}</p>
      </div>
      <div class="semana-barra">
        <div class="alternar" role="group"
          aria-label="Visão"><a class="botao ativo" aria-current="page" href="#/agenda/${seg}">Semana</a><a class="botao" href="#/agenda/mes/${seg
            .slice(0, 7)}">Mês</a></div>
        <a class="botao" href="#/agenda/${somarDias(seg, -7)}" aria-label="Semana anterior">‹</a>
        <a class="botao" href="#/agenda/${segundaDe(hojeISO())}">Esta semana</a>
        <a class="botao" href="#/agenda/${somarDias(seg, 7)}" aria-label="Próxima semana">›</a>
      </div>
    </div>
    ${estreito ? listaDaSemana(dias, links) : gradeDaSemana(dias, d.hoje ?? hojeISO())}
    <div class="grade grade-2" style="margin-top:16px">
      <div>${blocoPendentes(d.pendentes_de_confirmacao)}</div>
      <div></div>
    </div>
  `;
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
    return html`<div class="semana-cab ${dia.data === hoje ? "hoje" : ""}">${
      DIAS_CURTOS[dt.getDay()]
    }<b>${dt.getDate()}</b></div>`;
  });
  const colunas = dias.map((dia) =>
    html`<div class="semana-col" style="height:${altura}px">
      ${horas.map((m) => html`<div class="semana-linha" style="top:${yMin(m)}px"></div>`)}
      ${
      (dia.reservas_sala ?? []).map((r) =>
        html`<div class="semana-reserva" style="top:${y(r.inicio)}px;height:${
          y(r.fim) - y(r.inicio)
        }px" title="Sala ${r.inicio}–${r.fim}"></div>`
      )
    }
      ${
      dia.data === hoje && agoraMin > ini && agoraMin < fim
        ? html`<div class="semana-agora" style="top:${yMin(agoraMin)}px"></div>`
        : ""
    }
      ${
      (dia.consultas ?? []).map((c) => {
        const h = Math.max(y(c.fim) - y(c.inicio), 24);
        return html`
          <button class="semana-consulta ${c.status} ${c.sala_reservada === false ? "sem-sala" : ""}" data-consulta="${c
            .id}"
            style="top:${y(c.inicio)}px;height:${h - 2}px">
                    <b>${c.paciente?.alertas_saude?.length ? "⚠ " : ""}${c.paciente?.apelido ?? c.paciente?.nome}</b>
                    ${h > 44 ? html`<span>${c.inicio} · ${c.motivo ?? ""}</span>` : ""}
                  </button>
        `;
      })
    }
    </div>`
  );
  return html`
    <div class="semana" style="--dias:${dias.length}">
      <div class="semana-cab"></div>${cabecalhos}
      <div class="semana-horas" style="height:${altura}px">${horas.map((m) =>
        html`<span style="top:${yMin(m)}px">${String(m / 60).padStart(2, "0")}h</span>`
      )}</div>
      ${colunas}
    </div>
    <div class="legenda">
      <span><i style="background:var(--cor-areia-suave);border-top:2px solid var(--cor-areia)"></i>sala reservada</span>
      <span><i style="background:var(--cor-aviso)"></i>a confirmar</span>
      <span><i style="background:var(--cor-ok)"></i>confirmada</span>
      <span><i style="background:var(--cor-marca)"></i>realizada</span>
      <span><i style="background:var(--cor-alerta)"></i>faltou</span>
      <span><i style="border:2px dashed var(--cor-alerta)"></i>fora da reserva da sala</span>
    </div>
  `;
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
          if (e instanceof SemLogin) navegar();
        }
      }, 250);
    });
    ligarLinhas();
  });
  return html`
    <div class="cabecalho">
      <div>
        <h1>Pacientes</h1>
        <p>${lista.length} ${lista.length === 1 ? "paciente" : "pacientes"}${ultimaBusca ? " encontrados" : ""}</p>
      </div>
    </div>
    <input id="busca" class="busca" type="search" placeholder="Buscar por nome, apelido, telefone ou CPF"
      value="${ultimaBusca}" autocomplete="off">
    <div class="cartao" style="margin-top:16px" id="lista-pacientes">${tabelaPacientes(lista)}</div>
  `;
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
  return html`
    <table class="tabela">
      <thead>
        <tr>
          <th>Nome</th>
          <th class="col-opcional">Telefone</th>
          <th class="col-opcional">Última visita</th>
          <th>Próxima consulta</th>
        </tr>
      </thead>
      <tbody>${lista.map((p) =>
        html`
          <tr class="clicavel" data-paciente="${p.id}">
            <td><a class="link-paciente" href="#/paciente/${p.id}">${p.nome}</a>${p.apelido
              ? html`
                <span class="suave">(${p.apelido})</span>
              `
              : ""}
                  <div class="suave pequeno">Ficha ${p.ficha}${p.idade != null ? ` · ${p.idade} anos` : ""}${p.arquivado
                    ? " · arquivado"
                    : ""}</div>
                  ${chipsAlertas(p.alertas_saude, true)}</td>
            <td class="col-opcional">${telefone(p.telefone)}</td>
            <td class="col-opcional">${p.ultima_visita
              ? dataCurta(p.ultima_visita, true)
              : html`<span class="suave">—</span>`}</td>
            <td>${p.proxima_consulta
              ? `${dataCurta(p.proxima_consulta.data)} às ${p.proxima_consulta.inicio}`
              : html`<span class="suave">—</span>`}</td>
          </tr>
        `
      )}</tbody>
    </table>
  `;
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
  const telas = {
    resumo: abaResumo,
    anamnese: abaAnamnese,
    odontograma: abaOdontograma,
    atendimentos: abaAtendimentos,
    consultas: abaConsultas,
    orcamentos: abaOrcamentos,
    documentos: abaDocumentos,
    financeiro: abaFinanceiro,
  };
  const corpo = (telas[aba] ?? abaResumo)(p);
  const zap = linkWhatsApp(p.telefone);
  depoisDeMostrar.push(() =>
    ligarLancar({ recebimento: () => lancarRecebimento({ paciente: { id: p.id, nome: p.nome }, depois: recarregar }) })
  );
  return html`
    <p style="margin:0 0 10px"><a class="suave pequeno" href="#/pacientes">‹ Pacientes</a></p>
    <div class="ficha-topo">
      <div>
        <h1>${p.nome}</h1>
        <p class="suave" style="margin:6px 0 0">Ficha ${p.ficha}${p.idade != null
          ? ` · ${p.idade} anos`
          : ""}${p.apelido ? ` · “${p.apelido}”` : ""}${p.arquivado_em ? " · arquivado" : ""}</p>
      </div>
      <div class="botoes">
        ${podeLancar()
          ? html`<button type="button" class="botao botao-principal" data-lancar-tipo="recebimento">+ Recebimento</button>`
          : ""}
        ${p.telefone ? html`<a class="botao" href="tel:+55${p.telefone}">${telefone(p.telefone)}</a>` : ""}
        ${zap
          ? html`<a class="botao botao-whatsapp" href="${zap}" target="_blank" rel="noopener">${ICONE_CONVERSA} WhatsApp</a>`
          : ""}
      </div>
    </div>
    ${p.alertas_saude?.length
      ? html`<div class="alertas-faixa"><strong>⚠ Alertas de saúde</strong><ul>${
        p.alertas_saude.map((a) => html`<li>${a.descricao}</li>`)
      }</ul></div>`
      : ""}
    <nav class="abas">${abas.map(([k, nome]) =>
      html`<a href="#/paciente/${p.id}/${k}" class="${k === aba ? "ativo" : ""}">${nome}</a>`
    )}</nav>
    ${corpo}
  `;
}

function abaResumo(p) {
  const prox = p.consultas?.proximas ?? [];
  const sexo = { f: "Feminino", m: "Masculino", F: "Feminino", M: "Masculino" }[p.sexo] ?? p.sexo;
  return html`
    <div class="grade grade-2">
      <section class="cartao"><h2>Dados</h2><dl class="dados">
        ${campo(
          "Nascimento",
          p.data_nascimento
            ? `${dataCurta(p.data_nascimento, true)}${p.idade != null ? ` (${p.idade} anos)` : ""}`
            : null,
        )}
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
        ${campo(
          "Consentimento LGPD",
          p.consentimento_lgpd_em ? dataCurta(p.consentimento_lgpd_em, true) : "não registrado",
        )}
        ${campo("Uso de imagem", p.consentimento_imagem_em ? dataCurta(p.consentimento_imagem_em, true) : null)}
      </dl>
      ${p.observacoes
        ? html`
          <h3 style="margin-top:16px">Observações</h3>
          <p style="margin:6px 0 0">${p.observacoes}</p>
        `
        : ""}
      ${p.responsaveis?.length
        ? html`
          <h3 style="margin-top:16px">Responsáveis</h3>
          <ul class="lista">${p.responsaveis.map((r) =>
            html`<li><span class="forte">${r.nome}</span>${r.parentesco ? ` (${r.parentesco})` : ""}${
              r.e_pagador
                ? html`
                  <span class="etiqueta">paga</span>
                `
                : ""
            }
          <div class="suave pequeno">${
              [r.telefone ? telefone(r.telefone) : "", r.cpf ? `CPF ${cpf(r.cpf)}` : ""].filter(Boolean).join(" · ")
            }</div></li>`
          )}</ul>
        `
        : ""}
      </section>
      <div>
        <section class="cartao"><h2>Próximas consultas</h2>${prox.length
          ? html`<ul class="lista">${
            prox.map((c) =>
              html`<li><div class="linha"><span>${dataLonga(c.data)}, ${c.inicio}</span>${chipStatus(c.status)}</div>${
                c.motivo ? html`<div class="suave pequeno">${c.motivo}</div>` : ""
              }</li>`
            )
          }</ul>`
          : html`<p class="vazio">Nenhuma consulta marcada.</p>`}</section>
        ${p.ultimos_atendimentos?.[0]
          ? html`<section class="cartao"><h2>Último atendimento</h2><p class="suave pequeno" style="margin:0">${
            dataCurta(p.ultimos_atendimentos[0].data, true)
          }</p>
          <p style="margin:6px 0 0">${p.ultimos_atendimentos[0].evolucao}</p>
          ${
            p.ultimos_atendimentos[0].proxima_etapa
              ? html`<p class="pequeno" style="margin:8px 0 0"><span class="forte">Próxima etapa:</span> ${
                p.ultimos_atendimentos[0].proxima_etapa
              }</p>`
              : ""
          }</section>`
          : ""}
      </div>
    </div>
  `;
}

function abaAnamnese(p) {
  const a = p.anamnese;
  if (!a?.registrada) {
    return html`
      <section class="cartao">
        <p
          class="vazio">Anamnese ainda não registrada. Dite ao Claude, por exemplo: “anamnese da Ana: hipertensa, toma losartana, o resto tudo não”.</p>
      </section>
    `;
  }
  return html`
    <div class="grade grade-2">
      <section class="cartao"><h2>Respostas “sim”</h2>${a.positivas?.length
        ? html`<ul class="lista">${
          a.positivas.map((x) =>
            html`<li><span class="forte">${x.texto}</span>${
              x.detalhe ? html`<div class="suave">${x.detalhe}</div>` : ""
            }</li>`
          )
        }</ul>`
        : html`<p class="vazio">Nenhuma.</p>`}
      ${a.respostas_abertas?.length
        ? html`
          <h3 style="margin-top:18px">Outras respostas</h3>
          <ul class="lista">${a.respostas_abertas.map((x) =>
            html`<li><span class="suave pequeno">${x.texto}</span><div>${x.resposta}</div></li>`
          )}</ul>
        `
        : ""}</section>
      <section class="cartao">
        <h2>Sinais e registro</h2>
        <dl class="dados">
        ${campo("Pressão arterial", a.pressao_arterial)}
        ${campo("Frequência cardíaca", a.frequencia_cardiaca)}
        ${campo("Respostas “não”", a.negativas)}
        ${campo("Sem resposta", a.pendentes?.length ? `${a.pendentes.length} pergunta(s)` : null)}
        ${campo("Versão", a.versao)}
        ${campo("Atualizada em", a.atualizada_em ? dataCurta(a.atualizada_em, true) : null)}
        ${campo("Assinada pelo paciente", a.assinada ? "sim" : "não")}
      </dl>
      </section>
    </div>
  `;
}

// ---------- odontograma ----------
const SUPERIOR = [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28];
const INFERIOR = [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
const DEC_SUP = [55, 54, 53, 52, 51, 61, 62, 63, 64, 65];
const DEC_INF = [85, 84, 83, 82, 81, 71, 72, 73, 74, 75];
const SIGLAS = {
  implante: "IMP",
  tratamento_canal: "CAN",
  coroa: "CO",
  pino_nucleo: "NUC",
  protese_fixa_pilar: "PIL",
  protese_fixa_pontico: "PON",
  protese_removivel: "PR",
  canal_indicado: "CAN?",
  extracao_indicada: "EXO",
  raiz_residual: "RR",
  incluso: "INC",
  semi_incluso: "SI",
  mobilidade: "MOB",
  lesao_periapical: "LP",
  faceta: "FAC",
  recessao: "REC",
  sensibilidade: "SEN",
  giroversao: "GIR",
  extruido: "EXT",
  diastema: "DIA",
  deciduo_retido: "DR",
  desgaste: "DES",
  fratura: "FX",
  restauracao: "R",
  restauracao_provisoria: "RP",
  selante: "SEL",
  carie: "C",
  lesao_cervical: "LC",
  mancha_branca: "MB",
  restauracao_insatisfatoria: "RI",
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
  const lado = (letra) =>
    ({
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
    .map((m) => ({
      s: m.condicao === "ausente" ? "EXO" : SIGLAS[m.condicao] ?? m.condicao.slice(0, 3).toUpperCase(),
      cor: corDaMarca(m),
    }));
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
    ${
    anel
      ? html`
        <rect x="${x - 2}" y="${y - 2}" width="${S + 4}" height="${S + 4}" rx="6" fill="none" stroke="${corDaMarca(
          anel,
        )}"
          stroke-width="3" />
      `
      : ""
  }
    ${
    ausente
      ? html`
        <path d="M${x + 3} ${y + 3}L${x + S - 3} ${y + S - 3}M${x + S - 3} ${y + 3}L${x + 3} ${y + S - 3}"
          stroke="${corDaMarca(ausente)}" stroke-width="3" stroke-linecap="round" />
      `
      : ""
  }
    ${
    siglas.length
      ? html`<text class="sigla" x="${x + S / 2}" y="${ySigla}" fill="${siglas[0].cor}">${
        siglas.slice(0, 2).map((s) => s.s).join(" ")
      }</text>`
      : ""
  }
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
    return idx < metade
      ? centro - MEIO / 2 - (metade - idx) * (S + G) + G
      : centro + MEIO / 2 + (idx - metade) * (S + G);
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
    <line x1="${largura / 2}" y1="8" x2="${largura / 2}" y2="${
    altura - 8
  }" stroke="var(--cor-linha)" stroke-dasharray="4 4"/>
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
      detalhe.innerHTML = String(
        html`<span class="forte">Dente ${n}:</span> ${o?.resumo ?? "sem registro (hígido ou não examinado)"}`,
      );
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
    <section class="cartao"><h2>Por dente</h2>${odonto.length
      ? html`
        <table class="tabela">
          <tbody>${odonto.map((o) =>
            html`
              <tr>
                <td class="forte" style="width:64px">${o.dente}</td>
                <td>${o.resumo}</td>
              </tr>
            `
          )}</tbody>
        </table>
      `
      : html`<p class="vazio">Odontograma ainda vazio.</p>`}</section>
  `;
}

// ---------- atendimentos ----------
function abaAtendimentos(p) {
  const lista = p.ultimos_atendimentos ?? [];
  if (!lista.length) {
    return html`
      <section class="cartao">
        <p class="vazio">Nenhum atendimento registrado.</p>
      </section>
    `;
  }
  return html`${lista.map((a) => cartaoAtendimento(a))}${
    p.total_atendimentos > lista.length
      ? html`<p class="suave pequeno">Mostrando os ${lista.length} mais recentes de ${p.total_atendimentos}.</p>`
      : ""
  }`;
}

function cartaoAtendimento(a) {
  const anest = (a.anestesia ?? []).map((x) =>
    [x.anestesico, x.vasoconstritor, x.tubetes ? `${x.tubetes} tubete(s)` : "", x.tecnica].filter(Boolean).join(", ")
  );
  const mat = (a.materiais ?? []).map((x) =>
    [x.material, x.detalhe, x.lote ? `lote ${x.lote}` : ""].filter(Boolean).join(" ")
  );
  return html`<article class="cartao atendimento">
    <h3>${dataLonga(a.data)} <span class="suave pequeno">${
    a.hora_inicio ? `${a.hora_inicio}${a.hora_fim ? `–${a.hora_fim}` : ""}` : ""
  }</span></h3>
    ${
    a.corrige_atendimento_id
      ? html`<div class="correcao">Correção de um registro anterior${
        a.motivo_correcao ? `: ${a.motivo_correcao}` : ""
      }.</div>`
      : ""
  }
    ${
    a.corrigido_por?.length
      ? html`<div class="correcao">Este registro foi corrigido depois (veja o registro mais recente).</div>`
      : ""
  }
    ${
    a.procedimentos?.length
      ? html`<ul class="procs">${
        a.procedimentos.map((x) =>
          html`<li><span class="forte">${x.procedimento}</span>${x.dente ? ` · dente ${x.dente}` : ""}${
            x.faces ? ` ${x.faces}` : ""
          }${x.regiao ? ` · ${x.regiao}` : ""}${
            x.etapa && x.etapa !== "concluido" ? ` · ${x.etapa.replaceAll("_", " ")}` : ""
          }${
            x.observacao
              ? html`
                <span class="suave">(${x.observacao})</span>
              `
              : ""
          }</li>`
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
    <p class="suave pequeno">${a.profissional ?? ""}${
    a.registrado_em
      ? ` · registrado em ${dataCurta(a.registrado_em.slice(0, 10), true)} ${a.registrado_em.slice(11)}`
      : ""
  }</p>
  </article>`;
}

// ---------- consultas ----------
function abaConsultas(p) {
  const c = p.consultas ?? {};
  const item = (x) =>
    html`<li><div class="linha"><span>${dataLonga(x.data)}, ${x.inicio}</span>${chipStatus(x.status)}</div>${
      x.motivo ? html`<div class="suave pequeno">${x.motivo}</div>` : ""
    }${x.motivo_status ? html`<div class="suave pequeno">Motivo: ${x.motivo_status}</div>` : ""}</li>`;
  return html`
    <div class="grade grade-2">
      <section class="cartao"><h2>Próximas</h2>${c.proximas?.length
        ? html`<ul class="lista">${c.proximas.map(item)}</ul>`
        : html`<p class="vazio">Nenhuma marcada.</p>`}</section>
      <section class="cartao"><h2>Histórico</h2>${c.faltas
        ? html`<p class="etiqueta etiqueta-alerta">${c.faltas} falta(s)</p>`
        : ""}${c.historico?.length
        ? html`<ul class="lista">${c.historico.map(item)}</ul>`
        : html`<p class="vazio">Sem histórico.</p>`}</section>
    </div>
  `;
}

// ---------- módulos (orçamentos, documentos, financeiro do paciente) ----------
function abaOrcamentos(p) {
  if (!p.orcamentos?.length) {
    return html`
      <section class="cartao">
        <p
          class="vazio">Nenhum orçamento. Peça ao Claude: “monta um orçamento pra ${p.apelido ??
            p.nome.split(" ")[0]} com o que está planejado no odontograma”.</p>
      </section>
    `;
  }
  return p.orcamentos.map((o) =>
    html`<section class="cartao"><div class="linha"><div><h2 style="margin:0">${o.titulo}</h2>
      <div class="suave pequeno">${
      [
        o.data ? `emitido ${dataCurta(o.data, true)}` : "",
        o.validade && ["apresentado", "rascunho"].includes(o.situacao)
          ? `válido até ${dataCurta(o.validade, true)}`
          : "",
        o.aprovado_em ? `aprovado ${dataCurta(o.aprovado_em, true)}` : "",
        o.forma ?? "",
      ].filter(Boolean).join(" · ")
    }</div></div>
      <div class="botoes"><span class="etiqueta ${COR_ORCAMENTO[o.situacao] ?? ""}">${o.status}</span>${
      o.link ? html`<a class="botao" href="${o.link}" target="_blank" rel="noopener">Abrir PDF</a>` : ""
    }</div></div>
      <ul class="lista" style="margin-top:10px">${
      (o.itens ?? []).map((i) =>
        html`
          <li>
            <div class="linha">
              <div${i.conta === false ? cru(' style="opacity:.55"') : ""}>${i.descricao}${i.alternativa
                ? html`
                  <span class="etiqueta etiqueta-info">opção ${i.alternativa}</span>
                `
                : ""}
                    ${i.local ? html`<div class="suave pequeno">${i.local}</div>` : ""}</div>
                    <div class="botoes">${STATUS_ITEM[i.status]
                      ? html`<span class="etiqueta ${i.status === "realizado" ? "etiqueta-ok" : ""}">${
                        STATUS_ITEM[i.status]
                      }</span>`
                      : ""}<span>${i.valor != null ? dinheiro(i.valor) : ""}</span></div></div></li>
        `
      )
    }</ul>
      <div class="linha" style="margin-top:10px"><span class="suave">Total</span><span class="forte">${
      valorOrcamento(o)
    }</span></div>
      ${
      o.proximo_contato
        ? html`<p class="pequeno ${
          o.contato_em_atraso ? "texto-alerta" : "suave"
        }" style="margin:8px 0 0">Próximo contato: ${dataCurta(o.proximo_contato, true)}</p>`
        : ""
    }
    </section>`
  );
}

function abaFinanceiro(p) {
  const f = p.financeiro ?? {};
  const parcelas = (f.parcelas_em_aberto ?? []).map((x) => ({
    titulo: x.descricao ?? "Parcela",
    numero: x.parcela,
    data: x.vencimento,
    valor: x.restante,
    status: x.situacao,
  }));
  return html`
    <section class="cartao">
      <dl class="dados">
          ${campo("Total aprovado", f.total_orcado != null ? dinheiro(f.total_orcado) : null)}
          ${campo("Recebido", dinheiro(f.recebido ?? 0))}
          ${campo("A receber", dinheiro(f.saldo ?? f.a_receber ?? 0))}
          ${f.atrasado ? campo("Atrasado", dinheiro(f.atrasado)) : ""}
          ${campo("Último pagamento", f.ultimo_pagamento ? dataCurta(f.ultimo_pagamento, true) : null)}
        </dl>
    </section>
        ${parcelas.length
          ? html`<section class="cartao"><h2>Parcelas em aberto</h2>${listaGenerica(parcelas, "")}</section>`
          : ""}
        <section class="cartao"><h2>Pagamentos</h2>${listaGenerica(
          f.recebimentos,
          "Nenhum pagamento registrado.",
        )}</section>
  `;
}

// ------------------------------------------------------------------
// Estoque
// ------------------------------------------------------------------
async function telaEstoque() {
  const d = await api("estoque");
  if (!d) return emBreve("Estoque", "Aqui aparecem os materiais, o que está acabando e as últimas compras.");
  return telaEstoqueCompleta(d);
}
const SITUACAO_ESTOQUE = {
  ok: ["etiqueta-ok", "ok"],
  baixo: ["etiqueta-aviso", "baixo"],
  zerado: ["etiqueta-alerta", "acabou"],
  sem_contagem: ["etiqueta-apagada", "sem contagem"],
};

function telaEstoqueCompleta(d) {
  const itens = d.itens ?? [];
  const r = d.resumo ?? {};
  const compras = d.lista_de_compras ?? [];
  depoisDeMostrar.push(() => {
    const campoBusca = document.getElementById("busca-estoque");
    campoBusca?.addEventListener("input", () => {
      const q = normalizar(campoBusca.value);
      document.querySelectorAll("#tabela-estoque tbody tr").forEach((tr) => {
        tr.hidden = q !== "" && !tr.dataset.busca.includes(q);
      });
    });
    ligarLancar({ estoque: () => lancarEstoque({ materiais: d.materiais ?? [], depois: recarregar }) });
    conteudo().querySelectorAll("[data-ajustar]").forEach((b) =>
      b.addEventListener(
        "click",
        () => lancarEstoque({ materiais: d.materiais ?? [], material: b.dataset.ajustar, depois: recarregar }),
      )
    );
  });
  return html`
    <div class="cabecalho"><div><h1>Estoque</h1><p>${r.materiais ?? itens.length} materiais · ${r.com_contagem ??
      0} com contagem</p></div>
          ${podeLancar()
            ? html`
              <div
                class="botoes"><button type="button" class="botao botao-principal" data-lancar-tipo="estoque">Ajustar estoque</button></div>
            `
            : ""}</div>
        ${d.sem_contagem
          ? html`
            <section
              class="cartao aviso-faixa"><strong>Falta a contagem inicial.</strong> Conte a prateleira aos poucos e diga ao Claude, por exemplo: “tenho 2 caixas de luva M e 1 caixa de articaína”. A partir daí, cada atendimento dá baixa sozinho.</section>
          `
          : ""}
        <div class="numeros">
          <div class="numero"><b>${dinheiro(r.valor_em_estoque ?? 0)}</b><span>em estoque</span></div>
          <div class="numero"><b>${compras.length}</b><span>para comprar</span></div>
          ${r.total_estimado
            ? html`<div class="numero"><b>${dinheiro(r.total_estimado)}</b><span>compra estimada</span></div>`
            : ""}
          <div class="numero"><b>${(d.vencendo ?? []).length}</b><span>lotes vencendo (60 dias)</span></div>
        </div>
        <div class="grade grade-2">
      <section class="cartao">
        <div class="linha"><h2 style="margin:0">Materiais</h2>
            <input id="busca-estoque" class="busca busca-pequena" type="search" placeholder="Buscar material" autocomplete="off"></div>
        <table class="tabela" id="tabela-estoque">
          <thead>
            <tr>
              <th>Material</th>
              <th>Tem</th>
              <th class="col-opcional">Mínimo</th>
            </tr>
          </thead>
          <tbody>${itens.map((i) => {
            const [cor, rotulo] = SITUACAO_ESTOQUE[i.situacao] ?? ["", i.situacao ?? ""];
            return html`
              <tr data-busca="${normalizar(`${i.nome} ${i.categoria ?? ""}`)}">
                <td>${podeLancar()
                  ? html`<button type="button" class="link-material" data-ajustar="${i.nome}" title="Ajustar">${i.nome}</button>`
                  : html`<span class="forte">${i.nome}</span>`}${i.categoria
                  ? html`<div class="suave pequeno">${i.categoria}${
                    i.ultimo_preco != null ? ` · ${dinheiro(i.ultimo_preco)} por ${i.unidade_compra ?? "unidade"}` : ""
                  }${i.vence_primeiro ? ` · vence ${dataCurta(i.vence_primeiro, true)}` : ""}</div>`
                  : ""}</td>
                <td>${i.quantidade
                  ? html`<div>${i.quantidade}</div>`
                  : ""}<span class="etiqueta ${cor}">${rotulo}</span></td>
                <td class="col-opcional suave">${i.minimo ?? ""}</td>
              </tr>
            `;
          })}</tbody>
        </table>
      </section>
      <div>
            <section class="cartao"><h2>Lista de compras</h2>${compras.length
              ? html`<ul class="lista">${
                compras.map((c) =>
                  html`
                    <li>
                      <div class="linha">
                        <div><span class="forte">${c.material}</span>
                                    <div class="suave pequeno">${[
                                      c.saldo ? `tem ${c.saldo}` : "",
                                      c.ultimo_fornecedor ?? "",
                                      c.motivo ?? "",
                                    ].filter(Boolean).join(" · ")}</div></div>
                        <div class="botoes"><span class="etiqueta etiqueta-aviso">${c.comprar}</span>${c.valor_estimado
                          ? html`<span>${dinheiro(c.valor_estimado)}</span>`
                          : ""}</div>
                      </div>
                    </li>
                  `
                )
              }</ul>`
              : html`<p class="vazio">Nada para comprar agora.</p>`}</section>
            ${d.vencendo?.length
              ? html`
                <section class="cartao">
                  <h2>Vencendo</h2>
                  <ul class="lista">${d.vencendo.map((v) =>
                    html`
                      <li>
                        <div
                          class="linha"><div><span class="forte">${v.nome}</span><div class="suave pequeno">${v.lote
                            ? `lote ${v.lote} · `
                            : ""}${v.quantidade}</div></div>
                                  <span class="etiqueta ${v.validade <= hojeISO()
                                    ? "etiqueta-alerta"
                                    : "etiqueta-aviso"}">${dataCurta(v.validade, true)}</span></div>
                      </li>
                    `
                  )}</ul>
                </section>
              `
              : ""}
            <section class="cartao"><h2>Últimas compras</h2>${listaGenerica(
              d.ultimas_compras,
              "Nenhuma compra registrada. Diga ao Claude o que comprou, de quem e por quanto.",
            )}</section>
          </div>
    </div>
        ${blocoConsumo(d)}
        ${blocoMovimentos(d.movimentos)}
  `;
}

/** Quanto saiu de cada material por semana (uso, perda e vencido), 8 semanas. */
function blocoConsumo(d) {
  const consumo = d.consumo ?? [];
  if (!d.semanas) return "";
  const dia = (s) => `${String(s).slice(8, 10)}/${String(s).slice(5, 7)}`;
  return html`<section class="cartao" style="margin-top:16px"><h2>Consumo por semana</h2>${
    consumo.length
      ? html`
        <p class="suave pequeno"
          style="margin-top:-6px">Últimas 8 semanas, de ${dia(
            d.semanas[0],
          )} até esta semana (a barra mais escura). Conta uso, perda e vencido.</p>
        <table class="tabela">
          <thead>
            <tr>
              <th>Material</th>
              <th>Semanas</th>
              <th class="num">Média por semana</th>
              <th class="num col-opcional">Total</th>
            </tr>
          </thead>
          <tbody>${consumo.map((c) =>
            html`
              <tr>
                <td class="forte">${c.nome}</td>
                <td>${barrinhasSemanas(c.por_semana, d.semanas, c.unidade)}</td>
                <td class="num">${c.media_semana}</td>
                <td class="num col-opcional suave">${c.total}</td>
              </tr>
            `
          )}</tbody>
        </table>
      `
      : html`
        <p
          class="vazio">Sem consumo registrado nas últimas 8 semanas. Cada atendimento registrado dá baixa sozinho; o que gastar fora disso, lance em “Ajustar estoque”.</p>
      `
  }</section>`;
}

function blocoMovimentos(movimentos) {
  if (!movimentos?.length) return "";
  return html`
    <section class="cartao" style="margin-top:16px">
      <h2>Últimas movimentações</h2>
      <ul class="lista">${movimentos.map((m) =>
        html`
          <li>
            <div class="linha">
              <div><span class="forte">${m.material}</span>
                  <div class="suave pequeno">${m.tipo}${m.motivo ? ` · ${m.motivo}` : ""}</div></div>
              <div
                class="botoes"><span class="${m.entrada ? "texto-ok" : ""}">${m.entrada ? "+" : "−"}${m
                  .quantidade}</span><span class="suave pequeno">${dataCurta(m.data, true)}</span></div>
            </div>
          </li>
        `
      )}</ul>
    </section>
  `;
}

// ------------------------------------------------------------------
// Financeiro
// ------------------------------------------------------------------
/** Recebimentos ou despesas do mês, com o botão de estornar. */
function listaLancamentos(itens, tipo, vazio) {
  if (!itens?.length) return html`<p class="vazio">${vazio}</p>`;
  return html`<ul class="lista">${
    itens.map((x) =>
      html`
        <li>
          <div class="linha">
            <div>${x.paciente_id
              ? html`<a class="link-paciente" href="#/paciente/${x.paciente_id}/financeiro">${x.titulo}</a>`
              : html`<span class="forte">${x.titulo ?? "Lançamento"}</span>${
                x.clinica
                  ? html`
                    <span class="etiqueta etiqueta-info">clínica</span>
                  `
                  : ""
              }`}
              <div class="suave pequeno">${[
                x.data ? dataCurta(x.data, true) : "",
                x.forma ?? "",
                x.paciente_id || x.clinica ? x.descricao ?? "" : "",
                x.automatica ? "lançada sozinha" : "",
              ].filter(Boolean).join(" · ")}</div></div>
            <div class="botoes">${x.status
              ? html`<span class="etiqueta etiqueta-alerta">${x.status}</span>`
              : ""}<span class="forte ${x.status ? "riscado" : ""}">${dinheiro(
                x.valor,
              )}</span>${podeLancar() && x.id && !x.status && !x.automatica
              ? html`
                <button type="button" class="botao botao-pequeno" data-estornar="${x.id}" data-tipo="${tipo}"
                  aria-label="Estornar ${x.titulo ?? ""} de ${dinheiro(x.valor)}">Estornar</button>
              `
              : ""}</div>
          </div>
        </li>
      `
    )
  }</ul>`;
}

async function telaFinanceiro(mes) {
  const d = await api("financeiro", mes ? { mes } : {});
  if (!d) return emBreve("Financeiro", "Aqui aparecem os recebimentos, as despesas e o resumo do mês.");
  return telaFinanceiroCompleta(d);
}

function telaFinanceiroCompleta(d) {
  const r = d.resumo ?? {};
  const pequenaLista = (itens) =>
    itens?.length
      ? html`<dl class="dados">${
        itens.map((x) =>
          html`
            <div>
              <dt>${x.titulo}</dt>
              <dd>${dinheiro(x.valor)}</dd>
            </div>
          `
        )
      }</dl>`
      : html`<p class="vazio">Nada no mês.</p>`;
  const itens = new Map([...(d.recebimentos ?? []), ...(d.despesas ?? [])].filter((x) => x.id).map((x) => [x.id, x]));
  depoisDeMostrar.push(() => {
    ligarLancar();
    if (d.historico?.length) ligarGraficoDozeMeses(d.historico);
    conteudo().querySelectorAll("[data-estornar]").forEach((b) =>
      b.addEventListener("click", () => {
        const x = itens.get(b.dataset.estornar);
        estornar({
          tipo: b.dataset.tipo,
          id: x.id,
          descricao: [x.titulo, x.data ? dataCurta(x.data, true) : "", x.forma, dinheiro(x.valor)].filter(Boolean).join(
            " · ",
          ),
          depois: recarregar,
        });
      })
    );
  });
  return html`
    <div class="cabecalho">
      <div>
        <h1>Financeiro</h1>
        <p>${d.periodo ?? ""}</p>
      </div>
      <div
        class="botoes">${atalhosLancar([
          "recebimento",
          "despesa",
        ])}<div class="botoes"><a class="botao" href="#/financeiro/${d
          .anterior}" aria-label="Mês anterior">‹ ${mesCurto(d.anterior)}</a><a class="botao" href="#/financeiro/${d
          .proximo}" aria-label="Próximo mês">${mesCurto(d.proximo)} ›</a></div></div>
    </div>
        <div class="numeros">
      <div class="numero"><b>${dinheiro(r.recebido ?? 0)}</b><span>recebido${r.taxas
        ? ` (${dinheiro(r.liquido)} líquido)`
        : ""}</span></div>
      <div class="numero"><b>${dinheiro(r.despesas ?? 0)}</b><span>despesas</span></div>
      <div class="numero"><b>${dinheiro(r.resultado ?? 0)}</b><span>resultado</span></div>
      <div class="numero"><b>${dinheiro(r.a_receber ?? 0)}</b><span>a receber${r.atrasado
        ? `, ${dinheiro(r.atrasado)} atrasado`
        : ""}</span></div>
    </div>
        ${d.avisos?.length
          ? html`
            <section class="cartao aviso-faixa">
              <ul>${d.avisos.map((a) => html`<li>${a}</li>`)}</ul>
            </section>
          `
          : ""}
        ${d.historico?.length
          ? html`<section class="cartao" style="margin-bottom:16px"><h2>Últimos 12 meses</h2>${
            graficoDozeMeses(d.historico)
          }</section>`
          : ""}
        <div class="grade grade-2">
      <div>
        <section class="cartao"><h2>Recebimentos</h2>${listaLancamentos(
          d.recebimentos,
          "recebimento",
          "Nenhum recebimento no mês.",
        )}</section>
        <section class="cartao"><h2>Despesas</h2>${listaLancamentos(
          d.despesas,
          "despesa",
          "Nenhuma despesa no mês.",
        )}</section>
      </div>
      <div>
            ${d.recibos_a_emitir?.length
              ? html`<section class="cartao aviso-faixa"><h2>Recibos do Receita Saúde</h2>${
                listaGenerica(d.recibos_a_emitir, "")
              }
        <p class="suave pequeno" style="margin:10px 0 0">Depois de emitir no app Receita Saúde, diga ao Claude “emiti os recibos de novembro”. O pacote do mês para o contador também sai pelo Claude.</p></section>`
              : ""}
            ${d.parcelas_a_receber?.length
              ? html`<section class="cartao"><h2>Parcelas a receber</h2>${
                listaGenerica(d.parcelas_a_receber, "")
              }</section>`
              : ""}
            <section class="cartao"><h2>Por forma de pagamento</h2>${pequenaLista(d.por_forma)}</section>
            <section class="cartao"><h2>Despesas por categoria</h2>${pequenaLista(d.por_categoria)}</section>
          </div>
    </div>
  `;
}
// ------------------------------------------------------------------
if ("serviceWorker" in navigator && location.protocol === "https:") {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
capturarConvite();
navegar();
