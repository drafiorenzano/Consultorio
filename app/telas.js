// Telas novas do site: agenda do mês, orçamentos, documentos, preços,
// atividade (o que foi registrado pelo Claude e pelo site) e ajustes.

import { sair } from "./auth.js";
import { api, avisar, conteudo, depoisDeMostrar, podeLancar } from "./nucleo.js";
import {
  campo,
  COR_ORCAMENTO,
  dataCurta,
  dataLonga,
  deISO,
  DIAS_CURTOS,
  dinheiro,
  hojeISO,
  html,
  MESES,
  normalizar,
  paraISO,
  segundaDe,
  somarDias,
  telefone,
  TIPO_DOCUMENTO,
  valorOrcamento,
} from "./base.js";

/** Filtro de botões + busca que esconde linhas [data-filtro] e [data-busca]. */
function ligarFiltros(raiz = conteudo()) {
  let filtro = "todos", busca = "";
  const aplicar = () => {
    let visiveis = 0;
    raiz.querySelectorAll("[data-filtro]").forEach((el) => {
      const ok = (filtro === "todos" || el.dataset.filtro.split(" ").includes(filtro)) &&
        (!busca || (el.dataset.busca ?? "").includes(busca));
      el.hidden = !ok;
      if (ok) visiveis++;
    });
    const vazio = raiz.querySelector(".filtro-vazio");
    if (vazio) vazio.hidden = visiveis > 0;
  };
  raiz.querySelectorAll(".filtros button").forEach((b) =>
    b.addEventListener("click", () => {
      filtro = b.dataset.valor;
      raiz.querySelectorAll(".filtros button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      aplicar();
    })
  );
  raiz.querySelector(".busca-filtro")?.addEventListener("input", (e) => {
    busca = normalizar(e.target.value);
    aplicar();
  });
}

const filtros = (opcoes) =>
  html`<div class="filtros" role="group" aria-label="Filtrar">${
    opcoes.map(([v, r], i) =>
      html`<button type="button" class="chip" data-valor="${v}" aria-pressed="${i === 0}">${r}</button>`
    )
  }</div>`;

// ------------------------------------------------------------------
// Agenda do mês
// ------------------------------------------------------------------
export async function telaAgendaMes(aaaamm, abrirConsulta) {
  const base = /^\d{4}-\d{2}$/.test(aaaamm ?? "") ? `${aaaamm}-01` : `${hojeISO().slice(0, 7)}-01`;
  const primeiro = deISO(base);
  const inicio = segundaDe(base);
  const d = await api("agenda", { inicio, fim: somarDias(inicio, 41) });
  const mes = base.slice(0, 7);
  const ant = paraISO(new Date(primeiro.getFullYear(), primeiro.getMonth() - 1, 1)).slice(0, 7);
  const prox = paraISO(new Date(primeiro.getFullYear(), primeiro.getMonth() + 1, 1)).slice(0, 7);
  const hoje = d.hoje ?? hojeISO();
  const consultas = new Map();
  (d.dias ?? []).forEach((dia) => (dia.consultas ?? []).forEach((c) => consultas.set(c.id, c)));
  depoisDeMostrar.push(() =>
    conteudo().querySelectorAll("[data-consulta]").forEach((b) =>
      b.addEventListener("click", () => abrirConsulta(consultas.get(b.dataset.consulta)))
    )
  );
  const ativas = (dia) => (dia.consultas ?? []).filter((c) => !["cancelada", "remarcada"].includes(c.status));
  const total = (d.dias ?? []).filter((dia) => dia.data.startsWith(mes)).reduce((n, dia) => n + ativas(dia).length, 0);
  const celulas = (d.dias ?? []).map((dia) => {
    const dt = deISO(dia.data);
    const fora = !dia.data.startsWith(mes);
    const lista = ativas(dia);
    return html`<div class="mes-dia ${fora ? "fora" : ""} ${dia.data === hoje ? "hoje" : ""} ${
      dt.getDay() === 0 ? "domingo" : ""
    }">
      <div class="mes-num"><span class="mes-semana">${DIAS_CURTOS[dt.getDay()]}</span> ${dt.getDate()}${
      dia.reservas_sala?.length ? html`<span class="mes-sala" title="Sala reservada">▦</span>` : ""
    }</div>
      ${
      lista.slice(0, 4).map((c) =>
        html`
          <button type="button" class="mes-consulta ${c.status}"
            data-consulta="${c.id}"><b>${c.inicio}</b> ${c.paciente?.apelido ??
              c.paciente?.nome?.split(" ")[0]}</button>
        `
      )
    }
      ${
      lista.length > 4 ? html`<a class="mes-mais" href="#/agenda/${segundaDe(dia.data)}">+${lista.length - 4}</a>` : ""
    }
    </div>`;
  });
  return html`
    <div class="cabecalho">
      <div>
        <h1>Agenda</h1>
        <p>${MESES[primeiro.getMonth()]} de ${primeiro.getFullYear()} · ${total} ${total === 1
          ? "consulta"
          : "consultas"}</p>
      </div>
      <div class="semana-barra">
        <div class="alternar" role="group"
          aria-label="Visão"><a class="botao" href="#/agenda">Semana</a><a class="botao ativo" aria-current="page" href="#/agenda/mes/${mes}">Mês</a></div>
        <a class="botao" href="#/agenda/mes/${ant}" aria-label="Mês anterior">‹</a>
        <a class="botao" href="#/agenda/mes/${hojeISO().slice(0, 7)}">Este mês</a>
        <a class="botao" href="#/agenda/mes/${prox}" aria-label="Próximo mês">›</a>
      </div>
    </div>
    <div class="mes-grade">${DIAS_CURTOS.slice(1).concat(DIAS_CURTOS[0]).map((n) =>
      html`<div class="mes-cab">${n}</div>`
    )}${celulas}</div>
    <div class="legenda">
      <span><i style="background:var(--cor-aviso)"></i>a confirmar</span>
      <span><i style="background:var(--cor-ok)"></i>confirmada</span>
      <span><i style="background:var(--cor-marca)"></i>realizada</span>
      <span><i style="background:var(--cor-alerta)"></i>faltou</span>
      <span>▦ sala reservada</span>
    </div>
  `;
}

// ------------------------------------------------------------------
// Orçamentos
// ------------------------------------------------------------------
const GRUPO_ORCAMENTO = {
  rascunho: "aberto rascunho",
  apresentado: "aberto",
  aprovado: "aprovado",
  parcial: "aprovado",
  concluido: "aprovado",
  recusado: "perdido",
  expirado: "perdido",
};

export async function telaOrcamentos(sub, pacienteId) {
  // #/orcamentos/novo[/<paciente>]: o formulário só é baixado quando ela abre
  if (sub === "novo" && podeLancar()) return (await import("./orcamento/tela.js")).telaNovoOrcamento(pacienteId);
  const d = await api("orcamentos");
  if (!d) return html`<p class="vazio">Orçamentos ainda não disponíveis.</p>`;
  const r = d.resumo ?? {};
  const lista = d.orcamentos ?? [];
  depoisDeMostrar.push(() => ligarFiltros());
  return html`
    <div class="cabecalho">
      <div>
        <h1>Orçamentos</h1>
        <p>${r.total ?? 0} ${r.total === 1 ? "orçamento" : "orçamentos"}</p>
      </div>
      ${podeLancar() ? html`<a class="botao botao-principal" href="#/orcamentos/novo">+ Novo orçamento</a>` : ""}
    </div>
    <div class="numeros">
      <div class="numero"><b>${dinheiro(r.valor_em_aberto ?? 0)}</b><span>em aberto (${(r.rascunhos ?? 0) +
        (r.apresentados ?? 0)})</span></div>
      <div class="numero"><b>${dinheiro(r.valor_aprovado ?? 0)}</b><span>aprovado (${r.aprovados ?? 0})</span></div>
      <div class="numero"><b>${r.taxa_aprovacao != null
        ? `${r.taxa_aprovacao}%`
        : "—"}</b><span>de aprovação</span></div>
      <div class="numero"><b>${r.rascunhos ?? 0}</b><span>rascunhos</span></div>
    </div>
    <div class="barra-filtros">
      ${filtros([["todos", "Todos"], ["aberto", "Em aberto"], ["rascunho", "Rascunhos"], ["aprovado", "Aprovados"], [
        "perdido",
        "Recusados ou vencidos",
      ]])}
      <input class="busca busca-pequena busca-filtro" type="search" placeholder="Buscar paciente" aria-label="Buscar paciente" autocomplete="off">
    </div>
    <section class="cartao">
      <ul class="lista">${lista.map((o) =>
        html`
          <li data-filtro="${GRUPO_ORCAMENTO[o.situacao] ?? "outro"}" data-busca="${normalizar(
            `${o.paciente} ${o.titulo}`,
          )}">
            <div class="linha">
              <div>
                    <a class="link-paciente" href="#/paciente/${o.paciente_id}/orcamentos">${o.paciente}</a>
                    <div class="suave pequeno">${[
                      o.titulo,
                      o.numero ? `nº ${o.numero}${o.versao > 1 ? ` v${o.versao}` : ""}` : "",
                      o.data ? `emitido ${dataCurta(o.data, true)}` : "",
                      o.validade && ["apresentado", "rascunho"].includes(o.situacao)
                        ? `válido até ${dataCurta(o.validade, true)}`
                        : "",
                      o.aprovado_em ? `aprovado ${dataCurta(o.aprovado_em, true)}` : "",
                    ].filter(Boolean).join(" · ")}</div>
                    ${o.proximo_contato
                      ? html`<div class="pequeno ${o.contato_em_atraso ? "texto-alerta" : "suave"}">Próximo contato: ${
                        dataCurta(o.proximo_contato, true)
                      }</div>`
                      : ""}
                  </div>
              <div
                class="botoes"><span class="etiqueta ${COR_ORCAMENTO[o.situacao] ?? ""}">${o
                  .status}</span><span class="forte">${valorOrcamento(o)}</span>${o.link
                  ? html`<a class="botao" href="${o.link}" target="_blank" rel="noopener">PDF</a>`
                  : ""}</div>
            </div>
          </li>
        `
      )}</ul>
      <p class="vazio filtro-vazio"
        ${lista.length
          ? "hidden"
          : ""}>Nenhum orçamento aqui. Toque em “Novo orçamento” ou peça ao Claude: “monta um orçamento pra Fulana”.</p>
    </section>
  `;
}

