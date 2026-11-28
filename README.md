# Consultório

Sistema do consultório odontológico da Dra. Andressa, operado por voz: ela fala
com o Claude no celular e o Claude grava na base por um conector próprio (MCP).

Tem tudo o que o consultório precisa no dia a dia: pacientes, anamnese,
odontograma e prontuário; agenda com o aluguel da sala; orçamento, receita,
atestado e termos em PDF; estoque com baixa automática por procedimento;
financeiro com recibos do Receita Saúde e pacote do contador; preços de
campanha e calculadora de preço; agenda no app Calendário do iPhone/iPad e
ficha online que o paciente preenche antes da consulta. São 36 ferramentas no
conector MCP e um site (celular, iPad e computador) que mostra tudo e também
lança recebimentos, despesas, estoque e estornos, com login de e-mail, senha e
código de dois fatores. Desde 02/11/2026 a base tem dados reais de pacientes:
testes só em transação desfeita (rollback).

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

Os módulos estão documentados à parte: agenda e site (abaixo),
[documentos](docs/documentos.md), [estoque](docs/estoque.md) e
[financeiro](docs/financeiro.md).

| Módulo | Ferramentas |
|---|---|
| Agenda | `agendar_consulta`, `alterar_consulta` (confirmar, remarcar, cancelar, faltou, reabrir), `reservar_sala` (aluguel por hora, vira despesa), `ver_agenda` (horários livres, links de WhatsApp para confirmar, retornos sem consulta) |
| Documentos | `montar_orcamento` (a partir do plano no odontograma, com alternativas e fases), `alterar_orcamento`, `emitir_receita`, `emitir_atestado`, `emitir_termo`, `ver_documentos` |
| Estoque | `registrar_compra` (vira despesa), `movimentar_estoque`, `ver_estoque`, `salvar_material` |
| Financeiro | `registrar_pagamento`, `registrar_despesa`, `ver_financeiro`, `marcar_recibos`, `configurar_financeiro`, `gerar_pacote_contador` |
| Site | `acesso_ipad` (gera o convite do site, também para a conta própria de outra pessoa com `email` e `pessoa`, lista contas e aparelhos e tira o acesso; o nome ficou da época do app do iPad) |
| Preços | `salvar_campanha` (preços só de uma campanha, ex.: Campanha RJ; os normais não mudam), `ver_campanhas`, `calcular_preco` (lucro no Pix, débito e crédito 1x a 12x, com imposto e custos do kit) |
| Calendário | `acesso_calendario` (gera, lista e revoga o link de assinatura da agenda no app Calendário) |
| Ficha online | `ficha_online` (link pessoal com mensagem pronta para o WhatsApp; lista e cancela), `ver_ficha_online` (o que o paciente respondeu ao lado da ficha), `confirmar_ficha_online` (grava ou descarta, com campos a ignorar) |

### Site do consultório

`app/` é um site estático (HTML, CSS e JS, sem build) instalável como app
(PWA) que funciona no celular, no iPad e no computador: hoje, agenda (semana e
mês), pacientes com ficha completa e odontograma, orçamentos, documentos,
estoque, financeiro com gráfico de 12 meses, preços e campanhas, atividade
(tudo o que foi registrado, pelo Claude ou pelo site) e ajustes. Tema claro,
escuro ou automático; cores e fontes em `app/tema.css`, fontes em `app/fontes/`
(sem Google Fonts).

**Tela Hoje.** Só o que importa no dia: agenda de hoje (amanhã fechado logo
abaixo), a lista "a fazer" e os materiais. A lista junta recibos do Receita
Saúde a emitir ou cancelar, o pacote do contador do mês passado (na fase PJ, a
NFS-e), parcelas atrasadas ou que vencem em 7 dias, orçamentos aprovados sem
pagamento combinado, consultas a confirmar, fichas online, orçamentos para
acompanhar, retornos, rascunhos e campanha da semana
(`painel_inicio_afazer`, somado à ação `inicio`). Materiais mostra o que está
em falta ou acabando e os lotes vencidos ou que vencem em até 60 dias (só
quando a compra tem lote e validade). O resto fica nas abas.

**Exames na ficha.** A aba Exames do paciente guarda radiografia, tomografia,
exame, foto, laudo ou documento (foto, PNG ou PDF, até 20 MB; foto grande ou
HEIC vira JPEG de até 2400 px no próprio aparelho). A API dá um link de envio
de uso único (`anexo_envio`) para `documentos/anexos/<paciente>/<id>.<ext>`, o
navegador manda o arquivo direto para o Storage e grava com `gravar` tipo
`anexo`; antes de gravar a API confere no Storage que o arquivo chegou e usa o
tamanho e o tipo reais. O registro vai para `anexos` por
`mcp_registrar_anexo` (só inclusão, com auditoria). Anexo errado não se apaga:
"Tirar da ficha" grava em `anexos_retirados` com o motivo e o arquivo continua
guardado com o prontuário.

