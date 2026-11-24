// Peças comuns do site: HTML seguro, formatos de data e dinheiro, etiquetas.

// ------------------------------------------------------------------
// HTML seguro: tudo que entra em html`` é escapado, menos o que vem de cru().
// ------------------------------------------------------------------
export class Cru {
  constructor(s) {
    this.s = s;
  }
  toString() {
    return this.s;
  }
}
export const cru = (s) => new Cru(s);
export const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
export function juntar(v) {
  if (v == null || v === false) return "";
  if (v instanceof Cru) return v.s;
  if (Array.isArray(v)) return v.map(juntar).join("");
  return esc(v);
}
export function html(partes, ...valores) {
  let s = partes[0];
  valores.forEach((v, i) => (s += juntar(v) + partes[i + 1]));
  return cru(s);
}

// ------------------------------------------------------------------
// Formatos
// ------------------------------------------------------------------
export const MESES = [
  "janeiro",
  "fevereiro",
  "março",
  "abril",
  "maio",
  "junho",
  "julho",
  "agosto",
  "setembro",
  "outubro",
  "novembro",
  "dezembro",
];
export const DIAS = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
export const DIAS_CURTOS = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];

export const deISO = (s) => {
  const [a, m, d] = String(s).slice(0, 10).split("-").map(Number);
  return new Date(a, m - 1, d);
};
export const paraISO = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
export const hojeISO = () => paraISO(new Date());
export const somarDias = (s, n) => {
  const d = deISO(s);
  d.setDate(d.getDate() + n);
  return paraISO(d);
};
export const segundaDe = (s) => {
  const d = deISO(s);
  return somarDias(s, -((d.getDay() + 6) % 7));
};
export const dataLonga = (s) => {
  const d = deISO(s);
  return `${DIAS[d.getDay()]}, ${d.getDate()} de ${MESES[d.getMonth()]}`;
};
export const dataCurta = (s, ano = false) => {
  if (!s) return "";
  const d = deISO(s);
  const base = `${String(d.getDate()).padStart(2, "0")}/${String(d.getMonth() + 1).padStart(2, "0")}`;
  return ano || d.getFullYear() !== new Date().getFullYear() ? `${base}/${d.getFullYear()}` : base;
};
export const minutos = (hhmm) => {
  const [h, m] = String(hhmm).split(":").map(Number);
  return h * 60 + m;
};
export const duracao = (min) => {
  const h = Math.floor(min / 60), m = min % 60;
  return h ? `${h}h${m ? String(m).padStart(2, "0") : ""}` : `${m} min`;
};
export const dinheiro = (v) =>
  v == null ? "" : Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
