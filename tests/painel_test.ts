// deno-lint-ignore-file no-explicit-any
// Testes da API do site do consultório (sem banco nem Auth de verdade).

import { criarHandlerPainel, lerPdf, problemaNaSenha, sha256Hex } from "../supabase/functions/painel/handler.ts";
import { igual, verdade } from "./util.ts";

const CONVITE = "conviteDoSite_0123456789abcdefghijklmnopqr";
const USUARIO = "11111111-1111-4111-8111-111111111111";
const SESSAO = "22222222-2222-4222-8222-222222222222";
const PACIENTE = "33333333-3333-4333-8333-333333333333";

function tokenFalso(declaracoes: Record<string, unknown>): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${b64({ alg: "ES256" })}.${b64(declaracoes)}.assinatura`;
}
const TOKEN_OK = tokenFalso({ sub: USUARIO, aal: "aal2", session_id: SESSAO });
const TOKEN_SEM_2FA = tokenFalso({ sub: USUARIO, aal: "aal1", session_id: SESSAO });

interface Opcoes {
  dados?: unknown;
  conta?: { usuario_id?: string } | null; // resultado de painel_convite_usar (null = convite inválido)
  sessaoValida?: boolean;
  emailExistente?: string | null;
  fatores?: { id: string }[];
  arquivo?: { tamanho: number; tipo: string } | null; // o que o Storage diz do anexo enviado
  caminhoPdf?: string | null; // o que painel_orcamento_caminho devolve
}

async function montar(op: Opcoes = {}) {
  const hashConvite = await sha256Hex(CONVITE);
  const chamadas: any[] = [];
  const auth: any[] = [];
  const salvos: any[] = [];
  const handler = criarHandlerPainel({
    rpc: (funcao, args) => {
      chamadas.push({ funcao, args });
      if (funcao === "painel_convite") {
        return Promise.resolve(
          args.p_token_sha256 === hashConvite
            ? { acesso_id: "a1", email: "dra@exemplo.com", conta_existe: false }
            : null,
        );
      }
      if (funcao === "painel_convite_usar") {
        if (args.p_token_sha256 !== hashConvite || op.conta === null) return Promise.resolve(null);
        return Promise.resolve({ acesso_id: "a1", email: "dra@exemplo.com", ...(op.conta ?? {}) });
      }
      if (funcao === "painel_usuario_por_email") return Promise.resolve(op.emailExistente ?? null);
      if (funcao === "painel_conta_registrar") return Promise.resolve(null);
      if (funcao === "painel_autorizar") return Promise.resolve(op.sessaoValida ?? true);
      if (funcao === "painel_orcamento_caminho") {
        return Promise.resolve(
          op.caminhoPdf === undefined ? `${PACIENTE}/orcamento-7-20261125-020000-ab12.pdf` : op.caminhoPdf,
        );
      }
      return Promise.resolve(op.dados === undefined ? { ok: true } : op.dados);
    },
    auth: {
      usuario: (token) => Promise.resolve(token.endsWith(".assinatura") ? { id: USUARIO } : null),
      criarUsuario: (email, senha) => {
        auth.push({ criar: email, senha });
        return Promise.resolve("novo-usuario");
      },
      trocarSenha: (id, senha) => {
        auth.push({ trocar: id, senha });
        return Promise.resolve();
      },
      fatores: () => Promise.resolve(op.fatores ?? []),
      apagarFator: (id, fator) => {
        auth.push({ apagar: fator, de: id });
        return Promise.resolve();
      },
    },
    assinar: (caminhos) => Promise.resolve(Object.fromEntries(caminhos.map((c) => [c, `https://assinado/${c}`]))),
    envio: (caminho) => Promise.resolve(`https://envio/${caminho}?token=t`),
    infoArquivo: () => Promise.resolve(op.arquivo === undefined ? { tamanho: 1000, tipo: "image/jpeg" } : op.arquivo),
    salvar: (caminho, bytes, tipo) => {
      salvos.push({ caminho, tamanho: bytes.length, tipo });
      return Promise.resolve();
    },
  });
  const pedir = async (corpo: unknown, cabecalhos: Record<string, string> = {}, method = "POST") => {
    const res = await handler(
      new Request("https://x/functions/v1/painel", {
        method,
        headers: { "content-type": "application/json", ...cabecalhos },
        body: method === "POST" ? JSON.stringify(corpo) : undefined,
      }),
    );
    return {
      status: res.status,
      corpo: await res.json().catch(() => null),
      cors: res.headers.get("access-control-allow-origin"),
    };
  };
  const comLogin = (token = TOKEN_OK) => ({ authorization: `Bearer ${token}` });
  return { chamadas, auth, salvos, pedir, handler, comLogin };
}

