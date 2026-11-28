// API do site do consultório: leituras e os lançamentos do site. Sem dependências
// do Deno nem do Supabase, para testar localmente (tests/painel_test.ts).
//
// POST {acao, parametros}.
// - Leituras: "Authorization: Bearer <token>" da conta dela no Supabase Auth,
//   com o segundo fator (aal2). Cada leitura passa por painel_autorizar, que
//   confere a sessão (até 30 dias, aberta depois da última senha) e registra
//   o acesso em painel_log. Os dados vêm de public.painel(acao, parametros).
// - Lançamentos: acao "gravar" com {tipo, dados}. Mesmo login; painel_gravar
//   confere a sessão e chama a mesma função do conector (pagamento, despesa,
//   estornos e estoque), com a solicitação marcada como vinda do site.
// - Exames e arquivos: acao "anexo_envio" devolve um link de envio para o
//   Storage (bucket privado, pasta anexos/<paciente>/); o navegador manda o
//   arquivo direto para lá e depois grava com "gravar" tipo "anexo". A API
//   confere no Storage que o arquivo chegou e manda o tamanho e o tipo reais.
// - Orçamento: "orcamento_novo" traz o catálogo e as campanhas; "gravar" tipo
//   "orcamento" monta pela mesma função do conector (mcp_montar_orcamento) e
//   tipo "orcamento_pdf" recebe o PDF que o navegador desenhou: a API confere
//   que é PDF, guarda no Storage no caminho que o banco escolhe e registra.
// - Convite: "x-acesso: <código>" do link que o Claude gera (acesso_ipad).
//   "convite" diz para qual e-mail ele vale; "criar_conta" gasta o convite e
//   cria a conta (ou troca a senha e apaga o segundo fator antigo).

export interface ContasAuth {
  /** Usuário dono do token, ou null se o token não vale mais. */
  usuario: (token: string) => Promise<{ id: string } | null>;
  /** Cria a conta já confirmada e devolve o id. */
  criarUsuario: (email: string, senha: string) => Promise<string>;
  trocarSenha: (usuarioId: string, senha: string) => Promise<void>;
  fatores: (usuarioId: string) => Promise<{ id: string }[]>;
  apagarFator: (usuarioId: string, fatorId: string) => Promise<void>;
}

export interface DependenciasPainel {
  rpc: (funcao: string, argumentos: Record<string, unknown>) => Promise<unknown>;
  auth: ContasAuth;
  /** Links temporários para arquivos do Storage (PDFs), num pedido só: caminho -> link. */
  assinar?: (caminhos: string[], segundos: number) => Promise<Record<string, string>>;
  /** Link de envio (uma vez) para um arquivo novo no Storage. */
  envio?: (caminho: string) => Promise<string>;
  /** Tamanho e tipo do arquivo que está no Storage, ou null se não chegou. */
  infoArquivo?: (caminho: string) => Promise<{ tamanho: number; tipo: string } | null>;
  /** Guarda um arquivo novo no Storage (sem sobrescrever). */
  salvar?: (caminho: string, bytes: Uint8Array, tipo: string) => Promise<void>;
}

export const ACOES = new Set([
  "inicio",
  "agenda",
  "pacientes",
  "paciente",
  "orcamentos",
  "orcamento_novo",
  "documentos",
  "estoque",
  "financeiro",
  "precos",
  "atividade",
  "configuracoes",
]);
const ACOES_CONVITE = new Set(["convite", "criar_conta"]);
export const LANCAMENTOS = new Set([
  "pagamento",
  "estornar_pagamento",
  "despesa",
  "estornar_despesa",
  "estoque",
  "anexo",
  "retirar_anexo",
  "orcamento",
  "orcamento_pdf",
]);
/** Arquivos aceitos na ficha: tipo -> extensão. Até 20 MB (o limite do bucket). */
export const TIPOS_ANEXO: Record<string, string> = {
  "application/pdf": "pdf",
  "image/jpeg": "jpg",
  "image/png": "png",
};
export const LIMITE_ANEXO = 20 * 1024 * 1024;
/** PDF do orçamento desenhado no navegador (o normal fica perto de 150 KB). */
export const LIMITE_PDF_ORCAMENTO = 8 * 1024 * 1024;
const LIMITE_LINKS = 400;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, x-acesso, authorization, apikey",
  "Access-Control-Max-Age": "86400",
};