// ------------------------------------------------------------------
// Documentos
// ------------------------------------------------------------------
export async function telaDocumentos() {
  const d = await api("documentos");
  if (!d) return html`<p class="vazio">Documentos ainda não disponíveis.</p>`;
  const docs = d.documentos ?? [];
  const tipos = Object.keys(d.por_tipo ?? {}).sort();
  depoisDeMostrar.push(() => ligarFiltros());
  return html`
    <div class="cabecalho">
      <div>
        <h1>Documentos</h1>
        <p>${d.total ?? docs.length} emitidos${docs.length < (d.total ?? 0)
          ? ` · mostrando os ${docs.length} mais recentes`
          : ""}</p>
      </div>
    </div>
    <div class="barra-filtros">
      ${filtros([["todos", "Todos"], ...tipos.map((t) => [t, `${TIPO_DOCUMENTO[t] ?? t} (${d.por_tipo[t]})`])])}
      <input class="busca busca-pequena busca-filtro" type="search" placeholder="Buscar" aria-label="Buscar documento" autocomplete="off">
    </div>
    <section class="cartao">
      <ul class="lista">${docs.map((x) =>
        html`
          <li data-filtro="${x.tipo}" data-busca="${normalizar(`${x.paciente} ${x.titulo}`)}">
            <div class="linha">
              <div>
                <span class="forte">${x.titulo ?? TIPO_DOCUMENTO[x.tipo] ?? x.tipo}</span>
                <div
                  class="suave pequeno"><a class="link-paciente" href="#/paciente/${x.paciente_id}/documentos">${x
                    .paciente}</a> · ${dataCurta(x.data, true)}${x.hora ? ` às ${x.hora}` : ""}</div>
              </div>
              <div class="botoes"><span class="etiqueta">${TIPO_DOCUMENTO[x.tipo] ?? x.tipo}</span>${x.link
                ? html`<a class="botao" href="${x.link}" target="_blank" rel="noopener">Abrir PDF</a>`
                : ""}</div>
            </div>
          </li>
        `
      )}</ul>
      <p class="vazio filtro-vazio"
        ${docs.length
          ? "hidden"
          : ""}>Nenhum documento. Receitas, atestados e termos pedidos ao Claude aparecem aqui.</p>
    </section>
    <div class="grade grade-2" style="margin-top:16px">
      <section class="cartao">
        <h2>Receitas prontas</h2>
        <p class="suave pequeno">Peça ao Claude pelo nome, por exemplo: “receita de amoxicilina pra Fulana”.</p>
        <ul class="lista">${(d.modelos_receita ?? []).map((m) =>
          html`<li><span class="forte">${m.nome}</span>${
            m.antibiotico
              ? html`
                <span class="etiqueta etiqueta-aviso">antibiótico</span>
              `
              : ""
          }${
            m.pediatrico
              ? html`
                <span class="etiqueta etiqueta-info">infantil</span>
              `
              : ""
          }
          ${m.posologia ? html`<div class="suave pequeno">${m.posologia}</div>` : ""}</li>`
        )}</ul>
      </section>
      <section class="cartao">
        <h2>Termos</h2>
        <ul class="lista">${(d.modelos_termo ?? []).map((t) => html`<li>${t.titulo}</li>`)}</ul>
      </section>
    </div>
  `;
}

