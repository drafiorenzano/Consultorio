# Módulo de estoque

Controle de materiais do consultório por ditado: compras, gasto automático
nos atendimentos, perdas, contagens, lista de compras, validade e custo de
material por procedimento.

Migrations (já aplicadas no projeto `wyubbsqurhqrztpexkdc`):

| Versão | Arquivo | O que faz |
|---|---|---|
| 20261102034216 | `estoque.sql` | Tabelas, regras de saldo, lotes, baixa automática, consultas e permissões |
| 20261102034754 | `estoque_dados.sql` | 53 materiais, 3 fornecedores, kit base e 33 kits por procedimento |
| 20261102041416 | `ferramentas_estoque.sql` | As quatro funções `mcp_*` das ferramentas e o `removido_em` das linhas de kit |

Ferramentas: `supabase/functions/mcp/ferramentas/estoque.ts`. Testes:
`tests/estoque_test.ts` (sem banco) e um bloco SQL desfeito no fim (abaixo).

## Como funciona

- **Unidades.** Cada material tem uma unidade de compra (caixa, pacote), uma
  de uso (tubete, par, unidade, g) e o fator entre elas (1 caixa = 50
  tubetes). O saldo é guardado na unidade de uso e mostrado nas duas
  ("3 caixas + 12 tubetes"). Quando a Dra. não diz a unidade, a compra é na
  unidade de compra e os outros movimentos são na unidade de uso.
- **Movimentos só de inclusão.** Nada se apaga nem se altera: um engano se
  corrige com o movimento contrário (`desfazer`, `cancelar_compra` ou
  correção do atendimento). Compras só podem ser canceladas. Linhas de kit
  tiradas ficam marcadas com `removido_em`.
- **Custo médio ponderado.** Cada entrada com preço recalcula o custo médio
  do material. Frete e desconto da nota são rateados nos itens. Desfazer uma
  entrada desfaz o efeito dela no custo médio.
- **Lotes e validade.** Compras e contagens podem trazer lote e validade
  (AAAA-MM-DD, AAAA-MM ou MM/AAAA; mês e ano valem até o fim do mês). As
  saídas tiram primeiro do lote que vence primeiro (FEFO); o uso não tira de
  lote vencido. Sem lote, o saldo fica num "saldo sem lote", que pode ficar
  negativo antes da primeira contagem.
- **Grupos.** Itens que se substituem (resina por cor, luva por tamanho,
  fio de sutura) formam um grupo com um item padrão. A cor ou o tamanho dito
  no atendimento ("cor A3", "luva P") escolhe o item; sem nada dito, vai o
  padrão (resina A2, luva M, fio de nylon).
- **Acompanhado.** Um material só entra nos avisos e na lista de compras
  depois de ter uma compra, contagem ou entrada. Assim, a lista não fica cheia
  de material que nunca foi contado.

## Baixa automática nos atendimentos

Dois gatilhos `AFTER INSERT`, sem mudar as funções do prontuário:

- Em `atendimentos`: baixa o **kit base** (biossegurança de todo
  atendimento), a anestesia dita (tubetes do anestésico citado e uma agulha
  por anestesia, longa para bloqueio) e os materiais citados.
- Em `atendimento_itens` (itens `concluido` com `procedimento_id`): baixa o
  kit do procedimento. Um material citado no atendimento substitui a linha
  do kit (se ela disse "2 pares de luva", vai isso, e não o par do kit base).
- Correção (`corrige_atendimento_id`): estorna tudo o que o atendimento
  original baixou e aplica a baixa do novo.
- Um problema de estoque nunca impede o registro clínico: os gatilhos
  engolem o erro e o atendimento é gravado.

## Ferramentas

| Ferramenta | Tipo | Para quê | Exemplo de ditado |
|---|---|---|---|
| `registrar_compra` | gravação | Compra com fornecedor, itens, preço, lote, validade, frete, desconto e forma de pagamento | "Comprei duas caixas de articaína a 180 cada na Dental Cremer, no pix" |
| `movimentar_estoque` | gravação | Uso avulso, perda, vencido, contagem, entrada sem compra, desfazer, cancelar compra | "Contei 3 caixas de luva M"; "perdi dois tubetes de lidocaína"; "joguei fora a resina A1 vencida" |
| `ver_estoque` | leitura | Visões: resumo, saldos, material, lista_compras, compras_recentes, vencimentos, consumo, custos | "O que eu preciso comprar?"; "quanto tem de resina?"; "quanto custa o material de um canal de molar?" |
| `salvar_material` | gravação | Cadastrar ou alterar material (mínimo, sinônimos, embalagem, grupo) e kit de procedimento | "O mínimo de articaína é 2 caixas"; "no kit da extração vão 4 gazes" |

Respostas: JSON com `status`, o que mudou, saldos e `avisos` (estoque baixo,
validade em menos de 60 dias, preço mais de 20% acima do anterior, item sem
preço ou sem validade, fornecedor novo cadastrado).

Erros: em português, e nada é gravado. Um material desconhecido na compra
devolve os nomes parecidos e a dica de cadastrar com `salvar_material`.

## Consultas

