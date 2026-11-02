# Módulo de documentos (etapa 3)

Orçamento / plano de tratamento, receita, atestado, termo de consentimento e
orientações pós-procedimento. Tudo sai em PDF guardado no bucket privado
`documentos` (pasta do paciente), com link assinado válido por 7 dias.

Código:

- `supabase/functions/mcp/ferramentas/documentos.ts`: as 6 ferramentas do conector.
- `supabase/functions/mcp/documentos/pdf.ts`: geração dos PDFs (pdf-lib). O visual
  inteiro mora no objeto `TEMA` (cores do site, fontes, tamanhos, textos fixos).
- Migrations `20261102032848_documentos_base`, `20261102040434_documentos_orcamentos`,
  `20261102040742_documentos_receitas_atestados_termos`.
- Testes: `tests/documentos_test.ts` (sem banco: `rpc` falso e Storage em memória).

## Ferramentas

| Ferramenta | Para quê |
| --- | --- |
| `montar_orcamento` | Junta os planos do odontograma (camada planejado) com o que a Dra. ditar e gera o orçamento em PDF. |
| `alterar_orcamento` | `apresentar`, `aprovar` (tudo, uma alternativa ou itens), `recusar`, `acompanhamento` (anotar contato) e `editar`. |
| `emitir_receita` | Receita comum, por modelo (`amoxicilina_500`, `ibuprofeno_600`...) ou por extenso, com checagens de segurança. |
| `emitir_atestado` | Comparecimento, repouso (dias) ou acompanhante. |
| `emitir_termo` | Termo de consentimento (TCLE) ou folha de orientações, por modelo. |
| `ver_documentos` | Documentos de um paciente com links novos; sem paciente, quem está na hora do contato de acompanhamento; `regerar` faz o PDF de novo. |

Exemplos do que a Dra. dita:

- "Monta o orçamento do João: canal e coroa no 46 ou extração com implante, e raspagem S1 e S2"
  → `montar_orcamento` com alternativas A e B no 46.
- "O João aprovou a opção A, vai pagar no cartão em 6x" → `alterar_orcamento` `aprovar`, `alternativa: A`.
- "Receita de amoxicilina e paracetamol pra Mariana" → `emitir_receita` com dois modelos.
- "Atestado de 2 dias de repouso pro João" → `emitir_atestado` `repouso`, `dias: 2`.
- "Termo de exodontia do 38 e 48 pro João" → `emitir_termo` `modelo: exodontia`, `dentes: [38, 48]`.

## Orçamento

**Preços.** O valor vem do catálogo (`procedimentos.preco`). Procedimento sem preço
faz a ferramenta voltar `valor_necessario` com a lista do que falta e nada é
gravado; a Dra. diz o valor e a chamada se repete com `valores` (ou `valor` no item).
A faixa de mercado aparece só como referência. O valor fica congelado no item.

**Odontograma.** Cada plano ativo do odontograma entra como item (com o dente e as
faces). Um item ditado para o mesmo dente e procedimento (ou família, ou condição)
ajusta o item do odontograma em vez de duplicar. Plano sem procedimento definido
(ex.: coroa) fica de fora com aviso, até a Dra. dizer qual.

**Fases.** 1 urgência e preparo, 2 gengiva, 3 canal, 4 restaurações, 5 prótese e
implante, 6 estética, 7 manutenção. A fase vem da categoria do procedimento e pode
ser ditada.

**Alternativas.** Itens com `alternativa` A–D formam opções. O PDF mostra os itens
comuns por fase e cada opção com seu total e formas de pagamento. Aprovar um
orçamento com alternativas exige dizer qual (ou quais itens).

**Status.**

| Status | Quando |
| --- | --- |
| rascunho | Montado, ainda não entregue. Editar muda o próprio orçamento. |
| apresentado (Em aberto) | Entregue ao paciente. Editar cria a versão 2, 3... com o mesmo número; a anterior vira `substituido`. |
| expirado (Vencido) | Calculado: apresentado com a validade passada. Ainda pode ser aprovado (com aviso). |
| aprovado / parcial | Aprovação total ou de parte (outra alternativa ou itens recusados). |
| recusado | Com o motivo, se dito. Pode ser aprovado depois. |
| concluido | Todos os itens aprovados foram realizados. |

**Itens realizados (automático).** Três gatilhos ligam o orçamento ao prontuário:

- `odontograma_orcamento`: a marca realizado que encerra o plano do item marca o
  item como realizado; dente marcado ausente cancela os outros planos dele; marca
  anulada desfaz.
- `atendimento_itens_orcamento`: procedimento concluído no atendimento realiza o
  item sem plano no odontograma (mesmo procedimento ou família, dente e região).
- `atendimentos_orcamento`: atendimento corrigido desfaz o que o original realizou.

Item realizado antes da aprovação conta como realizado se não for de alternativa.

**Pagamento.** As condições padrão ficam em `documentos_config` (uma linha) e são
copiadas para o orçamento quando ele é montado; `pagamento` muda só aquele orçamento.