// ------------------------------------------------------------------
// Preços
// ------------------------------------------------------------------
const GRUPOS = {
  diagnostico: "Diagnóstico",
  prevencao: "Prevenção",
  dentistica: "Dentística",
  endodontia: "Endodontia",
  periodontia: "Periodontia",
  cirurgia: "Cirurgia",
  protese: "Prótese",
  implante: "Implante",
  estetica: "Estética",
  disfuncao: "Disfunção (DTM)",
  outros: "Outros",
};

export async function telaPrecos() {
  const d = await api("precos");
  if (!d) return html`<p class="vazio">Preços ainda não disponíveis.</p>`;
  const procs = d.procedimentos ?? [];
  const grupos = [...new Set(procs.map((p) => p.grupo ?? "outros"))];
  const sobra = (
    v,
  ) => (v == null ? "" : html`<span class="${v < 0 ? "texto-alerta forte" : ""}">${dinheiro(v)}</span>`);
  const ativas = (d.campanhas ?? []).filter((c) => !["cancelada", "encerrada"].includes(c.situacao));
  depoisDeMostrar.push(() => ligarFiltros());
  return html`
    <div class="cabecalho">
      <div>
        <h1>Preços</h1>
        <p>${procs.length} procedimentos · quanto sobra em cada forma de pagamento</p>
      </div>
    </div>
    <div class="barra-filtros">
      ${filtros([
        ["todos", "Todos"],
        ...grupos.map((g) => [normalizar(g).replace(/\s+/g, "_"), GRUPOS[g] ?? g.replaceAll("_", " ")]),
      ])}
      <input class="busca busca-pequena busca-filtro" type="search" placeholder="Buscar procedimento" aria-label="Buscar procedimento" autocomplete="off">
    </div>
    <section class="cartao rolagem-x">
      <table class="tabela tabela-precos">
        <thead>
          <tr>
            <th>Procedimento</th>
            <th class="num">Preço</th>
            <th class="num">Sobra no Pix</th>
            <th class="num col-opcional">Crédito à vista</th>
            <th class="num col-opcional">Crédito 12x</th>
          </tr>
        </thead>
        <tbody>${procs.map((p) =>
          html`
            <tr data-filtro="${normalizar(p.grupo ?? "outros").replace(/\s+/g, "_")}" data-busca="${normalizar(
              `${p.nome} ${p.codigo ?? ""}`,
            )}">
              <td><span class="forte">${p.nome}</span>
                      <div class="suave pequeno">${[
                        p.custo_materiais != null
                          ? `materiais ${dinheiro(p.custo_materiais)}${p.kit ? "" : " (só o básico)"}`
                          : "",
                        p.faixa_mercado ? `mercado: ${p.faixa_mercado}` : "",
                        p.no_site ? "no site" : "",
                      ].filter(Boolean).join(" · ")}</div>
                      ${p.campanhas?.length
                        ? html`<div class="etiquetas">${
                          p.campanhas.map((c) =>
                            html`<span class="etiqueta etiqueta-info">${c.campanha}: ${dinheiro(c.preco)}</span>`
                          )
                        }</div>`
                        : ""}</td>
              <td class="num forte">${p.preco != null
                ? dinheiro(p.preco)
                : html`<span class="suave">a definir</span>`}</td>
              <td class="num">${sobra(p.sobra_pix)}</td>
              <td class="num col-opcional">${sobra(p.sobra_credito_vista)}</td>
              <td class="num col-opcional">${sobra(p.sobra_credito_12x)}</td>
            </tr>
          `
        )}</tbody>
      </table>
      <p class="vazio filtro-vazio" hidden>Nenhum procedimento com esse nome.</p>
      <p
        class="suave pequeno">Sobra = preço − taxa da maquininha − imposto (${String(d.imposto_pct ?? 0).replace(
          ".",
          ",",
        )}%) − materiais (${dinheiro(
          d.custo_base ?? 0,
        )} de material básico por atendimento, mais o kit do procedimento quando houver). Para mudar um preço, fale com o Claude.</p>
    </section>
    <div class="grade grade-2" style="margin-top:16px">
      <section class="cartao"><h2>Campanhas</h2>${ativas.length
        ? ativas.map((c) =>
          html`
            <div
              class="campanha"><div class="linha"><span class="forte">${c
                .nome}</span><span class="etiqueta ${c.situacao === "em_andamento"
                ? "etiqueta-ok"
                : "etiqueta-info"}">${String(c.situacao ?? "").replaceAll("_", " ")}</span></div>
                      <div class="suave pequeno">${[c.periodo, c.local, c.cidade].filter(Boolean).join(" · ")}</div>
                      ${c.precos?.length
                        ? html`<ul class="lista pequeno">${
                          c.precos.map((x) =>
                            html`
                              <li>
                                <div class="linha"><span>${x.procedimento}</span><span>${dinheiro(
                                  x.preco_campanha,
                                )}${x.preco_normal
                                  ? html`
                                    <span class="suave">(normal ${dinheiro(x.preco_normal)})</span>
                                  `
                                  : ""}</span></div>
                              </li>
                            `
                          )
                        }</ul>`
                        : ""}</div>
          `
        )
        : html`<p class="vazio">Nenhuma campanha ativa ou marcada.</p>`}</section>
      <section class="cartao">
        <h2>Taxas da maquininha</h2>
        <table class="tabela">
          <tbody>${(d.formas ?? []).map((f) =>
            html`
              <tr>
                <td>${f.forma}</td>
                <td class="num">${String(f.percentual ?? 0).replace(".", ",")}%</td>
              </tr>
            `
          )}</tbody>
        </table>
      </section>
    </div>
  `;
}

