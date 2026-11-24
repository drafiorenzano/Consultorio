// Lançar pelo site: recebimento, despesa, movimento de estoque e estornos.
// Tudo passa pelas mesmas funções que o Claude usa (mesmas regras, mesmo
// registro na Atividade); o site só monta o pedido. Nada se apaga: erro se
// corrige com estorno.

import { abrirJanela, api, avisar, fecharJanela, gravar } from "./nucleo.js";
import { dataCurta, dinheiro, hojeISO, html, normalizar } from "./base.js";

export const FORMAS = [
  ["pix", "Pix"],
  ["dinheiro", "Dinheiro"],
  ["debito", "Débito"],
  ["credito_vista", "Crédito à vista"],
  ["credito_parcelado", "Crédito parcelado"],
  ["transferencia", "Transferência"],
  ["boleto", "Boleto"],
];
export const CATEGORIAS = [
  ["materiais", "Materiais"],
  ["laboratorio", "Laboratório"],
  ["aluguel_sala", "Aluguel de sala"],
  ["contador", "Contador"],
  ["cro", "CRO"],
  ["inss", "INSS"],
  ["impostos", "Impostos (DAS/DARF)"],
  ["iss", "ISS"],
  ["seguro", "Seguro"],
  ["software", "Software"],
  ["manutencao", "Manutenção"],
  ["marketing", "Marketing"],
  ["outros", "Outros"],
];
const TIPOS_ESTOQUE = [
  ["uso", "Usei (fora de atendimento)", "Gasto que não veio de um atendimento registrado."],
  ["perda", "Perdi ou estragou", "Caiu, contaminou, quebrou."],
  ["vencido", "Venceu (descarte)", "Jogou fora pela validade."],
  ["contagem", "Contei a prateleira", "Quanto tem agora. O sistema lança a diferença; 0 se acabou."],
  ["entrada", "Chegou sem compra", "Amostra, doação, sobra que voltou."],
];

/** "1.234,56", "1234,56" ou "1234.56" em número (ou null). */
export function lerValor(texto) {
  let t = String(texto ?? "").replace(/[R$\s]/g, "");
  if (!t) return null;
  if (t.includes(",")) t = t.replace(/\./g, "").replace(",", ".");
  else if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, "");
  const n = Number(t);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) / 100 : null;
}

const opcoes = (lista, escolhida) =>
  lista.map(([v, r]) => html`<option value="${v}" ${v === escolhida ? "selected" : ""}>${r}</option>`);

function rodape(rotulo) {
  return html`
    <div class="botoes janela-rodape">
      <button type="button" class="botao" data-fechar>Cancelar</button>
      <button type="submit" class="botao botao-principal" form="form-lancar">${rotulo}</button>
    </div>
  `;
}

function mostrarErro(janela, texto) {
  const caixa = janela.querySelector(".form-erro");
  caixa.textContent = texto;
  caixa.hidden = !texto;
  if (texto) caixa.scrollIntoView({ block: "nearest" });
}

/** Envia, trata "parece repetido" e mostra o resultado. */
async function enviar(janela, tipo, dados, { sucesso, repetido, confirmar, depois }) {
  const botao = janela.querySelector("button[type=submit]") ??
    document.querySelector(".janela-rodape button[type=submit]");
  const rotulo = botao?.textContent;
  if (botao) {
    botao.disabled = true;
    botao.textContent = "Lançando…";
  }
  mostrarErro(janela, "");
  try {
    const r = await gravar(tipo, dados);
    if (r?.status === "confirmacao_necessaria") {
      const caixa = janela.querySelector(".form-repetido");
      caixa.hidden = false;
      caixa.innerHTML = String(html`
        <p><strong>${repetido}</strong> Se for outro, lance mesmo assim.</p>
        <button type="button" class="botao" data-confirmar>É outro: lançar mesmo assim</button>
      `);
      caixa.querySelector("[data-confirmar]").addEventListener("click", () => {
        caixa.hidden = true;
        enviar(janela, tipo, { ...dados, [confirmar]: true }, { sucesso, repetido, confirmar, depois });
      });
      caixa.scrollIntoView({ block: "nearest" });
      return;
    }
    fecharJanela();
    const avisos = (r?.avisos ?? []).filter(Boolean);
    if (avisos.length) {
      abrirJanela(
        html`
          <h2>${sucesso(r)}</h2>
          <ul class="lista-avisos">${avisos.map((a) => html`<li>${a}</li>`)}</ul>
        `,
        { titulo: "Lançado" },
      );
    } else avisar(sucesso(r));
    depois?.();
  } catch (e) {
    mostrarErro(janela, e.message);
  } finally {
    if (botao?.isConnected) {
      botao.disabled = false;
      botao.textContent = rotulo;
    }
  }
}