| Campo | Padrão |
| --- | --- |
| `desconto_a_vista_pct` | 5% |
| `cartao_parcelas_max` | 6 |
| `entrada_pct` / `entrada_parcelas_max` | 30% + até 3 parcelas |
| `parcela_minima` | R$ 100 |
| `desconto_acumula` | não (com desconto no orçamento, sai o desconto à vista) |
| `orcamento_validade_dias` | 30 |
| `acompanhamento_dias` | {7, 21, 45} depois de apresentado |
| `destaque_parcela_acima` | R$ 1.000 (o PDF destaca a parcela) |

**Acompanhamento.** Orçamento apresentado tem um roteiro de contatos (7, 21 e 45
dias). `ver_documentos` sem paciente lista quem está na hora; cada contato é
anotado com `alterar_orcamento` `acompanhamento`.

## Receita

- 16 modelos em `medicamentos_modelos` (analgésicos, anti-inflamatórios,
  corticoide, antibióticos, clorexidina, profilaxias e 3 pediátricos). Os
  pediátricos pedem `peso_kg` e calculam a dose em ml e o número de frascos.
- Checagens que pedem confirmação (`confirmacao_necessaria`, nada gravado até
  `confirmar_alertas: true`): alergia (penicilina, dipirona, anti-inflamatório ou o
  nome citado), anticoagulante + anti-inflamatório, gestação, amamentação, problema
  renal, criança com dose de adulto, alergia a medicamento sem detalhe.
- Avisos (sem bloquear): hipertensão ou asma com anti-inflamatório, fígado com
  paracetamol, paciente sem anamnese, sem endereço em receita de antibiótico.
- Controle especial (Portaria 344/98: benzodiazepínicos, opioides,
  anticonvulsivantes...) é recusado: vai no talão em papel.
- Antibiótico sai em 2 vias (uma fica na farmácia), com validade de 10 dias.

## Atestado

- `comparecimento` (padrão), `repouso` (1 a 30 dias, a partir da data ou de
  `a_partir_de`) e `acompanhante` (para menor, usa o responsável cadastrado).
- Sem horário ditado, usa o do atendimento do dia.
- CID só com `cid_autorizado: true` (autorização expressa do paciente).

## Termos e orientações

- Consentimento: exodontia, endodontia, implante, prótese, clareamento, cirurgia.
  O texto cita o procedimento e os dentes; menor de idade sai com o responsável
  para assinar. Avisa se falta anamnese.
- Orientações: pós-exodontia, pós-implante, cuidados no clareamento.

## PDFs e registro

1. A função `mcp_*` grava o documento e devolve `documento` (`tipo`, `referencia_id`,
   `caminho`, `dados`).
2. O servidor gera o PDF, sobe em `documentos/<paciente>/<tipo>-<número>-<data>-<sufixo>.pdf`
   e chama `mcp_registrar_documento` (tamanho e sha256 ficam em `documentos`).
3. A resposta traz o link (7 dias). Sem Storage configurado, o documento fica
   gravado e a resposta avisa que o PDF não saiu; falha no upload vira erro
   explicado, sem registrar arquivo.

`ver_documentos` troca cada caminho por um link novo (até 15 por resposta) e
`regerar: {tipo, numero}` gera o PDF de novo a partir do que foi gravado.

## Tabelas

`documentos_config`, `documentos`, `medicamentos_modelos`, `termos_modelos`,
`orcamentos`, `orcamento_itens`, `receitas`, `atestados`, `termos_emitidos`.
Receitas, atestados, termos e `documentos` são só inclusão. Orçamentos aceitam
alteração (status, itens), mas nunca exclusão, e tudo passa pela auditoria. RLS
ligado sem políticas; as funções só executam como `service_role`.

## Perguntas para a Andressa (com o padrão usado até lá)

1. Condições de pagamento: desconto à vista, parcelas no cartão, entrada +
   parcelas e parcela mínima. Padrão: 5%, até 6x, 30% + 3x, mínimo R$ 100.
2. O desconto à vista soma com um desconto dado no orçamento? Padrão: não.
3. Parcela sem juros e boleto: pode escrever no orçamento? Padrão: o PDF não promete nenhum dos dois.
4. Validade do orçamento. Padrão: 30 dias.
5. Contatos de acompanhamento depois de apresentar. Padrão: 7, 21 e 45 dias.
6. Modelos de receita: doses e dias que ela usa (ex.: ibuprofeno 600 por 3 dias,
   dipirona 500 de 6/6 h, amoxicilina 500 por 7 dias). Padrão: posologias da referência.
7. Textos dos termos de consentimento e das orientações. Padrão: textos genéricos escritos por nós.
8. Cabeçalho dos documentos: precisa de CNPJ/CNES ou só nome, CRO e endereço? Padrão: só nome, CRO e endereço.
9. Texto do atestado (comparecimento/repouso). Padrão: o modelo em `mcp_emitir_atestado`.
10. Procedimento feito antes de o orçamento ser aprovado conta como realizado? Padrão: sim, se não for de alternativa.

Mudar um padrão de pagamento hoje é uma linha em `documentos_config`; por orçamento,
basta a Dra. dizer ("faz em 10x") que vai em `pagamento`.
