# Roteiro de teste (sistema completo)

Para testar no iPhone antes de mostrar à Dra. Andressa. Use o Project
"Consultório" com o conector ligado e fale (ou digite) as frases abaixo. Os
pacientes são fictícios: Mariana Costa Ribeiro ("Mari"), João Pedro Almeida,
Carlos Eduardo Nunes e Helena Martins Prado (9 anos).

Tudo o que for gravado fica no banco de teste. Antes de a Dra. usar de verdade,
os dados de demonstração serão limpos.

## 1. Agenda e sala (2 min)

1. "O que eu tenho amanhã?" → agenda com horários livres e links de WhatsApp
   para pedir confirmação.
2. "Marca o Carlos quinta às 15h, avaliação de prótese." → confirma antes de
   gravar; avisa se a sala não estiver reservada.
3. "A Mari confirmou." / "O João desmarcou, pediu pra semana que vem." →
   confirma ou remarca.
4. "Aluguei a sala sexta das 8 ao meio-dia, 60 a hora." → vira despesa de
   aluguel no financeiro.

## 2. Atendimento, orçamento e documentos (4 min)

1. "Avaliei o João: cárie no 16 MO, o 46 precisa de canal e coroa, ou extrair
   e fazer implante." → odontograma inicial e planejado.
2. "Monta o orçamento do João com duas opções pro 46." → pergunta os valores
   que faltam e devolve o PDF.
3. "Apresentei o orçamento pro João." e, depois, "Ele aprovou a opção A, vai
   pagar em 6x no cartão."
4. "Faz uma receita de amoxicilina pro João." → deve avisar da alergia a
   penicilina e não emitir sem a sua confirmação.
5. "Atestado de comparecimento pra Mari, hoje das 9 às 10:30." → PDF.
6. "Termo de consentimento de implante pra Mari." → PDF para imprimir.

## 3. Estoque (2 min)

1. "Contei o estoque: 2 caixas de luva M e 1 caixa de articaína." → contagem
   inicial.
2. "Comprei 2 caixas de articaína a 180 cada na Dental Cremer, no pix." → entra
   no estoque e vira despesa de materiais.
3. Registre um atendimento ("Acabei a Mari, resina MO no 36, um tubete de
   articaína") → a baixa do material sai sozinha e, se algo ficar abaixo do
   mínimo, o Claude avisa.
4. "O que está acabando?" / "Faz a lista de compras."

## 4. Financeiro (2 min)

1. "A Mari pagou 350 no pix." → recebimento com recibo do Receita Saúde
   pendente.
2. "Paguei 400 do laboratório da prótese do Carlos." → despesa.
3. "Como está o mês?" → recebido, despesas, resultado e avisos.
4. "Gera o pacote do contador de novembro." → planilhas e lote do Receita
   Saúde em links.

## 5. iPad (2 min)

1. No iPhone: "Gera o link do iPad." → o Claude mostra o link uma vez só.
2. No iPad, abra o link no Safari, toque em Compartilhar > Adicionar à Tela de
   Início. O app abre em Hoje.
3. Confira: agenda da semana, ficha da Mari (odontograma, orçamentos,
   documentos, financeiro), Estoque e Financeiro.
4. "Revoga o acesso do iPad." → o app volta a pedir o código.