export async function sha256Hex(texto: string): Promise<string> {
  return await sha256DosBytes(new TextEncoder().encode(texto));
}

async function sha256DosBytes(conteudo: Uint8Array): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", conteudo as Uint8Array<ArrayBuffer>));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

/** Lê as declarações do token (já conferido pelo Auth em deps.auth.usuario). */
export function declaracoesDoToken(token: string): Record<string, unknown> {
  try {
    const parte = token.split(".")[1] ?? "";
    const base64 = parte.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parte.length / 4) * 4, "=");
    const texto = new TextDecoder().decode(Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)));
    const dados = JSON.parse(texto);
    return dados && typeof dados === "object" ? dados : {};
  } catch (_) {
    return {};
  }
}

/** Senha do site: de 10 a 72 caracteres, sem ser uma repetição óbvia. */
export function problemaNaSenha(senha: unknown): string | null {
  if (typeof senha !== "string") return "Escolha uma senha.";
  if (senha.length < 10) return "A senha precisa ter pelo menos 10 caracteres.";
  if (new TextEncoder().encode(senha).length > 72) return "A senha pode ter no máximo 72 caracteres.";
  if (new Set(senha).size < 4) return "Essa senha é fácil demais de adivinhar. Misture letras e números.";
  if (/^(0123456789|1234567890|abcdefghij|qwertyuiop)/i.test(senha)) return "Essa senha é fácil demais de adivinhar.";
  return null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CAMINHO_ANEXO = /^anexos\/([0-9a-f-]{36})\/([0-9a-f-]{36})\.(pdf|jpg|png)$/;

/** Confere no Storage o arquivo do anexo e completa tamanho e tipo reais. */
async function prepararAnexo(dados: Record<string, unknown>, deps: DependenciasPainel) {
  const caminho = typeof dados.caminho === "string" ? dados.caminho : "";
  const m = caminho.match(CAMINHO_ANEXO);
  if (
    !m || m[1] !== String(dados.paciente_id ?? "").toLowerCase() || m[2] !== String(dados.anexo_id ?? "").toLowerCase()
  ) throw new Error("Arquivo do anexo inválido.");
  if (!deps.infoArquivo) throw new Error("Envio de arquivos indisponível.");
  const info = await deps.infoArquivo(caminho);
  if (!info) throw new Error("O arquivo não chegou. Tente enviar de novo.");
  if (TIPOS_ANEXO[info.tipo] !== m[3]) throw new Error("Esse tipo de arquivo não vale: use PDF, JPG ou PNG.");
  if (!(info.tamanho > 0) || info.tamanho > LIMITE_ANEXO) throw new Error("O arquivo passa de 20 MB.");
  return { ...dados, tamanho_bytes: info.tamanho, tipo_arquivo: info.tipo };
}

/** PDF em base64 que o site mandou: confere que é PDF e o tamanho. */
export function lerPdf(base64: unknown): Uint8Array {
  if (typeof base64 !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) {
    throw new Error("O PDF não chegou inteiro.");
  }
  if (base64.length > Math.ceil(LIMITE_PDF_ORCAMENTO / 3) * 4) throw new Error("O PDF ficou grande demais.");
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch (_) {
    throw new Error("O PDF não chegou inteiro.");
  }
  if (bytes.length < 200 || new TextDecoder().decode(bytes.subarray(0, 5)) !== "%PDF-") {
    throw new Error("O arquivo do orçamento não é um PDF.");
  }
  return bytes;
}

/**
 * Guarda o PDF do orçamento: confere a sessão, pede ao banco o caminho na pasta
 * do paciente, sobe para o Storage e registra (painel_gravar "orcamento_pdf").
 * O banco só recebe o caminho, o tamanho e o SHA-256 calculados aqui.
 */
async function guardarPdfOrcamento(
  dados: Record<string, unknown>,
  usuario: string,
  sessao: string | null,
  deps: DependenciasPainel,
): Promise<{ status: string } | Record<string, unknown>> {
  const id = typeof dados.orcamento_id === "string" && UUID.test(dados.orcamento_id)
    ? dados.orcamento_id.toLowerCase()
    : "";
  if (!id) throw new Error("Orçamento inválido.");
  const bytes = lerPdf(dados.pdf);
  if (!deps.salvar) throw new Error("Armazenamento indisponível.");
  const ok = await deps.rpc("painel_autorizar", {
    p_usuario: usuario,
    p_sessao: sessao,
    p_acao: "orcamento_pdf",
    p_paciente: null,
  });
  if (ok !== true) return { status: "sessao_expirada" };
  const caminho = await deps.rpc("painel_orcamento_caminho", { p_orcamento: id });
  if (typeof caminho !== "string" || !caminho) throw new Error("Orçamento não encontrado.");
  await deps.salvar(caminho, bytes, "application/pdf");
  return await deps.rpc("painel_gravar", {
    p_usuario: usuario,
    p_sessao: sessao,
    p_acao: "orcamento_pdf",
    p_dados: { orcamento_id: id, caminho, tamanho_bytes: bytes.length, sha256: await sha256DosBytes(bytes) },
  }) as Record<string, unknown>;
}

/** Troca cada {"arquivo": "caminho"} por um link temporário em "link" (um pedido só ao Storage). */
async function assinarArquivos(valor: unknown, deps: DependenciasPainel): Promise<unknown> {
  if (!deps.assinar) return valor;
  const caminhos = new Set<string>();
  const coletar = (v: unknown) => {
    if (Array.isArray(v)) v.forEach(coletar);
    else if (v && typeof v === "object") {
      const o = v as Record<string, unknown>;
      if (typeof o.arquivo === "string" && caminhos.size < LIMITE_LINKS) caminhos.add(o.arquivo);
      Object.values(o).forEach(coletar);
    }
  };
  coletar(valor);
  if (!caminhos.size) return valor;
  let links: Record<string, string> = {};
  try {
    links = await deps.assinar([...caminhos], 3600);
  } catch (_) {
    return valor; // sem link, o site mostra o documento sem o botão de abrir
  }
  const trocar = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(trocar);
    if (v && typeof v === "object") {
      const o: Record<string, unknown> = {};
      for (const [k, x] of Object.entries(v)) o[k] = trocar(x);
      if (typeof o.arquivo === "string" && links[o.arquivo]) o.link = links[o.arquivo];
      return o;
    }
    return v;
  };
  return trocar(valor);
}