const caixasFinais = html`
  <div class="form-repetido aviso-faixa" hidden></div>
  <p class="form-erro erro-caixa pequeno" hidden></p>
`;

// ------------------------------------------------------------------
// Escolher paciente (busca por nome)
// ------------------------------------------------------------------
function campoPaciente(paciente, obrigatorio = true) {
  if (paciente?.id) {
    return html`<div class="campo"><span class="rotulo">Paciente</span><div class="forte">${paciente.nome}</div>
      <input type="hidden" name="paciente_id" value="${paciente.id}"></div>`;
  }
  return html`<div class="campo campo-paciente"><label for="busca-paciente">Paciente${
    obrigatorio ? "" : " (opcional)"
  }</label>
    <input id="busca-paciente" class="busca" type="search" placeholder="Digite o nome" autocomplete="off" ${
    obrigatorio ? "autofocus" : ""
  }>
    <input type="hidden" name="paciente_id">
    <div class="escolhido" hidden></div>
    <ul class="sugestoes" role="listbox"></ul></div>`;
}

function ligarPaciente(janela) {
  const busca = janela.querySelector("#busca-paciente");
  if (!busca) return;
  const oculto = janela.querySelector("input[name=paciente_id]");
  const lista = janela.querySelector(".sugestoes");
  const escolhido = janela.querySelector(".escolhido");
  let espera, vez = 0;
  busca.addEventListener("input", () => {
    clearTimeout(espera);
    oculto.value = "";
    const q = busca.value.trim();
    if (q.length < 2) return (lista.innerHTML = "");
    espera = setTimeout(async () => {
      const minha = ++vez;
      try {
        const achados = (await api("pacientes", { busca: q })) ?? [];
        if (minha !== vez) return;
        lista.innerHTML = String(
          achados.length
            ? achados.slice(0, 6).map((p) =>
              html`<li><button type="button" class="sugestao" data-id="${p.id}" data-nome="${p.nome}">${p.nome}${
                p.apelido
                  ? html`
                    <span class="suave">(${p.apelido})</span>
                  `
                  : ""
              }<span class="suave pequeno"> · ficha ${p.ficha}</span></button></li>`
            )
            : html`<li class="suave pequeno">Ninguém com esse nome.</li>`,
        );
      } catch (_) {
        lista.innerHTML = "";
      }
    }, 250);
  });
  lista.addEventListener("click", (e) => {
    const b = e.target.closest(".sugestao");
    if (!b) return;
    oculto.value = b.dataset.id;
    escolhido.hidden = false;
    escolhido.innerHTML = String(
      html`<span class="forte">${b.dataset.nome}</span> <button type="button" class="botao-link pequeno">trocar</button>`,
    );
    busca.hidden = true;
    lista.innerHTML = "";
    escolhido.querySelector("button").addEventListener("click", () => {
      oculto.value = "";
      escolhido.hidden = true;
      busca.hidden = false;
      busca.value = "";
      busca.focus();
    });
  });
}

const nomeEscolhido = (janela, paciente) =>
  paciente?.nome ?? janela.querySelector(".escolhido .forte")?.textContent ?? "";

