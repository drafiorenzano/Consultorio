// Novo orçamento pelo site: o mesmo formulário do gerador que a Dra. usava no
// site público (paciente, procedimentos da tabela de preços, desconto,
// parcelas, observações), com a prévia do documento ao lado. Ao salvar, o
// orçamento é montado no banco pela mesma função do Claude (mcp_montar_orcamento:
// número, versão, preços de campanha, auditoria) e o PDF é desenhado a partir do
// que ficou gravado, guardado na ficha do paciente e oferecido para baixar ou
// mandar pelo WhatsApp.

import { abrirJanela, api, avisar, conteudo, depoisDeMostrar, fecharJanela, gravar } from "../nucleo.js";
import { dinheiro, html } from "../base.js";
import { campoPaciente, ligarPaciente } from "../lancar.js";
import {
  agrupar,
  avisosParaTela,
  campanhaInicial,
  lerNumero,
  montarPedido,
  planoDaTela,
  planoDoOrcamento,
  precoDe,
  valorNoCampo,
} from "./dados.js";
import { calcular, gerarPlanoTratamento, nomeArquivo, prepararPdf } from "./pdf.js";

const TEXTO_LEGAL = "Este orçamento é uma estimativa baseada na avaliação clínica realizada. Alterações no " +
  "quadro clínico identificadas durante o tratamento podem implicar revisão do plano e dos valores, sempre " +
  "comunicada previamente ao paciente.";