Deno.test("painel: sem login dá 401 e não lê nada", async () => {
  const { pedir, chamadas } = await montar();
  igual((await pedir({ acao: "inicio" })).status, 401);
  igual((await pedir({ acao: "inicio" }, { authorization: "Bearer lixo" })).status, 401);
  igual((await pedir({ acao: "inicio" }, { authorization: "Bearer a.b.outra" })).status, 401);
  igual(chamadas.length, 0);
});

Deno.test("painel: o código antigo do iPad não abre mais os dados", async () => {
  const { pedir, chamadas } = await montar();
  const r = await pedir({ acao: "inicio" }, { "x-acesso": CONVITE });
  igual(r.status, 401);
  igual(chamadas.length, 0);
});

Deno.test("painel: sem o segundo fator pede o código e não lê", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  const r = await pedir({ acao: "inicio" }, comLogin(TOKEN_SEM_2FA));
  igual(r.status, 403);
  igual(r.corpo.precisa_codigo, true);
  igual(chamadas.length, 0);
});

Deno.test("painel: sessão vencida ou de antes da senha nova dá 401", async () => {
  const { pedir, chamadas, comLogin } = await montar({ sessaoValida: false });
  const r = await pedir({ acao: "inicio" }, comLogin());
  igual(r.status, 401);
  igual(r.corpo.sessao, "expirada");
  igual(chamadas.map((c) => c.funcao), ["painel_autorizar"]);
});

Deno.test("painel: com login, confere a sessão, registra o paciente aberto e assina os PDFs", async () => {
  const { pedir, chamadas, comLogin } = await montar({
    dados: {
      documentos: [{ titulo: "Receita", arquivo: "p1/receita.pdf" }, { titulo: "Outra", arquivo: "p1/receita.pdf" }],
    },
  });
  const r = await pedir({ acao: "paciente", parametros: { id: PACIENTE } }, comLogin());
  igual(r.status, 200);
  igual(r.cors, "*");
  igual(chamadas[0], {
    funcao: "painel_autorizar",
    args: { p_usuario: USUARIO, p_sessao: SESSAO, p_acao: "paciente", p_paciente: PACIENTE },
  });
  igual(chamadas[1], { funcao: "painel", args: { p_acao: "paciente", p_params: { id: PACIENTE } } });
  igual(r.corpo.dados.documentos[0].link, "https://assinado/p1/receita.pdf");
  igual(r.corpo.dados.documentos[1].link, "https://assinado/p1/receita.pdf");
});

Deno.test("painel: ações novas passam; fora da lista é recusada antes do banco", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  for (const acao of ["orcamentos", "documentos", "precos", "atividade", "configuracoes"]) {
    igual((await pedir({ acao }, comLogin())).status, 200, acao);
  }
  const antes = chamadas.length;
  igual((await pedir({ acao: "mcp_cadastrar_paciente" }, comLogin())).status, 400);
  igual(chamadas.length, antes);
});

Deno.test("painel: ação sem leitura no banco dá 404", async () => {
  const { pedir, comLogin } = await montar({ dados: null });
  igual((await pedir({ acao: "estoque" }, comLogin())).status, 404);
});

Deno.test("painel: preflight CORS e só POST", async () => {
  const { handler, pedir } = await montar();
  const res = await handler(new Request("https://x/painel", { method: "OPTIONS" }));
  igual(res.status, 204);
  verdade(res.headers.get("access-control-allow-headers")?.includes("authorization"), "CORS sem authorization");
  igual((await pedir(null, {}, "GET")).status, 405);
});

Deno.test("convite: diz o e-mail sem gastar o link; link errado dá 401", async () => {
  const { pedir, chamadas } = await montar();
  const r = await pedir({ acao: "convite" }, { "x-acesso": CONVITE });
  igual(r.status, 200);
  igual(r.corpo.dados, { email: "dra@exemplo.com", conta_existe: false });
  igual(chamadas.map((c) => c.funcao), ["painel_convite"]);
  igual((await pedir({ acao: "convite" }, { "x-acesso": "conviteErrado_0123456789abcdefghijklmnopqr" })).status, 401);
  igual((await pedir({ acao: "convite" }, { "x-acesso": "curto" })).status, 401);
});