// ------------------------------------------------------------------
// Atividade
// ------------------------------------------------------------------
const FERRAMENTAS = {
  acesso_calendario: "Calendário do iPhone",
  acesso_ipad: "Link do site",
  agendar_consulta: "Agendou consulta",
  alterar_consulta: "Mudou consulta",
  alterar_orcamento: "Mudou orçamento",
  atualizar_paciente: "Atualizou paciente",
  buscar_paciente: "Buscou paciente",
  cadastrar_paciente: "Cadastrou paciente",
  calcular_preco: "Calculou preço",
  configurar_financeiro: "Ajustou financeiro",
  confirmar_ficha_online: "Revisou ficha online",
  emitir_atestado: "Emitiu atestado",
  emitir_receita: "Emitiu receita",
  emitir_termo: "Emitiu termo",
  ficha_online: "Ficha online",
  gerar_pacote_contador: "Pacote do contador",
  listar_procedimentos: "Consultou procedimentos",
  marcar_recibos: "Marcou recibos",
  montar_orcamento: "Montou orçamento",
  movimentar_estoque: "Estoque",
  registrar_anamnese: "Anamnese",
  registrar_atendimento: "Atendimento",
  registrar_compra: "Compra de material",
  registrar_despesa: "Despesa",
  registrar_odontograma: "Odontograma",
  registrar_pagamento: "Pagamento",
  reservar_sala: "Reserva de sala",
  salvar_campanha: "Campanha",
  salvar_material: "Cadastro de material",
  salvar_procedimento: "Procedimento",
  ver_agenda: "Consultou agenda",
  ver_campanhas: "Consultou campanhas",
  ver_documentos: "Consultou documentos",
  ver_estoque: "Consultou estoque",
  ver_ficha_online: "Consultou ficha online",
  ver_financeiro: "Consultou financeiro",
};

