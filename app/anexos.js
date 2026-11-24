// Exames e arquivos na ficha do paciente: anexar (foto ou PDF), ver e tirar
// da ficha. O arquivo vai direto para o Storage por um link de envio de uso
// único que a API gera; depois o site grava o registro. Faz parte do
// prontuário: nada se apaga, anexo errado só sai da lista (com motivo).

import { CHAVE_PUBLICA } from "./config.js";
import { abrirJanela, api, avisar, fecharJanela, gravar, podeLancar } from "./nucleo.js";
import { dataCurta, hojeISO, html } from "./base.js";

export const TIPOS_ANEXO = [
  ["radiografia", "Radiografia"],
  ["tomografia", "Tomografia"],
  ["exame", "Exame de laboratório"],
  ["foto", "Foto"],
  ["laudo", "Laudo ou relatório"],
  ["documento", "Documento"],
  ["outro", "Outro"],
];
const LIMITE = 20 * 1024 * 1024;
const LADO_MAXIMO = 2400;
const ACEITOS = ["application/pdf", "image/jpeg", "image/png"];

const tamanhoLegivel = (b) =>
  !b ? "" : b < 1024 * 1024 ? `${Math.max(1, Math.round(b / 1024))} KB` : `${(b / 1024 / 1024).toFixed(1)} MB`;

/** Abre a imagem respeitando a rotação da foto do celular. */
async function abrirImagem(arquivo) {
  try {
    return await createImageBitmap(arquivo, { imageOrientation: "from-image" });
  } catch (_) {
    return await createImageBitmap(arquivo);
  }
}

/**
 * PDF vai como está. Foto grande (ou HEIC do iPhone) vira JPEG de até
 * 2400 px no lado maior: continua nítida e ocupa bem menos espaço.
 */
export async function prepararArquivo(arquivo) {
  if (arquivo.type === "application/pdf") return arquivo;
  if (!arquivo.type.startsWith("image/")) throw new Error("Use uma foto (JPG ou PNG) ou um PDF.");
  const jaServe = ACEITOS.includes(arquivo.type) && arquivo.size <= 1.5 * 1024 * 1024;
  if (jaServe) return arquivo;
  let imagem;
  try {
    imagem = await abrirImagem(arquivo);
  } catch (_) {
    if (ACEITOS.includes(arquivo.type)) return arquivo;
    throw new Error("Não consegui abrir essa foto. Tente de novo ou mande em JPG.");
  }
  const escala = Math.min(1, LADO_MAXIMO / Math.max(imagem.width, imagem.height));
  const tela = document.createElement("canvas");
  tela.width = Math.round(imagem.width * escala);
  tela.height = Math.round(imagem.height * escala);
  tela.getContext("2d").drawImage(imagem, 0, 0, tela.width, tela.height);
  imagem.close?.();
  const blob = await new Promise((ok) => tela.toBlob(ok, "image/jpeg", 0.88));
  if (!blob) return arquivo;
  const nome = (arquivo.name || "foto").replace(/\.[^.]+$/, "");
  return new File([blob], `${nome}.jpg`, { type: "image/jpeg" });
}

/** Manda o arquivo pelo link de envio (igual ao que a biblioteca do Supabase faz). */
async function subir(url, arquivo) {
  const corpo = new FormData();
  corpo.append("cacheControl", "3600");
  corpo.append("", arquivo);
  let r;
  try {
    r = await fetch(url, { method: "PUT", headers: { apikey: CHAVE_PUBLICA, "x-upsert": "false" }, body: corpo });
  } catch (_) {
    throw new Error("Sem conexão para enviar o arquivo. Confira a internet e tente de novo.");
  }
  if (!r.ok) throw new Error(`O envio do arquivo não deu certo (erro ${r.status}). Tente de novo.`);
}

function mostrarErro(janela, texto) {
  const caixa = janela.querySelector(".form-erro");
  caixa.textContent = texto;
  caixa.hidden = !texto;
  if (texto) caixa.scrollIntoView({ block: "nearest" });
}

const opcoesTipo = (escolhido) =>
  TIPOS_ANEXO.map(([v, r]) => html`<option value="${v}" ${v === escolhido ? "selected" : ""}>${r}</option>`);

