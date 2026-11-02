-- =====================================================================
-- Etapa 4b: financeiro (ferramentas da IA).
--   registrar_pagamento (pagamento, combinar, estornar, cancelar_acordo)
--   registrar_despesa   (registrar, lancar_fixas, alterar_fixa, encerrar_fixa, estornar)
--   ver_financeiro      (mes, paciente, a_receber, inadimplentes, recibos, despesas, configuracao)
--   gerar_pacote_contador (dados do mês + registro do pacote gerado)
--   marcar_recibos, configurar_financeiro
-- Mesmo padrão das etapas anteriores: uma função por ferramenta, numa
-- transação só, com a solicitação aberta no início.
-- Para a integração: saldo_paciente(uuid), financeiro_resumo_mes(date),
-- financeiro_lancar_despesa_automatica(...) e
-- financeiro_estornar_despesa_automatica(...).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Leitura de valores e utilitários
-- ---------------------------------------------------------------------

-- Regime fiscal numa data: com data de virada, PJ a partir dela; sem data, o
-- regime configurado. (Substitui a versão da migration base.)
create or replace function public.regime_fiscal(p_data date)
returns text
language sql
stable
set search_path = ''
as $$
  select case when c.pj_a_partir_de is not null
              then case when p_data >= c.pj_a_partir_de then 'pj' else 'pf' end
              else c.regime end
    from public.configuracao_financeira c
$$;

-- Solicitação aberta nesta transação (para gravar junto do lançamento).
create or replace function public.fin_solicitacao()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(current_setting('app.solicitacao_id', true), '')::uuid
$$;

-- Valor em reais: aceita 350, 350.5, "350,50", "1.800,00", "R$ 90".
create or replace function public.fin_valor(p_valor text, p_campo text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_valor, ''));
begin
  if v = '' then return null; end if;
  v := regexp_replace(v, '^R\$\s*', '', 'i');
  if v ~ '^-?\d{1,3}(\.\d{3})+(,\d{1,2})?$' then
    v := replace(replace(v, '.', ''), ',', '.');
  elsif v ~ '^-?\d+,\d{1,2}$' then
    v := replace(v, ',', '.');
  elsif v !~ '^-?\d+(\.\d+)?$' then
    raise exception '% "%" inválido: use só o número em reais (ex.: 350 ou 350.50).', p_campo, p_valor;
  end if;
  return round(v::numeric, 2);
end
$$;

create or replace function public.fin_inteiro(p_valor text, p_campo text)
returns int
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_valor, ''));
begin
  if v = '' then return null; end if;
  if v !~ '^\d{1,4}$' then
    raise exception '% "%" inválido: use um número inteiro.', p_campo, p_valor;
  end if;
  return v::int;
end
$$;

create or replace function public.fin_uuid(p_valor text, p_campo text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_valor is null or btrim(p_valor) = '' then return null; end if;
  return btrim(p_valor)::uuid;
exception when invalid_text_representation then
  raise exception '% inválido: use o id devolvido pelas ferramentas.', p_campo;
end
$$;

-- Mês "AAAA-MM" (ou uma data AAAA-MM-DD) -> primeiro dia do mês. Vazio = mês atual.
create or replace function public.fin_mes(p_valor text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_valor, ''));
begin
  if v = '' then return date_trunc('month', public.hoje())::date; end if;
  if v ~ '^\d{4}-\d{2}$' then
    return (v || '-01')::date;
  elsif v ~ '^\d{4}-\d{2}-\d{2}$' then
    return date_trunc('month', v::date)::date;
  end if;
  raise exception 'Mês "%" inválido: use AAAA-MM (ex.: 2026-11).', p_valor;
exception
  when datetime_field_overflow or invalid_datetime_format then
    raise exception 'Mês "%" não existe no calendário.', p_valor;
end
$$;

-- Dia de vencimento num mês, ajustado ao último dia (dia 31 em fevereiro = 28/29).
create or replace function public.fin_dia_do_mes(p_mes date, p_dia int)
returns date
language sql
immutable
set search_path = ''
as $$
  select make_date(extract(year from p_mes)::int, extract(month from p_mes)::int,
                   least(p_dia, extract(day from (date_trunc('month', p_mes) + interval '1 month - 1 day'))::int))
$$;

