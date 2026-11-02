# Financeiro (etapa 4b)

Pagamentos dos pacientes, acordos com parcelas, despesas do consultório, recibos do Receita Saúde e o pacote
mensal do contador. As regras ficam no banco (funções `mcp_*` e `fin_*`). O servidor MCP só valida os
argumentos e, no pacote, monta os CSV e guarda no Storage.

## Ferramentas

| Ferramenta | Função no banco | Para quê |
| --- | --- | --- |
| `registrar_pagamento` | `mcp_registrar_pagamento` | `acao`: `pagamento` (padrão), `combinar` (acordo com parcelas), `estornar`, `cancelar_acordo` |
| `registrar_despesa` | `mcp_registrar_despesa` | `acao`: `registrar` (padrão), `lancar_fixas`, `alterar_fixa`, `encerrar_fixa`, `estornar` |
| `ver_financeiro` (leitura) | `mcp_ver_financeiro` | `visao`: `mes`, `paciente`, `a_receber`, `inadimplentes`, `recibos`, `despesas`, `configuracao` |
| `marcar_recibos` | `mcp_marcar_recibos` | recibo emitido ou cancelado no Receita Saúde, um a um ou o último lote do mês |
| `configurar_financeiro` | `mcp_configurar_financeiro` | CPF e registro da Dra., regime e data da virada para PJ, CNPJ, taxas da maquininha |
| `gerar_pacote_contador` | `mcp_pacote_contador` e `mcp_registrar_pacote_contador` | CSV do mês no Storage, com links de 7 dias |

Todas as ferramentas de gravação recebem `texto_original` (obrigatório) e mandam o resto em `p_dados`. Cada
chamada é uma transação só e abre a solicitação com `iniciar_solicitacao`. As respostas trazem `status`
(`ok`, `sem_mudanca`, `confirmacao_necessaria`) e `avisos`.

## Regras

- **Lançamentos só de inclusão.** `recebimentos`, `despesas`, `recibos_receita_saude` e `pacotes_contador`
  recusam UPDATE e DELETE por gatilho. Corrigir é estornar: um lançamento novo, com valor negativo, ligado ao
  original (`estorna_id`) e com motivo. O estorno sai, por padrão, com a data do original, para o mês fechar certo.
  Acordos, parcelas, despesas fixas e configuração podem ser alterados, mas não apagados (acordo se cancela,
  despesa fixa se encerra). Tudo passa pela auditoria.
- **Pagamento.** O valor tem de ser maior que zero e a data não pode estar no futuro (o que é futuro se combina
  com `acao combinar`). A taxa da maquininha vem da configuração, a não ser que a Dra. diga o valor ou o
  percentual. Também se calculam o valor líquido e a data prevista de crédito.
- **Quem pagou.** Pode vir `pagador.responsavel_id`, `pagador.nome` (reconhece o paciente e os responsáveis pelo
  nome completo ou pelo primeiro nome) ou `pagador.e_o_paciente`. Sem nada disso, vale o primeiro responsável
  marcado como pagador e, se não houver, o próprio paciente. Paciente menor sem responsável gera aviso.
  O beneficiário do recibo é sempre o paciente.
- **Parcelas.** Com `quitar_parcela` (padrão true), o pagamento vai primeiro para a parcela pedida e depois para as
  abertas mais antigas. Se cobrir mais de uma, vira um recebimento por parcela, com a taxa dividida na proporção.
  O que sobra fica avulso.
- **Duplicidade.** Um pagamento igual (mesmo paciente, data, forma e valor, contando o total já dividido entre
  parcelas) ou uma despesa parecida (mesma categoria e valor em até 3 dias) devolve `confirmacao_necessaria`. A ferramenta só grava com `confirmar_duplicado` ou
  `confirmar_duplicada`.
- **Despesas.** São 13 categorias: `aluguel_sala`, `materiais`, `laboratorio`, `cro`, `contador`, `inss`,
  `impostos`, `iss`, `seguro`, `software`, `manutencao`, `marketing` e `outros`. O banco também aceita
  sinônimos falados. Laboratório sem paciente e despesa sem comprovante geram aviso.
  `recorrente` cadastra uma despesa fixa mensal e já lança a do mês. `lancar_fixas` lança as pendentes de um
  mês e aceita o valor do mês para as que variam.
- **Despesas automáticas.** Reservas de sala da agenda e compras do estoque entram por
  `financeiro_lancar_despesa_automatica`, sem passar pela IA. Essa entrada é idempotente pela origem: a mesma
  chamada não duplica, e um valor diferente estorna o lançamento anterior e lança de novo. Não se estornam por
  `registrar_despesa`: corrige-se na origem.
