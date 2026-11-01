// Gera o SQL dos catálogos fixos (condições do odontograma e perguntas da
// anamnese) a partir dos JSON usados pelo servidor MCP, para que banco e
// servidor nunca divirjam.
//
//   node scripts/gerar-catalogos.mjs > supabase/migrations/<versao>_dados_catalogos.sql
//
// O SQL é idempotente (insert ... on conflict do update): rodar de novo com
// o JSON alterado atualiza o catálogo sem apagar nada. Com
// --desativar-ausentes, a pergunta que saiu do JSON fica inativa (as
// respostas antigas continuam no histórico).

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const raiz = new URL("../supabase/functions/mcp/catalogos/", import.meta.url);
const ler = (nome) => JSON.parse(readFileSync(fileURLToPath(new URL(nome, raiz)), "utf8"));

const q = (v) => (v === undefined || v === null ? "null" : `'${String(v).replaceAll("'", "''")}'`);
const arr = (a) => (a.length ? `array[${a.map(q).join(", ")}]::text[]` : "'{}'::text[]");

export function gerarSql({ desativarAusentes = false } = {}) {
  const condicoes = ler("condicoes.json");
  const perguntas = ler("anamnese.json");
  const linhas = [];
  linhas.push("-- GERADO por scripts/gerar-catalogos.mjs a partir de supabase/functions/mcp/catalogos/*.json.");
  linhas.push("-- Não edite à mão: altere o JSON e gere de novo.");
  linhas.push("");
  linhas.push("insert into public.odontograma_condicoes (codigo, nome, tipo, usa_faces, resolve, ordem) values");
  linhas.push(
    condicoes.map((c, i) =>
      `  (${q(c.codigo)}, ${q(c.nome)}, ${q(c.tipo)}, ${c.usa_faces}, ${arr(c.resolve)}, ${(i + 1) * 10})`
    ).join(",\n"),
  );
  linhas.push("on conflict (codigo) do update set nome = excluded.nome, tipo = excluded.tipo,");
  linhas.push("  usa_faces = excluded.usa_faces, resolve = excluded.resolve, ordem = excluded.ordem;");
  linhas.push("");
  linhas.push("insert into public.anamnese_perguntas (codigo, ordem, grupo, texto, tipo, detalhe, alerta_tipo, alerta_texto, ativa) values");
  linhas.push(
    perguntas.map((p, i) =>
      `  (${q(p.codigo)}, ${(i + 1) * 10}, ${q(p.grupo)}, ${q(p.texto)}, ${q(p.tipo)}, ${q(p.detalhe)}, ${q(p.alerta_tipo)}, ${q(p.alerta_texto)}, true)`
    ).join(",\n"),
  );
  linhas.push("on conflict (codigo) do update set ordem = excluded.ordem, grupo = excluded.grupo,");
  linhas.push("  texto = excluded.texto, tipo = excluded.tipo, detalhe = excluded.detalhe,");
  linhas.push("  alerta_tipo = excluded.alerta_tipo, alerta_texto = excluded.alerta_texto, ativa = true;");
  if (desativarAusentes) {
    linhas.push("");
    linhas.push("update public.anamnese_perguntas set ativa = false");
    linhas.push(` where codigo <> all (${arr(perguntas.map((p) => p.codigo))});`);
  }
  return linhas.join("\n") + "\n";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(gerarSql({ desativarAusentes: process.argv.includes("--desativar-ausentes") }));
}
