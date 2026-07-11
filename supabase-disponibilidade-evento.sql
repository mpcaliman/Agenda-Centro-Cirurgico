-- =====================================================================
--  DISPONIBILIDADE POR EVENTO
--  Permite que um profissional associado a um agendamento (ex.: o
--  cirurgião) solicite disponibilidade a uma PESSOA específica (ex.: o
--  anestesista) para aquela cirurgia — além da forma do gestor (por
--  dia/período). Rode no Supabase → SQL Editor → Run.
-- =====================================================================

-- 1) Alvo por pessoa específica (além do alvo por função).
alter table public.availability_requests
  add column if not exists target_user_id uuid references public.profiles(id) on delete cascade;

-- 2) Quem pode VER as solicitações.
drop policy if exists avreq_select on public.availability_requests;
create policy avreq_select on public.availability_requests
  for select using (
    surgical_center_id = public.current_center_id() and public.is_active_user() and (
      public.is_gestor()
      or created_by = auth.uid()                       -- quem criou (vê a resposta)
      or target_user_id = auth.uid()                   -- a pessoa solicitada
      or (target_user_id is null and exists (          -- solicitação por função
        select 1 from public.user_roles ur
        where ur.user_id = auth.uid() and ur.role = availability_requests.target_role))
      or (appointment_id is not null and public.is_associated(appointment_id))
    )
  );

-- 3) Quem pode CRIAR: o gestor (qualquer) ou um associado ao agendamento
--    (solicitação por evento).
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

-- 4) Respostas: quem criou a solicitação também enxerga a resposta.
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
