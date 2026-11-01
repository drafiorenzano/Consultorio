-- Faces ditas por extenso com conectivos ("mesial e oclusal") davam erro:
-- remove os conectivos antes de validar.

create or replace function public.normalizar_faces(p_dente smallint, p_faces text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  f text;
  q int;
  u int;
  c text;
  res text := '';
begin
  if p_faces is null or btrim(p_faces) = '' then
    return null;
  end if;
  f := public.normalizar(p_faces);
  f := regexp_replace(f, 'mesial', 'M', 'g');
  f := regexp_replace(f, 'distal', 'D', 'g');
  f := regexp_replace(f, 'oclusal', 'O', 'g');
  f := regexp_replace(f, 'incisal', 'I', 'g');
  f := regexp_replace(f, 'vestibular|bucal|labial', 'V', 'g');
  f := regexp_replace(f, 'lingual', 'L', 'g');
  f := regexp_replace(f, 'palatin[ao]|palatal', 'P', 'g');
  -- conectivos ditos entre as faces ("mesial e oclusal", "faces M e O")
  f := regexp_replace(f, '\m(e|com|face|faces|na|no|nas|nos)\M', ' ', 'g');
  f := upper(regexp_replace(f, '[^A-Za-z]', '', 'g'));
  f := replace(f, 'B', 'V');
  if f ~ '[^MDOIVLP]' or f = '' then
    raise exception using
      message = format('Face inválida: "%s". Use M, D, O, I, V, L ou P (ex.: MO, MOD).', p_faces);
  end if;
  if p_dente is not null then
    q := p_dente / 10;
    u := p_dente % 10;
    if q in (1, 2, 5, 6) then f := replace(f, 'L', 'P'); else f := replace(f, 'P', 'L'); end if;
    if u <= 3 then f := replace(f, 'O', 'I'); else f := replace(f, 'I', 'O'); end if;
  end if;
  foreach c in array array['M', 'O', 'I', 'D', 'V', 'L', 'P'] loop
    if position(c in f) > 0 then res := res || c; end if;
  end loop;
  return res;
end
$$;