Deno.test("convite: senha fraca é recusada antes de gastar o link", async () => {
  const { pedir, chamadas } = await montar();
  const r = await pedir({ acao: "criar_conta", parametros: { senha: "123" } }, { "x-acesso": CONVITE });
  igual(r.status, 400);
  igual(chamadas.length, 0);
  igual(problemaNaSenha("aaaaaaaaaaaa") !== null, true);
  igual(problemaNaSenha("Moema1673-sorriso"), null);
});

Deno.test("convite: primeira vez cria a conta e registra", async () => {
  const { pedir, chamadas, auth } = await montar();
  const r = await pedir({ acao: "criar_conta", parametros: { senha: "Moema1673-sorriso" } }, { "x-acesso": CONVITE });
  igual(r.status, 200);
  igual(r.corpo.dados, { email: "dra@exemplo.com" });
  igual(auth, [{ criar: "dra@exemplo.com", senha: "Moema1673-sorriso" }]);
  igual(chamadas.map((c) => c.funcao), ["painel_convite_usar", "painel_usuario_por_email", "painel_conta_registrar"]);
  igual(chamadas[2].args, { p_usuario: "novo-usuario", p_email: "dra@exemplo.com" });
});

Deno.test("convite: com conta, troca a senha e apaga o segundo fator antigo", async () => {
  const { pedir, auth } = await montar({ conta: { usuario_id: USUARIO }, fatores: [{ id: "f1" }, { id: "f2" }] });
  const r = await pedir({ acao: "criar_conta", parametros: { senha: "Moema1673-sorriso" } }, { "x-acesso": CONVITE });
  igual(r.status, 200);
  igual(auth, [
    { trocar: USUARIO, senha: "Moema1673-sorriso" },
    { apagar: "f1", de: USUARIO },
    { apagar: "f2", de: USUARIO },
  ]);
});

Deno.test("convite: conta que já existia no Auth é reaproveitada", async () => {
  const { pedir, auth } = await montar({ emailExistente: USUARIO });
  igual(
    (await pedir({ acao: "criar_conta", parametros: { senha: "Moema1673-sorriso" } }, { "x-acesso": CONVITE })).status,
    200,
  );
  igual(auth[0], { trocar: USUARIO, senha: "Moema1673-sorriso" });
});

Deno.test("convite: link já usado não cria nada", async () => {
  const { pedir, auth } = await montar({ conta: null });
  const r = await pedir({ acao: "criar_conta", parametros: { senha: "Moema1673-sorriso" } }, { "x-acesso": CONVITE });
  igual(r.status, 401);
  igual(auth.length, 0);
});

Deno.test("gravar: manda o lançamento para painel_gravar com a sessão, sem chamar painel_autorizar à parte", async () => {
  const { pedir, chamadas, comLogin } = await montar({ dados: { status: "ok", avisos: [] } });
  const dados = { paciente_id: PACIENTE, valor: 300, forma: "pix", texto_original: "Pelo site: R$ 300 no Pix" };
  const r = await pedir({ acao: "gravar", parametros: { tipo: "pagamento", dados } }, comLogin());
  igual(r.status, 200);
  igual(chamadas, [{
    funcao: "painel_gravar",
    args: { p_usuario: USUARIO, p_sessao: SESSAO, p_acao: "pagamento", p_dados: dados },
  }]);
});

Deno.test("gravar: tipo fora da lista ou sem dados é recusado antes do banco", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  igual((await pedir({ acao: "gravar", parametros: { tipo: "apagar_paciente", dados: {} } }, comLogin())).status, 400);
  igual((await pedir({ acao: "gravar", parametros: { tipo: "despesa" } }, comLogin())).status, 400);
  igual(chamadas.length, 0);
});

Deno.test("gravar: sem login ou sem o código não grava", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  const corpo = { acao: "gravar", parametros: { tipo: "despesa", dados: { valor: 10 } } };
  igual((await pedir(corpo)).status, 401);
  igual((await pedir(corpo, comLogin(TOKEN_SEM_2FA))).status, 403);
  igual(chamadas.length, 0);
});

Deno.test("gravar: sessão vencida no banco vira 401", async () => {
  const { pedir, comLogin } = await montar({ dados: { status: "sessao_expirada" } });
  const r = await pedir({ acao: "gravar", parametros: { tipo: "despesa", dados: { valor: 10 } } }, comLogin());
  igual(r.status, 401);
  igual(r.corpo.sessao, "expirada");
});

