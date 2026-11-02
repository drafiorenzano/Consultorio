// deno-lint-ignore-file no-explicit-any
// Testes locais do servidor MCP, sem banco: o `rpc` é falso e só registra
// as chamadas. Rodar com:
//   deno test --allow-read --config supabase/functions/mcp/deno.json tests/

import { ErroRpc, tokenDaUrl } from "../supabase/functions/mcp/servidor.ts";
import { BASE, igual, INIT, montar, TOKEN, verdade } from "./util.ts";

Deno.test("token: extrai da URL e recusa formatos estranhos", () => {
  igual(tokenDaUrl(`${BASE}/${TOKEN}`), TOKEN);
  igual(tokenDaUrl(`https://x/mcp/${TOKEN}`), TOKEN);
  igual(tokenDaUrl(`${BASE}`), null);
  igual(tokenDaUrl(`${BASE}/curto`), null);
  igual(tokenDaUrl(`${BASE}/${TOKEN}%27or1=1`), null);
});

Deno.test("sem token válido: 404 e nenhuma chamada ao banco de dados clínico", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("initialize", INIT, "tokenErrado_0123456789abcdefghijklmnopqrstuvwx");
  igual(r.status, 404);
  igual(chamadas.length, 0);
});

Deno.test("GET devolve 405 (servidor stateless, só POST)", async () => {
  const { handler } = await montar();
  const res = await handler(new Request(`${BASE}/${TOKEN}`, { method: "GET" }));
  igual(res.status, 405);
});

Deno.test("initialize traz nome, versão e instruções em português", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", INIT);
  igual(r.status, 200);
  const res = (r.corpo as any).result;
  igual(res.serverInfo.name, "consultorio");
  verdade(res.instructions.includes("texto_original"), "instruções sem texto_original");
  verdade(res.capabilities.tools, "sem capacidade de ferramentas");
});

Deno.test("tools/list: ferramentas do prontuário, leitura x gravação, nenhuma destrutiva", async () => {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  const tools = (r.corpo as any).result.tools as any[];
  const nomes = tools.map((t) => t.name);
  igual(new Set(nomes).size, nomes.length, "nomes repetidos");
  const base = [
    "atualizar_paciente",
    "buscar_paciente",
    "cadastrar_paciente",
    "listar_procedimentos",
    "registrar_anamnese",
    "registrar_atendimento",
    "registrar_odontograma",
    "salvar_procedimento",
  ];
  for (const n of base) verdade(nomes.includes(n), `falta ${n}`);
  for (const t of tools) verdade(t.description && t.annotations, `${t.name} sem descrição ou anotações`);
  const porNome = Object.fromEntries(tools.map((t) => [t.name, t]));
  for (const t of tools) igual(t.annotations.destructiveHint, false, `${t.name} destrutiva`);
  igual(porNome.buscar_paciente.annotations.readOnlyHint, true);
  igual(porNome.listar_procedimentos.annotations.readOnlyHint, true);
  igual(porNome.cadastrar_paciente.annotations.readOnlyHint, false);
  igual(porNome.registrar_atendimento.inputSchema.required.sort(), ["evolucao", "paciente_id", "texto_original"]);
  igual(porNome.cadastrar_paciente.inputSchema.required.sort(), ["nome", "texto_original"]);
  igual(porNome.atualizar_paciente.inputSchema.required.sort(), ["paciente_id", "texto_original"]);
  igual(porNome.registrar_odontograma.inputSchema.required.sort(), ["marcas", "paciente_id", "texto_original"]);
});

