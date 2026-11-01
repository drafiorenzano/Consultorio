# Consultório

Sistema do consultório odontológico da Dra. Andressa, operado por voz: ela fala
com o Claude no celular e o Claude grava na base por um conector próprio (MCP).

Este repositório está na **etapa 1 (base completa e prontuário)**: pacientes,
anamnese, odontograma, prontuário e catálogo de procedimentos com os preços
dela, no Supabase, e um servidor MCP com oito ferramentas. Só dados fictícios
de pacientes; os dados do consultório e os preços são os reais.

## Como funciona

```
iPhone (app do Claude, ditado ou modo de voz)
   │  "Acabei a Mari, resina MO no 36, dois tubetes de articaína"
   ▼
Claude (Project "Consultório")  ──►  conector MCP (Edge Function "mcp")
                                         │  valida o acesso e chama
                                         ▼
                                  Postgres (Supabase, São Paulo)
                                  funções mcp_* : validam, gravam,
                                  auditam; nada se apaga
```

- **As regras moram no banco.** Cada ferramenta é uma função Postgres
  `mcp_*` que roda numa transação só. O servidor MCP só traduz a chamada da IA.
- **Prontuário só de inclusão.** `atendimentos`, `atendimento_itens`,
  `anamneses`, `odontograma`, `solicitacoes` e `auditoria` recusam UPDATE,
  DELETE e TRUNCATE. Correção é um
  novo atendimento com `corrige_atendimento_id` e `motivo_correcao`
  (Código de Ética Odontológica, art. 17). Pacientes são arquivados, nunca
  apagados (guarda de 20 anos, Lei 13.787/2018).
- **Auditoria.** Cada chamada da IA vira uma linha em `solicitacoes` com o texto
  original do pedido (inclusive as que falharam). Cada linha gravada gera uma
  entrada em `auditoria` com antes/depois, ligada à solicitação.
- **Acesso.** Todas as tabelas têm RLS ligado e nenhuma política: a chave
  pública não lê nada. Só a Edge Function, com a chave secreta, chama as
  funções `mcp_*`. Por enquanto o conector é autenticado por um token secreto na
  URL (o hash fica em `acessos_mcp`); antes de entrar dado real, isso vira login
  OAuth do Supabase.

## Ferramentas

| Ferramenta | O que faz |
|---|---|
| `buscar_paciente` | Busca por nome, apelido, CPF, telefone ou nº da ficha. Correspondência exata devolve a ficha (alertas de saúde, anamnese, odontograma, responsáveis, últimos atendimentos); várias ou só parecidas ("Maria" → "Mariana") voltam como lista para a IA confirmar. |
| `cadastrar_paciente` | Abre ficha nova. Valida CPF (dígitos), telefone (DDD), datas; detecta homônimo e pede confirmação; avisa o que falta (CPF para o Receita Saúde, responsável de menor). |
| `atualizar_paciente` | Muda a ficha: contato, documentos, endereço (completa), observações (substitui ou acrescenta com data), consentimentos, responsável, alertas, arquivar. Alertas que vêm da anamnese só mudam pela anamnese. |
| `registrar_anamnese` | 47 perguntas (catálogo em `catalogos/anamnese.json`). Cada registro é uma versão nova que herda as respostas anteriores; "o resto tudo não" = `demais_negativas`. Respostas "sim" de risco viram alertas de saúde (sem repetir o que o cadastro já diz) e "não" que contradiz o cadastro gera aviso. Pressão ("12 por 8" → 120x80) e frequência cardíaca. |
| `registrar_odontograma` | Marcas por dente/faces em camadas: `inicial` (o que o paciente já tem) e `planejado` (plano de tratamento, ligado ao catálogo). Aceita vários dentes ou região (arcada, quadrante, sextante). Marcas superadas são encerradas sozinhas (ausente encerra tudo no dente, menos o plano de implante/prótese); engano se desfaz com `remover` + motivo. |
| `registrar_atendimento` | Grava a evolução: procedimentos por dente FDI/faces ou região, anestesia (tubetes), materiais, intercorrências, orientações, próxima etapa, retorno. Liga cada item ao catálogo (resina pelo nº de faces, extração e canal pelo tipo de dente) e, se concluído num dente, marca como `realizado` no odontograma, fechando a cárie e o plano correspondentes. Correção anula as marcas do atendimento corrigido. |
| `listar_procedimentos` | Catálogo com código, preço e grupo. Sem preço, mostra só a faixa de mercado como referência. |
| `salvar_procedimento` | Altera preço, nome, sinônimos, ativo, ou inclui procedimento novo. Avisa mudança de preço acima de 50%. |

Catálogos de condições do odontograma e perguntas da anamnese ficam em JSON
(`supabase/functions/mcp/catalogos/`) e alimentam tanto as descrições das
ferramentas quanto as tabelas do banco. Depois de mudar um JSON:

```bash
node scripts/gerar-catalogos.mjs > supabase/migrations/<versao>_dados_catalogos.sql
```

(um teste confere que a migration mais recente bate com os JSONs).

## Estrutura

```
supabase/
  migrations/        esquema, funções e permissões (aplicadas em ordem)
  seed.sql           pacientes fictícios para teste
  functions/mcp/     Edge Function do servidor MCP
    index.ts         entrada (chave secreta, chamada ao PostgREST)
    servidor.ts      ferramentas MCP e HTTP (sem dependência de Deno/Supabase)
    catalogos/       condições do odontograma e perguntas da anamnese (JSON)
    deno.json        dependências
scripts/             gerador do SQL dos catálogos
tests/               testes do servidor MCP e dos catálogos (sem banco)
docs/                instruções do Project e roteiro de teste no iPhone
```

## Desenvolvimento

Testes do servidor (Deno 2):

```bash
deno test --allow-read --config supabase/functions/mcp/deno.json tests/
```

Publicar (Supabase CLI):

```bash
supabase link --project-ref <ref>
supabase db push
supabase functions deploy mcp --no-verify-jwt
```

Pela API/MCP do Supabase, mande `import_map_path: "deno.json"` junto com os
arquivos (index.ts, servidor.ts, deno.json e os dois JSON de `catalogos/`):
sem isso o deploy reaproveita o caminho da versão anterior e falha.

Criar um acesso para o conector (o token nunca vai para o repositório):

```bash
TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
HASH=$(printf %s "$TOKEN" | sha256sum | cut -d' ' -f1)
# no SQL editor do Supabase:
#   insert into acessos_mcp (descricao, token_sha256) values ('celular da Dra.', '<HASH>');
# URL do conector: https://<ref>.supabase.co/functions/v1/mcp/$TOKEN
```

Revogar: `update acessos_mcp set revogado_em = now() where id = '...';`

## Próximas etapas

Ver o plano completo no projeto: ~~1) base completa e prontuário~~ (feito),
2) agenda e app do iPad, 3) PDFs (orçamento a partir do plano no odontograma,
receita, TCLE), 4) estoque e financeiro, 5) entrega nas contas dela (inclui
login OAuth no lugar do token na URL e unificar os preços com o site).
