-- =====================================================================
--  CRIAR O PRIMEIRO GESTOR (seu acesso)
--
--  PASSO 1: No Supabase, vá em Authentication → Users → Add user →
--           crie um usuário com o SEU e-mail e uma senha. Confirme.
--  PASSO 2: Troque abaixo o e-mail e o nome pelos seus e rode no SQL Editor.
-- =====================================================================

insert into public.profiles (id, surgical_center_id, full_name, email, status)
select u.id,
       (select id from public.surgical_centers order by created_at limit 1),
       'Seu Nome Completo',
       u.email,
       'ativo'
from auth.users u
where u.email = 'SEU_EMAIL@exemplo.com'
on conflict (id) do update set status = 'ativo';

insert into public.user_roles (user_id, role)
select u.id, 'gestor'
from auth.users u
where u.email = 'SEU_EMAIL@exemplo.com'
on conflict (user_id, role) do nothing;