function itemAtividade(x) {
  return html`
    <li class="atividade ${x.ok === false ? "falhou" : ""}">
      <div class="atividade-hora">${x.hora}</div>
      <div>
          <div class="linha"><span class="forte">${FERRAMENTAS[x.ferramenta] ??
            x.ferramenta.replaceAll("_", " ")}</span>
            <span class="etiquetas">${x.pelo_site
              ? html`<span class="etiqueta etiqueta-info">pelo site</span>`
              : ""}${x.ok === false
              ? html`<span class="etiqueta etiqueta-alerta">não gravou</span>`
              : x.mudancas
              ? html`<span class="etiqueta etiqueta-ok">${x.mudancas} ${
                x.mudancas === 1 ? "alteração" : "alterações"
              }</span>`
              : ""}</span></div>
          ${x.texto ? html`<p class="atividade-texto">“${x.texto}”</p>` : ""}
          ${x.ok === false && x.erro ? html`<p class="pequeno texto-alerta">${x.erro}</p>` : ""}
          ${x.pacientes?.length
            ? html`<div class="pequeno">${
              x.pacientes.map((p, i) =>
                html`${i ? ", " : ""}<a class="link-paciente" href="#/paciente/${p.id}">${p.nome}</a>`
              )
            }</div>`
            : ""}
        </div>
    </li>
  `;
}