// ------------------------------------------------------------------
// Anexar
// ------------------------------------------------------------------
export function anexarExame({ paciente, depois }) {
  const janela = abrirJanela(
    html`
      <h2>Anexar exame ou arquivo</h2>
      <form id="form-anexo" class="formulario" novalidate>
        <div class="campo"><span class="rotulo">Paciente</span><div class="forte">${paciente.nome}</div></div>
        <div class="campo"><label for="arquivo">Arquivo</label>
          <input id="arquivo" name="arquivo" type="file" class="arquivo" accept="image/*,application/pdf" required>
          <p class="suave pequeno">Foto, imagem ou PDF, até 20 MB. No celular dá para tirar a foto na hora.</p>
          <div class="anexo-previa" hidden></div>
        </div>
        <div class="campos-2">
          <div class="campo"><label for="tipo">Tipo</label>
            <select id="tipo" name="tipo" class="busca">${opcoesTipo("radiografia")}</select></div>
          <div class="campo"><label for="data">Data do exame</label>
            <input id="data" name="data_documento" class="busca" type="date" value="${hojeISO()}" max="${hojeISO()}"></div>
        </div>
        <div class="campo"><label for="titulo">Nome (opcional)</label>
          <input id="titulo" name="titulo" class="busca" maxlength="120" placeholder="Ex.: Panorâmica, Hemograma"></div>
        <div class="campo"><label for="observacao">Observação (opcional)</label>
          <textarea id="observacao" name="observacao" class="busca" rows="2" maxlength="1000"
            placeholder="Ex.: trazida pelo paciente, feita em outra clínica"></textarea></div>
        <p class="suave pequeno">O arquivo fica guardado com o prontuário do paciente.</p>
        <p class="form-erro erro-caixa pequeno" hidden></p>
      </form>
    `,
    {
      titulo: "Anexar exame",
      rodape: html`
        <div class="botoes janela-rodape">
          <button type="button" class="botao" data-fechar>Cancelar</button>
          <button type="submit" class="botao botao-principal" form="form-anexo">Anexar</button>
        </div>
      `,
    },
  );
  const entrada = janela.querySelector("#arquivo");
  const previa = janela.querySelector(".anexo-previa");
  let urlPrevia = null;
  entrada.addEventListener("change", () => {
    const f = entrada.files?.[0];
    if (urlPrevia) URL.revokeObjectURL(urlPrevia);
    urlPrevia = null;
    previa.hidden = !f;
    if (!f) return;
    mostrarErro(janela, "");
    if (f.type.startsWith("image/")) {
      urlPrevia = URL.createObjectURL(f);
      previa.innerHTML = String(html`<img src="${urlPrevia}" alt="Prévia do arquivo">`);
    } else {
      previa.innerHTML = String(
        html`<span class="anexo-pdf">PDF</span><span class="pequeno">${f.name} · ${tamanhoLegivel(f.size)}</span>`,
      );
    }
    if (f.type === "application/pdf" && janela.querySelector("#tipo").value === "radiografia") {
      janela.querySelector("#tipo").value = "exame";
    }
  });

  janela.querySelector("#form-anexo").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const original = entrada.files?.[0];
    if (!original) return mostrarErro(janela, "Escolha o arquivo ou tire a foto.");
    const f = new FormData(ev.target);
    const botao = document.querySelector(".janela-rodape button[type=submit]");
    const rotulo = botao?.textContent;
    const passo = (t) => botao && (botao.textContent = t);
    if (botao) botao.disabled = true;
    mostrarErro(janela, "");
    try {
      passo("Preparando…");
      const arquivo = await prepararArquivo(original);
      if (arquivo.size > LIMITE) throw new Error("O arquivo passa de 20 MB. Mande uma versão menor.");
      const envio = await api("anexo_envio", {
        paciente_id: paciente.id,
        tipo_arquivo: arquivo.type,
        tamanho: arquivo.size,
      });
      if (!envio?.url) throw new Error("O envio de arquivos não está disponível agora.");
      passo("Enviando…");
      await subir(envio.url, arquivo);
      passo("Gravando…");
      const tipo = f.get("tipo");
      const nomeTipo = TIPOS_ANEXO.find(([v]) => v === tipo)?.[1] ?? "Arquivo";
      const r = await gravar("anexo", {
        anexo_id: envio.anexo_id,
        paciente_id: paciente.id,
        caminho: envio.caminho,
        tipo,
        titulo: f.get("titulo")?.trim() || null,
        data_documento: f.get("data_documento") || null,
        observacao: f.get("observacao")?.trim() || null,
        nome_arquivo: original.name || null,
        texto_original: `Pelo site: anexou ${nomeTipo.toLowerCase()} na ficha de ${paciente.nome}`,
      });
      if (urlPrevia) URL.revokeObjectURL(urlPrevia);
      fecharJanela();
      const avisos = (r?.avisos ?? []).filter(Boolean);
      avisar(avisos.length ? `Anexado. ${avisos.join(" ")}` : "Exame anexado na ficha.");
      depois?.();
    } catch (e) {
      mostrarErro(janela, e.message);
    } finally {
      if (botao?.isConnected) {
        botao.disabled = false;
        botao.textContent = rotulo;
      }
    }
  });
}

