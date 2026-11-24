// Gráficos do site, em SVG sem biblioteca: colunas de 12 meses (recebido e
// despesas) e as barrinhas de consumo semanal do estoque. Cores em tema.css
// (--grafico-*), conferidas para daltonismo nos dois temas.

import { dinheiro, html, MESES } from "./base.js";

const compacto = new Intl.NumberFormat("pt-BR", { notation: "compact", maximumFractionDigits: 1 });
const inteiro = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 0 });

/** Teto "redondo" do eixo e o passo das linhas (4 faixas). */
function escala(maximo) {
  if (!(maximo > 0)) return { teto: 1000, passo: 250 };
  const bruto = maximo / 4;
  const potencia = 10 ** Math.floor(Math.log10(bruto));
  const passo = [1, 2, 2.5, 5, 10].map((m) => m * potencia).find((p) => p >= bruto);
  return { teto: passo * 4, passo };
}

/** Coluna com a ponta arredondada (4px) e a base reta. */
function coluna(x, y, largura, altura) {
  if (altura <= 0) return "";
  const r = Math.min(4, altura, largura / 2);
  return `M${x},${y + altura}V${y + r}Q${x},${y} ${x + r},${y}H${x + largura - r}Q${x + largura},${y} ${x + largura},${
    y + r
  }V${y + altura}Z`;
}

const nomeMes = (aaaamm, comAno = false) => {
  const [a, m] = String(aaaamm).split("-").map(Number);
  return `${MESES[m - 1]?.slice(0, 3) ?? ""}${comAno ? ` ${a}` : ""}`;
};

/** Só o desenho (SVG) do gráfico de 12 meses, na largura real da tela. */
function svgDozeMeses(meses, L) {
  const A = 230, ESQ = 48, DIR = 4, TOPO = 10, BASE = 26;
  const maior = Math.max(...meses.map((m) => Math.max(Number(m.recebido_bruto) || 0, Number(m.despesas) || 0)));
  const { teto, passo } = escala(maior);
  const altura = A - TOPO - BASE;
  const yDe = (v) => TOPO + altura - (Math.max(0, v) / teto) * altura;
  const faixa = (L - ESQ - DIR) / meses.length;
  const barra = Math.min(24, Math.max(4, (faixa - 8) / 2 - 1));
  const rotuloEixo = (v) => (teto >= 10000 ? compacto.format(v) : inteiro.format(v));
  const linhas = [];
  for (let v = 0; v <= teto + 1e-9; v += passo) linhas.push(v);
  const variosAnos = new Set(meses.map((m) => String(m.mes).slice(0, 4))).size > 1;
  // pouco espaço: rótulo mês sim, mês não (o último sempre); o ano só se couber
  const comRotulo = (i) => faixa >= 34 || (meses.length - 1 - i) % 2 === 0;
  const comAno = (i, m) => variosAnos && faixa >= 64 && (i === 0 || String(m.mes).endsWith("-01"));

  const grupos = meses.map((m, i) => {
    const centro = ESQ + faixa * i + faixa / 2;
    const rec = Number(m.recebido_bruto) || 0, desp = Number(m.despesas) || 0;
    const y1 = yDe(rec), y2 = yDe(desp);
    const descricao = `${nomeMes(m.mes, true)}: recebido ${dinheiro(rec)}, despesas ${dinheiro(desp)}, resultado ${
      dinheiro(m.resultado)
    }`;
    return html`<g class="mes" data-i="${i}" tabindex="0" role="img" aria-label="${descricao}">
      <rect class="alvo" x="${ESQ + faixa * i}" y="${TOPO}" width="${faixa}" height="${altura}"/>
      <path d="${coluna(centro - barra - 1, y1, barra, TOPO + altura - y1)}" fill="var(--grafico-entrada)"/>
      <path d="${coluna(centro + 1, y2, barra, TOPO + altura - y2)}" fill="var(--grafico-saida)"/>
      ${
      comRotulo(i) ? html`<text class="eixo-x" x="${centro}" y="${A - 8}">${nomeMes(m.mes, comAno(i, m))}</text>` : ""
    }
    </g>`;
  });
  return html`
    <svg viewBox="0 0 ${L} ${A}" width="${L}" height="${A}" role="group"
      aria-label="Recebido e despesas por mês, últimos 12 meses">
        ${linhas.map((v) =>
          html`
            <line class="grade-linha" x1="${ESQ}" x2="${L - DIR}" y1="${yDe(v)}" y2="${yDe(v)}" />
            <text class="eixo-y" x="${ESQ - 8}" y="${yDe(v) + 4}">${rotuloEixo(v)}</text>
          `
        )}
        ${grupos}
      </svg>
  `;
}

/**
 * Recebido e despesas dos últimos 12 meses (colunas lado a lado), com
 * legenda, dica ao passar o dedo ou o mouse e a tabela com os números.
 * O desenho é refeito na largura da tela por ligarGraficoDozeMeses.
 */
