# Consultório: regras para quem mexe no código

Sistema do consultório da Dra. Andressa Fiorenzano (cirurgiã-dentista,
implantodontista), operado por voz pelo Claude no celular. O README explica a
arquitetura, as ferramentas e como publicar. Leia antes de mudar algo.

## Com quem você fala

Quem pede as mudanças é a própria Dra. Andressa, pelo iPad ou pelo celular. Ela
não é programadora: fale em português simples, sem jargão, e diga o que muda
para ela no dia a dia. Faça em passos pequenos e mostre o resultado de cada um.

## Dados reais de pacientes

- A base (Supabase, projeto "consultorio", São Paulo) tem dados reais de saúde
  desde 02/11/2026. LGPD e sigilo profissional valem aqui.
- Nunca mostre, copie ou exporte dados de pacientes na conversa, em arquivos,
  em commits ou em testes. Para entender um problema, use contagens e ids.
- Teste no banco só dentro de uma transação desfeita: um bloco `do $$ ... $$`
  que termina em `raise exception` com o resultado, para nada ficar gravado.
- Nada se apaga. Prontuário, anamnese, odontograma, solicitações e auditoria
  recusam UPDATE e DELETE de propósito (Código de Ética, art. 17; guarda de 20
  anos, Lei 13.787/2018). Não contorne isso; correção é um registro novo.
- Antes de qualquer coisa paga (plano do Supabase, domínio, serviço novo) ou
  que apague algo, pergunte a ela.

## Segredos

- O repositório é público. Nunca grave token, chave ou link de acesso em
  arquivo, commit, log ou mensagem. Os acessos ficam em `acessos_mcp` só como
  SHA-256.
- Não peça para ela colar chaves na conversa. Chaves do Supabase ficam nos
  segredos das Edge Functions.

## Como mudar

- Banco: uma migration nova em `supabase/migrations/` por mudança (nunca edite
  uma já aplicada). As regras ficam nas funções `mcp_*`; o servidor MCP só
  traduz a chamada. Depois de aplicar, confira que a função no banco é igual à
  do arquivo.
- Servidor MCP (`supabase/functions/mcp/`): toda ferramenta nova tem teste em
  `tests/`. Rode antes de publicar:
  `deno test --allow-read --config supabase/functions/mcp/deno.json tests/`
- Formatação: `deno fmt --line-width 120` nos arquivos que você mudou. Não
  rode nos JSON de `supabase/functions/mcp/catalogos/` (eles têm formato
  próprio; depois de mudar um, gere a migration com
  `scripts/gerar-catalogos.mjs`).
- Publicar o conector: veja "Como está publicado hoje" no README. Ao subir a
  versão, troque `VERSAO` em `servidor.ts` e o cabeçalho de
  `scripts/pacote/carregador.js`.
- Ficha online: a página do paciente é `app/ficha/index.html` e fica publicada
  no site dela (outro repositório) em `public/ficha/index.html`. Mudou uma,
  copie para a outra. Se mudar o texto do aviso de privacidade, suba a versão
  do termo nos dois lados (`TERMO` na página e `ficha_online_termo_versao()` no
  banco).
- O site (`app/`, celular, iPad e computador) é estático, sem build. Cores em
  `app/tema.css`, fontes em `app/fontes/`. Mudou um arquivo do site: suba
  `VERSAO` em `app/sw.js` e ponha arquivo novo em `CASCA`, senão o iPad fica
  com a versão velha guardada. Lançamento pelo site passa por `painel_gravar`,
  que chama as mesmas funções `mcp_*` do conector: regra nova vai na função
  `mcp_*`, não no site.

## Antes de terminar

- Testes passando, nada de dado de paciente no diff, nenhum segredo.
- Commit com mensagem em português dizendo o que muda para ela.
- Se mudou ferramentas, atualize o README e `docs/instrucoes-project.md` (o
  texto das instruções do Project no Claude dela).