**Orçamento pelo site.** Em Orçamentos (ou na aba Orçamentos da ficha), "+ Novo
orçamento" abre o mesmo gerador que ela usava no `/orcamento` do site público
(paciente, procedimentos da tabela de preços ou texto livre, dente/região,
quantidade, valor, desconto em R$ ou %, parcelas, observações), com a prévia
do documento ao lado. A ação `orcamento_novo` traz o catálogo com os preços, as
campanhas (a escolhida vai pelo id) e, com `paciente_id`, o orçamento em aberto
do paciente, para ela escolher entre versão nova (padrão) ou outro à parte.
Salvar chama `gravar` tipo `orcamento`, que monta por `mcp_montar_orcamento`
(número, versão, preço de campanha, acompanhamento de 7/21/45 dias e
auditoria, como o Claude), só com os itens do formulário
(`incluir_odontograma: false`) e com as condições do PDF (sem desconto à vista
nem entrada; cartão em até N vezes). O PDF é desenhado no navegador a partir
do que ficou gravado, com o mesmo desenho e as mesmas fontes do site público
(`app/orcamento/pdf.js`, jsPDF 4.2.1 em `app/orcamento/`, baixado só quando ela
abre a tela), e volta pela `gravar` tipo `orcamento_pdf`: a API confere que é
PDF, sobe para o caminho que o banco escolhe (`painel_orcamento_caminho`) e
registra em `documentos` com `gerado_por = 'site'`, tamanho e SHA-256. Ela pode
baixar o PDF ou mandar pelo compartilhar do iPhone (WhatsApp, e-mail).

**Login.** Conta do Supabase Auth com e-mail, senha e código TOTP (app Senhas
do iPhone). A conta só nasce, ou troca de senha, pelo convite que o Claude gera
com `acesso_ipad` (link `#acesso=...`, uma vez só, 7 dias; o hash fica em
`acessos_mcp` com escopo `painel`). O convite também apaga o código antigo, e o
código novo só vale se for cadastrado até 24 h depois de usar o convite. Cada
pedido passa por `painel_autorizar`: sessão com segundo fator (aal2), aberta
depois da última troca de senha, com até 30 dias, e cada acesso fica em
`painel_log`.

**Outras contas.** Outra pessoa (ex.: o Guilherme) pode ter conta própria,
separada da dela: `acesso_ipad` com `acao = gerar`, `email` e `pessoa` grava o
e-mail no convite (`acessos_mcp.email_convite`) e a conta nasce com
`painel_contas.pessoa` preenchido. Convite sem `email` é sempre da conta da
Dra. (`painel_email_da_dra()`), e gerar um convite para outra pessoa só
substitui os convites pendentes dessa mesma pessoa. `acesso_ipad` com
`acao = revogar` e `email` desliga só aquela conta (`desativada_em`); `listar`
mostra as contas e os convites pendentes. Todas as contas veem e lançam o mesmo
que ela. Em Ajustes, `painel_ajustes` mostra a conta de quem está vendo (o id
vem do login, na API, nunca do pedido) e a lista "Quem entra no site".

**API.** A Edge Function `painel` (sem JWT do gateway: ela mesma confere o
token) devolve `public.painel(acao, parametros)` e, na ação `gravar`, chama
`painel_gravar`, que usa as mesmas funções do conector
(`mcp_registrar_pagamento`, `mcp_registrar_despesa`,
`mcp_movimentar_estoque`, `mcp_registrar_anexo`, `mcp_montar_orcamento`,
`mcp_registrar_documento`) com as mesmas validações. A solicitação fica marcada
como vinda do site (`solicitacoes.cliente = 'site'`) e aparece em Atividade
como "pelo site". Só os campos listados em `painel_campos` passam. Estornos
são registros novos, nada se apaga. `LANCAR_PELO_SITE` em `app/config.js`
desliga os botões de lançar sem mexer no banco.

**Segurança no navegador.** CSP na página (só scripts do próprio site,
conexão e imagens só do Supabase do consultório), sem referrer, `noindex`. A chave em
`app/config.js` é a publicável (pública por definição); RLS sem políticas
continua bloqueando tudo fora das funções.

**Publicar.** O workflow `.github/workflows/app-ipad.yml` publica a pasta no
GitHub Pages (Settings > Pages > Source: GitHub Actions); o endereço vai em
`configuracao.painel_url`. Ao mudar arquivos do site, suba `VERSAO` em
`app/sw.js` e inclua os arquivos novos em `CASCA`.

