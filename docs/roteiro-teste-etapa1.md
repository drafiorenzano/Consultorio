# Roteiro de teste da etapa 1 (iPhone)

Objetivo: ver se o Claude entende, por ditado, anamnese, odontograma, plano de
tratamento, preços e correções. Leva uns 25 minutos. Todos os pacientes da
base são fictícios. Se ainda não fez o roteiro da etapa 0, faça antes (ele
explica como adicionar o conector e criar o Project).

## 1. Atualizar o conector e o Project

1. A URL do conector não mudou. Em claude.ai > **Configurações** >
   **Conectores** > Consultório, desconecte e conecte de novo (ou use
   "Atualizar", se aparecer) para ele ler as ferramentas novas. Devem aparecer
   8: buscar_paciente, cadastrar_paciente, atualizar_paciente,
   registrar_anamnese, registrar_odontograma, registrar_atendimento,
   listar_procedimentos e salvar_procedimento.
2. Permissões: buscar_paciente e listar_procedimentos em "Sempre permitir";
   as outras em "Pedir aprovação".
3. Troque as **Instruções** do Project pelo texto novo de
   `docs/instrucoes-project.md`.

## 2. Testes por ditado

Fale normalmente pelo microfone do campo de mensagem. Anote o que aconteceu em
cada um.

| # | Diga | Esperado |
|---|---|---|
| 1 | "Abre a Mari." | Mostra a ficha: alergia a dipirona, medo de dentista, pressão 12x8, 18 e 28 ausentes, 36 restaurado (resina MO). |
| 2 | "Anamnese do Carlos: tem fibrilação atrial, usa Xarelto 20 miligramas, pressão alta controlada com losartana, sem alergia, o resto tudo não. Pressão 14 por 9." | Resume e pede confirmação; grava. Responde com os alertas (anticoagulante, hipertensão, cardiopatia) e as perguntas pendentes (queixa, última consulta, higiene). |
| 3 | "Avaliação do João: cárie na oclusal do 46, restauração de amálgama ruim MO no 26, faltam os sisos de cima. Vou fazer resina no 46 e trocar a do 26." | Grava no odontograma: cárie O no 46, restauração insatisfatória MO no 26, 18 e 28 ausentes; planejado resina 1 face no 46 e resina 2 faces no 26. |
| 4 | "Quanto eu cobro por um implante com a coroa?" | Implante unitário R$ 1.800 + coroa sobre implante R$ 1.500. Não inventa preço. |
| 5 | "E um canal de molar?" | Diz que ainda não tem preço dela e mostra só a faixa de mercado como referência. |
| 6 | "Fiz a resina no 46 do João, oclusal, cor A3, um tubete de lidocaína com epinefrina." | Grava o atendimento ligado a "resina 1 face"; no odontograma a cárie e o planejado do 46 saem e fica "restauração O, feito hoje". |
| 6b | "Extraí o 38 do João." | Antes de gravar, ou na resposta, avisa que o João não tem anamnese registrada (extração é procedimento invasivo). O 38 passa a ausente. |
| 7 | "O João não é alérgico a penicilina, é a amoxicilina. Corrige a ficha." | Usa atualizar_paciente: tira o alerta de penicilina e põe amoxicilina. Mostra os alertas finais. |
| 8 | "Tira o 28 do odontograma da Mari, marquei errado." | Pede o motivo (ou usa o que você disse), remove a marca e mostra que o 28 voltou a ficar sem registro. |
| 9 | "A Mari fez o canal do 36 em outro dentista ano passado." | Marca tratamento de canal no 36 como já existente (inicial), sem criar atendimento. |

## 3. Modo de voz

No modo de voz (onda sonora), repita os testes 1 e 6. Observe se ele usa o
conector, como aparece o pedido de aprovação e se entende números de dente e
faces.

## 4. O que me mandar

Para cada teste: funcionou / não funcionou / estranho, e uma frase sobre o
que aconteceu. Prints ajudam. Eu leio a auditoria (o texto que o Claude
recebeu e o que ele gravou) e ajusto as ferramentas.

Observação: o projeto do Supabase é do plano gratuito e pausa depois de 7 dias
sem uso. Se o conector não responder, me avise que eu reativo.
