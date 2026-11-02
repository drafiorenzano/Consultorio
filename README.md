# Consultório

Sistema do consultório odontológico da Dra. Andressa, operado por voz: ela fala
com o Claude no celular e o Claude grava na base por um conector próprio (MCP).

Tem tudo o que o consultório precisa no dia a dia: pacientes, anamnese,
odontograma e prontuário; agenda com o aluguel da sala; orçamento, receita,
atestado e termos em PDF; estoque com baixa automática por procedimento;
financeiro com recibos do Receita Saúde e pacote do contador. São 29
ferramentas no conector MCP e um app do iPad só de leitura. Só dados fictícios
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

Os módulos estão documentados à parte: agenda e iPad (abaixo),
[documentos](docs/documentos.md), [estoque](docs/estoque.md) e
[financeiro](docs/financeiro.md).

| Módulo | Ferramentas |
|---|---|
| Agenda | `agendar_consulta`, `alterar_consulta` (confirmar, remarcar, cancelar, faltou, reabrir), `reservar_sala` (aluguel por hora, vira despesa), `ver_agenda` (horários livres, links de WhatsApp para confirmar, retornos sem consulta) |
| Documentos | `montar_orcamento` (a partir do plano no odontograma, com alternativas e fases), `alterar_orcamento`, `emitir_receita`, `emitir_atestado`, `emitir_termo`, `ver_documentos` |
| Estoque | `registrar_compra` (vira despesa), `movimentar_estoque`, `ver_estoque`, `salvar_material` |
| Financeiro | `registrar_pagamento`, `registrar_despesa`, `ver_financeiro`, `marcar_recibos`, `configurar_financeiro`, `gerar_pacote_contador` |
| iPad | `acesso_ipad` (gera, lista e revoga o link do app) |

### App do iPad

`app/` é um site estático (HTML, CSS e JS, sem build) instalável como app
(PWA): hoje, agenda da semana, pacientes, ficha completa com odontograma,
orçamentos, documentos e financeiro do paciente, estoque e financeiro do mês.
Só leitura. Ele lê a Edge Function `painel`, que aceita um código próprio no
cabeçalho `x-acesso` (escopo `painel` em `acessos_mcp`; o código do conector
não abre o painel e vice-versa) e devolve `public.painel(acao, parametros)`.
PDFs ganham link temporário (1 h). Cores e fontes ficam em `app/tema.css`.
O workflow `.github/workflows/app-ipad.yml` publica a pasta no GitHub Pages
(Settings > Pages > Source: GitHub Actions); o endereço vai em
`configuracao.painel_url` e o link de acesso sai pela ferramenta `acesso_ipad`.

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
    index.ts         entrada (chave secreta, chamada ao PostgREST, Storage)
    servidor.ts      ferramentas do prontuário e HTTP (sem dependência de Deno/Supabase)
    ferramentas/     módulos: agenda, documentos, estoque, financeiro, ipad
    documentos/      PDFs (pdf-lib)
    financeiro/      planilhas e lote do Receita Saúde
    catalogos/       condições do odontograma e perguntas da anamnese (JSON)
    deno.json        dependências
  functions/painel/  API só de leitura do app do iPad
app/                 app do iPad (PWA estática)
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

Pela API/MCP do Supabase, mande `import_map_path: "deno.json"` junto com todos
os arquivos da pasta (menos `deno.lock`): sem isso o deploy reaproveita o
caminho da versão anterior e falha. `supabase functions deploy painel
--no-verify-jwt` publica a API do iPad.

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

~~1) base e prontuário~~, ~~2) agenda e app do iPad~~, ~~3) PDFs~~,
~~4) estoque e financeiro~~ (feitos). Falta 5) entrega: limpar os dados de
demonstração, login OAuth no lugar do token na URL, unificar os preços com o
site e ajustar os padrões com as respostas da Dra.