Deno.test("catálogos: perguntas e condições vêm do JSON e aparecem nas descrições", async () => {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  const porNome = Object.fromEntries(((r.corpo as any).result.tools as any[]).map((t) => [t.name, t]));
  const anamnese = porNome.registrar_anamnese;
  const codigos = anamnese.inputSchema.properties.respostas.items.properties.pergunta.enum as string[];
  verdade(codigos.includes("anticoagulante") && codigos.includes("bisfosfonato"), "faltam perguntas de risco");
  igual(codigos.length, 47);
  verdade(anamnese.description.includes("gestacao: Está grávida"), "descrição sem a lista de perguntas");
  const odonto = porNome.registrar_odontograma;
  const cond = odonto.inputSchema.properties.marcas.items.properties.condicao.enum as string[];
  verdade(cond.includes("carie") && cond.includes("ausente") && cond.includes("implante"), "faltam condições");
  verdade(odonto.description.includes("restauracao (com faces)"), "descrição sem as condições");
  verdade(
    !JSON.stringify(odonto.inputSchema.properties.marcas.items.properties.regiao.enum).includes("boca"),
    "região do odontograma não deve aceitar boca",
  );
});

Deno.test("buscar_paciente repassa os argumentos para mcp_buscar_paciente", async () => {
  const { mcp, chamadas } = await montar({
    mcp_buscar_paciente: () => ({ encontrados: 1, paciente: { nome: "Mariana" } }),
  });
  const r = await mcp("tools/call", {
    name: "buscar_paciente",
    arguments: { busca: "Mari", texto_original: "abre a Mari" },
  });
  const res = (r.corpo as any).result;
  igual(res.isError, undefined);
  verdade(res.content[0].text.includes("Mariana"), "resposta sem o paciente");
  igual(chamadas.at(-1), {
    funcao: "mcp_buscar_paciente",
    args: { p_busca: "Mari", p_paciente_id: null, p_texto_original: "abre a Mari", p_incluir_arquivados: false },
  });
});

Deno.test("cadastrar_paciente separa dados, texto original e confirmação de homônimo", async () => {
  const { mcp, chamadas } = await montar({ mcp_cadastrar_paciente: () => ({ status: "ok" }) });
  await mcp("tools/call", {
    name: "cadastrar_paciente",
    arguments: {
      nome: "Ana Paula Souza",
      cpf: "116.000.345-94",
      alertas_saude: [{ tipo: "alergia", descricao: "alergia a dipirona" }],
      texto_original: "paciente nova Ana Paula Souza, alérgica a dipirona",
    },
  });
  const c = chamadas.at(-1)!;
  igual(c.funcao, "mcp_cadastrar_paciente");
  igual(c.args.p_texto_original, "paciente nova Ana Paula Souza, alérgica a dipirona");
  igual(c.args.p_confirmar_homonimo, false);
  igual((c.args.p_dados as any).nome, "Ana Paula Souza");
  igual("texto_original" in (c.args.p_dados as any), false, "texto_original vazou para p_dados");
});

Deno.test("argumento inválido (dente como texto) é recusado antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("tools/call", {
    name: "registrar_atendimento",
    arguments: {
      paciente_id: "x",
      evolucao: "Restauração",
      texto_original: "t",
      procedimentos: [{ procedimento: "resina", dente: "trinta e seis" }],
    },
  });
  const res = (r.corpo as any).result ?? (r.corpo as any).error;
  verdade(res.isError === true || (r.corpo as any).error, "deveria recusar dente não numérico");
  igual(chamadas.filter((c) => c.funcao === "mcp_registrar_atendimento").length, 0);
});

Deno.test("erro do banco vira isError, com 'Nada foi gravado' e registro da falha", async () => {
  const { mcp, chamadas } = await montar({
    mcp_registrar_atendimento: () => {
      throw new ErroRpc("Dente 19 não existe na numeração FDI.");
    },
  });
  const r = await mcp("tools/call", {
    name: "registrar_atendimento",
    arguments: {
      paciente_id: "abc",
      evolucao: "Restauração no 19",
      texto_original: "fiz resina no 19",
      procedimentos: [{ procedimento: "resina", dente: 19, faces: "O" }],
    },
  });
  const res = (r.corpo as any).result;
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("Nada foi gravado."), res.content[0].text);
  verdade(res.content[0].text.includes("Dente 19"), "mensagem do banco não repassada");
  const falha = chamadas.find((c) => c.funcao === "mcp_registrar_falha");
  verdade(falha, "falha não registrada");
  igual(falha!.args.p_texto_original, "fiz resina no 19");
});