function blocosPorDia(itens, ultimoDia = "") {
  const saida = [];
  let dia = ultimoDia, grupo = [];
  const fechar = () =>
    grupo.length && saida.push(html`
      <section class="cartao">
        <h2>${dataLonga(dia)}</h2>
        <ul class="lista">${grupo}</ul>
      </section>
    `);
  for (const x of itens) {
    if (x.data !== dia) {
      fechar();
      dia = x.data;
      grupo = [];
    }
    grupo.push(itemAtividade(x));
  }
  fechar();
  return saida;
}

let soMudancas = true;
export async function telaAtividade() {
  const d = await api("atividade", { so_mudancas: soMudancas });
  if (!d) return html`<p class="vazio">Atividade ainda não disponível.</p>`;
  let itens = d.itens ?? [];
  depoisDeMostrar.push(() => {
    document.getElementById("so-mudancas")?.addEventListener("change", (e) => {
      soMudancas = e.target.checked;
      dispatchEvent(new HashChangeEvent("hashchange"));
    });
    const mais = document.getElementById("ver-mais");
    mais?.addEventListener("click", async () => {
      mais.disabled = true;
      mais.textContent = "Carregando…";
      try {
        const m = await api("atividade", { so_mudancas: soMudancas, antes: itens.at(-1)?.em });
        const novos = m?.itens ?? [];
        document.getElementById("lista-atividade").insertAdjacentHTML("beforeend", String(blocosPorDia(novos)));
        itens = itens.concat(novos);
        mais.hidden = novos.length < 80;
      } catch (e) {
        avisar(e.message, "erro");
      } finally {
        mais.disabled = false;
        mais.textContent = "Ver mais antigos";
      }
    });
  });
  return html`
    <div
      class="cabecalho"><div><h1>Atividade</h1><p>Tudo o que foi pedido ao Claude ou lançado pelo site (${d.total ??
        0} pedidos)</p></div>
      <label class="interruptor"><input type="checkbox" id="so-mudancas" ${soMudancas
        ? "checked"
        : ""}> Só o que gravou algo</label></div>
    <div id="lista-atividade">${itens.length ? blocosPorDia(itens) : html`
      <section class="cartao">
        <p class="vazio">Nada por aqui ainda.</p>
      </section>
    `}</div>
    <div class="botoes"
      style="margin-top:16px;justify-content:center"><button type="button" class="botao" id="ver-mais" ${itens.length <
          80
        ? "hidden"
        : ""}>Ver mais antigos</button></div>
    <p
      class="suave pequeno">Nada se apaga: correções entram como um registro novo, e cada alteração fica guardada com o antes e o depois.</p>
  `;
}