-- R$ 1.234,56
create or replace function public.fin_reais(p_valor numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'R$ ' || translate(to_char(coalesce(p_valor, 0), 'FM999,999,990.00'), ',.', '.,')
$$;

-- Forma de pagamento dita -> código.
create or replace function public.ler_forma_pagamento(p_valor text, p_parcelas int default null)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := replace(public.normalizar(p_valor), '_', ' ');
  r text;
begin
  if v = '' then return null; end if;
  r := case
    when v in ('pix') then 'pix'
    when v in ('dinheiro', 'especie', 'em especie', 'em dinheiro', 'cash') then 'dinheiro'
    when v in ('debito', 'cartao de debito', 'cartao debito', 'no debito') then 'debito'
    when v in ('credito', 'credito vista', 'credito a vista', 'credito avista', 'cartao de credito', 'cartao credito',
               'cartao', 'no credito', 'no cartao') then
      case when coalesce(p_parcelas, 1) > 1 then 'credito_parcelado' else 'credito_vista' end
    when v in ('credito parcelado', 'parcelado', 'cartao parcelado', 'parcelado no cartao', 'parcelado no credito')
      then 'credito_parcelado'
    when v in ('boleto', 'boleto bancario') then 'boleto'
    when v in ('transferencia', 'transferencia bancaria', 'ted', 'doc', 'deposito') then 'transferencia'
  end;
  if r is null then
    raise exception 'Forma de pagamento "%" não reconhecida. Use pix, dinheiro, debito, credito_vista, credito_parcelado, boleto ou transferencia.', p_valor;
  end if;
  return r;
end
$$;

-- Categoria de despesa dita -> código.
create or replace function public.ler_categoria_despesa(p_valor text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := replace(public.normalizar(p_valor), '_', ' ');
  r text;
begin
  if v = '' then return null; end if;
  r := case
    when v in ('aluguel sala', 'aluguel', 'aluguel de sala', 'sala', 'locacao', 'locacao de sala', 'reserva de sala',
               'coworking') then 'aluguel_sala'
    when v in ('materiais', 'material', 'insumos', 'material odontologico', 'materiais odontologicos',
               'deposito dental', 'dental') then 'materiais'
    when v in ('laboratorio', 'lab', 'protetico', 'protese', 'laboratorio de protese') then 'laboratorio'
    when v in ('cro', 'anuidade cro', 'anuidade do cro', 'conselho') then 'cro'
    when v in ('contador', 'contabilidade', 'honorarios contabeis', 'escritorio contabil') then 'contador'
    when v in ('inss', 'previdencia', 'gps', 'carne inss') then 'inss'
    when v in ('impostos', 'imposto', 'das', 'darf', 'carne leao', 'simples', 'simples nacional', 'irpf',
               'imposto de renda', 'impostos das') then 'impostos'
    when v in ('iss', 'issqn', 'imposto sobre servico') then 'iss'
    when v in ('seguro', 'seguro rc', 'seguro de responsabilidade civil', 'responsabilidade civil') then 'seguro'
    when v in ('software', 'sistema', 'assinatura', 'aplicativo', 'app', 'programa') then 'software'
    when v in ('manutencao', 'conserto', 'assistencia tecnica', 'reparo') then 'manutencao'
    when v in ('marketing', 'anuncio', 'anuncios', 'publicidade', 'instagram', 'propaganda', 'site') then 'marketing'
    when v in ('outros', 'outro', 'outra', 'outras', 'diversos') then 'outros'
  end;
  if r is null then
    raise exception 'Categoria "%" não reconhecida. Use aluguel_sala, materiais, laboratorio, cro, contador, inss, impostos, iss, seguro, software, manutencao, marketing ou outros.', p_valor;
  end if;
  return r;
end
$$;

create or replace function public.fin_rotulo_categoria(p_categoria text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_categoria
    when 'aluguel_sala' then 'Aluguel de sala' when 'materiais' then 'Materiais'
    when 'laboratorio' then 'Laboratório' when 'cro' then 'CRO' when 'contador' then 'Contador'
    when 'inss' then 'INSS' when 'impostos' then 'Impostos (DAS/DARF)' when 'iss' then 'ISS'
    when 'seguro' then 'Seguro' when 'software' then 'Software' when 'manutencao' then 'Manutenção'
    when 'marketing' then 'Marketing' else 'Outros' end
$$;

-- Taxa da maquininha pela configuração: percentual (por número de parcelas,
-- se houver tabela, ou percentual + adicional por parcela), fixo e dias.
create or replace function public.calcular_taxa_pagamento(
  p_forma text,
  p_parcelas int,
  p_valor numeric,
  p_data date,
  out percentual numeric,
  out taxa numeric,
  out liquido numeric,
  out data_credito date)
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb;
  n int := greatest(coalesce(p_parcelas, 1), 1);
begin
  select c.taxas -> p_forma into v from public.configuracao_financeira c;
  v := coalesce(v, '{}'::jsonb);
  if p_forma = 'credito_parcelado' and v -> 'por_parcelas' ->> n::text is not null then
    percentual := (v -> 'por_parcelas' ->> n::text)::numeric;
  else
    percentual := coalesce((v ->> 'percentual')::numeric, 0)
      + case when p_forma = 'credito_parcelado'
             then coalesce((v ->> 'adicional_por_parcela')::numeric, 0) * (n - 1) else 0 end;
  end if;
  percentual := least(round(percentual, 3), 30);
  taxa := round(p_valor * percentual / 100 + coalesce((v ->> 'fixo')::numeric, 0), 2);
  liquido := p_valor - taxa;
  data_credito := p_data + coalesce((v ->> 'dias')::int, 0);
end
$$;

-- ---------------------------------------------------------------------
-- Situação de parcelas, recibos e saldo
-- ---------------------------------------------------------------------
create or replace function public.parcela_pago(p_parcela uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(r.valor_bruto), 0) from public.recebimentos r where r.parcela_id = p_parcela
$$;

create or replace function public.parcela_json(p public.parcelas_previstas)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  a public.acordos_pagamento;
  v_pago numeric := public.parcela_pago(p.id);
  v_rest numeric := greatest(p.valor - public.parcela_pago(p.id), 0);
  v_sit text;
begin
  select * into a from public.acordos_pagamento where id = p.acordo_id;
  v_sit := case
    when v_rest = 0 then 'quitada'
    when p.cancelada_em is not null or a.cancelado_em is not null then 'cancelada'
    when p.vencimento < public.hoje() then 'atrasada'
    when v_pago > 0 then 'parcial'
    else 'aberta' end;
  return jsonb_strip_nulls(jsonb_build_object(
    'id', p.id,
    'acordo', a.numero,
    'acordo_id', a.id,
    'descricao', a.descricao,
    'parcela', format('%s/%s', p.numero, p.total),
    'vencimento', p.vencimento,
    'valor', p.valor,
    'pago', v_pago,
    'restante', case when v_sit = 'cancelada' then 0 else v_rest end,
    'situacao', v_sit,
    'dias_atraso', case when v_sit = 'atrasada' then public.hoje() - p.vencimento end));
end
$$;

-- Situação do recibo do Receita Saúde de um recebimento:
-- pendente | emitido | cancelar (emitido, mas o pagamento foi estornado) |
-- cancelado | nao_se_aplica (estorno, ou estornado sem recibo) | nfse_contador (PJ).
create or replace function public.recibo_situacao(p_recebimento uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  r public.recebimentos;
  e public.recibos_receita_saude;
  v_estornado boolean;
begin
  select * into r from public.recebimentos where id = p_recebimento;
  if not found then return null; end if;
  if r.estorna_id is not null then
    return jsonb_build_object('situacao', 'nao_se_aplica');
  end if;
  if r.regime_fiscal = 'pj' then
    return jsonb_build_object('situacao', 'nfse_contador');
  end if;
  v_estornado := exists (select 1 from public.recebimentos x where x.estorna_id = r.id);
  select * into e from public.recibos_receita_saude
   where recebimento_id = r.id order by registrado_em desc limit 1;
  if e.id is null then
    return jsonb_build_object('situacao', case when v_estornado then 'nao_se_aplica' else 'pendente' end);
  end if;
  if e.situacao = 'emitido' then
    return jsonb_strip_nulls(jsonb_build_object(
      'situacao', case when v_estornado then 'cancelar' else 'emitido' end,
      'codigo', e.codigo, 'data_emissao', e.data_emissao));
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'situacao', case when v_estornado then 'cancelado' else 'pendente' end,
    'codigo_cancelado', e.codigo));
end
$$;

create or replace function public.recebimento_json(r public.recebimentos)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', r.id,
    'numero', r.numero,
    'data_pagamento', r.data_pagamento,
    'paciente', (select jsonb_build_object('id', p.id, 'nome', p.nome) from public.pacientes p where p.id = r.paciente_id),
    'pagador', jsonb_build_object('nome', r.pagador_nome, 'cpf', r.pagador_cpf, 'e_o_paciente', r.pagador_e_paciente),
    'valor_bruto', r.valor_bruto,
    'forma', r.forma,
    'parcelas_cartao', case when r.parcelas_cartao > 1 then r.parcelas_cartao end,
    'taxa_percentual', r.taxa_percentual,
    'taxa', r.taxa_valor,
    'valor_liquido', r.valor_liquido,
    'data_credito_prevista', r.data_credito_prevista,
    'descricao', r.descricao,
    'parcela', (select format('%s/%s do acordo nº %s', pp.numero, pp.total, a.numero)
                  from public.parcelas_previstas pp join public.acordos_pagamento a on a.id = pp.acordo_id
                 where pp.id = r.parcela_id),
    'atendimento_id', r.atendimento_id,
    'orcamento_id', r.orcamento_id,
    'regime_fiscal', r.regime_fiscal,
    'estorno_de', (select o.numero from public.recebimentos o where o.id = r.estorna_id),
    'motivo_estorno', r.motivo_estorno,
    'estornado_por', (select e.numero from public.recebimentos e where e.estorna_id = r.id limit 1),
    'recibo', public.recibo_situacao(r.id)))
