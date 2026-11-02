#!/usr/bin/env bash
# Monta o pacote do servidor MCP para a publicação pela tabela pacote_conector.
#
#   scripts/pacote/montar.sh [pasta_de_saida]
#
# Gera, na pasta de saída (padrão: /tmp/pacote-conector):
#   pacote.js        o servidor inteiro num arquivo (deno bundle)
#   pacote.sql       insert das partes em public.pacote_conector (rodar no SQL editor)
#   index.js         o carregador com o SHA-256 novo (publicar como index.js da
#                    função mcp, junto com supabase/functions/mcp/deno.json)
#
# Precisa do Deno 2. Depois: rode pacote.sql, publique index.js + deno.json
# (verify_jwt desligado) e apague as versões antigas da tabela quando a nova
# estiver no ar.
set -euo pipefail

raiz="$(cd "$(dirname "$0")/../.." && pwd)"
saida="${1:-/tmp/pacote-conector}"
mkdir -p "$saida"

deno bundle --config "$raiz/supabase/functions/mcp/deno.json" \
  --external zod --external pdf-lib --external '@modelcontextprotocol/sdk/*' \
  -o "$saida/pacote.js" "$raiz/supabase/functions/mcp/index.ts"

hash="$(sha256sum "$saida/pacote.js" | cut -d' ' -f1)"
b64="$(gzip -9 -n -c "$saida/pacote.js" | base64 -w0)"

{
  echo "-- Pacote $hash"
  echo "begin;"
  parte=0
  for ((i = 0; i < ${#b64}; i += 6000)); do
    echo "insert into public.pacote_conector (sha256, parte, texto) values ('$hash', $parte, '${b64:i:6000}');"
    parte=$((parte + 1))
  done
  echo "commit;"
} > "$saida/pacote.sql"

sed "s/^const ESPERADO = \"[0-9a-f]*\";/const ESPERADO = \"$hash\";/" \
  "$raiz/scripts/pacote/carregador.js" > "$saida/index.js"

echo "Pacote $hash ($(wc -c < "$saida/pacote.js") bytes) em $saida"