Deno.test("anexo: o link de envio confere a sessão e o paciente e monta a pasta do paciente", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  const r = await pedir({
    acao: "anexo_envio",
    parametros: { paciente_id: PACIENTE, tipo_arquivo: "image/jpeg", tamanho: 2_000_000 },
  }, comLogin());
  igual(r.status, 200);
  const { anexo_id, caminho, url } = r.corpo.dados;
  igual(caminho, `anexos/${PACIENTE}/${anexo_id}.jpg`);
  igual(url, `https://envio/${caminho}?token=t`);
  igual(chamadas, [{
    funcao: "painel_autorizar",
    args: { p_usuario: USUARIO, p_sessao: SESSAO, p_acao: "anexo_envio", p_paciente: PACIENTE },
  }]);
});

Deno.test("anexo: tipo, tamanho e paciente errados são recusados antes do Storage", async () => {
  const { pedir, chamadas, comLogin } = await montar();
  const base = { paciente_id: PACIENTE, tipo_arquivo: "image/jpeg", tamanho: 1000 };
  const p = (x: Record<string, unknown>) => pedir({ acao: "anexo_envio", parametros: { ...base, ...x } }, comLogin());
  igual((await p({ tipo_arquivo: "image/heic" })).status, 400);
  igual((await p({ tipo_arquivo: "text/html" })).status, 400);
  igual((await p({ tamanho: 21 * 1024 * 1024 })).status, 400);
  igual((await p({ tamanho: 0 })).status, 400);
  igual((await p({ paciente_id: "../outro" })).status, 400);
  igual((await pedir({ acao: "anexo_envio", parametros: base })).status, 401);
  igual(chamadas.length, 0);
});

Deno.test("anexo: gravar usa o tamanho e o tipo reais do Storage", async () => {
  const { pedir, chamadas, comLogin } = await montar({
    dados: { status: "ok" },
    arquivo: { tamanho: 54321, tipo: "application/pdf" },
  });
  const id = "44444444-4444-4444-8444-444444444444";
  const dados = {
    anexo_id: id,
    paciente_id: PACIENTE,
    caminho: `anexos/${PACIENTE}/${id}.pdf`,
    tipo: "laudo",
    tamanho_bytes: 1,
    tipo_arquivo: "image/png",
  };
  const r = await pedir({ acao: "gravar", parametros: { tipo: "anexo", dados } }, comLogin());
  igual(r.status, 200);
  igual(chamadas[0].args.p_dados.tamanho_bytes, 54321);
  igual(chamadas[0].args.p_dados.tipo_arquivo, "application/pdf");
});

Deno.test("anexo: arquivo que não chegou, de outro paciente ou de outro tipo não grava", async () => {
  const id = "44444444-4444-4444-8444-444444444444";
  const dados = { anexo_id: id, paciente_id: PACIENTE, caminho: `anexos/${PACIENTE}/${id}.jpg` };
  const corpo = (d: Record<string, unknown>) => ({ acao: "gravar", parametros: { tipo: "anexo", dados: d } });

  let m = await montar({ arquivo: null });
  let r = await m.pedir(corpo(dados), m.comLogin());
  igual(r.status, 400);
  verdade(r.corpo.erro.includes("não chegou"), "explica que o arquivo não chegou");
  igual(m.chamadas.length, 0);

  m = await montar();
  r = await m.pedir(corpo({ ...dados, paciente_id: "55555555-5555-4555-8555-555555555555" }), m.comLogin());
  igual(r.status, 400);
  igual(m.chamadas.length, 0);

  m = await montar({ arquivo: { tamanho: 10, tipo: "text/html" } });
  r = await m.pedir(corpo(dados), m.comLogin());
  igual(r.status, 400);
  igual(m.chamadas.length, 0);
});

// ------------------------------------------------------------------
// Orçamento pelo site
// ------------------------------------------------------------------
const ORCAMENTO = "66666666-6666-4666-8666-666666666666";
const PDF_FALSO = new TextEncoder().encode("%PDF-1.3\n" + "x".repeat(400) + "\n%%EOF");
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

Deno.test("orçamento: o formulário lê o catálogo e registra o paciente aberto", async () => {
  const { pedir, chamadas, comLogin } = await montar({ dados: { procedimentos: [] } });
  const r = await pedir({ acao: "orcamento_novo", parametros: { paciente_id: PACIENTE } }, comLogin());
  igual(r.status, 200);
  igual(chamadas[0].args, { p_usuario: USUARIO, p_sessao: SESSAO, p_acao: "orcamento_novo", p_paciente: PACIENTE });
  igual(chamadas[1], { funcao: "painel", args: { p_acao: "orcamento_novo", p_params: { paciente_id: PACIENTE } } });
});