export function graficoDozeMeses(historico, id = "grafico-12") {
  const meses = (historico ?? []).filter(Boolean);
  if (!meses.length) return "";
  return html`
    <figure class="grafico" id="${id}">
      <div class="grafico-legenda" aria-hidden="true">
        <span><i style="background:var(--grafico-entrada)"></i>Recebido</span>
        <span><i style="background:var(--grafico-saida)"></i>Despesas</span>
      </div>
      <div class="grafico-area">
          ${svgDozeMeses(meses, 720)}
          <div class="dica" hidden></div>
        </div>
      <details class="grafico-tabela pequeno">
        <summary>Ver os números</summary>
        <table class="tabela numeros-tabela">
          <thead>
            <tr>
              <th>Mês</th>
              <th>Recebido</th>
              <th>Taxas</th>
              <th>Despesas</th>
              <th>Resultado</th>
            </tr>
          </thead>
          <tbody>${[...meses].reverse().map((m) =>
            html`
              <tr>
                <td>${nomeMes(m.mes, true)}</td>
                <td>${dinheiro(m.recebido_bruto)}</td>
                <td>${dinheiro(m.taxas)}</td>
                <td>${dinheiro(m.despesas)}</td>
                <td class="forte">${dinheiro(m.resultado)}</td>
              </tr>
            `
          )}</tbody>
        </table>
        <p class="suave">Resultado = recebido − taxas da maquininha − despesas.</p>
      </details>
    </figure>
  `;
}

/** Desenha na largura real e liga a dica (passar o dedo, o mouse ou o teclado). */
export function ligarGraficoDozeMeses(historico, id = "grafico-12") {
  const fig = document.getElementById(id);
  if (!fig) return;
  const meses = (historico ?? []).filter(Boolean);
  const area = fig.querySelector(".grafico-area");
  const dica = fig.querySelector(".dica");
  let largura = 0;
  const desenhar = () => {
    const w = Math.floor(area.clientWidth);
    if (!w || w === largura) return;
    largura = w;
    area.querySelector("svg").outerHTML = String(svgDozeMeses(meses, w));
  };
  desenhar();
  if ("ResizeObserver" in globalThis) new ResizeObserver(desenhar).observe(area);

  const mostrarDica = (g) => {
    const m = meses[Number(g.dataset.i)];
    if (!m) return;
    fig.querySelectorAll(".mes.ativo").forEach((x) => x.classList.remove("ativo"));
    g.classList.add("ativo");
    dica.innerHTML = String(html`
      <div class="forte">${nomeMes(m.mes, true)}</div>
      <div><i style="background:var(--grafico-entrada)"></i>Recebido <b>${dinheiro(m.recebido_bruto)}</b></div>
      <div><i style="background:var(--grafico-saida)"></i>Despesas <b>${dinheiro(m.despesas)}</b></div>
      <div class="suave">Resultado <b>${dinheiro(m.resultado)}</b></div>
    `);
    dica.hidden = false;
    const caixa = g.querySelector(".alvo").getBoundingClientRect();
    const base = area.getBoundingClientRect();
    const larg = dica.offsetWidth;
    let x = caixa.left - base.left + caixa.width / 2 - larg / 2;
    x = Math.max(0, Math.min(x, base.width - larg));
    dica.style.left = `${x}px`;
    dica.style.top = `0px`;
  };
  const esconder = () => {
    dica.hidden = true;
    fig.querySelectorAll(".mes.ativo").forEach((x) => x.classList.remove("ativo"));
  };
  area.addEventListener("pointerover", (e) => {
    const g = e.target.closest?.(".mes");
    if (g) mostrarDica(g);
  });
  area.addEventListener("focusin", (e) => {
    const g = e.target.closest?.(".mes");
    if (g) mostrarDica(g);
  });
  area.addEventListener("focusout", esconder);
  area.addEventListener("pointerleave", esconder);
}

/** Barrinhas de 8 semanas (a última em destaque). */
export function barrinhasSemanas(valores, semanas, unidade) {
  const v = (valores ?? []).map((x) => Number(x) || 0);
  if (!v.length) return "";
  const maior = Math.max(...v, 0) || 1;
  const B = 6, G = 2, A = 22;
  const largura = v.length * (B + G) - G;
  const dia = (s) => (s ? `${String(s).slice(8, 10)}/${String(s).slice(5, 7)}` : "");
  return html`
    <svg class="barrinhas" viewBox="0 0 ${largura} ${A}" width="${largura * 1.6}" height="${A * 1.2}" role="img"
      aria-label="Uso por semana nas últimas ${v.length} semanas: ${v.map((x) => inteiro.format(x)).join(
        ", ",
      )} ${unidade ?? ""}">
        ${v.map((x, i) => {
          const h = Math.max(x > 0 ? 2 : 0, (x / maior) * (A - 1));
          return html`
            <path d="${coluna(i * (B + G), A - h, B, h) ||
              `M${i * (B + G)},${A - 0.5}h${B}`}" fill="${i === v.length - 1
              ? "var(--grafico-saida)"
              : "var(--grafico-apagado)"}" ${x > 0 ? "" : html`stroke="var(--grafico-apagado)" stroke-width="1"`}>
              <title>Semana de ${dia(semanas?.[i])}: ${String(x).replace(".", ",")} ${unidade ?? ""}</title>
            </path>
          `;
        })}
      </svg>
  `;
}