// ------------------------------------------------------------------
// Tirar da ficha (o arquivo continua guardado)
// ------------------------------------------------------------------
export function retirarAnexo({ anexo, paciente, depois }) {
  const janela = abrirJanela(
    html`
      <h2>Tirar da ficha</h2>
      <form id="form-retirar" class="formulario" novalidate>
        <p><strong>${anexo.titulo}</strong></p>
        <p
          class="suave pequeno">O exame sai da lista desta ficha, mas o arquivo continua guardado com o prontuário (nada se apaga). Use quando anexou no paciente errado ou em dobro.</p>
        <div class="campo"><label for="motivo">Motivo</label>
          <input id="motivo" name="motivo" class="busca" minlength="3" maxlength="200" placeholder="Ex.: era de outro paciente" required autofocus></div>
        <p class="form-erro erro-caixa pequeno" hidden></p>
      </form>
    `,
    {
      titulo: "Tirar da ficha",
      rodape: html`
        <div class="botoes janela-rodape">
          <button type="button" class="botao" data-fechar>Cancelar</button>
          <button type="submit" class="botao botao-principal" form="form-retirar">Tirar da ficha</button>
        </div>
      `,
    },
  );
  janela.querySelector("#form-retirar").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const motivo = new FormData(ev.target).get("motivo")?.trim() ?? "";
    if (motivo.length < 3) return mostrarErro(janela, "Diga o motivo.");
    try {
      await gravar("retirar_anexo", {
        anexo_id: anexo.id,
        motivo,
        texto_original: `Pelo site: tirou "${anexo.titulo}" da ficha de ${paciente.nome}: ${motivo}`,
      });
      fecharJanela();
      avisar("Saiu da ficha. O arquivo continua guardado.");
      depois?.();
    } catch (e) {
      mostrarErro(janela, e.message);
    }
  });
}

// ------------------------------------------------------------------
// Aba "Exames" da ficha
// ------------------------------------------------------------------
function itemAnexo(a) {
  const imagem = String(a.tipo_arquivo ?? "").startsWith("image/");
  const miniatura = imagem && a.link
    ? html`<img src="${a.link}" alt="" loading="lazy">`
    : html`<span class="anexo-pdf">${imagem ? "IMG" : "PDF"}</span>`;
  return html`
    <li class="anexo">
      ${a.link
        ? html`
          <a class="anexo-miniatura" href="${a.link}" target="_blank" rel="noopener"
            aria-label="Abrir ${a
              .titulo}">${miniatura}</a>
        `
        : html`<span class="anexo-miniatura">${miniatura}</span>`}
      <div class="anexo-texto">
        <div class="forte">${a.titulo}</div>
        <div class="suave pequeno">${[a.rotulo, a.data ? dataCurta(a.data, true) : null, tamanhoLegivel(a.tamanho)]
          .filter(Boolean).join(" · ")}</div>
        ${a.observacao ? html`<div class="pequeno">${a.observacao}</div>` : ""}
        <div class="botoes anexo-botoes">
          ${a.link ? html`<a class="botao" href="${a.link}" target="_blank" rel="noopener">Abrir</a>` : ""}
          ${podeLancar()
            ? html`<button type="button" class="botao-link pequeno" data-retirar="${a.id}">Tirar da ficha</button>`
            : ""}
        </div>
      </div>
    </li>
  `;
}

export function abaAnexos(p) {
  const lista = p.anexos ?? [];
  return html`
    <section class="cartao">
      <div class="linha"><h2>Exames e arquivos</h2>${podeLancar()
        ? html`<button type="button" class="botao botao-principal" data-anexar>+ Anexar exame</button>`
        : ""}</div>
      ${lista.length ? html`<ul class="anexos">${lista.map(itemAnexo)}</ul>` : html`
        <p
          class="vazio">Nenhum exame anexado ainda. Radiografia, tomografia, exame de sangue ou foto que o paciente trouxer: anexe aqui pelo celular, iPad ou computador.</p>
      `}
      <p class="suave pequeno" style="margin:12px 0 0">Os arquivos ficam guardados com o prontuário. Para abrir, toque no exame.</p>
    </section>
  `;
}

/** Liga os botões de anexar e de tirar da ficha da tela atual. */
export function ligarAnexos(raiz, p, depois) {
  raiz.querySelectorAll("[data-anexar]").forEach((b) =>
    b.addEventListener("click", () => anexarExame({ paciente: { id: p.id, nome: p.nome }, depois }))
  );
  raiz.querySelectorAll("[data-retirar]").forEach((b) =>
    b.addEventListener("click", () => {
      const anexo = (p.anexos ?? []).find((a) => a.id === b.dataset.retirar);
      if (anexo) retirarAnexo({ anexo, paciente: p, depois });
    })
  );
}
