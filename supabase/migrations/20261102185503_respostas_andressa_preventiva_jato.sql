-- Respostas da Dra. Andressa (02/11/2026, pelo Guilherme), 3ª leva:
-- consulta preventiva passa de R$ 380 para R$ 450 e inclui jato de bicarbonato.
update public.procedimentos
   set preco = 450,
       nome = 'Consulta preventiva (limpeza completa + jato de bicarbonato + profilaxia e flúor)',
       sinonimos = array(select distinct s from unnest(sinonimos || array['jato de bicarbonato', 'jato',
                         'profilaxia com jato', 'limpeza com jato']) s)
 where codigo = 'consulta_preventiva';

-- O bicarbonato do jato entra no estoque e no kit da preventiva (quantidade de
-- referência; ela ajusta).
insert into public.estoque_materiais (codigo, nome, categoria, unidade_compra, unidade_uso, fator,
                                      estoque_minimo, controla_validade, sinonimos)
values ('bicarbonato_jato', 'Bicarbonato de sódio para jato (profilaxia)', 'profilaxia', 'frasco', 'g', 250, 50, true,
        array(select distinct public.normalizar(s) from unnest(array['bicarbonato', 'bicarbonato de sódio',
              'pó de bicarbonato', 'pó para jato', 'pó do jato']) s))
on conflict (codigo) do nothing;

insert into public.estoque_kit_itens (kit_id, material_id, quantidade)
select k.id, m.id, 10
  from public.estoque_kits k
  join public.procedimentos p on p.id = k.procedimento_id and p.codigo = 'consulta_preventiva'
  join public.estoque_materiais m on m.codigo = 'bicarbonato_jato'
 where not exists (select 1 from public.estoque_kit_itens i where i.kit_id = k.id and i.material_id = m.id);

update public.estoque_kits k
   set nome = 'Kit ' || p.nome
  from public.procedimentos p
 where k.procedimento_id = p.id and p.codigo = 'consulta_preventiva';

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
    when p_codigo = 'consulta_preventiva' then 'Limpeza completa, jato de bicarbonato, polimento e flúor.'
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
