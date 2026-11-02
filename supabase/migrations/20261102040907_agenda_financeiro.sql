-- Reserva da sala vira despesa (aluguel_sala) no financeiro, na data da
-- reserva. Cancelar a reserva estorna a despesa; mudar o valor substitui.

create or replace function public.reserva_sala_para_financeiro()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.cancelada_em is not null then
    if tg_op = 'UPDATE' and old.cancelada_em is null then
      perform public.financeiro_estornar_despesa_automatica('reserva_sala', new.id,
        coalesce('Reserva da sala cancelada: ' || nullif(btrim(new.motivo_cancelamento), ''), 'Reserva da sala cancelada.'));
    end if;
    return null;
  end if;
  if tg_op = 'INSERT' or new.valor is distinct from old.valor or new.inicio is distinct from old.inicio
     or new.fim is distinct from old.fim then
    perform public.financeiro_lancar_despesa_automatica('reserva_sala', new.id, public.data_local(new.inicio),
      'aluguel_sala', new.valor,
      format('Aluguel da sala %s, %s–%s%s', to_char(public.data_local(new.inicio), 'DD/MM'),
             public.hora_local(new.inicio), public.hora_local(new.fim), coalesce(' · ' || new.local, '')),
      new.local);
  end if;
  return null;
end
$$;

create trigger reservas_sala_financeiro after insert or update on public.reservas_sala
  for each row execute function public.reserva_sala_para_financeiro();

revoke execute on function public.reserva_sala_para_financeiro() from public, anon, authenticated;

-- Reservas que já existiam (dados de demonstração) entram no financeiro.
select public.financeiro_lancar_despesa_automatica('reserva_sala', r.id, public.data_local(r.inicio), 'aluguel_sala',
         r.valor,
         format('Aluguel da sala %s, %s–%s%s', to_char(public.data_local(r.inicio), 'DD/MM'),
                public.hora_local(r.inicio), public.hora_local(r.fim), coalesce(' · ' || r.local, '')),
         r.local)
  from public.reservas_sala r
 where r.cancelada_em is null and r.valor is not null;
