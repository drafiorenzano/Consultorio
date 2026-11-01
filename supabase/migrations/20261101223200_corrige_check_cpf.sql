-- CPF é opcional: a restrição deve aceitar nulo (cpf_valido(null) devolve false).
alter table public.pacientes drop constraint if exists pacientes_cpf_check;
alter table public.pacientes add constraint pacientes_cpf_check
  check (cpf is null or public.cpf_valido(cpf));

alter table public.responsaveis drop constraint if exists responsaveis_cpf_check;
alter table public.responsaveis add constraint responsaveis_cpf_check
  check (cpf is null or public.cpf_valido(cpf));
