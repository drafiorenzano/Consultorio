-- =====================================================================
-- Site: a tela Hoje mostra só o que importa hoje, com a lista "a fazer".
--
-- Junta numa leitura só o que pede ação: recibos do Receita Saúde a emitir,
-- parcelas para cobrar (atrasadas e as que vencem em 7 dias), orçamentos
-- aprovados sem pagamento combinado, pacote do contador do mês passado e
-- materiais vencidos ou vencendo (60 dias). Só leitura.
-- =====================================================================

create or replace function public.painel_inicio_afazer()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with mes_passado as (
    select (date_trunc('month', public.hoje()) - interval '1 month')::date ini,
           date_trunc('month', public.hoje())::date fim
  ),
  parcelas as (
    select public.parcela_json(pp) j, p.id paciente_id, p.nome paciente, public.telefone_contato(p.id) telefone
      from public.parcelas_previstas pp
      join public.acordos_pagamento a on a.id = pp.acordo_id and a.cancelado_em is null
      join public.pacientes p on p.id = a.paciente_id
     where pp.cancelada_em is null
       and pp.vencimento <= public.hoje() + 7
       and pp.valor - public.parcela_pago(pp.id) > 0
  )
  select jsonb_strip_nulls(jsonb_build_object(
    'regime', public.regime_fiscal(public.hoje()),
    -- recibos do Receita Saúde (pessoa física) ainda não emitidos ou a cancelar
    'recibos_a_emitir', (
      select jsonb_build_object('quantidade', count(*),
                                'total', sum(r.valor_bruto) filter (where x.s = 'pendente'),
                                'mais_antigo', min(r.data_pagamento),
                                'a_cancelar', count(*) filter (where x.s = 'cancelar'))
        from public.recebimentos r
        cross join lateral (select public.recibo_situacao(r.id) ->> 'situacao' s) x
       where r.estorna_id is null and r.regime_fiscal = 'pf' and r.paciente_id is not null
         and x.s in ('pendente', 'cancelar')
      having count(*) > 0),
    -- parcelas combinadas: atrasadas e as que vencem nos próximos 7 dias
    'cobrar', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'paciente', paciente, 'paciente_id', paciente_id, 'telefone', telefone,
               'descricao', j ->> 'descricao', 'parcela', j ->> 'parcela',
               'vencimento', j -> 'vencimento', 'restante', j -> 'restante',
               'atrasada', case when j ->> 'situacao' = 'atrasada' then true end,
               'dias_atraso', j -> 'dias_atraso'))
             order by (j ->> 'vencimento')::date, paciente)
        from parcelas),
    -- aprovado, mas nenhum pagamento nem acordo depois da aprovação
    'aprovados_sem_pagamento', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'paciente', p.nome, 'paciente_id', p.id, 'titulo', o.titulo, 'numero', o.numero,
               'aprovado_em', o.aprovado_em, 'valor', public.orcamento_resumo(o.id) -> 'valor'))
             order by o.aprovado_em)
        from public.orcamentos o
        join public.pacientes p on p.id = o.paciente_id and p.arquivado_em is null
       where o.status in ('aprovado', 'parcial') and o.aprovado_em is not null
         and not exists (select 1 from public.recebimentos r
                          where r.paciente_id = o.paciente_id and r.estorna_id is null
                            and (r.orcamento_id = o.id or r.data_pagamento >= o.aprovado_em))
         and not exists (select 1 from public.acordos_pagamento a
                          where a.paciente_id = o.paciente_id and a.cancelado_em is null
                            and (a.orcamento_id = o.id or (a.criado_em at time zone public.fuso())::date >= o.aprovado_em))),
    -- pacote do contador do mês passado (com movimento e ainda não gerado)
    'pacote_contador', (
      select jsonb_build_object('competencia', m.ini, 'mes', public.nome_do_mes(m.ini))
        from mes_passado m
       where not exists (select 1 from public.pacotes_contador pc where pc.competencia = m.ini)
         and (exists (select 1 from public.recebimentos r where r.data_pagamento >= m.ini and r.data_pagamento < m.fim)
              or exists (select 1 from public.despesas d where d.data >= m.ini and d.data < m.fim))),
    -- lotes com validade: vencidos e os que vencem em até 60 dias
    'validade', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'nome', mt.nome, 'lote', s.lote, 'validade', s.validade,
               'vencido', case when s.validade < public.hoje() then true end,
               'quantidade', public.estoque_qtd(mt.unidade_uso, mt.unidade_compra, mt.fator, s.saldo)))
             order by s.validade, mt.nome)
        from public.estoque_materiais mt
        cross join lateral public.estoque_lotes_saldo(mt.id) s
       where mt.ativo and s.saldo > 0 and s.validade is not null and s.validade <= public.hoje() + 60),
    'lotes_com_validade', (select count(*) from public.estoque_lotes where validade is not null)))
$$;

create or replace function public.painel(p_acao text, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  p_params := coalesce(p_params, '{}'::jsonb);
  return case p_acao
    when 'inicio' then public.painel_inicio() || public.painel_inicio_extra() || public.painel_inicio_afazer()
    when 'agenda' then public.painel_agenda(p_params)
    when 'pacientes' then public.painel_pacientes(p_params)
    when 'paciente' then public.painel_paciente(p_params)
    when 'financeiro' then public.painel_financeiro(p_params) || public.painel_financeiro_extra(p_params)
    when 'estoque' then public.painel_estoque(p_params) || public.painel_estoque_extra(p_params)
                        || public.painel_estoque_materiais()
    when 'orcamentos' then public.painel_orcamentos(p_params)
    when 'documentos' then public.painel_documentos(p_params)
    when 'precos' then public.painel_precos(p_params)
    when 'atividade' then public.painel_atividade(p_params)
    when 'configuracoes' then public.painel_configuracoes()
    else null
  end;
end
$$;

revoke execute on function public.painel_inicio_afazer() from public, anon, authenticated;
grant execute on function public.painel_inicio_afazer() to service_role;