$$;

create or replace function public.acordo_json(p_acordo uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', a.id,
    'numero', a.numero,
    'paciente', (select jsonb_build_object('id', p.id, 'nome', p.nome) from public.pacientes p where p.id = a.paciente_id),
    'descricao', a.descricao,
    'valor_total', a.valor_total,
    'forma_prevista', a.forma_prevista,
    'orcamento_id', a.orcamento_id,
    'criado_em', (a.criado_em at time zone public.fuso())::date,
    'cancelado_em', (a.cancelado_em at time zone public.fuso())::date,
    'motivo_cancelamento', a.motivo_cancelamento,
    'parcelas', (select jsonb_agg(public.parcela_json(pp) order by pp.numero)
                   from public.parcelas_previstas pp where pp.acordo_id = a.id)))
    from public.acordos_pagamento a
   where a.id = p_acordo
$$;

-- Saldo financeiro do paciente (para a ficha e para a IA).
create or replace function public.saldo_paciente(p_paciente uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_p public.parcelas_previstas;
  v_j jsonb;
  v_lista jsonb := '[]'::jsonb;
  v_areceber numeric := 0;
  v_atrasado numeric := 0;
  v_pago numeric;
  v_ultimo date;
begin
  select coalesce(sum(valor_bruto), 0), max(data_pagamento) filter (where estorna_id is null)
    into v_pago, v_ultimo
    from public.recebimentos where paciente_id = p_paciente;
  for v_p in
    select pp.* from public.parcelas_previstas pp
      join public.acordos_pagamento a on a.id = pp.acordo_id
     where a.paciente_id = p_paciente and a.cancelado_em is null and pp.cancelada_em is null
     order by pp.vencimento, a.numero, pp.numero
  loop
    v_j := public.parcela_json(v_p);
    if (v_j ->> 'restante')::numeric > 0 then
      v_areceber := v_areceber + (v_j ->> 'restante')::numeric;
      if v_j ->> 'situacao' = 'atrasada' then
        v_atrasado := v_atrasado + (v_j ->> 'restante')::numeric;
      end if;
      v_lista := v_lista || jsonb_build_array(v_j);
    end if;
  end loop;
  return jsonb_strip_nulls(jsonb_build_object(
    'pago_total', v_pago,
    'ultimo_pagamento', v_ultimo,
    'a_receber', v_areceber,
    'atrasado', v_atrasado,
    'parcelas_em_aberto', v_lista));
end
$$;

-- ---------------------------------------------------------------------
-- Despesas: JSON, estorno e lançamento automático (agenda, estoque)
-- ---------------------------------------------------------------------
create or replace function public.despesa_json(d public.despesas)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', d.id,
    'numero', d.numero,
    'data', d.data,
    'competencia', to_char(d.competencia, 'YYYY-MM'),
    'categoria', d.categoria,
    'descricao', d.descricao,
    'fornecedor', d.fornecedor,
    'fornecedor_documento', d.fornecedor_documento,
    'valor', d.valor,
    'forma', d.forma,
    'paciente', (select jsonb_build_object('id', p.id, 'nome', p.nome) from public.pacientes p where p.id = d.paciente_id),
    'origem', case when d.origem <> 'manual' then d.origem end,
    'comprovante', d.comprovante,
    'estorno_de', (select o.numero from public.despesas o where o.id = d.estorna_id),
    'motivo_estorno', d.motivo_estorno,
    'estornada_por', (select e.numero from public.despesas e where e.estorna_id = d.id limit 1)))