export const telefone = (t) => {
  const d = String(t ?? "").replace(/\D/g, "");
  if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`;
  if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`;
  return t ?? "";
};
export const cpf = (c) => {
  const d = String(c ?? "").replace(/\D/g, "");
  return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : c ?? "";
};
export const normalizar = (t) => String(t ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
export const linkWhatsApp = (t) => {
  const d = String(t ?? "").replace(/\D/g, "");
  return d ? `https://wa.me/${d.length <= 11 ? "55" + d : d}` : null;
};
export const texto = (v) => {
  if (v == null) return "";
  if (typeof v === "object") return Object.values(v).filter((x) => x != null && x !== "").map(texto).join(", ");
  return String(v);
};

export const STATUS = {
  agendada: "A confirmar",
  confirmada: "Confirmada",
  realizada: "Realizada",
  faltou: "Faltou",
  cancelada: "Cancelada",
  remarcada: "Remarcada",
};
export const chipStatus = (s) => html`<span class="etiqueta status status-${s}">${STATUS[s] ?? s}</span>`;

export const ICONE_CONVERSA = cru(
  '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a9 9 0 0 0-7.8 13.5L3 21l4.6-1.2A9 9 0 1 0 12 3zm0 16.2c-1.4 0-2.8-.4-4-1.1l-.3-.2-2.7.7.7-2.6-.2-.3A7.2 7.2 0 1 1 12 19.2zm4-5.4c-.2-.1-1.3-.6-1.5-.7-.2-.1-.4-.1-.5.1l-.7.9c-.1.1-.3.2-.5.1a5.9 5.9 0 0 1-2.9-2.6c-.2-.4.2-.4.6-1.2.1-.1 0-.3 0-.4l-.7-1.6c-.2-.4-.4-.4-.5-.4h-.4a.8.8 0 0 0-.6.3 2.5 2.5 0 0 0-.8 1.9c0 1.1.8 2.2.9 2.3.1.2 1.6 2.5 3.9 3.5 1.5.6 2 .7 2.7.6.4-.1 1.3-.5 1.5-1.1.2-.5.2-1 .1-1.1l-.6-.4z"/></svg>',
);

export function chipsAlertas(alertas, curto = false) {
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
// Listas e campos usados em várias telas
// ------------------------------------------------------------------
export function campo(rotulo, valor) {
  if (valor == null || valor === "" || (Array.isArray(valor) && !valor.length)) return "";
  return html`
    <div>
      <dt>${rotulo}</dt>
      <dd>${valor}</dd>
    </div>
  `;
}

export function listaGenerica(itens, vazio) {
  if (!itens?.length) return html`<p class="vazio">${vazio}</p>`;
  return html`<ul class="lista">${
    itens.map((x) =>
      html`
        <li>
          <div class="linha">
            <div>${x.paciente_id
              ? html`<a class="link-paciente" href="#/paciente/${x.paciente_id}">${x.titulo}</a>`
              : html`<span class="forte">${x.titulo ?? x.descricao ?? x.tipo ?? "Item"}</span>`}
              <div class="suave pequeno">${[
                x.data ? dataCurta(x.data, true) : "",
                x.numero ? `nº ${x.numero}` : "",
                x.forma ?? "",
                x.paciente_id ? x.descricao ?? "" : "",
              ].filter(Boolean).join(" · ")}</div></div>
            <div class="botoes">${x.status
              ? html`<span class="etiqueta ${/estorn|cancel|atrasad/.test(x.status) ? "etiqueta-alerta" : ""}">${
                String(x.status).replaceAll("_", " ")
              }</span>`
              : ""}${x.valor != null ? html`<span class="forte">${dinheiro(x.valor)}</span>` : ""}${x.link
              ? html`<a class="botao" href="${x.link}" target="_blank" rel="noopener">Abrir PDF</a>`
              : ""}</div>
          </div>
        </li>
      `
    )
  }</ul>`;
}

export const COR_ORCAMENTO = {
  aprovado: "etiqueta-ok",
  concluido: "etiqueta-ok",
  parcial: "etiqueta-ok",
  apresentado: "etiqueta-aviso",
  rascunho: "etiqueta-apagada",
  recusado: "etiqueta-alerta",
  expirado: "etiqueta-alerta",
};
export const STATUS_ITEM = { realizado: "feito", em_andamento: "em andamento", cancelado: "cancelado" };

export const TIPO_DOCUMENTO = {
  orcamento: "Orçamento",
  receita: "Receita",
  atestado: "Atestado",
  termo: "Termo",
  consentimento: "Termo de consentimento",
  orientacoes: "Orientações",
};
export const abaDocumentos = (p) =>
  html`<section class="cartao">${
    listaGenerica(
      (p.documentos ?? []).map((d) => ({ ...d, forma: TIPO_DOCUMENTO[d.tipo] ?? d.tipo })),
      "Nenhum documento emitido. Receitas, atestados e termos pedidos ao Claude aparecem aqui.",
    )
  }</section>`;

export const valorOrcamento = (o) =>
  o.valor != null
    ? dinheiro(o.valor)
    : (o.opcoes ?? []).map((x) => `Opção ${x.alternativa}: ${dinheiro(x.total)}`).join(" · ");

export const emBreve = (titulo, texto) =>
  html`
    <div class="cabecalho">
      <div>
        <h1>${titulo}</h1>
      </div>
    </div>
    <section class="cartao">
      <p class="vazio">${texto}</p>
    </section>
  `;

export const mesCurto = (aaaamm) => {
  const [a, m] = String(aaaamm ?? "").split("-").map(Number);
  return m ? `${MESES[m - 1].slice(0, 3)}${a !== new Date().getFullYear() ? ` ${a}` : ""}` : "";
};