// ------------------------------------------------------------------
// Recebimento
// ------------------------------------------------------------------
export function lancarRecebimento({ paciente, depois } = {}) {
  const janela = abrirJanela(
    html`
      <h2>Lançar recebimento</h2>
      <form id="form-lancar" class="formulario" novalidate>
            ${campoPaciente(paciente)}
            <div class="campos-2">
              <div class="campo"><label for="valor">Valor (R$)</label>
                <input id="valor" name="valor" class="busca" inputmode="decimal" placeholder="0,00" autocomplete="off" required ${paciente
                  ? "autofocus"
                  : ""}></div>
              <div class="campo"><label for="data">Data</label>
                <input id="data" name="data" class="busca" type="date" value="${hojeISO()}" max="${hojeISO()}" required></div>
            </div>
            <div class="campos-2">
              <div class="campo"><label for="forma">Forma</label>
                <select id="forma" name="forma" class="busca">${opcoes(FORMAS, "pix")}</select></div>
              <div class="campo" id="campo-parcelas" hidden><label for="parcelas">Em quantas vezes</label>
                <input id="parcelas" name="parcelas_cartao" class="busca" type="number" min="2" max="24" value="2"></div>
            </div>
            <div class="campo"><label for="descricao">Do que é (vai no recibo)</label>
              <input id="descricao" name="descricao" class="busca" placeholder="Ex.: restauração do 36" maxlength="200"></div>
            <p class="suave pequeno">Quita as parcelas em aberto do paciente, da mais antiga para a mais nova. O recibo do Receita Saúde fica pendente, como quando você fala com o Claude.</p>
            ${caixasFinais}
          </form>
    `,
    { rodape: rodape("Lançar"), titulo: "Lançar recebimento" },
  );
  ligarPaciente(janela);
  const forma = janela.querySelector("#forma");
  forma.addEventListener(
    "change",
    () => (janela.querySelector("#campo-parcelas").hidden = forma.value !== "credito_parcelado"),
  );
  janela.querySelector("#form-lancar").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const f = new FormData(ev.target);
    const valor = lerValor(f.get("valor"));
    if (!f.get("paciente_id")) return mostrarErro(janela, "Escolha o paciente.");
    if (!valor) return mostrarErro(janela, "Digite o valor, por exemplo 350,00.");
    const dados = {
      paciente_id: f.get("paciente_id"),
      valor,
      forma: f.get("forma"),
      data: f.get("data") || hojeISO(),
      descricao: f.get("descricao")?.trim() || null,
    };
    if (dados.forma === "credito_parcelado") dados.parcelas_cartao = Number(f.get("parcelas_cartao")) || 2;
    const rotulo = FORMAS.find(([v]) => v === dados.forma)?.[1] ?? dados.forma;
    dados.texto_original = `Pelo site: recebimento de ${dinheiro(valor)} (${rotulo}${
      dados.parcelas_cartao ? ` em ${dados.parcelas_cartao}x` : ""
    }) de ${nomeEscolhido(janela, paciente)} em ${dataCurta(dados.data, true)}${
      dados.descricao ? `: ${dados.descricao}` : ""
    }`;
    enviar(janela, "pagamento", dados, {
      sucesso: () => `Recebimento de ${dinheiro(valor)} lançado.`,
      repetido: "Já existe um pagamento igual deste paciente nesta data.",
      confirmar: "confirmar_duplicado",
      depois,
    });
  });
}

// ------------------------------------------------------------------
// Despesa
// ------------------------------------------------------------------
export function lancarDespesa({ depois } = {}) {
  const janela = abrirJanela(
    html`
      <h2>Lançar despesa</h2>
      <form id="form-lancar" class="formulario" novalidate>
            <div class="campos-2">
              <div class="campo"><label for="valor">Valor (R$)</label>
                <input id="valor" name="valor" class="busca" inputmode="decimal" placeholder="0,00" autocomplete="off" required autofocus></div>
              <div class="campo"><label for="data">Data do pagamento</label>
                <input id="data" name="data" class="busca" type="date" value="${hojeISO()}" max="${hojeISO()}" required></div>
            </div>
            <div class="campo"><label for="categoria">Categoria</label>
              <select id="categoria" name="categoria" class="busca">${opcoes(CATEGORIAS, "materiais")}</select></div>
            <div id="lab-paciente" hidden>${campoPaciente(null, false)}</div>
            <div class="campo"><label for="descricao">Descrição</label>
              <input id="descricao" name="descricao" class="busca" placeholder="Ex.: anuidade do CRO" maxlength="200"></div>
            <div class="campos-2">
              <div class="campo"><label for="fornecedor">Pago a (opcional)</label>
                <input id="fornecedor" name="fornecedor" class="busca" maxlength="120"></div>
              <div class="campo"><label for="forma">Forma (opcional)</label>
                <select id="forma" name="forma" class="busca"><option value="">—</option>${opcoes(
                  FORMAS,
                  "",
                )}</select></div>
            </div>
            <details class="pequeno"><summary>Refere-se a outro mês?</summary>
              <div class="campo"><label for="competencia">Mês da despesa</label>
                <input id="competencia" name="competencia" class="busca" type="month"></div>
            </details>
            <p class="suave pequeno">Reserva de sala e compra de material entram sozinhas pela agenda e pelo estoque: não precisa lançar aqui.</p>
            ${caixasFinais}
          </form>
    `,
    { rodape: rodape("Lançar"), titulo: "Lançar despesa" },
  );
  ligarPaciente(janela);
  const cat = janela.querySelector("#categoria");
  cat.addEventListener("change", () => (janela.querySelector("#lab-paciente").hidden = cat.value !== "laboratorio"));
  janela.querySelector("#form-lancar").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const f = new FormData(ev.target);
    const valor = lerValor(f.get("valor"));
    if (!valor) return mostrarErro(janela, "Digite o valor, por exemplo 120,00.");
    const dados = {
      valor,
      categoria: f.get("categoria"),
      data: f.get("data") || hojeISO(),
      descricao: f.get("descricao")?.trim() || null,
      fornecedor: f.get("fornecedor")?.trim() || null,
      forma: f.get("forma") || null,
      competencia: f.get("competencia") || null,
      paciente_id: f.get("categoria") === "laboratorio" ? f.get("paciente_id") || null : null,
    };
    const rotulo = CATEGORIAS.find(([v]) => v === dados.categoria)?.[1];
    dados.texto_original = `Pelo site: despesa de ${dinheiro(valor)} (${rotulo}) em ${dataCurta(dados.data, true)}${
      dados.descricao ? `: ${dados.descricao}` : ""
    }${dados.fornecedor ? `, pago a ${dados.fornecedor}` : ""}`;
    enviar(janela, "despesa", dados, {
      sucesso: () => `Despesa de ${dinheiro(valor)} lançada.`,
      repetido: "Já existe uma despesa igual (mesma categoria e valor) em data próxima.",
      confirmar: "confirmar_duplicada",
      depois,
    });
  });
}