Deno.test("atualizar_paciente separa o id dos dados", async () => {
  const { mcp, chamadas } = await montar({ mcp_atualizar_paciente: () => ({ status: "ok" }) });
  await mcp("tools/call", {
    name: "atualizar_paciente",
    arguments: {
      paciente_id: "p1",
      email: "a@b.com",
      alertas_remover: ["dipirona"],
      limpar: ["rg"],
      texto_original: "troca o e-mail da Mari",
    },
  });
  igual(chamadas.at(-1), {
    funcao: "mcp_atualizar_paciente",
    args: {
      p_paciente_id: "p1",
      p_dados: { email: "a@b.com", alertas_remover: ["dipirona"], limpar: ["rg"] },
      p_texto_original: "troca o e-mail da Mari",
    },
  });
});

Deno.test("registrar_anamnese recusa pergunta fora do questionário antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("tools/call", {
    name: "registrar_anamnese",
    arguments: {
      paciente_id: "p1",
      respostas: [{ pergunta: "signo", resposta: "leão" }],
      texto_original: "t",
    },
  });
  const res = (r.corpo as any).result ?? (r.corpo as any).error;
  verdade(res.isError === true || (r.corpo as any).error, "deveria recusar pergunta inexistente");
  igual(chamadas.filter((c) => c.funcao === "mcp_registrar_anamnese").length, 0);
});

Deno.test("registrar_anamnese e odontograma mandam os dados inteiros em p_dados", async () => {
  const { mcp, chamadas } = await montar({
    mcp_registrar_anamnese: () => ({ status: "ok" }),
    mcp_registrar_odontograma: () => ({ status: "ok" }),
  });
  await mcp("tools/call", {
    name: "registrar_anamnese",
    arguments: {
      paciente_id: "p1",
      respostas: [{ pergunta: "alergia_latex", resposta: "sim" }],
      demais_negativas: true,
      pressao_arterial: "12 por 8",
      texto_original: "alérgica a látex, o resto tudo não, pressão 12 por 8",
    },
  });
  igual((chamadas.at(-1)!.args.p_dados as any).demais_negativas, true);
  igual((chamadas.at(-1)!.args.p_dados as any).paciente_id, "p1");
  await mcp("tools/call", {
    name: "registrar_odontograma",
    arguments: {
      paciente_id: "p1",
      marcas: [{ dentes: [18, 28], condicao: "ausente" }, { dente: 36, condicao: "carie", faces: "O" }],
      texto_original: "18 e 28 ausentes, cárie oclusal no 36",
    },
  });
  const c = chamadas.at(-1)!;
  igual(c.funcao, "mcp_registrar_odontograma");
  igual((c.args.p_dados as any).marcas.length, 2);
  igual("texto_original" in (c.args.p_dados as any), false);
});

Deno.test("salvar_procedimento aceita preço nulo (tirar o preço)", async () => {
  const { mcp, chamadas } = await montar({ mcp_salvar_procedimento: () => ({ status: "atualizado" }) });
  const r = await mcp("tools/call", {
    name: "salvar_procedimento",
    arguments: { codigo: "selante", preco: null, texto_original: "tira o preço do selante" },
  });
  igual((r.corpo as any).result.isError, undefined);
  igual(chamadas.at(-1)!.args.p_dados, { codigo: "selante", preco: null });
});

Deno.test("listar_procedimentos é consulta: erro diz que a consulta não foi feita", async () => {
  const { mcp } = await montar({
    mcp_listar_procedimentos: () => {
      throw new ErroRpc("banco fora do ar");
    },
  });
  const r = await mcp("tools/call", { name: "listar_procedimentos", arguments: { busca: "resina" } });
  const res = (r.corpo as any).result;
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("A consulta não foi feita."), res.content[0].text);
});