### Agenda no Calendário do iPhone/iPad

A Edge Function `calendario` serve a agenda em iCal (`GET
/functions/v1/calendario/<código>`), só leitura, de 60 dias atrás a 13 meses
à frente: consultas (primeiro nome + inicial do sobrenome e procedimento, "✓"
quando confirmada), reservas da sala e campanhas (as duas como "livre"). O
código tem escopo `calendario` em `acessos_mcp` (o hash, nunca o código) e sai
pela ferramenta `acesso_calendario` como link `webcal://`; no iPhone, tocar no
link abre "Assinar". O Calendário atualiza sozinho (pede a cada 15 min; o iOS
decide quando). O endereço das funções fica em `configuracao.funcoes_url`.

### Ficha online

O paciente preenche cadastro e anamnese pelo celular antes da consulta.
`ficha_online` (enviar) cria uma linha em `fichas_online` com o SHA-256 de um
código aleatório e devolve o link `<configuracao.ficha_url>/#c=<código>`: o
código fica depois do `#`, então não chega ao servidor que hospeda a página.
A página (`app/ficha/index.html`, um arquivo só, sem dependências) fala com a
Edge Function `ficha` (`POST {acao: exemplo|abrir|enviar}`), que chama
`ficha_online_abrir` e `ficha_online_enviar`. O link vale 7 dias (1 a 30),
serve para um envio só, e um link novo cancela o anterior do mesmo paciente.
As respostas são validadas no banco (`ficha_online_normalizar`) e ficam em
`fichas_online.respostas` até a Dra. revisar (`ver_ficha_online`) e confirmar
(`confirmar_ficha_online`, que chama `mcp_atualizar_paciente` e
`mcp_registrar_anamnese` com origem `formulario`). A página guarda o rascunho
só no `sessionStorage`. `<ficha_url>/#exemplo` mostra o formulário sem enviar
nada. A versão do termo aceito (`ficha_online_termo_versao()`) precisa bater
com a constante `TERMO` da página.

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
    ferramentas/     módulos: agenda, calendario, documentos, estoque, ficha_online, financeiro, ipad, precos
    documentos/      PDFs (pdf-lib)
    financeiro/      planilhas e lote do Receita Saúde
    catalogos/       condições do odontograma e perguntas da anamnese (JSON)
    deno.json        dependências
  functions/painel/  API do site (leituras, lançamentos e convite)
  functions/calendario/  agenda em iCal para o app Calendário
  functions/ficha/   API pública da ficha online (abrir e enviar)
app/                 site do consultório (PWA estática, sem build)
app/ficha/           página da ficha online que o paciente abre
scripts/             gerador do SQL dos catálogos; pacote/ monta e carrega o conector publicado
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
--no-verify-jwt` publica a API do site; `calendario` e `ficha` vão do mesmo
jeito (as duas sem JWT: a primeira confere o código da URL, a segunda o código
da ficha).

**Como está publicado hoje.** O servidor completo ficou grande demais para um
envio só pela API, e o publicador do Supabase não importa código de
`*.supabase.co`. Por isso a função `mcp` no ar é o carregador
`scripts/pacote/carregador.js`: na partida ele lê o pacote montado (deno
bundle) da tabela `pacote_conector`, confere o SHA-256 fixado no carregador e
roda. Para publicar uma versão nova assim:

```bash
scripts/pacote/montar.sh /tmp/pacote   # gera pacote.sql e index.js
# 1. rode pacote.sql no SQL editor (entra a versão nova, a antiga continua)
# 2. publique /tmp/pacote/index.js + supabase/functions/mcp/deno.json como "mcp"
# 3. apague da tabela as partes da versão antiga
```

Sem o SQL editor, o banco busca o pacote sozinho: junte as partes de
`pacote.sql` num arquivo `.b64`, suba num commit, rode
`select net.http_get('https://raw.githubusercontent.com/<dono>/<repo>/<commit>/<arquivo>')`,
confira o md5 de `net._http_response.content` e insira as partes de 6000
caracteres a partir dele; depois tire o arquivo do repositório.

Com o Supabase CLI (`supabase functions deploy mcp --no-verify-jwt`) a função
volta a ser publicada direto de `supabase/functions/mcp/` e a tabela
`pacote_conector` pode ser apagada.

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
~~4) estoque e financeiro~~, ~~calendário e ficha online~~, ~~site completo
com login e lançamentos~~ (feitos). Os dados
de demonstração foram apagados em 02/11/2026. Falta: login OAuth no lugar do
token na URL, unificar os preços com o site e ajustar os padrões com as
respostas da Dra.