- **Fiscal.** `regime_fiscal(data)` decide pela data da virada (`pj_a_partir_de`, hoje 01/12/2026):
  - Antes da virada, pessoa física. Cada pagamento precisa de um recibo no Receita Saúde, emitido na data do
    pagamento.
  - A partir da virada, pessoa jurídica. O contador emite a NFS-e, e o recibo fica como `nfse_contador`.

  O recibo de um pagamento passa por estas situações:
  - `pendente`: ainda não foi emitido.
  - `emitido`: emitido no Receita Saúde.
  - `cancelar`: foi emitido, mas o pagamento foi estornado.
  - `cancelado`: cancelado no Receita Saúde.
  - `nao_se_aplica` e `nfse_contador`: não há recibo do Receita Saúde.
- **Hora clínica.** Estimativa: as despesas do mês, menos materiais, laboratório, impostos e ISS, divididas
  pelas horas atendidas registradas (`hora_inicio` e `hora_fim` dos atendimentos).

## Tabelas

| Tabela | Conteúdo |
| --- | --- |
| `configuracao_financeira` | uma linha: regime, `pj_a_partir_de`, CPF e registro da Dra., código da ocupação, CNPJ, taxas |
| `acordos_pagamento` | acordos combinados com o paciente |
| `parcelas_previstas` | parcelas de cada acordo |
| `recebimentos` | pagamentos e estornos, com taxa, líquido, pagador, beneficiário e regime |
| `recibos_receita_saude` | eventos de recibo (emitido ou cancelado, com código) |
| `despesas_recorrentes` | despesas fixas mensais |
| `despesas` | despesas lançadas e estornos, com a origem (`manual`, `recorrente`, `reserva_sala`, `compra`) |
| `pacotes_contador` | cada pacote gerado: arquivos e resumo, com os ids do lote do Receita Saúde |

Todas as tabelas têm RLS ligado e nenhuma policy. Só o `service_role` executa as funções.

## Taxas da maquininha (InfinitePay, a confirmar o plano)

