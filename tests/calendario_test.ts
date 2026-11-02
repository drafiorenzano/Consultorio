// Testes do calendário assinado (iCal), sem banco.

import {
  codigoDoCaminho,
  criarHandlerCalendario,
  dobrar,
  escapar,
  type FeedCalendario,
  montarIcs,
  sha256Hex,
  utc,
} from "../supabase/functions/calendario/handler.ts";
import { igual, verdade } from "./util.ts";

const CODIGO = "-Im4DR7tARFUHdD0Z0j8joQ164zoGLkJeegtNPFiOLY";
const AGORA = new Date("2026-11-02T20:00:00Z");

const FEED: FeedCalendario = {
  nome: "Consultório · Dra. Andressa Fiorenzano",
  fuso: "America/Sao_Paulo",
  eventos: [
    {
      uid: "sala-1@consultorio",
      inicio: "2026-11-04T18:00:00+00:00",
      fim: "2026-11-04T22:00:00+00:00",
      titulo: "Sala reservada",
      local: "Av. República do Líbano, 1673 – Moema, São Paulo-SP",
      livre: true,
      sequencia: 93649440,
      modificado_em: "2026-11-02T19:57:20.278588+00:00",
    },
    {
      uid: "consulta-2@consultorio",
      inicio: "2026-11-04T19:00:00-03:00",
      fim: "2026-11-04T20:00:00-03:00",
      titulo: "✓ Maria S. · Avaliação, revisão; teste",
      descricao: "Ficha nº 12\nConfirmada pelo paciente",
    },
    {
      uid: "campanha-3@consultorio",
      dia_inteiro: true,
      data_inicio: "2026-11-12",
      data_fim: "2026-11-14",
      titulo: "Campanha RJ",
      local: "Clínica X, Rio de Janeiro",
      livre: true,
    },
  ],
};

async function montar(resposta: FeedCalendario | null | Error = FEED) {
  const valido = await sha256Hex(CODIGO);
  const pedidos: string[] = [];
  const handler = criarHandlerCalendario({
    feed: (h) => {
      pedidos.push(h);
      if (resposta instanceof Error) return Promise.reject(resposta);
      return Promise.resolve(h === valido ? resposta : null);
    },
    agora: () => AGORA,
  });
  return { handler, pedidos };
}

Deno.test("calendario: escapar e datas", () => {
  igual(escapar("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne");
  igual(utc("2026-11-04T19:00:00-03:00"), "20261104T220000Z");
  igual(utc("2026-11-02T19:57:20.278588+00:00"), "20261102T195720Z");
});

Deno.test("calendario: dobra linhas longas em até 75 bytes sem cortar acento", () => {
  const linha = "DESCRIPTION:" + "ção ".repeat(40);
  const dobrada = dobrar(linha);
  const enc = new TextEncoder();
  for (const pedaco of dobrada.split("\r\n")) verdade(enc.encode(pedaco).length <= 75, `pedaço longo: ${pedaco}`);
  igual(dobrada.replace(/\r\n /g, ""), linha);
  igual(dobrar("curta"), "curta");
});

Deno.test("calendario: monta o .ics com consulta, sala livre e campanha de dia inteiro", () => {
  const ics = montarIcs(FEED, AGORA);
  verdade(ics.startsWith("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"), "cabeçalho");
  verdade(ics.endsWith("END:VCALENDAR\r\n"), "fim");
  verdade(!/[^\r]\n/.test(ics), "toda quebra de linha é CRLF");
  const desdobrado = ics.replace(/\r\n /g, "");
  verdade(desdobrado.includes("X-WR-CALNAME:Consultório · Dra. Andressa Fiorenzano"), "nome do calendário");
  igual((desdobrado.match(/BEGIN:VEVENT/g) ?? []).length, 3);
  verdade(desdobrado.includes("DTSTART:20261104T220000Z\r\nDTEND:20261104T230000Z"), "horário em UTC");
  verdade(desdobrado.includes("SUMMARY:✓ Maria S. · Avaliação\\, revisão\\; teste"), "título escapado");
  verdade(desdobrado.includes("DESCRIPTION:Ficha nº 12\\nConfirmada pelo paciente"), "descrição com \\n");
  verdade(desdobrado.includes("DTSTART;VALUE=DATE:20261112\r\nDTEND;VALUE=DATE:20261114"), "dia inteiro");
  verdade(desdobrado.includes("UID:sala-1@consultorio\r\nDTSTAMP:20261102T200000Z"), "uid e carimbo");
  verdade(/UID:sala-1[\s\S]*?TRANSP:TRANSPARENT[\s\S]*?SEQUENCE:93649440/.test(desdobrado), "sala não ocupa");
  verdade(/UID:consulta-2[\s\S]*?TRANSP:OPAQUE/.test(desdobrado), "consulta ocupa");
  verdade(desdobrado.includes("LAST-MODIFIED:20261102T195720Z"), "última mudança");
  verdade(desdobrado.includes("LOCATION:Av. República do Líbano\\, 1673 – Moema\\, São Paulo-SP"), "local");
});

Deno.test("calendario: código do caminho", () => {
  igual(codigoDoCaminho(`https://x.supabase.co/functions/v1/calendario/${CODIGO}`), CODIGO);
  igual(codigoDoCaminho(`https://x.supabase.co/calendario/${CODIGO}.ics`), CODIGO);
  igual(codigoDoCaminho(`https://x.supabase.co/calendario/${CODIGO}/?a=1`), CODIGO);
});

Deno.test("calendario: link válido devolve text/calendar", async () => {
  const { handler } = await montar();
  const r = await handler(new Request(`https://x/functions/v1/calendario/${CODIGO}`));
  igual(r.status, 200);
  igual(r.headers.get("content-type"), "text/calendar; charset=utf-8");
  verdade((await r.text()).includes("SUMMARY:Campanha RJ"), "corpo");
  const head = await handler(new Request(`https://x/functions/v1/calendario/${CODIGO}.ics`, { method: "HEAD" }));
  igual(head.status, 200);
});

Deno.test("calendario: código errado, curto ou revogado dá 404 sem dados", async () => {
  const { handler, pedidos } = await montar();
  const errado = await handler(new Request("https://x/functions/v1/calendario/" + "x".repeat(43)));
  igual(errado.status, 404);
  verdade(!(await errado.text()).includes("BEGIN:VCALENDAR"), "sem calendário");
  const curto = await handler(new Request("https://x/functions/v1/calendario/abc"));
  igual(curto.status, 404);
  igual(pedidos.length, 1, "código curto nem chega ao banco");
  const post = await handler(new Request(`https://x/functions/v1/calendario/${CODIGO}`, { method: "POST" }));
  igual(post.status, 405);
});

Deno.test("calendario: erro no banco dá 503", async () => {
  const { handler } = await montar(new Error("caiu"));
  const r = await handler(new Request(`https://x/functions/v1/calendario/${CODIGO}`));
  igual(r.status, 503);
});