$$;

create or replace function public.despesa_fixa_json(r public.despesas_recorrentes)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', r.id,
    'descricao', r.descricao,
    'categoria', r.categoria,
    'fornecedor', r.fornecedor,
    'valor', r.valor,
    'dia', r.dia,
    'forma', r.forma,
    'desde', to_char(r.inicio, 'YYYY-MM'),
    'encerrada_em', r.encerrada_em,
    'ativa', r.encerrada_em is null or r.encerrada_em >= public.hoje()))
$$;

-- Despesa ainda valendo (não é estorno nem foi estornada).
create or replace function public.despesa_vigente(p_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.despesas d
                  where d.id = p_id and d.estorna_id is null
                    and not exists (select 1 from public.despesas e where e.estorna_id = d.id))
$$;

-- Lançamento negativo que anula uma despesa.
create or replace function public.despesa_estornar(p_id uuid, p_motivo text, p_data date default null)
returns public.despesas
language plpgsql
set search_path = ''
as $$
declare
  d public.despesas;
  e public.despesas;
begin
  select * into d from public.despesas where id = p_id;
  if not found then raise exception 'Despesa não encontrada.'; end if;
  if not public.despesa_vigente(p_id) then
    raise exception 'A despesa nº % já é um estorno ou já foi estornada.', d.numero;
  end if;
  insert into public.despesas (data, competencia, categoria, descricao, fornecedor, fornecedor_documento, valor, forma,
                               paciente_id, origem, origem_id, comprovante, estorna_id, motivo_estorno, solicitacao_id)
  values (coalesce(p_data, d.data), d.competencia, d.categoria, format('Estorno da despesa nº %s', d.numero),
          d.fornecedor, d.fornecedor_documento, -d.valor, d.forma, d.paciente_id, d.origem, d.origem_id, d.comprovante,
          d.id, p_motivo, public.fin_solicitacao())
  returning * into e;
  return e;
