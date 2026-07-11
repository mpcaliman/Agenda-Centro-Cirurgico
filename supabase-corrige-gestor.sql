-- =====================================================================
--  CORRIGE E PROTEGE O ACESSO DE GESTOR
--  Rode no Supabase → SQL Editor → Run.
--  1) Restaura seu usuário como gestor (troque o e-mail).
--  2) Cria uma proteção que IMPEDE remover o último gestor do centro,
--     evitando que uma edição de funções trave o seu acesso.
-- =====================================================================

-- (1) Restaura seu gestor — TROQUE pelo SEU e-mail:
insert into public.user_roles (user_id, role)
select id, 'gestor' from auth.users where email = 'SEU_EMAIL@exemplo.com'
on conflict (user_id, role) do nothing;

-- (2) Proteção contra remover o último gestor do centro:
create or replace function public.protect_last_gestor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.role = 'gestor' then
    if not exists (
      select 1
      from public.user_roles ur
      join public.profiles p on p.id = ur.user_id
      where ur.role = 'gestor'
        and ur.user_id <> old.user_id
        and p.surgical_center_id = (select surgical_center_id from public.profiles where id = old.user_id)
    ) then
      raise exception 'Não é possível remover o último gestor do centro cirúrgico.';
    end if;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_protect_last_gestor on public.user_roles;
create trigger trg_protect_last_gestor
  before delete on public.user_roles
  for each row execute function public.protect_last_gestor();
