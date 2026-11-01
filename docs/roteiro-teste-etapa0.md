# Roteiro de teste da etapa 0 (iPhone)

Objetivo: confirmar que o Claude no iPhone entende o ditado em português, usa o
conector para buscar e gravar, e como aparece o pedido de aprovação. Leva uns
20 minutos. Todos os pacientes da base são fictícios.

Pode testar na sua própria conta do Claude: os dados ficam no Supabase da
Andressa, não na sua conta. Quando a licença dela existir, repetimos no
aparelho dela.

## 1. Adicionar o conector (no computador, uma vez)

1. Abra claude.ai > **Configurações** > **Conectores** > **Adicionar conector
   personalizado** (os nomes podem variar um pouco).
2. Nome: `Consultório`. URL do servidor MCP:

   `https://<projeto>.supabase.co/functions/v1/mcp/<token>` (o Guilherme recebe a URL com o token por fora do repositório)

3. Deixe em branco os campos de OAuth (Client ID/Secret) e salve. Ele deve
   listar 3 ferramentas: buscar_paciente, cadastrar_paciente e
   registrar_atendimento.
4. Nas permissões do conector, deixe **buscar_paciente** como "Sempre
   permitir" e as outras duas como "Pedir aprovação". Assim testamos o pedido
   de aprovação no celular.

A URL funciona como senha: não mande para ninguém. Se vazar, eu revogo e gero
outra em um minuto.

## 2. Criar o Project

1. Em claude.ai > **Projects**, crie "Consultório (teste)".
2. Cole em **Instruções** o texto de `docs/instrucoes-project.md`.
3. No iPhone, abra o app do Claude, entre no Project e confira, no botão de
   ferramentas da conversa, se o conector Consultório está ligado.

## 3. Testes por ditado

Use o microfone do campo de mensagem (ditado) e fale normalmente. Anote o que
aconteceu em cada um.

| # | Diga | Esperado |
|---|---|---|
| 1 | "Quem é a Mari? Ela tem alguma alergia?" | Acha Mariana Costa Ribeiro e avisa alergia a dipirona. |
| 2 | "Paciente nova: Beatriz Lopes Andrade, nascida em 14 de fevereiro de 1995, telefone 11 98877-6655, alérgica a látex, toma levotiroxina." | Resume e pede confirmação; depois de "sim", pede sua aprovação da ferramenta, grava e avisa que falta o CPF. |
| 3 | "Acabei a Beatriz. Fiz profilaxia e uma resina na oclusal do 46, cor A2, um tubete de lidocaína. Volta em 6 meses." | Confirma e grava: profilaxia (boca), resina 46 face O, lidocaína 1 tubete, retorno em ~6 meses. |
| 4 | "Abre o Carlos." | Mostra a ficha e destaca que ele usa rivaroxabana (anticoagulante). |
| 5 | "Registra para a Maria que fiz uma limpeza." | Não acha "Maria" exata e pergunta se é a Mariana. Não deve gravar sem perguntar. |
| 6 | "Corrige o último atendimento da Beatriz: a resina foi no 47, não no 46." | Grava uma correção ligada ao atendimento anterior (o original continua lá). |
| 7 | "Extraí o 19 do João." | Explica que o dente 19 não existe na numeração FDI e pergunta qual era. Nada é gravado. |

## 4. Testes no modo de voz

Toque no botão do modo de voz (onda sonora) e repita os testes 1 e 3.
Observe:

- Ele usa o conector dentro do modo de voz?
- Como aparece o pedido de aprovação (na tela, falado, não aparece)?
- Ele entende bem português falado, nomes e números de dente?

Se o modo de voz falhar, seguimos só com ditado, que já resolve.

## 5. O que me mandar

Para cada teste: funcionou / não funcionou / estranho, e uma frase sobre o
que aconteceu. Prints do pedido de aprovação ajudam. Eu leio a auditoria (o
texto que o Claude recebeu e o que ele gravou) e ajusto as ferramentas.

Observação: o projeto do Supabase é do plano gratuito e pausa depois de 7 dias
sem uso. Se o teste for mais tarde e o conector não responder, me avise que eu
reativo.
