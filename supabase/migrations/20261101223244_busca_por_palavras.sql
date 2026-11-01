-- Busca de paciente mais segura para nomes ditados.
--
-- Antes, "Ana" encontrava "Mariana" (trecho de palavra) e devolvia a ficha
-- como se fosse a paciente certa. Agora:
--   * correspondência EXATA: cada palavra dita é uma palavra inteira do nome,
--     nome social ou apelido (sem acento/maiúsculas), ou CPF/telefone/ficha;
--   * correspondência APROXIMADA: prefixo ("Mari" -> "Mariana") ou grafia
--     parecida ("Nunez" -> "Nunes"). Sempre volta como lista, para a IA
--     confirmar com a dentista antes de usar.
-- A ficha completa só é devolvida quando há exatamente uma correspondência
-- exata.

create or replace function public.mcp_buscar_paciente(
  p_busca text default null,
  p_paciente_id uuid default null,
  p_texto_original text default null,
  p_incluir_arquivados boolean default false,
  p_limite int default 5)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_termo text;
  v_dig text;
  v_limite int := greatest(1, least(coalesce(p_limite, 5), 20));
  v_exatos uuid[];
  v_aprox uuid[];
  v_lista jsonb;
begin
  perform public.iniciar_solicitacao('buscar_paciente',
    jsonb_strip_nulls(jsonb_build_object('busca', p_busca, 'paciente_id', p_paciente_id,
                                         'incluir_arquivados', p_incluir_arquivados)),
    p_texto_original);

  if p_paciente_id is not null then
    if not exists (select 1 from public.pacientes where id = p_paciente_id) then
      raise exception 'Paciente não encontrado (id %). Busque pelo nome.', p_paciente_id;
    end if;
    return jsonb_build_object('encontrados', 1, 'correspondencia', 'exata',
                              'paciente', public.paciente_ficha(p_paciente_id));
  end if;

  if coalesce(btrim(p_busca), '') = '' then
    raise exception 'Informe nome, apelido, CPF, telefone ou número da ficha para buscar.';
  end if;

  v_termo := public.normalizar(p_busca);

  if regexp_replace(v_termo, '[0-9 .()/+-]', '', 'g') = '' then
    -- Busca numérica: CPF, telefone (final) ou número da ficha.
    v_dig := public.somente_digitos(p_busca);
    select coalesce(array_agg(p.id order by p.nome), '{}') into v_exatos
      from public.pacientes p
     where (p_incluir_arquivados or p.arquivado_em is null)
       and ((length(v_dig) = 11 and p.cpf = v_dig)
         or (length(v_dig) >= 8 and p.telefone like '%' || v_dig)
         or (length(v_dig) <= 7 and p.ficha::text = v_dig));
    v_aprox := '{}';
  else
    with tokens as (
      select distinct t
        from unnest(string_to_array(v_termo, ' ')) t
       where length(t) >= 2 and t not in ('da', 'de', 'do', 'das', 'dos')
    ),
    cand as (
      select p.id, p.nome,
             string_to_array(public.normalizar(concat_ws(' ', p.nome, p.nome_social, p.apelido)), ' ') as palavras
        from public.pacientes p
       where p_incluir_arquivados or p.arquivado_em is null
    ),
    pontos as (
      select c.id, c.nome,
             bool_and(tk.t = any (c.palavras)) as exata,
             avg((select max(case
                               when w = tk.t then 1.0
                               when length(tk.t) >= 3 and w like tk.t || '%' then 0.85
                               else extensions.similarity(tk.t, w) end)
                    from unnest(c.palavras) w)) as score
        from cand c
       cross join tokens tk
       group by c.id, c.nome
    ),
    aprox as (
      select id, nome, score from pontos where not exata and score >= 0.4
    )
    select coalesce((select array_agg(id order by nome) from pontos where exata), '{}'),
           -- aproximados: só os próximos do melhor resultado
           coalesce((select array_agg(id order by score desc, nome)
                       from (select id, nome, score from aprox
                              where score >= (select max(score) from aprox) - 0.2
                              order by score desc, nome
                              limit v_limite) s), '{}')
      into v_exatos, v_aprox;
  end if;

  if cardinality(v_exatos) = 1 then
    return jsonb_build_object('encontrados', 1, 'correspondencia', 'exata',
                              'paciente', public.paciente_ficha(v_exatos[1]));
  end if;

  if cardinality(v_exatos) > 1 then
    select jsonb_agg(public.paciente_resumo(p) order by p.nome) into v_lista
      from public.pacientes p where p.id = any (v_exatos[1:v_limite]);
    return jsonb_build_object(
      'encontrados', cardinality(v_exatos),
      'correspondencia', 'exata',
      'mensagem', 'Há mais de um paciente com esse nome. Pergunte à Dra. qual deles (sobrenome, idade ou telefone).',
      'pacientes', v_lista);
  end if;

  if cardinality(v_aprox) > 0 then
    select jsonb_agg(public.paciente_resumo(p) order by array_position(v_aprox, p.id)) into v_lista
      from public.pacientes p where p.id = any (v_aprox);
    return jsonb_build_object(
      'encontrados', 0,
      'correspondencia', 'aproximada',
      'mensagem', format('Ninguém com o nome exato "%s". Os nomes mais parecidos estão abaixo: confirme com a Dra. se é algum deles antes de usar.', p_busca),
      'parecidos', v_lista);
  end if;

  return jsonb_build_object(
    'encontrados', 0,
    'mensagem', format('Nenhum paciente encontrado para "%s". Confira a grafia ou cadastre o paciente.', p_busca));
end
$$;