// ------------------------------------------------------------------
// Estoque (um material por vez)
// ------------------------------------------------------------------
export function lancarEstoque({ materiais = [], material, depois } = {}) {
  const porNome = new Map(materiais.map((m) => [m.nome, m]));
  const unidades = (m) => [...new Set([m?.unidade_uso, m?.unidade_compra].filter(Boolean))];
  const janela = abrirJanela(
    html`
      <h2>Ajustar estoque</h2>
      <form id="form-lancar" class="formulario" novalidate>
            <fieldset class="campo escolhas"><legend>O que aconteceu</legend>
              ${TIPOS_ESTOQUE.map(([v, r, d], i) =>
                html`
                  <label
                    class="escolha"><input type="radio" name="tipo" value="${v}" ${i === 0
                      ? "checked"
                      : ""}><span><span class="forte">${r}</span><span class="suave pequeno">${d}</span></span></label>
                `
              )}
            </fieldset>
            <div class="campo"><label for="material">Material</label>
              <input id="material" name="material" class="busca" list="lista-materiais" value="${material ??
                ""}" autocomplete="off" placeholder="Digite para procurar" required>
              <datalist id="lista-materiais">${materiais.map((m) =>
                html`<option value="${m.nome}"></option>`
              )}</datalist></div>
            <div class="campos-2">
              <div class="campo"><label for="quantidade">Quantidade</label>
                <input id="quantidade" name="quantidade" class="busca" inputmode="decimal" autocomplete="off" required></div>
              <div class="campo"><label for="unidade">Unidade</label>
                <select id="unidade" name="unidade" class="busca"></select></div>
            </div>
            <div class="campos-2">
              <div class="campo"><label for="data">Data</label>
                <input id="data" name="data" class="busca" type="date" value="${hojeISO()}" max="${hojeISO()}"></div>
              <div class="campo" id="campo-preco" hidden><label for="preco">Preço de cada (opcional)</label>
                <input id="preco" name="preco_unitario" class="busca" inputmode="decimal" placeholder="0,00"></div>
            </div>
            <div class="campo"><label for="motivo">Observação (opcional)</label>
              <input id="motivo" name="motivo" class="busca" maxlength="200"></div>
            ${caixasFinais}
          </form>
    `,
    { rodape: rodape("Lançar"), titulo: "Ajustar estoque" },
  );
  const campoMaterial = janela.querySelector("#material");
  const seletor = janela.querySelector("#unidade");
  const atualizarUnidades = () => {
    const m = porNome.get(campoMaterial.value) ??
      materiais.find((x) => normalizar(x.nome) === normalizar(campoMaterial.value));
    const us = unidades(m);
    seletor.innerHTML = String(
      us.length ? us.map((u) => html`<option>${u}</option>`) : html`<option value="">—</option>`,
    );
  };
  campoMaterial.addEventListener("input", atualizarUnidades);
  atualizarUnidades();
  janela.querySelectorAll("input[name=tipo]").forEach((r) =>
    r.addEventListener("change", () => {
      const t = janela.querySelector("input[name=tipo]:checked").value;
      janela.querySelector("#campo-preco").hidden = !["entrada", "contagem"].includes(t);
      janela.querySelector("label[for=quantidade]").textContent = t === "contagem" ? "Quanto tem agora" : "Quantidade";
    })
  );
  janela.querySelector("#form-lancar").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const f = new FormData(ev.target);
    const tipo = f.get("tipo");
    const qtd = Number(String(f.get("quantidade") ?? "").replace(",", "."));
    if (!String(f.get("material") ?? "").trim()) return mostrarErro(janela, "Escolha o material.");
    if (
      !Number.isFinite(qtd) || qtd < 0 || (qtd === 0 && tipo !== "contagem") ||
      String(f.get("quantidade")).trim() === ""
    ) {
      return mostrarErro(
        janela,
        tipo === "contagem" ? "Digite quanto tem agora (0 se acabou)." : "Digite a quantidade.",
      );
    }
    const dados = {
      tipo,
      material: String(f.get("material")).trim(),
      quantidade: qtd,
      unidade: f.get("unidade") || null,
      data: f.get("data") || hojeISO(),
      motivo: f.get("motivo")?.trim() || null,
      preco_unitario: ["entrada", "contagem"].includes(tipo) ? lerValor(f.get("preco_unitario")) : null,
    };
    const rotulo = TIPOS_ESTOQUE.find(([v]) => v === tipo)?.[1].toLowerCase();
    dados.texto_original = `Pelo site: estoque, ${rotulo}: ${String(qtd).replace(".", ",")} ${
      dados.unidade ?? ""
    } de ${dados.material} em ${dataCurta(dados.data, true)}${dados.motivo ? ` (${dados.motivo})` : ""}`;
    enviar(janela, "estoque", dados, {
      sucesso: (r) => {
        const m = r?.movimentos?.[0];
        return m ? `${m.material}: agora tem ${m.saldo}.` : "Estoque atualizado.";
      },
      repetido: "Parece repetido.",
      confirmar: "confirmar",
      depois,
    });
  });
}