async function convite(acao: string, codigo: string, parametros: Record<string, unknown>, deps: DependenciasPainel) {
  const usado = "Este link já foi usado ou venceu. Peça um novo ao Claude: “me manda o link do site”.";
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(codigo)) return json({ erro: usado }, 401);
  const hash = await sha256Hex(codigo);

  if (acao === "convite") {
    const info = await deps.rpc("painel_convite", { p_token_sha256: hash }) as Record<string, unknown> | null;
    if (!info) return json({ erro: usado }, 401);
    return json({ dados: { email: info.email ?? null, conta_existe: info.conta_existe === true } });
  }

  const problema = problemaNaSenha(parametros.senha);
  if (problema) return json({ erro: problema }, 400);
  const senha = parametros.senha as string;

  const info = await deps.rpc("painel_convite_usar", { p_token_sha256: hash }) as Record<string, unknown> | null;
  if (!info) return json({ erro: usado }, 401);
  const email = typeof info.email === "string" ? info.email : "";
  if (!email) return json({ erro: "Falta o e-mail do consultório no cadastro. Peça ao Claude para incluir." }, 400);

  let id = typeof info.usuario_id === "string" ? info.usuario_id : "";
  if (!id) {
    const existente = await deps.rpc("painel_usuario_por_email", { p_email: email });
    if (typeof existente === "string") id = existente;
  }
  if (id) {
    await deps.auth.trocarSenha(id, senha);
    for (const f of await deps.auth.fatores(id)) await deps.auth.apagarFator(id, f.id);
  } else {
    id = await deps.auth.criarUsuario(email, senha);
  }
  await deps.rpc("painel_conta_registrar", { p_usuario: id, p_email: email });
  return json({ dados: { email } });
}

