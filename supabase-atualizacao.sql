-- =====================================================================
--  ATUALIZAÇÃO COMPLETA — RODAR UMA ÚNICA VEZ
--  Cole TODO este arquivo no Supabase → SQL Editor → New query → Run.
--
--  Reúne, de forma segura para reexecutar (idempotente), tudo o que foi
--  adicionado depois da instalação inicial:
--    1. Correção do erro ao criar agendamento (save_appointment).
--    2. Proteção do gestor (não deixa remover o último) + restaura o seu.
--    3. Disponibilidade por PESSOA, por FUNÇÃO (chamado aberto) e DIRIGIDA
--       a pessoas específicas, com confirmar/recusar e "primeiro que
--       aceita leva".
--    4. Privacidade da agenda: quem não é do agendamento só vê
--       "Indisponível" (garantido no banco, via RLS).
--
--  Pode rodar mais de uma vez sem problema.
-- =====================================================================


-- =====================================================================
-- 1) CORREÇÃO: erro "row-level security policy" ao criar agendamento.
-- =====================================================================
do $$
begin
  alter function public.save_appointment(jsonb, text) security definer;
exception when undefined_function then
  raise notice 'save_appointment(jsonb, text) não encontrada — ignorando.';
end $$;


-- =====================================================================
-- 2) GESTOR: proteção contra remover o último + restaura o seu acesso.
--    Se o seu e-mail de login for outro, troque abaixo.
-- =====================================================================
insert into public.user_roles (user_id, role)
select id, 'gestor' from auth.users where email = 'mpcaliman@hotmail.com'
on conflict (user_id, role) do nothing;

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


-- =====================================================================
-- 3) COLUNAS de disponibilidade + ligação da notificação.
-- =====================================================================
alter table public.availability_requests
  add column if not exists target_user_id uuid references public.profiles(id) on delete cascade,
  add column if not exists status text not null default 'aberta',   -- 'aberta' | 'preenchida' | 'cancelada'
  add column if not exists accepted_by uuid references public.profiles(id) on delete set null,
  add column if not exists accepted_at timestamptz,
  add column if not exists target_user_ids uuid[];

alter table public.notifications
  add column if not exists related_request_id uuid
    references public.availability_requests(id) on delete cascade;


-- =====================================================================
-- 4) FUNÇÕES seguras (rótulo, abrir e responder disponibilidade).
-- =====================================================================
create or replace function public.role_label(r public.user_role)
returns text language sql immutable as $$
  select case r
    when 'gestor' then 'Gestor'
    when 'cirurgiao' then 'Cirurgião'
    when 'cirurgiao_auxiliar' then 'Cirurgião auxiliar'
    when 'anestesiologista' then 'Anestesiologista'
    when 'pediatra' then 'Pediatra'
    when 'auxiliar' then 'Auxiliar'
    when 'empresa' then 'Empresa prestadora'
    else r::text
  end;
$$;