end
$$;

-- Despesa vinda de outro módulo (reserva de sala da agenda, compra do
-- estoque). Idempotente: mesma origem com os mesmos dados não duplica; se o
-- valor, a data ou a categoria mudarem, estorna o lançamento anterior e lança
-- o novo. Valor nulo ou zero só estorna (origem cancelada).
create or replace function public.financeiro_lancar_despesa_automatica(
  p_origem text,
  p_origem_id uuid,
  p_data date,
  p_categoria text,
  p_valor numeric,
  p_descricao text,
  p_fornecedor text default null,
  p_paciente uuid default null,
  p_forma text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_atual public.despesas;
  v_nova public.despesas;
  v_cat text := coalesce(public.ler_categoria_despesa(p_categoria),
                         case p_origem when 'reserva_sala' then 'aluguel_sala' else 'materiais' end);
begin
  if p_origem is null or p_origem not in ('reserva_sala', 'compra') then
    raise exception 'Origem "%" inválida para despesa automática: use reserva_sala ou compra.', p_origem;
  end if;
  if p_origem_id is null then
    raise exception 'Despesa automática sem o id de origem.';
  end if;
  select d.* into v_atual from public.despesas d
   where d.origem = p_origem and d.origem_id = p_origem_id and public.despesa_vigente(d.id)
   order by d.registrado_em desc limit 1;

  if v_atual.id is not null and v_atual.valor = round(coalesce(p_valor, 0), 2)
     and v_atual.data = p_data and v_atual.categoria = v_cat then
    return jsonb_build_object('status', 'sem_mudanca', 'despesa', public.despesa_json(v_atual));
  end if;
  if v_atual.id is not null then
    perform public.despesa_estornar(v_atual.id, format('Alterada na origem (%s).', p_origem), null);
  end if;
  if coalesce(p_valor, 0) <= 0 then
    return jsonb_build_object('status', case when v_atual.id is null then 'sem_mudanca' else 'estornada' end);
  end if;
  if p_data is null then
    raise exception 'Despesa automática sem data.';
  end if;
  insert into public.despesas (data, competencia, categoria, descricao, fornecedor, valor, forma, paciente_id,
                               origem, origem_id, solicitacao_id)
  values (p_data, date_trunc('month', p_data)::date, v_cat,
          coalesce(nullif(btrim(p_descricao), ''), public.fin_rotulo_categoria(v_cat)),
          nullif(btrim(p_fornecedor), ''), round(p_valor, 2), public.ler_forma_pagamento(p_forma, null), p_paciente,
          p_origem, p_origem_id, public.fin_solicitacao())
  returning * into v_nova;
  return jsonb_build_object('status', case when v_atual.id is null then 'lancada' else 'substituida' end,
                            'despesa', public.despesa_json(v_nova));
end
$$;

create or replace function public.financeiro_estornar_despesa_automatica(
  p_origem text,
  p_origem_id uuid,
  p_motivo text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select d.id from public.despesas d
     where d.origem = p_origem and d.origem_id = p_origem_id and public.despesa_vigente(d.id)
  loop
    perform public.despesa_estornar(v_id, coalesce(nullif(btrim(p_motivo), ''), format('Cancelada na origem (%s).', p_origem)), null);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('status', case when v_n = 0 then 'sem_mudanca' else 'estornada' end, 'estornadas', v_n);
end
$$;

-- Despesa fixa já lançada na competência (e não estornada).
create or replace function public.despesa_fixa_lancada(p_fixa uuid, p_competencia date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.despesas d
                  where d.origem = 'recorrente' and d.origem_id = p_fixa and d.competencia = p_competencia
                    and public.despesa_vigente(d.id))
$$;

-- ---------------------------------------------------------------------
-- Resumo do mês (também serve a painéis e ao pacote do contador)
-- ---------------------------------------------------------------------
create or replace function public.fin_totais_mes(p_mes date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with rec as (
    select coalesce(sum(valor_bruto), 0) bruto, coalesce(sum(taxa_valor), 0) taxas,
           coalesce(sum(valor_liquido), 0) liquido
      from public.recebimentos
     where data_pagamento >= p_mes and data_pagamento < (p_mes + interval '1 month')::date),
  desp as (
    select coalesce(sum(valor), 0) total from public.despesas
     where data >= p_mes and data < (p_mes + interval '1 month')::date)
  select jsonb_build_object('mes', to_char(p_mes, 'YYYY-MM'), 'recebido_bruto', rec.bruto, 'taxas', rec.taxas,
                            'recebido_liquido', rec.liquido, 'despesas', desp.total,
                            'resultado', rec.liquido - desp.total)
    from rec, desp
$$;

create or replace function public.financeiro_resumo_mes(p_mes date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ini date := date_trunc('month', p_mes)::date;
  v_fim date := (date_trunc('month', p_mes) + interval '1 month')::date;
  v_cfg public.configuracao_financeira;
  v_tot jsonb;
  v_formas jsonb;
  v_qtd int;
  v_areceber jsonb;
  v_cats jsonb;
  v_fixas jsonb;
  v_fixas_valor numeric;
  v_rec_pend int;
  v_rec_pend_valor numeric;
  v_rec_cancelar int;
  v_horas numeric;
  v_sem_hora int;
  v_atend int;
  v_custos_fixos numeric;
  v_avisos text[] := '{}';
begin
  select * into v_cfg from public.configuracao_financeira;
  v_tot := public.fin_totais_mes(v_ini);

  select count(*) into v_qtd from public.recebimentos r
   where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.estorna_id is null
     and not exists (select 1 from public.recebimentos e where e.estorna_id = r.id);

  select coalesce(jsonb_agg(jsonb_build_object('forma', forma, 'bruto', b, 'taxas', t, 'liquido', l) order by b desc), '[]'::jsonb)
    into v_formas
    from (select forma, sum(valor_bruto) b, sum(taxa_valor) t, sum(valor_liquido) l
            from public.recebimentos
           where data_pagamento >= v_ini and data_pagamento < v_fim
           group by forma having sum(valor_bruto) <> 0) x;

  with abertas as (
    select pp.vencimento, greatest(pp.valor - public.parcela_pago(pp.id), 0) restante
      from public.parcelas_previstas pp join public.acordos_pagamento a on a.id = pp.acordo_id
     where a.cancelado_em is null and pp.cancelada_em is null)
  select jsonb_build_object(
           'vence_no_mes', coalesce(sum(restante) filter (where vencimento >= v_ini and vencimento < v_fim), 0),
           'atrasado_hoje', coalesce(sum(restante) filter (where vencimento < public.hoje()), 0),
           'proximos_30_dias', coalesce(sum(restante) filter (where vencimento >= public.hoje()
                                                                and vencimento < public.hoje() + 30), 0),
           'total_em_aberto', coalesce(sum(restante), 0))
    into v_areceber
    from abertas where restante > 0;

  select coalesce(jsonb_agg(jsonb_build_object('categoria', categoria, 'total', s) order by s desc), '[]'::jsonb)
    into v_cats
    from (select categoria, sum(valor) s from public.despesas
           where data >= v_ini and data < v_fim group by categoria having sum(valor) <> 0) x;

  select coalesce(jsonb_agg(public.despesa_fixa_json(r) order by r.dia), '[]'::jsonb), coalesce(sum(r.valor), 0)
    into v_fixas, v_fixas_valor
    from public.despesas_recorrentes r
   where r.inicio < v_fim and (r.encerrada_em is null or r.encerrada_em >= v_ini)
     and not public.despesa_fixa_lancada(r.id, v_ini);

  select count(*) filter (where s = 'pendente'), coalesce(sum(valor_bruto) filter (where s = 'pendente'), 0),
         count(*) filter (where s = 'cancelar')
    into v_rec_pend, v_rec_pend_valor, v_rec_cancelar
    from (select r.valor_bruto, public.recibo_situacao(r.id) ->> 'situacao' s
            from public.recebimentos r
           where r.data_pagamento >= v_ini and r.data_pagamento < v_fim and r.estorna_id is null
             and r.regime_fiscal = 'pf') x;

  -- Hora clínica: custos fixos ÷ horas atendidas (versão mais recente de cada atendimento).
  select coalesce(sum(extract(epoch from (a.hora_fim - a.hora_inicio)) / 3600.0)
                    filter (where a.hora_inicio is not null and a.hora_fim is not null), 0),
         count(*) filter (where a.hora_inicio is null or a.hora_fim is null),
         count(*)
    into v_horas, v_sem_hora, v_atend
    from public.atendimentos a
   where a.data >= v_ini and a.data < v_fim
     and not exists (select 1 from public.atendimentos c where c.corrige_atendimento_id = a.id);
  select coalesce(sum(valor), 0) into v_custos_fixos from public.despesas
   where data >= v_ini and data < v_fim and categoria not in ('materiais', 'laboratorio', 'impostos', 'iss');

  if v_cfg.cpf_profissional is null then
    v_avisos := array_append(v_avisos, 'CPF da Dra. não configurado: o lote do Receita Saúde precisa dele (configurar_financeiro).');
  end if;
  if v_rec_pend > 0 then
    v_avisos := array_append(v_avisos, format('%s recibo(s) do Receita Saúde pendente(s) no mês, somando %s.',
                                              v_rec_pend, public.fin_reais(v_rec_pend_valor)));
  end if;
  if v_rec_cancelar > 0 then
    v_avisos := array_append(v_avisos, format('%s recibo(s) emitido(s) de pagamento estornado: cancele no Receita Saúde.', v_rec_cancelar));
  end if;
  if jsonb_array_length(v_fixas) > 0 and v_ini <= public.hoje() then
    v_avisos := array_append(v_avisos, format('%s despesa(s) fixa(s) ainda não lançada(s) no mês (%s): registrar_despesa com acao lancar_fixas.',
                                              jsonb_array_length(v_fixas), public.fin_reais(v_fixas_valor)));
  end if;
  if v_sem_hora > 0 then
    v_avisos := array_append(v_avisos, format('%s atendimento(s) sem horário de início e fim ficaram fora da hora clínica.', v_sem_hora));
  end if;
  if v_cfg.regime = 'pf' and v_cfg.pj_a_partir_de is not null then
    if v_cfg.pj_a_partir_de > v_ini and v_cfg.pj_a_partir_de < v_fim then
      v_avisos := array_append(v_avisos, format('Mês da virada: pagamentos até %s entram como pessoa física (Receita Saúde); a partir de %s, pessoa jurídica (NFS-e pelo contador).',
                                                to_char(v_cfg.pj_a_partir_de - 1, 'DD/MM/YYYY'), to_char(v_cfg.pj_a_partir_de, 'DD/MM/YYYY')));
    elsif v_cfg.pj_a_partir_de between public.hoje() and public.hoje() + 45 then
      v_avisos := array_append(v_avisos, format('A partir de %s os pagamentos passam a ser da pessoa jurídica (NFS-e emitida pelo contador). Até lá, Receita Saúde.',
                                                to_char(v_cfg.pj_a_partir_de, 'DD/MM/YYYY')));
    end if;
  end if;

  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'regime', case when public.regime_fiscal(v_ini) = public.regime_fiscal(v_fim - 1) then public.regime_fiscal(v_ini)
                   else 'pf_e_pj' end,
    'recebido', jsonb_build_object('bruto', v_tot -> 'recebido_bruto', 'taxas', v_tot -> 'taxas',
                                   'liquido', v_tot -> 'recebido_liquido', 'pagamentos', v_qtd, 'por_forma', v_formas),
    'a_receber', coalesce(v_areceber, '{}'::jsonb),
    'despesas', jsonb_build_object('total', v_tot -> 'despesas', 'por_categoria', v_cats,
                                   'fixas_nao_lancadas', v_fixas),
    'resultado', v_tot -> 'resultado',
    'mes_anterior', public.fin_totais_mes((v_ini - interval '1 month')::date),
    'recibos_receita_saude', jsonb_build_object('pendentes', v_rec_pend, 'valor_pendente', v_rec_pend_valor,
                                                'a_cancelar', v_rec_cancelar),
    'hora_clinica', jsonb_strip_nulls(jsonb_build_object(
      'custos_fixos', v_custos_fixos,
      'horas_atendidas', round(v_horas, 1),
      'atendimentos', v_atend,
      'valor_hora', case when v_horas > 0 then round(v_custos_fixos / v_horas, 2) end,
      'como_calcula', 'Estimativa: despesas do mês sem materiais, laboratório e impostos, divididas pelas horas atendidas registradas. Com a agenda, passa a usar as horas disponíveis.')),
    'avisos', to_jsonb(v_avisos));
end
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke execute on function
  public.regime_fiscal(date),
  public.fin_solicitacao(),
  public.fin_valor(text, text),
  public.fin_inteiro(text, text),
  public.fin_uuid(text, text),
  public.fin_mes(text),
  public.fin_dia_do_mes(date, int),
  public.fin_reais(numeric),
  public.ler_forma_pagamento(text, int),
  public.ler_categoria_despesa(text),
  public.fin_rotulo_categoria(text),
  public.calcular_taxa_pagamento(text, int, numeric, date),
  public.parcela_pago(uuid),
  public.parcela_json(public.parcelas_previstas),
  public.recibo_situacao(uuid),
  public.recebimento_json(public.recebimentos),
  public.acordo_json(uuid),
  public.saldo_paciente(uuid),
  public.despesa_json(public.despesas),
  public.despesa_fixa_json(public.despesas_recorrentes),
  public.despesa_vigente(uuid),
  public.despesa_estornar(uuid, text, date),
  public.financeiro_lancar_despesa_automatica(text, uuid, date, text, numeric, text, text, uuid, text),
  public.financeiro_estornar_despesa_automatica(text, uuid, text),
  public.despesa_fixa_lancada(uuid, date),
  public.fin_totais_mes(date),
  public.financeiro_resumo_mes(date)
  from public, anon, authenticated;
grant execute on function
  public.regime_fiscal(date),
  public.fin_solicitacao(),
  public.fin_valor(text, text),
  public.fin_inteiro(text, text),
  public.fin_uuid(text, text),
  public.fin_mes(text),
  public.fin_dia_do_mes(date, int),
  public.fin_reais(numeric),
  public.ler_forma_pagamento(text, int),
  public.ler_categoria_despesa(text),
  public.fin_rotulo_categoria(text),
  public.calcular_taxa_pagamento(text, int, numeric, date),
  public.parcela_pago(uuid),
  public.parcela_json(public.parcelas_previstas),
  public.recibo_situacao(uuid),
  public.recebimento_json(public.recebimentos),
  public.acordo_json(uuid),
  public.saldo_paciente(uuid),
  public.despesa_json(public.despesas),
  public.despesa_fixa_json(public.despesas_recorrentes),
  public.despesa_vigente(uuid),
  public.despesa_estornar(uuid, text, date),
  public.financeiro_lancar_despesa_automatica(text, uuid, date, text, numeric, text, text, uuid, text),
  public.financeiro_estornar_despesa_automatica(text, uuid, text),
  public.despesa_fixa_lancada(uuid, date),
  public.fin_totais_mes(date),
  public.financeiro_resumo_mes(date)
  to service_role;