Deno.test("orçamento: gravar vai para painel_gravar e o documento do conector não volta ao navegador", async () => {
  const { pedir, chamadas, comLogin } = await montar({
    dados: {
      status: "ok",
      orcamento: { id: ORCAMENTO, numero: 7 },
      documento: { caminho: "x", dados: {} },
      avisos: [],
    },
  });
  const dados = {
    paciente_id: PACIENTE,
    itens: [{ procedimento_codigo: "resina_2_faces", dente: 36 }],
    apresentar: true,
  };
  const r = await pedir({ acao: "gravar", parametros: { tipo: "orcamento", dados } }, comLogin());
  igual(r.status, 200);
  igual(chamadas, [{
    funcao: "painel_gravar",
    args: { p_usuario: USUARIO, p_sessao: SESSAO, p_acao: "orcamento", p_dados: dados },
  }]);
  igual(r.corpo.dados.orcamento.numero, 7);
  igual("documento" in r.corpo.dados, false);
});

Deno.test("orçamento: o PDF é guardado no caminho do banco e registrado com tamanho e SHA-256 daqui", async () => {
  const { pedir, chamadas, salvos, comLogin } = await montar({ dados: { status: "ok", documento_id: "d1" } });
  const dados = { orcamento_id: ORCAMENTO, pdf: base64(PDF_FALSO), caminho: "outro/lugar.pdf", sha256: "0".repeat(64) };
  const r = await pedir({ acao: "gravar", parametros: { tipo: "orcamento_pdf", dados } }, comLogin());
  igual(r.status, 200);
  const caminho = `${PACIENTE}/orcamento-7-20261125-020000-ab12.pdf`;
  igual(chamadas.map((c) => c.funcao), ["painel_autorizar", "painel_orcamento_caminho", "painel_gravar"]);
  igual(chamadas[0].args.p_acao, "orcamento_pdf");
  igual(chamadas[1].args, { p_orcamento: ORCAMENTO });
  igual(salvos, [{ caminho, tamanho: PDF_FALSO.length, tipo: "application/pdf" }]);
  const gravado = chamadas[2].args;
  igual(gravado.p_acao, "orcamento_pdf");
  igual(gravado.p_dados.caminho, caminho);
  igual(gravado.p_dados.tamanho_bytes, PDF_FALSO.length);
  igual(
    gravado.p_dados.sha256,
    Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", PDF_FALSO)),
      (b) => b.toString(16).padStart(2, "0"),
    ).join(""),
  );
  igual("pdf" in gravado.p_dados, false);
});

Deno.test("orçamento: arquivo que não é PDF, base64 quebrado ou orçamento inválido não chega ao Storage", async () => {
  const { pedir, chamadas, salvos, comLogin } = await montar();
  const p = (dados: Record<string, unknown>) =>
    pedir({ acao: "gravar", parametros: { tipo: "orcamento_pdf", dados } }, comLogin());
  igual(
    (await p({ orcamento_id: ORCAMENTO, pdf: base64(new TextEncoder().encode("<html>" + "x".repeat(300))) })).status,
    400,
  );
  igual((await p({ orcamento_id: ORCAMENTO, pdf: "não é base64!" })).status, 400);
  igual((await p({ orcamento_id: ORCAMENTO })).status, 400);
  igual((await p({ orcamento_id: "../x", pdf: base64(PDF_FALSO) })).status, 400);
  igual(chamadas.length, 0);
  igual(salvos.length, 0);
  let erro: unknown = null;
  try {
    lerPdf("A".repeat(12 * 1024 * 1024));
  } catch (e) {
    erro = e;
  }
  verdade(String(erro).includes("grande"), "PDF grande demais é recusado");
});

Deno.test("orçamento: sessão vencida não guarda o PDF", async () => {
  const { pedir, chamadas, salvos, comLogin } = await montar({ sessaoValida: false });
  const r = await pedir({
    acao: "gravar",
    parametros: { tipo: "orcamento_pdf", dados: { orcamento_id: ORCAMENTO, pdf: base64(PDF_FALSO) } },
  }, comLogin());
  igual(r.status, 401);
  igual(chamadas.map((c) => c.funcao), ["painel_autorizar"]);
  igual(salvos.length, 0);
});

Deno.test("orçamento: orçamento que não existe não guarda nada", async () => {
  const { pedir, salvos, comLogin } = await montar({ caminhoPdf: null });
  const r = await pedir({
    acao: "gravar",
    parametros: { tipo: "orcamento_pdf", dados: { orcamento_id: ORCAMENTO, pdf: base64(PDF_FALSO) } },
  }, comLogin());
  igual(r.status, 400);
  igual(salvos.length, 0);
});
