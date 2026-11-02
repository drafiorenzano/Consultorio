// deno-lint-ignore-file no-explicit-any
// Testes das ferramentas da agenda (sem banco).

import { ErroRpc } from "../supabase/functions/mcp/servidor.ts";
import { igual, INIT, montar, verdade } from "./util.ts";

async function ferramentas() {
  const { mcp } = await montar();
  const r = await mcp("tools/list");
  return Object.fromEntries(((r.corpo as any).result.tools as any[]).map((t) => [t.name, t]));
}

Deno.test("agenda: quatro ferramentas, só ver_agenda é leitura", async () => {
  const t = await ferramentas();
  for (const n of ["agendar_consulta", "alterar_consulta", "reservar_sala", "ver_agenda"]) verdade(t[n], `falta ${n}`);
  igual(t.ver_agenda.annotations.readOnlyHint, true);
  igual(t.agendar_consulta.annotations.readOnlyHint, false);
  igual(t.alterar_consulta.annotations.readOnlyHint, false);
  igual(t.reservar_sala.annotations.readOnlyHint, false);
  igual(t.agendar_consulta.inputSchema.required.sort(), ["data", "hora", "paciente_id", "texto_original"]);
  igual(t.alterar_consulta.inputSchema.required.sort(), ["acao", "texto_original"]);
  igual(t.reservar_sala.inputSchema.required, ["texto_original"]);
  igual(t.ver_agenda.inputSchema.required ?? [], []);
  igual(t.alterar_consulta.inputSchema.properties.acao.enum, [
    "confirmar",
    "remarcar",
    "cancelar",
    "faltou",
    "reabrir",
    "alterar",
  ]);
});

Deno.test("agenda: instruções do servidor falam da agenda e do link de WhatsApp", async () => {
  const { mcp } = await montar();
  const r = await mcp("initialize", INIT);
  const ins = (r.corpo as any).result.instructions as string;
  verdade(ins.includes("agendar_consulta"), "instruções sem agendar_consulta");
  verdade(ins.includes("Você não envia mensagens"), "instruções sem o aviso do WhatsApp");
});

Deno.test("agendar_consulta manda dados em p_dados e o pedido em p_texto_original", async () => {
  const { mcp, chamadas } = await montar({ mcp_agendar_consulta: () => ({ status: "ok" }) });
  const r = await mcp("tools/call", {
    name: "agendar_consulta",
    arguments: {
      paciente_id: "p1",
      data: "2026-11-10",
      hora: "9:00",
      duracao_min: 90,
      procedimento_codigo: "implante_unitario",
      texto_original: "marca a Mari terça às 9 pro implante, uma hora e meia",
    },
  });
  igual((r.corpo as any).result.isError, undefined);
  igual(chamadas.at(-1), {
    funcao: "mcp_agendar_consulta",
    args: {
      p_dados: {
        paciente_id: "p1",
        data: "2026-11-10",
        hora: "9:00",
        duracao_min: 90,
        procedimento_codigo: "implante_unitario",
      },
      p_texto_original: "marca a Mari terça às 9 pro implante, uma hora e meia",
    },
  });
});

Deno.test("agendar_consulta recusa data e hora fora do formato antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  for (const args of [{ data: "10/11", hora: "09:00" }, { data: "2026-11-10", hora: "nove" }]) {
    const r = await mcp("tools/call", {
      name: "agendar_consulta",
      arguments: { paciente_id: "p1", texto_original: "t", ...args },
    });
    const res = (r.corpo as any).result ?? (r.corpo as any).error;
    verdade(res.isError === true || (r.corpo as any).error, `deveria recusar ${JSON.stringify(args)}`);
  }
  igual(chamadas.filter((c) => c.funcao === "mcp_agendar_consulta").length, 0);
});

Deno.test("alterar_consulta: conflito do banco vira 'Nada foi gravado' com a mensagem", async () => {
  const { mcp, chamadas } = await montar({
    mcp_alterar_consulta: () => {
      throw new ErroRpc("Conflito: João Pedro Almeida já está marcado(a) das 10:00 às 11:00 em 10/11.");
    },
  });
  const r = await mcp("tools/call", {
    name: "alterar_consulta",
    arguments: { acao: "remarcar", paciente_id: "p1", nova_hora: "10:30", texto_original: "passa a Mari pras 10:30" },
  });
  const res = (r.corpo as any).result;
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("Nada foi gravado. Conflito"), res.content[0].text);
  verdade(chamadas.some((c) => c.funcao === "mcp_registrar_falha"), "falha não registrada");
});

Deno.test("alterar_consulta recusa ação desconhecida antes do banco", async () => {
  const { mcp, chamadas } = await montar();
  const r = await mcp("tools/call", {
    name: "alterar_consulta",
    arguments: { acao: "apagar", consulta_id: "c1", texto_original: "apaga" },
  });
  const res = (r.corpo as any).result ?? (r.corpo as any).error;
  verdade(res.isError === true || (r.corpo as any).error, "deveria recusar a ação apagar");
  igual(chamadas.filter((c) => c.funcao === "mcp_alterar_consulta").length, 0);
});

Deno.test("reservar_sala: série semanal com valor por hora", async () => {
  const { mcp, chamadas } = await montar({ mcp_reservar_sala: () => ({ status: "ok", total_reservas: 3 }) });
  await mcp("tools/call", {
    name: "reservar_sala",
    arguments: {
      data: "2026-11-10",
      hora_inicio: "08:00",
      hora_fim: "12:00",
      valor_hora: 60,
      repetir_semanal_ate: "2026-11-24",
      texto_original: "aluguei a sala terças de 8 ao meio-dia até o fim do mês, 60 a hora",
    },
  });
  const c = chamadas.at(-1)!;
  igual(c.funcao, "mcp_reservar_sala");
  igual((c.args.p_dados as any).repetir_semanal_ate, "2026-11-24");
  igual("texto_original" in (c.args.p_dados as any), false);
});

Deno.test("ver_agenda é leitura: sem argumentos funciona e erro diz que a consulta não foi feita", async () => {
  const ok = await montar({ mcp_ver_agenda: () => ({ dias: [] }) });
  const r1 = await ok.mcp("tools/call", { name: "ver_agenda", arguments: {} });
  igual((r1.corpo as any).result.isError, undefined);
  igual(ok.chamadas.at(-1), { funcao: "mcp_ver_agenda", args: { p_dados: {}, p_texto_original: null } });

  const erro = await montar({
    mcp_ver_agenda: () => {
      throw new ErroRpc("Período longo demais: até dois meses por vez.");
    },
  });
  const r2 = await erro.mcp("tools/call", {
    name: "ver_agenda",
    arguments: { data_inicio: "2026-11-01", data_fim: "2027-03-01" },
  });
  const res = (r2.corpo as any).result;
  igual(res.isError, true);
  verdade(res.content[0].text.startsWith("A consulta não foi feita."), res.content[0].text);
});