// ------------------------------------------------------------------
// Tela
// ------------------------------------------------------------------
export async function telaNovoOrcamento(pacienteId) {
  const base = await api("orcamento_novo", pacienteId ? { paciente_id: pacienteId } : {});
  if (!base) return html`<p class="vazio">O orçamento pelo site ainda não está disponível.</p>`;
  depoisDeMostrar.push(() => ligarTela(base));
  const grupos = agrupar(base.procedimentos);
  const campanhas = base.campanhas ?? [];
  const pac = base.paciente;
  return html`
    <p style="margin:0 0 10px"><a class="suave pequeno" href="${pac
      ? `#/paciente/${pac.id}/orcamentos`
      : "#/orcamentos"}">‹ ${pac ? pac.nome : "Orçamentos"}</a></p>
    <div class="cabecalho">
      <div>
        <h1>Novo orçamento</h1>
        <p>Preencha os campos e o documento se monta sozinho na prévia. Ao salvar, ele fica na ficha do paciente e o PDF sai pronto para enviar.</p>
      </div>
    </div>
    <div class="orc-tela">
      <form id="orc-form" class="cartao orc-form formulario" novalidate autocomplete="off">
        <section class="orc-bloco">
          <h2>Paciente</h2>
          ${campoPaciente(pac ? { id: pac.id, nome: pac.nome } : null)}
          <div id="orc-aberto"></div>
          <div class="campos-2">
            <div class="campo"><span class="rotulo">Emissão</span><div class="orc-fixo">Hoje</div></div>
            <div class="campo"><label for="orc-validade">Validade (dias)</label>
              <input id="orc-validade" name="validade_dias" class="busca" type="number" inputmode="numeric" min="1" max="180" step="1" value="${base
                .validade_dias ?? 30}"></div>
          </div>
        </section>

        <section class="orc-bloco">
          <div class="orc-bloco-topo">
            <h2>Procedimentos</h2>
            <button type="button" class="botao botao-pequeno" id="orc-adicionar">+ Adicionar</button>
          </div>
          ${campanhas.length
            ? html`<div class="campo"><label for="orc-campanha">Preços</label>
              <select id="orc-campanha" name="campanha_id" class="busca">
                <option value="">Preços normais</option>
                ${campanhas.map((c) => html`<option value="${c.id}">${c.nome} (${c.periodo})</option>`)}
              </select></div>`
            : ""}
          <div class="campo"><label for="orc-tabela">Escolher da tabela de preços (um por vez, quantos quiser)</label>
            <select id="orc-tabela" class="busca">
              <option value="">Escolher da tabela de preços…</option>
              ${grupos.map((g) =>
                html`<optgroup label="${g.grupo}">${
                  g.itens.map((p) => html`<option value="${p.codigo}">${p.nome}</option>`)
                }</optgroup>`
              )}
            </select></div>
          <div id="orc-itens" class="orc-itens"></div>
          <label class="orc-check">
            <input type="checkbox" name="detalhar" id="orc-detalhar">
            <span>Mostrar o preço de cada procedimento
              <em>Desmarcado, o documento lista os procedimentos e mostra só o valor total.</em></span>
          </label>
        </section>

        <section class="orc-bloco">
          <h2>Valores</h2>
          <div class="campos-3">
            <div class="campo"><label for="orc-desconto">Desconto</label>
              <input id="orc-desconto" name="desconto" class="busca" inputmode="decimal" placeholder="0"></div>
            <div class="campo"><label for="orc-desconto-tipo">Tipo</label>
              <select id="orc-desconto-tipo" name="desconto_tipo" class="busca">
                <option value="reais">R$</option>
                <option value="pct">%</option>
              </select></div>
            <div class="campo"><label for="orc-parcelas">Parcelar em</label>
              <input id="orc-parcelas" name="parcelas" class="busca" type="number" inputmode="numeric" min="0" max="24" step="1" value="0"></div>
          </div>
          <p class="suave pequeno orc-dica">Parcelas em 0 = mostra só o valor à vista.</p>
        </section>

        <section class="orc-bloco">
          <h2>Observações</h2>
          <div class="campo"><label for="orc-obs">Texto livre (o que está incluso, prazos, cuidados)</label>
            <textarea id="orc-obs" name="observacoes" class="busca" rows="4" maxlength="2000" placeholder="Ex.: Valores incluem todas as sessões e retornos de acompanhamento. Exames de imagem não inclusos."></textarea></div>
        </section>

        <label class="orc-check">
          <input type="checkbox" name="apresentar" checked>
          <span>Vou entregar ao paciente agora
            <em>Fica como entregue e aparece em Hoje para você acompanhar (7, 21 e 45 dias). Desmarcado, fica como rascunho.</em></span>
        </label>

        <p class="form-erro erro-caixa pequeno" hidden></p>
        <div class="botoes orc-acoes">
          <button type="submit" class="botao botao-principal" id="orc-salvar">Salvar e gerar PDF</button>
          <button type="button" class="botao-link" id="orc-limpar">Limpar tudo</button>
        </div>
        <p
          class="suave pequeno orc-nota">Fica salvo na ficha do paciente, com número, como os orçamentos que o Claude monta. Para mudar depois, faça um novo: ele vira a versão seguinte.</p>
      </form>

      <div class="orc-previa" aria-label="Prévia do documento">
        <div class="orc-moldura">
          <div id="orc-doc" class="orc-doc"></div>
        </div>
      </div>
    </div>
  `;
}

// ------------------------------------------------------------------
// Comportamento
// ------------------------------------------------------------------
function ligarTela(base) {
  const raiz = conteudo();
  const form = raiz.querySelector("#orc-form");
  if (!form) return;
  const itens = form.querySelector("#orc-itens");
  const seletor = form.querySelector("#orc-tabela");
  const selCampanha = form.querySelector("#orc-campanha");
  const doc = raiz.querySelector("#orc-doc");
  let paciente = base.paciente ? { id: base.paciente.id, nome: base.paciente.nome } : null;
  let salvando = false;

  const campanhaAtual = () => (base.campanhas ?? []).find((c) => c.id === (selCampanha?.value ?? "")) ?? null;
  const proc = (codigo) => base.procedimentos.find((p) => p.codigo === codigo);

  // ── linhas de procedimento ──
  function novaLinha({ codigo = "", descricao = "", valor = "" } = {}) {
    const p = codigo ? proc(codigo) : null;
    const div = document.createElement("div");
    div.className = "orc-item";
    if (p) {
      div.dataset.codigo = p.codigo;
      div.dataset.nome = p.nome;
    }
    div.innerHTML = String(html`
      <button type="button" class="orc-item-remover" aria-label="Tirar este procedimento">×</button>
      <input class="busca orc-item-desc" data-campo="descricao" placeholder="Procedimento" aria-label="Procedimento"
        value="${descricao}" maxlength="200">
      <input class="busca" data-campo="local" placeholder="Dente / região (opcional)" aria-label="Dente ou região"
        maxlength="120">
      <div class="orc-item-numeros">
        <input class="busca" data-campo="qtd" type="number" inputmode="numeric" min="1" max="99" step="1" value="1"
          aria-label="Quantidade" title="Quantidade">
        <input class="busca" data-campo="valor" inputmode="decimal" placeholder="Valor (R$)"
          aria-label="Valor unitário em reais" value="${valor}">
      </div>
      ${p && p.aplica_a?.startsWith("dente")
        ? html`<p class="suave pequeno orc-item-dica">${
          p.aplica_a === "dente_faces" ? "Dente e faces, ex.: 36 MO" : "Dente, ex.: 36"
        }</p>`
        : ""}
    `);
    itens.appendChild(div);
    atualizar();
    return div;
  }

  const campo = (linha, nome) => linha.querySelector(`[data-campo="${nome}"]`);
  const linhaEmBranco = () =>
    Array.from(itens.querySelectorAll(".orc-item")).find((l) =>
      !l.dataset.codigo && !campo(l, "descricao").value.trim() && !campo(l, "valor").value.trim()
    );

  form.querySelector("#orc-adicionar").addEventListener("click", () => {
    novaLinha().querySelector("[data-campo=descricao]").focus();
  });
  itens.addEventListener("click", (e) => {
    const b = e.target.closest(".orc-item-remover");
    if (!b) return;
    b.closest(".orc-item").remove();
    if (!itens.children.length) novaLinha();
    atualizar();
  });
  // da tabela de preços: aproveita uma linha vazia em vez de deixá-la sobrando
  seletor.addEventListener("change", () => {
    const p = proc(seletor.value);
    seletor.value = "";
    if (!p) return;
    const preco = precoDe(p, campanhaAtual());
    const vaga = linhaEmBranco();
    const linha = novaLinha({ codigo: p.codigo, descricao: p.nome, valor: valorNoCampo(preco) });
    if (vaga) {
      vaga.replaceWith(linha);
      atualizar();
    }
    if (preco == null) campo(linha, "valor").focus({ preventScroll: true });
  });
  // trocar a campanha troca o preço das linhas que ainda estão com o preço da tabela
  selCampanha?.addEventListener("change", () => {
    const antes = selCampanha.dataset.antes ?? "";
    const campAntes = (base.campanhas ?? []).find((c) => c.id === antes) ?? null;
    itens.querySelectorAll(".orc-item[data-codigo]").forEach((l) => {
      const p = proc(l.dataset.codigo);
      const v = campo(l, "valor");
      if (lerNumero(v.value) === precoDe(p, campAntes)) v.value = valorNoCampo(precoDe(p, campanhaAtual()));
    });
    selCampanha.dataset.antes = selCampanha.value;
    atualizar();
  });

  // ── paciente e orçamento em aberto ──
  function mostrarAberto() {
    const caixa = form.querySelector("#orc-aberto");
    const a = base.paciente?.aberto;
    if (!a || !paciente) {
      caixa.innerHTML = "";
      return;
    }
    caixa.innerHTML = String(html`
      <fieldset class="campo escolhas orc-aberto">
        <legend>${paciente.nome.split(" ")[0]} já tem o orçamento nº ${a.numero}${a.versao > 1
          ? ` (versão ${a.versao})`
          : ""} ${a.status === "rascunho" ? "em rascunho" : "em aberto"}</legend>
        <label class="escolha"><input type="radio" name="substituir" value="sim" checked><span><b>Substituir por este</b>
          <span class="suave pequeno">Vira a versão ${a.versao + 1} do nº ${a
            .numero}; a anterior fica guardada.</span></span></label>
        <label class="escolha"><input type="radio" name="substituir" value="nao"><span><b>Fazer outro, à parte</b>
          <span class="suave pequeno">Os dois ficam em aberto.</span></span></label>
      </fieldset>
    `);
  }
  async function carregarPaciente(p) {
    paciente = p;
    base.paciente = p ? { id: p.id, nome: p.nome } : null;
    mostrarAberto();
    atualizar();
    if (!p) return;
    try {
      const d = await api("orcamento_novo", { paciente_id: p.id });
      if (paciente?.id !== p.id) return;
      base.paciente = d?.paciente ?? base.paciente;
      mostrarAberto();
      escolherCampanhaInicial();
      atualizar();
    } catch (e) {
      avisar(e.message, "erro");
    }
  }
  ligarPaciente(form, carregarPaciente);

  function escolherCampanhaInicial() {
    if (!selCampanha) return;
    const substituir = form.querySelector("input[name=substituir]:checked")?.value !== "nao";
    const id = campanhaInicial(base, substituir);
    if (id !== selCampanha.value) {
      selCampanha.dataset.antes = selCampanha.value;
      selCampanha.value = id;
      selCampanha.dispatchEvent(new Event("change"));
    }
  }
  form.addEventListener("change", (e) => {
    if (e.target.name === "substituir") escolherCampanhaInicial();
  });

  // ── estado e prévia ──
  function estado() {
    const f = new FormData(form);
    return {
      paciente_id: paciente?.id ?? "",
      itens: Array.from(itens.querySelectorAll(".orc-item")).map((l) => ({
        codigo: l.dataset.codigo,
        nome_base: l.dataset.nome,
        descricao: campo(l, "descricao").value,
        local: campo(l, "local").value,
        qtd: campo(l, "qtd").value,
        valor: campo(l, "valor").value,
      })),
      validade_dias: f.get("validade_dias"),
      campanha_id: f.get("campanha_id") ?? "",
      desconto: f.get("desconto"),
      desconto_tipo: f.get("desconto_tipo"),
      parcelas: f.get("parcelas"),
      observacoes: f.get("observacoes"),
      detalhar: f.get("detalhar") === "on",
      apresentar: f.get("apresentar") === "on",
      substituir: f.get("substituir") !== "nao",
    };
  }

  function atualizar() {
    doc.innerHTML = String(documentoHtml(planoDaTela(estado(), base, paciente?.nome)));
  }
  form.addEventListener("input", atualizar);
  form.addEventListener("change", atualizar);
  // Enter num campo não salva sem querer (só o botão salva)
  form.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.target.tagName === "INPUT") e.preventDefault();
  });

  // prévia do tamanho da coluna (a folha é A4, em milímetros, como no PDF)
  const moldura = raiz.querySelector(".orc-moldura");
  const ajustar = () => {
    const largura = moldura.clientWidth - 2 * parseFloat(getComputedStyle(moldura).paddingLeft || "0");
    doc.style.zoom = String(Math.min(1, Math.max(0.3, largura / 794)));
  };
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(ajustar).observe(moldura);
  ajustar();

  form.querySelector("#orc-limpar").addEventListener("click", () => {
    if (!confirm("Limpar todos os campos deste orçamento?")) return;
    itens.innerHTML = "";
    form.querySelector("#orc-obs").value = "";
    form.querySelector("#orc-desconto").value = "";
    form.querySelector("#orc-parcelas").value = "0";
    form.querySelector("#orc-validade").value = String(base.validade_dias ?? 30);
    novaLinha();
  });

  // ── salvar ──
  const erro = form.querySelector(".form-erro");
  const mostrarErro = (t) => {
    erro.innerHTML = String(Array.isArray(t) ? html`${t.map((x, i) => html`${i ? html`<br>` : ""}${x}`)}` : t ?? "");
    erro.hidden = !t || (Array.isArray(t) && !t.length);
    if (!erro.hidden) erro.scrollIntoView({ block: "nearest", behavior: "smooth" });
  };
  // o aviso do que falta some assim que ela volta a mexer no formulário
  form.addEventListener("input", () => {
    if (!erro.hidden && !salvando) mostrarErro("");
  });

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (salvando) return;
    const est = estado();
    const pedido = montarPedido(est, base);
    if (pedido.erros) return mostrarErro(pedido.erros);
    mostrarErro("");
    const botao = form.querySelector("#orc-salvar");
    salvando = true;
    botao.disabled = true;
    botao.textContent = "Salvando…";
    // o gerador do PDF começa a baixar enquanto o banco grava
    const gerador = prepararPdf();
    gerador.catch(() => {});
    try {
      const r = await gravar("orcamento", pedido.dados);
      if (r?.status === "valor_necessario") {
        return mostrarErro(
          (r.faltando ?? []).map((f) => `Falta o valor de “${f.procedimento ?? f.procedimento_codigo}”.`),
        );
      }
      if (r?.status !== "ok" || !r.orcamento) throw new Error(r?.mensagem ?? "O orçamento não foi gravado.");
      await depoisDeSalvar(r, est, gerador);
      await carregarPaciente(paciente);
    } catch (e) {
      mostrarErro(e.message);
    } finally {
      salvando = false;
      if (botao.isConnected) {
        botao.disabled = false;
        botao.textContent = "Salvar e gerar PDF";
      }
    }
  });

  if (!itens.children.length) novaLinha();
  escolherCampanhaInicial();
  mostrarAberto();
  atualizar();
}

// ------------------------------------------------------------------
// Depois de gravar: PDF, guardar na ficha, baixar ou mandar
// ------------------------------------------------------------------
const paraBase64 = (buffer) => {
  const bytes = new Uint8Array(buffer);
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};

async function depoisDeSalvar(r, est, geradorPromessa) {
  const orc = r.orcamento;
  window.dispatchEvent(new Event("consultorio:gravou"));
  const avisos = avisosParaTela(r.avisos);
  const nome = nomeArquivo(orc.paciente?.nome ?? "");
  const janela = abrirJanela(
    html`
      <h2>Orçamento nº ${orc.numero}${orc.versao > 1 ? ` (versão ${orc.versao})` : ""} salvo</h2>
      <p class="suave" style="margin:0 0 10px">${orc.paciente?.nome} · ${dinheiro(
        orc.total ?? orc.opcoes?.[0]?.total,
      )} · ${orc.status === "apresentado" ? "entregue, em aberto" : "rascunho"} · válido até ${orc.validade?.split("-")
        .reverse().join("/")}</p>
      ${avisos.length
        ? html`
          <div class="aviso-faixa cartao">
            <ul class="lista-avisos">${avisos.map((a) => html`<li>${a}</li>`)}</ul>
          </div>
        `
        : ""}
      <p class="pequeno orc-estado-pdf" role="status">Gerando o PDF…</p>
      <div class="botoes orc-botoes-pdf" hidden>
        <button type="button" class="botao botao-principal" data-compartilhar hidden>Enviar (WhatsApp, e-mail…)</button>
        <button type="button" class="botao" data-baixar>Baixar PDF</button>
        <button type="button" class="botao" data-guardar hidden>Tentar guardar de novo</button>
      </div>
    `,
    {
      titulo: "Orçamento salvo",
      rodape: html`
        <div class="botoes janela-rodape">
          <a class="botao" href="#/paciente/${orc.paciente?.id ?? ""}/orcamentos">Ver na ficha</a>
          <button type="button" class="botao" data-fechar>Fechar</button>
        </div>
      `,
    },
  );
  const estadoPdf = janela.querySelector(".orc-estado-pdf");
  const botoes = janela.querySelector(".orc-botoes-pdf");

  let bytes;
  try {
    const gerador = await geradorPromessa.catch(() => prepararPdf());
    const pdf = gerarPlanoTratamento(planoDoOrcamento(orc, { detalhar: est.detalhar }), gerador);
    bytes = pdf.output("arraybuffer");
  } catch (e) {
    estadoPdf.textContent =
      `O orçamento foi salvo, mas o PDF não saiu (${e.message}). Peça ao Claude: “me manda o PDF do orçamento nº ${orc.numero}”.`;
    estadoPdf.classList.add("texto-alerta");
    return;
  }
  const arquivo = new File([bytes], nome, { type: "application/pdf" });
  const url = URL.createObjectURL(arquivo);
  botoes.hidden = false;

  janela.querySelector("[data-baixar]").addEventListener("click", () => {
    const a = document.createElement("a");
    a.href = url;
    a.download = nome;
    document.body.appendChild(a);
    a.click();
    a.remove();
  });
  const compartilhar = janela.querySelector("[data-compartilhar]");
  if (navigator.canShare?.({ files: [arquivo] })) {
    compartilhar.hidden = false;
    compartilhar.addEventListener("click", async () => {
      try {
        await navigator.share({ files: [arquivo], title: nome });
      } catch (e) {
        if (e?.name !== "AbortError") avisar("Não consegui abrir o envio. Use Baixar PDF.", "erro");
      }
    });
  }

  const guardar = janela.querySelector("[data-guardar]");
  const tentarGuardar = async () => {
    guardar.hidden = true;
    estadoPdf.classList.remove("texto-alerta", "texto-ok");
    estadoPdf.textContent = "Guardando o PDF na ficha…";
    try {
      await gravar("orcamento_pdf", { orcamento_id: orc.id, pdf: paraBase64(bytes) });
      estadoPdf.textContent = "✓ PDF guardado na ficha do paciente.";
      estadoPdf.classList.add("texto-ok");
    } catch (e) {
      estadoPdf.textContent = `O PDF está pronto aqui, mas não foi guardado na ficha (${e.message}).`;
      estadoPdf.classList.add("texto-alerta");
      guardar.hidden = false;
    }
  };
  guardar.addEventListener("click", tentarGuardar);
  await tentarGuardar();
}

// ------------------------------------------------------------------
// Prévia do documento (o mesmo desenho do PDF, em HTML)
// ------------------------------------------------------------------
export function documentoHtml(plano) {
  const c = calcular(plano);
  const linhaVazia = html`
    <tr class="d-vazio">
      <td colspan="5">Nenhum procedimento adicionado.</td>
    </tr>
  `;
  return html`
    <header class="d-topo">
      <div class="d-identidade">
        <span class="d-nome">${plano.clinica.nome}</span>
        <span class="d-cro">${[plano.clinica.papel, plano.clinica.cro].filter(Boolean).join(" · ")}</span>
        <span class="d-tipo">Plano de Tratamento</span>
      </div>
      <div class="d-contato">
        ${[plano.clinica.whatsapp, plano.clinica.instagram, plano.clinica.email].filter(Boolean).map((x) =>
          html`<span>${x}</span>`
        )}
      </div>
    </header>
    <div class="d-corpo">
      <div class="d-cabecalho">
        <div class="d-paciente"><span class="d-rotulo">Paciente</span><strong>${plano.paciente || "—"}</strong></div>
        <div><span class="d-rotulo">Emissão</span><strong>${plano.emissao}</strong></div>
        <div><span class="d-rotulo">Válido até</span><strong>${plano.validade}</strong></div>
      </div>
      <table class="d-tabela ${plano.detalharPrecos ? "" : "sem-precos"}">
        <thead>
          <tr>
            <th class="col-desc">Procedimento</th>
            <th class="col-reg">Dente / região</th>
            <th class="col-qtd">Qtd.</th>
            <th class="col-val">Valor unit.</th>
            <th class="col-sub">Subtotal</th>
          </tr>
        </thead>
        <tbody>${plano.itens.length
          ? plano.itens.map((i) =>
            html`
              <tr>
                <td class="col-desc">${i.descricao || "—"}</td>
                <td class="col-reg">${i.regiao || "—"}</td>
                <td class="col-qtd">${i.qtd}</td>
                <td class="col-val">${dinheiro(i.valor)}</td>
                <td class="col-sub">${dinheiro(i.qtd * i.valor)}</td>
              </tr>
            `
          )
          : linhaVazia}</tbody>
      </table>
      <div class="d-totais">
        <div class="d-obs"><span class="d-rotulo">Observações</span><p>${plano.observacoes || "—"}</p></div>
        <div class="d-somas">
          ${c.temDesconto
            ? html`
              <div class="d-soma"><span>Valor do tratamento</span><span>${dinheiro(c.subtotal)}</span></div>
              <div class="d-soma d-soma-desconto"><span>${plano.descontoRotulo}</span><span>– ${dinheiro(
                c.desconto,
              )}</span></div>
            `
            : ""}
          <div class="d-soma d-soma-total">
            <span>${c.parcelado ? "Parcelado em" : c.temDesconto ? "Valor a pagar" : "Total"}</span>
            <span class="d-soma-total-valor">${c.parcelado
              ? html`<span class="d-vezes">${plano.parcelas}x</span>`
              : ""}<span>${dinheiro(c.parcelado ? c.total / plano.parcelas : c.total)}</span></span>
          </div>
          ${c.parcelado
            ? html`<div class="d-soma d-soma-cheio"><span>Valor total</span><span>${dinheiro(c.total)}</span></div>`
            : ""}
        </div>
      </div>
      <footer class="d-rodape">
        <p>${TEXTO_LEGAL}</p>
      </footer>
    </div>
  `;
}
