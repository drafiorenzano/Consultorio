-- Reabrir uma consulta cancelada ou com falta só pelo paciente (sem o id):
-- localizar_consulta passa a procurar as inativas quando a ação é "reabrir".
create or replace function public.localizar_consulta(p_dados jsonb)
returns public.consultas
language plpgsql
stable
set search_path = ''
as $$
declare
  v public.consultas;
  v_id uuid;
  v_pac public.pacientes;
  v_data date;
  v_n int;
  v_lista text;
  v_reabrir boolean := public.normalizar(p_dados ->> 'acao') = 'reabrir';
  v_status text[];
begin
  if nullif(btrim(p_dados ->> 'consulta_id'), '') is not null then
    begin
      v_id := (p_dados ->> 'consulta_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'consulta_id inválido. Use ver_agenda para achar a consulta.';
    end;
    select * into v from public.consultas where id = v_id;
    if not found then raise exception 'Consulta não encontrada. Use ver_agenda para achar a consulta.'; end if;
    return v;
  end if;
  if nullif(btrim(p_dados ->> 'paciente_id'), '') is null then
    raise exception 'Diga qual consulta: consulta_id (de ver_agenda) ou paciente_id (de buscar_paciente).';
  end if;
  v_pac := public.obter_paciente_ativo(p_dados ->> 'paciente_id');
  v_data := public.ler_data(p_dados ->> 'data', 'Data');
  v_status := case when v_reabrir then array['cancelada', 'faltou'] else array['agendada', 'confirmada'] end;
  select count(*), string_agg(to_char(c.inicio at time zone public.fuso(), 'DD/MM HH24:MI'), ', ' order by c.inicio)
    into v_n, v_lista
    from public.consultas c
   where c.paciente_id = v_pac.id and c.status = any (v_status)
     and (case when v_data is not null then public.data_local(c.inicio) = v_data
               when v_reabrir then c.status_em >= now() - interval '30 days'
               else c.fim >= now() - interval '12 hours' end);
  if v_n = 0 then
    raise exception 'Não achei consulta % de %.',
      case when v_reabrir then 'cancelada ou com falta' else 'marcada' end,
      v_pac.nome || case when v_data is null then '' else ' em ' || to_char(v_data, 'DD/MM') end;
  end if;
  if v_n > 1 and (v_data is not null or v_reabrir) then
    raise exception '% tem % consultas % (%). Diga a data e o horário ou use o consulta_id.', v_pac.nome, v_n,
      case when v_reabrir then 'canceladas ou com falta' else 'nesse dia' end, v_lista;
  end if;
  select * into v from public.consultas c
   where c.paciente_id = v_pac.id and c.status = any (v_status)
     and (case when v_data is not null then public.data_local(c.inicio) = v_data
               when v_reabrir then c.status_em >= now() - interval '30 days'
               else c.fim >= now() - interval '12 hours' end)
   order by c.inicio limit 1;
  return v;
end
$$;

revoke execute on function public.localizar_consulta(jsonb) from public, anon, authenticated;
grant execute on function public.localizar_consulta(jsonb) to service_role;
