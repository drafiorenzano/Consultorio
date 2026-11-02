// Agenda do consultório como calendário assinado (iCal, RFC 5545), só leitura.
// Sem dependências do Deno nem do Supabase, para testar localmente
// (tests/calendario_test.ts).
//
// GET /calendario/<código> devolve o .ics. O código é conferido pelo SHA-256
// em public.calendario_feed (acessos_mcp com escopo "calendario"), que também
// devolve os eventos. O iPhone e o iPad buscam de novo sozinhos de tempos em
// tempos; o que mudar na agenda aparece na próxima busca.

export interface EventoCalendario {
  uid: string;
  titulo: string;
  /** Horário (ISO com fuso) para eventos com hora. */
  inicio?: string;
  fim?: string;
  /** Eventos de dia inteiro (campanhas): datas AAAA-MM-DD, fim exclusivo. */
  dia_inteiro?: boolean;
  data_inicio?: string;
  data_fim?: string;
  local?: string;
  descricao?: string;
  /** true: não ocupa o horário (reserva de sala, campanha). */
  livre?: boolean;
  sequencia?: number;
  modificado_em?: string;
}

export interface FeedCalendario {
  nome: string;
  fuso?: string;
  eventos: EventoCalendario[];
}

export interface DependenciasCalendario {
  /** Lê os eventos; null quando o código não vale (revogado ou inexistente). */
  feed: (sha256: string) => Promise<FeedCalendario | null>;
  agora?: () => Date;
}

export async function sha256Hex(texto: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Texto de propriedade iCal: barra, ponto e vírgula, vírgula e quebras de linha escapados. */
export function escapar(texto: string): string {
  return texto
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r\n|\r|\n/g, "\\n");
}

/** Dobra a linha em pedaços de até 75 bytes (UTF-8), sem cortar um caractere ao meio. */
export function dobrar(linha: string): string {
  const cod = new TextEncoder();
  const partes: string[] = [];
  let atual = "";
  let bytes = 0;
  let limite = 75;
  for (const ch of linha) {
    const n = cod.encode(ch).length;
    if (bytes + n > limite) {
      partes.push(atual);
      atual = "";
      bytes = 0;
      limite = 74; // a continuação começa com um espaço
    }
    atual += ch;
    bytes += n;
  }
  partes.push(atual);
  return partes.join("\r\n ");
}

/** 2026-11-04T19:57:20.278+00:00 -> 20261104T195720Z */
export function utc(iso: string | Date): string {
  const d = iso instanceof Date ? iso : new Date(iso);
  if (Number.isNaN(d.getTime())) throw new Error(`Data inválida: ${iso}`);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z").replace(/[-:]/g, "");
}

/** 2026-11-12 -> 20261112 */
export function dataIcal(data: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(data)) throw new Error(`Data inválida: ${data}`);
  return data.replace(/-/g, "");
}

export function montarIcs(feed: FeedCalendario, agora: Date = new Date()): string {
  const linhas = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Consultorio Dra. Andressa Fiorenzano//Agenda//PT",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `NAME:${escapar(feed.nome)}`,
    `X-WR-CALNAME:${escapar(feed.nome)}`,
    `X-WR-TIMEZONE:${feed.fuso ?? "America/Sao_Paulo"}`,
    "X-APPLE-CALENDAR-COLOR:#2C4A3E",
    "REFRESH-INTERVAL;VALUE=DURATION:PT15M",
    "X-PUBLISHED-TTL:PT15M",
  ];
  const carimbo = utc(agora);
  for (const e of feed.eventos) {
    const ev = ["BEGIN:VEVENT", `UID:${escapar(e.uid)}`, `DTSTAMP:${carimbo}`];
    if (e.dia_inteiro) {
      if (!e.data_inicio) continue;
      ev.push(`DTSTART;VALUE=DATE:${dataIcal(e.data_inicio)}`);
      if (e.data_fim) ev.push(`DTEND;VALUE=DATE:${dataIcal(e.data_fim)}`);
    } else {
      if (!e.inicio || !e.fim) continue;
      ev.push(`DTSTART:${utc(e.inicio)}`, `DTEND:${utc(e.fim)}`);
    }
    ev.push(`SUMMARY:${escapar(e.titulo)}`);
    if (e.local) ev.push(`LOCATION:${escapar(e.local)}`);
    if (e.descricao) ev.push(`DESCRIPTION:${escapar(e.descricao)}`);
    ev.push(`TRANSP:${e.livre ? "TRANSPARENT" : "OPAQUE"}`, "STATUS:CONFIRMED");
    if (typeof e.sequencia === "number" && Number.isFinite(e.sequencia) && e.sequencia >= 0) {
      ev.push(`SEQUENCE:${Math.floor(e.sequencia)}`);
    }
    if (e.modificado_em) ev.push(`LAST-MODIFIED:${utc(e.modificado_em)}`);
    ev.push("END:VEVENT");
    linhas.push(...ev);
  }
  linhas.push("END:VCALENDAR");
  return linhas.map(dobrar).join("\r\n") + "\r\n";
}

function texto(corpo: string, status: number): Response {
  return new Response(corpo, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
  });
}

/** Último pedaço do caminho, sem ".ics": /functions/v1/calendario/<código>.ics -> <código>. */
export function codigoDoCaminho(url: string): string {
  const caminho = new URL(url).pathname.replace(/\/+$/, "");
  const ultimo = decodeURIComponent(caminho.slice(caminho.lastIndexOf("/") + 1));
  return ultimo.replace(/\.ics$/i, "");
}

export function criarHandlerCalendario(deps: DependenciasCalendario) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "GET" && req.method !== "HEAD") return texto("Use GET.", 405);
    const codigo = codigoDoCaminho(req.url);
    if (!/^[A-Za-z0-9_-]{32,128}$/.test(codigo)) return texto("Link de calendário inválido.", 404);
    let feed: FeedCalendario | null;
    try {
      feed = await deps.feed(await sha256Hex(codigo));
    } catch (e) {
      console.error(`calendario: ${e instanceof Error ? e.message : e}`);
      return texto("Não consegui ler a agenda agora. Tente de novo em alguns minutos.", 503);
    }
    if (!feed) return texto("Link de calendário inválido ou revogado.", 404);
    const ics = montarIcs(feed, deps.agora?.() ?? new Date());
    return new Response(req.method === "HEAD" ? null : ics, {
      status: 200,
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Content-Disposition": 'inline; filename="consultorio.ics"',
        "Cache-Control": "private, no-store",
        "X-Robots-Tag": "noindex",
      },
    });
  };
}