-- Remove a versão antiga (3 argumentos) para evitar sobrecarga ambígua.
drop function if exists public.open_availability(uuid, public.user_role, text);
create or replace function public.open_availability(
  p_appointment_id uuid,
  p_target_role    public.user_role,
  p_message        text default null,
  p_target_user_ids uuid[] default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_center   uuid;
  v_date     date;
  v_start    time;
  v_end      time;
  v_req_id   uuid;
  v_directed boolean := (p_target_user_ids is not null and array_length(p_target_user_ids, 1) is not null);
begin
  select surgical_center_id into v_center from public.profiles where id = v_uid;
  if v_center is null then raise exception 'Usuário sem centro cirúrgico.'; end if;

  if not (public.is_gestor() or public.is_associated(p_appointment_id)) then
    raise exception 'Sem permissão para abrir disponibilidade neste procedimento.';
  end if;

  select appointment_date, start_time, end_time
    into v_date, v_start, v_end
  from public.appointments
  where id = p_appointment_id and surgical_center_id = v_center;
  if v_date is null then raise exception 'Agendamento não encontrado.'; end if;

  insert into public.availability_requests(
    surgical_center_id, appointment_id, target_role, target_user_id, target_user_ids,
    request_date, start_time, end_time, message, created_by, status)
  values (v_center, p_appointment_id, p_target_role, null,
    case when v_directed then p_target_user_ids else null end,
    v_date, v_start, v_end, p_message, v_uid, 'aberta')
  returning id into v_req_id;

  insert into public.notifications(
    surgical_center_id, user_id, title, body, type,
    related_appointment_id, related_request_id)
  select distinct v_center, p.id,
    'Disponibilidade solicitada',
    'Procedimento em ' || to_char(v_date,'DD/MM/YYYY') ||
      ' das ' || to_char(v_start,'HH24:MI') || ' às ' || to_char(v_end,'HH24:MI') ||
      ' precisa de ' || public.role_label(p_target_role) ||
      '. Confirme se pode realizar.' ||
      coalesce(' Obs.: ' || nullif(p_message,''), ''),
    'disponibilidade', p_appointment_id, v_req_id
  from public.profiles p
  join public.user_roles ur on ur.user_id = p.id
  where p.surgical_center_id = v_center
    and p.status = 'ativo'
    and ur.role = p_target_role
    and p.id <> v_uid
    and (not v_directed or p.id = any(p_target_user_ids));

  return v_req_id;
end;
$$;

create or replace function public.respond_availability(
  p_request_id uuid,
  p_accept     boolean
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_req       public.availability_requests%rowtype;
  v_appt_role public.appointment_role;
  v_updated   int;
  v_name      text;
begin
  select * into v_req from public.availability_requests where id = p_request_id;
  if v_req.id is null then raise exception 'Solicitação não encontrada.'; end if;

  if v_req.target_user_ids is not null and array_length(v_req.target_user_ids, 1) is not null then
    if not (v_uid = any(v_req.target_user_ids)) then
      raise exception 'Você não foi convidado para esta disponibilidade.';
    end if;
  elsif not exists (
    select 1 from public.user_roles ur
    join public.profiles p on p.id = ur.user_id
    where ur.user_id = v_uid and ur.role = v_req.target_role
      and p.surgical_center_id = v_req.surgical_center_id
      and p.status = 'ativo'
  ) then
    raise exception 'Você não está elegível para esta disponibilidade.';
  end if;

  insert into public.availability_responses(request_id, responder_id, answer)
  values (p_request_id, v_uid,
    case when p_accept then 'disponivel'::public.availability_answer
         else 'indisponivel'::public.availability_answer end)
  on conflict (request_id, responder_id)
  do update set answer = excluded.answer, responded_at = now();

  if not p_accept then
    return 'recusada';
  end if;

  update public.availability_requests
    set status = 'preenchida', accepted_by = v_uid, accepted_at = now()
    where id = p_request_id and status = 'aberta';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return 'ja_preenchida';
  end if;

  if v_req.appointment_id is not null then
    v_appt_role := case v_req.target_role
      when 'cirurgiao'          then 'cirurgiao_adicional'::public.appointment_role
      when 'cirurgiao_auxiliar' then 'cirurgiao_auxiliar'::public.appointment_role
      when 'anestesiologista'   then 'anestesiologista'::public.appointment_role
      when 'pediatra'           then 'pediatra'::public.appointment_role
      when 'auxiliar'           then 'auxiliar'::public.appointment_role
      when 'empresa'            then 'empresa'::public.appointment_role
      else 'auxiliar'::public.appointment_role
    end;
    insert into public.appointment_professionals(appointment_id, user_id, role)
    values (v_req.appointment_id, v_uid, v_appt_role)
    on conflict (appointment_id, user_id, role) do nothing;
  end if;

  select full_name into v_name from public.profiles where id = v_uid;

  if v_req.created_by is not null and v_req.created_by <> v_uid then
    insert into public.notifications(
      surgical_center_id, user_id, title, body, type,
      related_appointment_id, related_request_id)
    values (v_req.surgical_center_id, v_req.created_by,
      'Disponibilidade aceita',
      v_name || ' aceitou a disponibilidade de ' || public.role_label(v_req.target_role) ||
      ' para o procedimento de ' || to_char(v_req.request_date,'DD/MM/YYYY') || '.',
      'disponibilidade_aceita', v_req.appointment_id, p_request_id);
  end if;

  insert into public.notifications(
    surgical_center_id, user_id, title, body, type,
    related_appointment_id, related_request_id)
  select v_req.surgical_center_id, pr.id,
    'Disponibilidade aceita',
    v_name || ' aceitou a disponibilidade de ' || public.role_label(v_req.target_role) ||
    ' para o procedimento de ' || to_char(v_req.request_date,'DD/MM/YYYY') || '.',
    'disponibilidade_aceita', v_req.appointment_id, p_request_id
  from public.profiles pr
  join public.user_roles ur on ur.user_id = pr.id
  where pr.surgical_center_id = v_req.surgical_center_id
    and ur.role = 'gestor'
    and pr.id <> v_uid
    and pr.id is distinct from v_req.created_by;

  update public.notifications
    set is_read = true
    where related_request_id = p_request_id
      and type = 'disponibilidade';

  return 'preenchida';
end;
$$;

grant execute on function public.role_label(public.user_role) to authenticated;
grant execute on function public.open_availability(uuid, public.user_role, text, uuid[]) to authenticated;
grant execute on function public.respond_availability(uuid, boolean) to authenticated;


-- =====================================================================
-- 5) POLÍTICAS de acesso (RLS) das solicitações e respostas.
-- =====================================================================
drop policy if exists avreq_select on public.availability_requests;
create policy avreq_select on public.availability_requests
  for select using (
    surgical_center_id = public.current_center_id() and public.is_active_user() and (
      public.is_gestor()
      or created_by = auth.uid()
      or target_user_id = auth.uid()
      or (target_user_ids is not null and auth.uid() = any(target_user_ids))
      or (target_user_id is null and target_user_ids is null and exists (
            select 1 from public.user_roles ur
            where ur.user_id = auth.uid() and ur.role = availability_requests.target_role))
      or (appointment_id is not null and public.is_associated(appointment_id))
    )
  );

drop policy if exists avreq_manage on public.availability_requests;
drop policy if exists avreq_insert on public.availability_requests;
create policy avreq_insert on public.availability_requests
  for insert with check (
    surgical_center_id = public.current_center_id() and public.is_active_user()
    and created_by = auth.uid() and (
      public.is_gestor()
      or (appointment_id is not null and public.is_associated(appointment_id))
    )
  );

drop policy if exists avreq_update on public.availability_requests;
create policy avreq_update on public.availability_requests
  for update using (public.is_gestor() or created_by = auth.uid())
  with check (surgical_center_id = public.current_center_id());

drop policy if exists avreq_delete on public.availability_requests;
create policy avreq_delete on public.availability_requests
  for delete using (public.is_gestor() or created_by = auth.uid());

drop policy if exists avresp_select on public.availability_responses;
create policy avresp_select on public.availability_responses
  for select using (
    public.is_active_user() and (
      responder_id = auth.uid()
      or public.is_gestor()
      or exists (
        select 1 from public.availability_requests r
        where r.id = availability_responses.request_id and r.created_by = auth.uid())
    )
  );


-- =====================================================================
-- 6) PRIVACIDADE DA AGENDA — garantia no banco.
--    Detalhes só para o gestor e os associados; os demais só veem a
--    ocupação neutra ("Indisponível") via get_occupancy.
-- =====================================================================
drop policy if exists appt_select on public.appointments;
create policy appt_select on public.appointments
  for select using (
    surgical_center_id = public.current_center_id()
    and public.is_active_user()
    and (public.is_gestor() or public.is_associated(id))
  );

drop policy if exists rb_select on public.room_blocks;
create policy rb_select on public.room_blocks
  for select using (
    surgical_center_id = public.current_center_id()
    and public.is_active_user()
    and (public.is_gestor() or reserved_user_id = auth.uid())
  );