// ------------------------------------------------------------------
// Ajustes
// ------------------------------------------------------------------
const quando = (ts) => {
  if (!ts) return "";
  const d = new Date(ts);
  return `${dataCurta(paraISO(d), true)} às ${String(d.getHours()).padStart(2, "0")}:${
    String(d.getMinutes()).padStart(2, "0")
  }`;
};
const ACAO_LOG = {
  inicio: "Início",
  agenda: "Agenda",
  pacientes: "Pacientes",
  paciente: "Ficha de paciente",
  orcamentos: "Orçamentos",
  documentos: "Documentos",
  estoque: "Estoque",
  financeiro: "Financeiro",
  precos: "Preços",
  atividade: "Atividade",
  configuracoes: "Ajustes",
};

export async function telaAjustes() {
  const d = await api("configuracoes");
  if (!d) return html`<p class="vazio">Ajustes ainda não disponíveis.</p>`;
  const c = d.consultorio ?? {}, f = d.financeiro ?? {}, conta = d.conta ?? {};
  const tema = window.temaDoSite?.escolha() ?? "automatico";
  depoisDeMostrar.push(() => {
    document.querySelectorAll("input[name=tema]").forEach((r) =>
      r.addEventListener("change", () => window.temaDoSite?.trocar(r.value))
    );
    document.getElementById("sair")?.addEventListener("click", async () => {
      await sair(false);
      location.hash = "#/hoje";
      dispatchEvent(new HashChangeEvent("hashchange"));
    });
    document.getElementById("sair-todos")?.addEventListener("click", async (e) => {
      const b = e.currentTarget;
      if (b.dataset.confirmar !== "1") {
        b.dataset.confirmar = "1";
        b.textContent = "Toque de novo para confirmar";
        return;
      }
      await sair(true);
      location.hash = "#/hoje";
      dispatchEvent(new HashChangeEvent("hashchange"));
    });
  });
  const regime = { pf: "Pessoa física (Receita Saúde)", pj: "Pessoa jurídica (nota pelo contador)" };
  const contas = d.contas ?? [];
  const variasContas = contas.length > 1;
  const nomeConta = (x) => (x.da_dra || x.pessoa === "Dra." ? c.dentista_nome ?? "Dra." : x.pessoa);
  return html`
    <div class="cabecalho">
      <div>
        <h1>Ajustes</h1>
        <p>Para mudar um dado do consultório, fale com o Claude.</p>
      </div>
    </div>
    <div class="grade grade-2">
      <div>
        <section class="cartao">
          <h2>Consultório</h2>
          <dl class="dados">
          ${campo("Nome", c.nome_consultorio)}
          ${campo("Profissional", c.dentista_nome)}
          ${campo("CRO", c.cro)}
          ${campo("Especialidade", c.especialidade)}
          ${campo("Endereço", [c.endereco, c.cidade, c.uf].filter(Boolean).join(", "))}
          ${campo("Telefone", c.telefone ? telefone(c.telefone) : null)}
          ${campo("E-mail", c.email)}
          ${campo("Instagram", c.instagram)}
          ${campo("Site", c.site)}
        </dl>
        </section>
        <section class="cartao"><h2>Financeiro</h2><dl class="dados">
          ${campo("Hoje", regime[f.regime_hoje] ?? f.regime_hoje)}
          ${campo("Pessoa jurídica a partir de", f.pj_a_partir_de ? dataCurta(f.pj_a_partir_de, true) : null)}
          ${campo("CPF nos recibos", f.cpf_profissional)}
          ${campo("CNPJ", f.cnpj)}
          ${campo("Registro profissional", f.registro_profissional)}
          ${campo(
            "Imposto estimado",
            f.imposto_percentual != null ? `${String(f.imposto_percentual).replace(".", ",")}%` : null,
          )}
        </dl>
        ${f.pendencias?.length
          ? html`<div class="aviso-faixa cartao" style="margin:14px 0 0"><strong>Falta:</strong><ul>${
            f.pendencias.map((p) => html`<li>${p}</li>`)
          }</ul></div>`
          : ""}
        </section>
        <section
          class="cartao"><h2>Acessos ativos</h2>${d.acessos?.length
            ? html`<ul class="lista">${
              d.acessos.map((a) =>
                html`<li><span class="forte">${a.tipo}</span>${
                  a.descricao && a.descricao !== a.tipo
                    ? html`
                      <span class="suave">· ${a.descricao}</span>
                    `
                    : ""
                }
          <div class="suave pequeno">criado ${quando(a.criado_em)}${
                  a.ultimo_uso ? ` · último uso ${quando(a.ultimo_uso)}` : ""
                }</div></li>`
              )
            }</ul>`
            : html`<p class="vazio">Nenhum.</p>`}<p class="suave pequeno">Para tirar um acesso, peça ao Claude (por exemplo: “revoga o acesso do calendário”).</p></section>
      </div>
      <div>
        <section class="cartao">
          <h2>Aparência</h2>
          <div class="escolhas-linha" role="radiogroup" aria-label="Aparência">
            ${[["automatico", "Automática"], ["claro", "Clara"], ["escuro", "Escura"]].map(([v, r]) =>
              html`<label class="escolha-chip"><input type="radio" name="tema" value="${v}" ${
                tema === v ? "checked" : ""
              }> ${r}</label>`
            )}
          </div>
          <p class="suave pequeno">Automática segue o modo claro ou escuro do aparelho.</p>
        </section>
        <section class="cartao">
          <h2>Sua conta</h2>
          <dl class="dados">
          ${variasContas ? campo("Quem", conta.pessoa ?? c.dentista_nome) : ""}
          ${campo("E-mail", conta.email)}
          ${campo("Senha criada em", conta.senha_definida_em ? quando(conta.senha_definida_em) : null)}
          ${campo(
            "Aparelhos conectados",
            conta.aparelhos_conectados != null ? String(conta.aparelhos_conectados) : null,
          )}
        </dl>
          <div class="botoes" style="margin-top:14px">
            <button type="button" class="botao" id="sair">Sair deste aparelho</button>
            <button type="button" class="botao" id="sair-todos">Sair de todos os aparelhos</button>
          </div>
          <p class="suave pequeno">Esqueceu a senha ou trocou de celular? Peça ao Claude: “me manda o link do site”.</p>
        </section>
        ${variasContas
          ? html`
            <section class="cartao">
              <h2>Quem entra no site</h2>
              <ul class="lista">${contas.map((x) =>
                html`
                  <li>
                    <div class="linha"><span class="forte">${nomeConta(
                      x,
                    )}</span><span class="suave pequeno">${x.aparelhos_conectados === 1
                      ? "1 aparelho"
                      : `${x.aparelhos_conectados ?? 0} aparelhos`}</span></div>
                    <div class="suave pequeno">${x.email}${x.ultimo_acesso
                      ? ` · último acesso ${quando(x.ultimo_acesso)}`
                      : " · ainda não entrou"}</div>
                  </li>
                `
              )}</ul>
              <p
                class="suave pequeno">Cada conta tem a própria senha e o próprio código. Para tirar alguém, peça ao Claude (por exemplo: “tira o acesso do ${nomeConta(
                  contas.find((x) => !x.da_dra) ?? {},
                ) ?? "fulano"} ao site”).</p>
            </section>
          `
          : ""}
        <section
          class="cartao"><h2>Últimos acessos ao site</h2>${d.ultimos_acessos_site?.length
            ? html`<ul class="lista pequeno">${
              d.ultimos_acessos_site.map((l) =>
                html`
                  <li>
                    <div class="linha"><span>${ACAO_LOG[l.acao] ?? (l.acao.startsWith("gravar:")
                      ? `Lançamento (${l.acao.slice(7).replaceAll("_", " ")})`
                      : l.acao)}${variasContas && l.quem
                      ? html`
                        <span class="suave">· ${l.quem === "Dra." ? "Dra." : l.quem}</span>
                      `
                      : ""}</span><span class="suave">${quando(l.em)}</span></div>
                  </li>
                `
              )
            }</ul>`
            : html`<p class="vazio">Nenhum.</p>`}<p class="suave pequeno">Cada abertura de ficha fica registrada, como pede o prontuário eletrônico.</p></section>
      </div>
    </div>
  `;
}
