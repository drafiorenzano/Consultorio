-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme), 1ª leva.

-- A resina indireta reforçada com zircônia (R$ 850) é onlay, não coroa: no
-- odontograma vira restauração (com faces), não coroa.
update public.procedimentos
   set nome = 'Onlay em resina indireta reforçada com zircônia',
       aplica_a = 'dente_faces',
       condicao_resultante = 'restauracao',
       detalhe_resultante = 'onlay em resina indireta reforçada com zircônia',
       sinonimos = array['onlay', 'onlay em resina', 'onlay de resina', 'onlay em resina indireta',
                         'onlay de resina reforcada com zirconia', 'resina indireta',
                         'resina indireta reforcada com zirconia', 'restauracao indireta']
 where codigo = 'resina_indireta_zirconia';

-- Preços que ela passou.
update public.procedimentos as p
   set preco = v.preco, faixa_mercado = null
  from (values ('consulta_avaliacao', 280), ('urgencia', 350),
               ('radiografia_periapical', 20), ('selante', 220)) as v(codigo, preco)
 where p.codigo = v.codigo;

-- Radiografia panorâmica (não estava no catálogo).
insert into public.procedimentos
  (codigo, nome, grupo, categoria, aplica_a, preco, sinonimos, ordem)
values
  ('radiografia_panoramica', 'Radiografia panorâmica', 'Diagnóstico', 'diagnostico', 'boca', 130,
   array['panoramica', 'panoramico', 'radiografia panoramica', 'rx panoramico', 'rx panoramica',
         'raio x panoramico', 'raio x panoramica'], 225)
on conflict (codigo) do update
   set preco = excluded.preco, faixa_mercado = null, ativo = true;

create or replace function public.explicacao_leiga(p_codigo text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_codigo is null then null
    when p_codigo = 'resina_indireta_zirconia' then
      'Peça feita sob medida no laboratório que reconstrói a parte de cima do dente, mais resistente que a restauração comum.'
    when p_codigo like 'resina\_%' then
      'Restauração da cor do dente, para tratar cárie, fratura ou desgaste.'
    when p_codigo like 'exodontia\_siso%' then 'Remoção do dente do siso.'
    when p_codigo = 'exodontia_deciduo' then 'Remoção do dente de leite.'
    when p_codigo like 'exodontia\_%' then 'Remoção do dente.'
    when p_codigo = 'retratamento_canal' then 'Refazer um tratamento de canal antigo que voltou a dar problema.'
    when p_codigo like 'canal\_%' then 'Tratamento do nervo do dente para tirar a dor ou a infecção e manter o dente.'
    when p_codigo = 'pulpectomia' then 'Alívio da dor de dente com a limpeza do nervo (primeira etapa do canal).'
    when p_codigo = 'implante_unitario' then 'Raiz artificial de titânio que substitui o dente perdido.'
    when p_codigo = 'coroa_sobre_implante' then 'Dente de porcelana fixado sobre o implante.'
    when p_codigo = 'protocolo_gm' then 'Dentes fixos sobre implantes para a arcada inteira.'
    when p_codigo = 'coroa_provisoria' then 'Dente provisório enquanto o definitivo fica pronto.'
    when p_codigo like 'coroa\_%' then
      'Peça que cobre e protege o dente inteiro, devolvendo forma e cor.'
    when p_codigo = 'nucleo' then 'Pino que dá sustentação à coroa em dente com canal.'
    when p_codigo = 'consulta_preventiva' then 'Limpeza completa, polimento e flúor.'
    when p_codigo = 'consulta_avaliacao' then 'Exame completo da boca e planejamento do tratamento.'
    when p_codigo = 'urgencia' then 'Atendimento para aliviar a dor ou resolver uma urgência.'
    when p_codigo = 'radiografia_periapical' then 'Radiografia do dente para o diagnóstico.'
    when p_codigo = 'radiografia_panoramica' then 'Radiografia da boca inteira para o diagnóstico e o planejamento.'
    when p_codigo = 'selante' then 'Proteção dos sulcos do dente contra a cárie.'
    when p_codigo = 'restauracao_provisoria' then 'Fechamento provisório do dente até o tratamento definitivo.'
    when p_codigo = 'raspagem_sextante' then 'Limpeza profunda abaixo da gengiva para tratar a inflamação.'
    when p_codigo = 'gengivectomia' then 'Ajuste do contorno da gengiva.'
    when p_codigo = 'frenectomia' then 'Pequena cirurgia no freio do lábio ou da língua.'
    when p_codigo = 'biopsia' then 'Retirada de um pequeno pedaço de tecido para exame.'
    when p_codigo = 'remocao_sutura' then 'Retirada dos pontos.'
    when p_codigo = 'enxerto_osseo' then 'Reconstrução do osso para receber o implante.'
    when p_codigo = 'levantamento_seio' then 'Ganho de osso no fundo da arcada de cima para receber o implante.'
    when p_codigo = 'reabertura_implante' then 'Exposição do implante para começar a parte do dente.'
    when p_codigo = 'protese_parcial_removivel' then 'Prótese de tirar e pôr que repõe alguns dentes.'
    when p_codigo = 'protese_total' then 'Dentadura completa.'
    when p_codigo = 'placa_miorrelaxante' then 'Placa para usar à noite, que protege os dentes do ranger e relaxa a musculatura.'
    when p_codigo like 'clareamento%' then 'Deixa os dentes mais claros com gel clareador.'
  end
$$;