- **Lista de compras:** materiais acompanhados no ponto de pedido ou abaixo
  dele. Ponto de pedido = consumo diário × prazo de entrega + estoque mínimo.
  O consumo diário é a média dos últimos 60 dias (no mínimo 14 dias de base).
  A quantidade sugerida cobre até o ponto de pedido mais 30 dias de consumo
  (sem consumo, o dobro do mínimo) e é arredondada para a unidade de compra,
  com o último preço e o último fornecedor.
- **Vencimentos:** lotes com saldo que vencem nos próximos 60 dias (ou nos
  `dias` pedidos), incluindo os já vencidos.
- **Consumo:** gasto por semana (atendimentos, custo, os 15 materiais mais
  caros) nas últimas 4 semanas (até 26).
- **Custos:** custo de material de cada procedimento com kit, e a porcentagem
  do preço.

## Funções para os outros módulos

| Função | Devolve |
|---|---|
| `custo_materiais(procedimento_id, incluir_base default false)` | Custo estimado do kit pelo custo médio atual (numeric). Com `procedimento_id` nulo e `incluir_base = true`, só o kit base. |
| `custo_materiais_detalhe(procedimento_id, incluir_base)` | O mesmo, item a item (jsonb), com os materiais ainda sem custo. |
| `custo_materiais_atendimento(atendimento_id)` | Custo real do que foi baixado num atendimento, com os estornos (numeric). |
| `estoque_avisos(materiais uuid[] default null, validade boolean default true)` | Avisos de estoque baixo, negativo e vencimento (text[]). |
| `estoque_avisos_atendimento(atendimento_id)` | Avisos só dos materiais baixados naquele atendimento (text[]). |

## Pedidos de integração (para a sessão principal)

1. **Avisos no registrar_atendimento.** Acrescentar à resposta de
   `mcp_registrar_atendimento` o campo `avisos_estoque` com
   `public.estoque_avisos_atendimento(<id do atendimento>)` (ou somar aos
   `avisos`). Não mudei a função.
2. **Compra vira despesa no financeiro.** Cada compra registrada pode virar
   uma despesa: origem `compra`, `origem_id` = `estoque_compras.id`,
   categoria `materiais`, valor = `valor_total`, forma = `forma_pagamento`
   (já no vocabulário do financeiro), data e competência = `data`. Quando a
   compra for cancelada (`cancelada_em` preenchido), estornar a despesa. Pode
   ser um gatilho do financeiro em `estoque_compras` (`AFTER INSERT` e
   `AFTER UPDATE OF cancelada_em`).
3. **Margem por procedimento.** O financeiro pode usar `custo_materiais` e
   `custo_materiais_atendimento` para o custo de material.

## Padrões assumidos (perguntas para a Dra. Andressa)

Tudo funciona sem resposta; cada item é um valor padrão que ela pode mudar
por ditado com `salvar_material`.

1. **Quantidades dos kits.** Os 33 kits seguem a prática comum de
   consultório. Ela deve conferir os procedimentos que mais faz (resina,
   canal, extração, limpeza).
2. **Luva:** tamanho M como padrão.
3. **Anestesia:** quando ela não diz quantos tubetes, conta 1; bloqueio usa
   agulha longa, infiltrativa usa curta.
4. **Resina:** o kit de resina de 1 face também gasta matriz e cunha.
5. **Procedimento em várias sessões** (canal, prótese): o kit só sai quando o
   item é registrado como concluído.
6. **Estoque mínimo e prazo:** mínimos de partida e 5 dias de entrega para
   todos os fornecedores.
7. **Radiografia:** filme convencional. Se ela usa sensor digital, desativar
   o filme e tirar do kit.
8. **Implante:** os componentes (implante, cicatrizador, pilar) não estão nos
   kits, porque variam por caso; entram como uso avulso ou citados no
   atendimento.
9. **Contagem inicial:** ainda não há saldo. O primeiro uso real é a
   contagem da prateleira, material por material
   ("contei 2 caixas de articaína, validade 03/2027...").
10. **Fornecedores:** Dental Cremer, Dental Speed e Surya Dental cadastrados.
    Os que ela usar de fato são criados sozinhos na primeira compra.

## Teste no banco

O bloco SQL de teste roda tudo numa transação que termina com
`raise exception 'RESULT ...'` (nada fica gravado). Ele cobre:

- contagem inicial com validade mês/ano;
- compra com frete rateado e fornecedor achado por parte do nome;
- custo médio ponderado e aviso de preço;
- baixa automática de uma resina 2 faces: saída FEFO, agulha longa no
  bloqueio, cor da resina pelo contexto, luva citada no lugar da linha do kit
  e kit base;
- correção do atendimento com estorno;
- lista de compras e vencimentos;
- perda e desfazer;
- cancelamento de compra com aviso de material já usado;
- material novo, mínimo em caixas e kit (incluir, tirar, voltar, grupo);
- todas as visões;
- erros em português e o bloqueio de alteração de movimentos.

Resultado em 2026-11-02, com todas as migrations aplicadas:
`RESULT ok: contagem, compra, media_ponderada, baixa_automatica custo=13.94,
correcao, lista_vencimentos, perda_desfazer, cancelar_compra,
salvar_material_kit, visoes custo_resina_2=3.68, erros`.
