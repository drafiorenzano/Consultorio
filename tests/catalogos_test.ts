// O SQL dos catálogos (migração) tem de ser exatamente o gerado a partir
// dos JSON que o servidor MCP usa. Se falhar: altere o JSON e gere uma
// migração nova com scripts/gerar-catalogos.mjs.
//   deno test --allow-read --config supabase/functions/mcp/deno.json tests/

import { gerarSql } from "../scripts/gerar-catalogos.mjs";

Deno.test("migração dos catálogos bate com os JSON do servidor", async () => {
  const arquivo = new URL("../supabase/migrations/20261101230531_dados_catalogos.sql", import.meta.url);
  const gravado = await Deno.readTextFile(arquivo);
  if (gravado !== gerarSql()) {
    throw new Error("catalogos/*.json mudou: gere uma migração nova com scripts/gerar-catalogos.mjs");
  }
});

Deno.test("cada condição citada em 'resolve' existe", async () => {
  const condicoes = JSON.parse(
    await Deno.readTextFile(new URL("../supabase/functions/mcp/catalogos/condicoes.json", import.meta.url)),
  ) as { codigo: string; resolve: string[] }[];
  const codigos = new Set(condicoes.map((c) => c.codigo));
  const faltando = condicoes.flatMap((c) => c.resolve.filter((r) => !codigos.has(r)));
  if (faltando.length) throw new Error(`condições inexistentes em resolve: ${faltando.join(", ")}`);
});