Tabela pública da InfinitePay em 02/11/2026: Plano Inicial (até R$ 20 mil por
mês), recebimento em 1 dia útil, Visa e Mastercard
([infinitepay.io/taxas](https://infinitepay.io/taxas)). Se o plano dela for
outro, ela muda com `configurar_financeiro`.

| Forma | % | Dias |
| --- | --- | --- |
| PIX, dinheiro, transferência | 0 | 0 |
| Débito | 1,37 | 1 |
| Crédito à vista | 3,15 | 1 |
| Crédito 2x a 12x (`por_parcelas`) | 5,39 · 6,12 · 6,85 · 7,57 · 8,28 · 8,99 · 9,69 · 10,38 · 11,06 · 11,74 · 12,40 | 1 |
| Boleto | 0 | 1 |

O imposto da calculadora de preço (`calcular_preco`) fica em
`configuracao_financeira.imposto_percentual` (padrão 6%).

## Campanhas e calculadora de preço

- `campanhas` e `campanha_precos`: uma campanha tem nome, datas (até 60 dias),
  local e os preços que mudam. Preço de campanha nulo = volta ao normal. Nada se
  apaga: campanha se cancela. Uma campanha por dia.
- `montar_orcamento` usa, nesta ordem: o valor ditado, o preço da campanha
  (a pedida; senão a do orçamento em aberto; senão a de hoje) e o preço do
  catálogo. `campanha: "nenhuma"` usa só o catálogo. O orçamento guarda
  `campanha_id` e o PDF diz "Valores da Campanha X".
- Nos dias de campanha a confirmação por WhatsApp leva o local da campanha e a
  agenda não cobra reserva de sala.
- `calcular_preco`: lucro = preço − taxa da forma − imposto sobre o preço −
  custos (kit do procedimento e kit base pelo custo médio do estoque, sala, e
  os custos ditos). Com `margem_desejada`, sugere o preço (no Pix) e diz quanto
  cobrar em cada forma para manter a margem.

## Pacote do contador

`gerar_pacote_contador` usa o mês passado, a não ser que receba outro `mes`. O fluxo é:

1. Lê os dados do mês com `mcp_pacote_contador`.
2. Monta os arquivos (`financeiro/csv.ts`).
3. Grava cada arquivo no bucket privado `documentos`, em `contador/AAAA-MM/`, como `text/csv`.
4. Cria links de 7 dias.
5. Registra o pacote com `mcp_registrar_pacote_contador`, incluindo `resumo.lote_receita_saude`, os ids que foram
   no arquivo do Receita Saúde.

Gerar o mesmo mês de novo substitui os arquivos e registra um pacote novo. Sem Storage, a ferramenta devolve
`status: sem_arquivos` e não registra nada.

| Arquivo | Conteúdo |
| --- | --- |
| `receita-saude-AAAA-MM.csv` | lote de recibos pendentes (só quando há pendentes e o CPF da Dra. está configurado) |
| `recebimentos-AAAA-MM.csv` | todos os pagamentos do mês, com estornos |
| `despesas-livro-caixa-AAAA-MM.csv` | despesas do mês, com estornos |
| `resumo-AAAA-MM.csv` | recebido, despesas por categoria, resultado, a receber, recibos, hora clínica, avisos e pendências |

Quando o lote passa de 1.000 linhas, os arquivos ganham o sufixo `-1`, `-2` e assim por diante.

Depois que a Dra. envia o lote, `marcar_recibos` com `mes` e `todos_pendentes: true` marca como emitidos só os
recibos que foram no último arquivo do mês.

### Lote do Receita Saúde

O arquivo segue o layout de importação em lote:

- 16 campos separados por `;`, sem cabeçalho.
- Até 1.000 linhas por arquivo, todas do mesmo ano.
- Linhas terminadas em CRLF.
- Conteúdo só em ASCII: descrições sem acento e sem `;`, com até 255 caracteres.

| # | Campo | Valor |
| --- | --- | --- |
| 1 | data do pagamento | `DD/MM/AAAA` |
| 2 | código do rendimento | `R01.001.001` |
| 3 | código da ocupação | `226` (configurável) |
| 4 | valor | `350,00` (vírgula, sem milhar) |
| 5 | (vazio) | |
| 6 | descrição | descrição do pagamento, mais ` - parcela n/N` e ` - atendimento em DD/MM/AAAA` |
| 7 | tipo do pagador | `PF` |
| 8 | CPF do pagador | só dígitos |
| 9 | CPF do beneficiário (paciente) | só dígitos |
| 10–13 | (vazios) | |
| 14 | indicador | `S` |
| 15 | CPF da Dra. | só dígitos |
| 16 | registro profissional | até 15 caracteres, pode ficar vazio |

O lote só inclui pagamentos de pessoa física, pendentes e com os dois CPFs. O que fica de fora aparece em
`problemas`, com o número do pagamento e o motivo.

### Planilhas completas

As planilhas saem em UTF-8 com BOM, separadas por `;` e com cabeçalho, para abrir direto no Excel:

- Valores com vírgula decimal.
- Datas em `DD/MM/AAAA`.
- CPF e CNPJ com pontuação.
- Formas, categorias e situações por extenso.
- Textos que começam com `=`, `+`, `-` ou `@` ganham um apóstrofo na frente, para não virarem fórmula.

## Funções para os outros módulos

| Função | Para quê |
| --- | --- |
| `saldo_paciente(uuid)` | pago, a receber, atrasado e parcelas em aberto, para a ficha do paciente |
| `financeiro_resumo_mes(date)` | resumo do mês, para um painel |
| `financeiro_lancar_despesa_automatica(origem, origem_id, data, categoria, valor, descricao, fornecedor, paciente, forma)` | despesa automática da agenda (`'reserva_sala'`, categoria `aluguel_sala`) ou do estoque (`'compra'`, categoria `materiais`); idempotente, devolve `lancada`, `sem_mudanca`, `substituida` ou `estornada` |
| `financeiro_estornar_despesa_automatica(origem, origem_id, motivo)` | estorna a despesa automática quando a reserva ou a compra é cancelada |

`acordos_pagamento.orcamento_id` e `recebimentos.orcamento_id` ainda não têm chave estrangeira. A ligação fica
para quando a tabela de orçamentos existir.

## Testes

- `tests/financeiro_test.ts`, sem banco: esquemas e anotações das ferramentas, o que vai para cada função,
  recusas antes do banco, formato dos CSV e o pacote com Storage falso, sem Storage e com falha do Storage.
- No banco, um bloco `DO` com dados fictícios que termina em `raise exception 'RESULT ...'`, para tudo ser
  desfeito. Ele cobre pagamentos, divisão por parcela, taxas, duplicidade, estornos, acordos, despesas fixas e
  automáticas, recibos, pacote, a virada para PJ e a auditoria.

## Pontos a confirmar com a Dra. (padrão adotado)

| Ponto | Padrão adotado |
| --- | --- |
| CPF da Dra. | Vazio: o lote não é gerado e a ferramenta avisa |
| Registro profissional que vai no recibo | Vazio |
| Taxas reais da InfinitePay dela | Valores de referência da tabela acima |
| Data da virada para PJ | 01/12/2026 |
| Quem paga pelo menor | O primeiro responsável marcado como pagador |
| Crédito parcelado | Um recibo pelo valor total, na data da compra |
| Data do estorno | A data do pagamento original |
| O que entra como custo fixo na hora clínica | Tudo, menos materiais, laboratório, impostos e ISS |
| Codificação e quebra de linha do lote do Receita Saúde | ASCII e CRLF, a conferir na primeira importação |
| Quitação automática da parcela mais antiga | Sim |