export function criarHandlerPainel(deps: DependenciasPainel) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (req.method !== "POST") return json({ erro: "Use POST." }, 405);

    let pedido: { acao?: unknown; parametros?: unknown };
    try {
      pedido = await req.json();
    } catch (_) {
      return json({ erro: "Pedido inválido." }, 400);
    }
    const acao = typeof pedido?.acao === "string" ? pedido.acao : "";
    const parametros =
      (pedido?.parametros && typeof pedido.parametros === "object" && !Array.isArray(pedido.parametros)
        ? pedido.parametros
        : {}) as Record<string, unknown>;

    try {
      if (ACOES_CONVITE.has(acao)) return await convite(acao, req.headers.get("x-acesso") ?? "", parametros, deps);
      const gravar = acao === "gravar";
      const envio = acao === "anexo_envio";
      if (!ACOES.has(acao) && !gravar && !envio) return json({ erro: "Ação desconhecida." }, 400);
      const tipo = typeof parametros.tipo === "string" ? parametros.tipo : "";
      const lancamento = parametros.dados && typeof parametros.dados === "object" && !Array.isArray(parametros.dados)
        ? parametros.dados
        : null;
      if (gravar && (!LANCAMENTOS.has(tipo) || !lancamento)) return json({ erro: "Lançamento desconhecido." }, 400);

      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
      const sair = { erro: "Sua sessão terminou. Entre de novo com e-mail, senha e código.", sessao: "expirada" };
      if (!token || token.split(".").length !== 3) return json(sair, 401);
      const usuario = await deps.auth.usuario(token);
      if (!usuario) return json(sair, 401);
      const d = declaracoesDoToken(token);
      if (d.aal !== "aal2") return json({ erro: "Falta o código de dois fatores.", precisa_codigo: true }, 403);
      const sessao = typeof d.session_id === "string" ? d.session_id : null;

      if (gravar) {
        if (tipo === "orcamento_pdf") {
          const r = await guardarPdfOrcamento(lancamento as Record<string, unknown>, usuario.id, sessao, deps);
          if (r?.status === "sessao_expirada") return json(sair, 401);
          return json({ dados: r });
        }
        const dados = tipo === "anexo" ? await prepararAnexo(lancamento as Record<string, unknown>, deps) : lancamento;
        const r = await deps.rpc("painel_gravar", {
          p_usuario: usuario.id,
          p_sessao: sessao,
          p_acao: tipo,
          p_dados: dados,
        });
        if ((r as { status?: string } | null)?.status === "sessao_expirada") return json(sair, 401);
        // o documento (caminho e dados do PDF do conector) não vai para o navegador
        if (tipo === "orcamento" && r && typeof r === "object") delete (r as Record<string, unknown>).documento;
        return json({ dados: r });
      }
      if (envio) {
        const pac = typeof parametros.paciente_id === "string" && UUID.test(parametros.paciente_id)
          ? parametros.paciente_id.toLowerCase()
          : "";
        const ext = TIPOS_ANEXO[String(parametros.tipo_arquivo ?? "")];
        const tamanho = Number(parametros.tamanho);
        if (!pac) return json({ erro: "Escolha o paciente." }, 400);
        if (!ext) return json({ erro: "Esse tipo de arquivo não vale: use PDF, JPG ou PNG." }, 400);
        if (!(tamanho > 0) || tamanho > LIMITE_ANEXO) return json({ erro: "O arquivo passa de 20 MB." }, 400);
        if (!deps.envio) return json({ erro: "Envio de arquivos indisponível." }, 404);
        const ok = await deps.rpc("painel_autorizar", {
          p_usuario: usuario.id,
          p_sessao: sessao,
          p_acao: "anexo_envio",
          p_paciente: pac,
        });
        if (ok !== true) return json(sair, 401);
        const id = crypto.randomUUID();
        const caminho = `anexos/${pac}/${id}.${ext}`;
        return json({ dados: { anexo_id: id, caminho, url: await deps.envio(caminho) } });
      }
      const idPaciente = acao === "paciente"
        ? parametros.id
        : acao === "orcamento_novo"
        ? parametros.paciente_id
        : null;
      const paciente = typeof idPaciente === "string" && UUID.test(idPaciente) ? idPaciente : null;
      const autorizado = await deps.rpc("painel_autorizar", {
        p_usuario: usuario.id,
        p_sessao: sessao,
        p_acao: acao,
        p_paciente: paciente,
      });
      if (autorizado !== true) return json(sair, 401);

      // Ajustes mostram a conta de quem está vendo: o id vem do login, nunca do pedido.
      const params = acao === "configuracoes" ? { ...parametros, usuario_id: usuario.id } : parametros;
      const dados = await deps.rpc("painel", { p_acao: acao, p_params: params });
      if (dados === null) return json({ erro: "Ação ainda não disponível." }, 404);
      return json({ dados: await assinarArquivos(dados, deps) });
    } catch (e) {
      console.error(`painel ${acao}: ${e instanceof Error ? e.message : String(e)}`);
      return json({ erro: e instanceof Error ? e.message : String(e) }, 400);
    }
  };
}