// ------------------------------------------------------------------
// Estornos (com motivo)
// ------------------------------------------------------------------
export function estornar({ tipo, id, descricao, depois }) {
  const recebimento = tipo === "recebimento";
  const janela = abrirJanela(
    html`
      <h2>Estornar ${recebimento ? "recebimento" : "despesa"}</h2>
      <form id="form-lancar" class="formulario" novalidate>
            <p>${descricao}</p>
            <p class="suave pequeno">Nada se apaga: o estorno fica registrado ao lado do lançamento original e os totais voltam ao que eram.${recebimento
              ? " Se o recibo já foi emitido no Receita Saúde, ele aparece em “recibos para cancelar”."
              : ""}</p>
            <div class="campo"><label for="motivo">Motivo</label>
              <input id="motivo" name="motivo" class="busca" minlength="3" maxlength="200" placeholder="Ex.: lancei em dobro" required autofocus></div>
            ${caixasFinais}
          </form>
    `,
    { rodape: rodape("Estornar"), titulo: "Estornar" },
  );
  janela.querySelector("#form-lancar").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const motivo = new FormData(ev.target).get("motivo")?.trim() ?? "";
    if (motivo.length < 3) return mostrarErro(janela, "Diga o motivo do estorno.");
    const dados = recebimento ? { recebimento_id: id, motivo } : { despesa_id: id, motivo };
    dados.texto_original = `Pelo site: estornar ${recebimento ? "recebimento" : "despesa"} (${descricao}): ${motivo}`;
    enviar(janela, recebimento ? "estornar_pagamento" : "estornar_despesa", dados, {
      sucesso: () => "Estorno lançado.",
      repetido: "",
      confirmar: "confirmar",
      depois,
    });
  });
}

/** Escolher o que lançar (atalho do menu). */
export function escolherLancamento(acoes) {
  const janela = abrirJanela(
    html`
      <h2>Lançar</h2>
      <div class="escolha-lancar">
        <button type="button" class="botao largo" data-l="recebimento">Recebimento de paciente</button>
        <button type="button" class="botao largo" data-l="despesa">Despesa</button>
        <button type="button" class="botao largo" data-l="estoque">Ajustar estoque</button>
      </div>
      <p class="suave pequeno">Ou fale com o Claude, como sempre: os dois caminhos gravam no mesmo lugar.</p>
    `,
    { titulo: "Lançar" },
  );
  janela.querySelectorAll("[data-l]").forEach((b) => b.addEventListener("click", () => acoes[b.dataset.l]()));
}
