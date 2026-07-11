-- =====================================================================
--  DISPONIBILIDADE COMO "CHAMADO ABERTO POR FUNÇÃO"
--  O cirurgião (ou gestor) abre uma vaga para uma FUNÇÃO num procedimento.
--  Todos os usuários ativos daquela função são notificados e podem
--  CONFIRMAR ou RECUSAR. O primeiro que confirmar assume e a vaga fecha;
--  quem agendou e os gestores são avisados. Recusar não faz nada — a vaga
--  continua aberta para os demais.
--
--  As mensagens são NEUTRAS: só data, horário e função. Nunca dados do
--  paciente.
--
--  Rode no Supabase → SQL Editor → Run.
-- =====================================================================

-- 1) Estado da solicitação + quem assumiu + alvos dirigidos.
alter table public.availability_requests
  add column if not exists status text not null default 'aberta',   -- 'aberta' | 'preenchida' | 'cancelada'
  add column if not exists accepted_by uuid references public.profiles(id) on delete set null,
  add column if not exists accepted_at timestamptz,
  -- Quando preenchido, a disponibilidade é DIRIGIDA a essas pessoas (todas
  -- da mesma função). Quando nulo, é aberta a TODOS daquela função.
  add column if not exists target_user_ids uuid[];

-- 2) Ligação da notificação com a solicitação (para os botões confirmar/recusar).
alter table public.notifications
  add column if not exists related_request_id uuid
    references public.availability_requests(id) on delete cascade;

-- 3) Rótulo legível de uma função (para as mensagens).
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

-- 4) Abrir um chamado de disponibilidade por função.
--    p_target_user_ids nulo/vazio  => ABERTA a todos daquela função.
--    p_target_user_ids preenchido  => DIRIGIDA só a essas pessoas (que têm
--                                     a função).
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

  -- Precisa ser gestor OU estar associado ao agendamento.
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

  -- Notifica os destinatários (ativos, mesma função, mesmo centro, menos
  -- quem abriu). Se DIRIGIDA, apenas as pessoas escolhidas. Mensagem neutra.
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

-- 5) Responder a um chamado (confirmar = assume e fecha; recusar = nada).
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

  -- Elegibilidade: se DIRIGIDA, precisa estar na lista; se ABERTA, precisa
  -- ter a função pedida. Em ambos os casos, ativo no mesmo centro.
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

  -- Registra a resposta (histórico).
  insert into public.availability_responses(request_id, responder_id, answer)
  values (p_request_id, v_uid,
    case when p_accept then 'disponivel'::public.availability_answer
         else 'indisponivel'::public.availability_answer end)
  on conflict (request_id, responder_id)
  do update set answer = excluded.answer, responded_at = now();

  if not p_accept then
    return 'recusada';
  end if;

  -- ACEITE: fecha de forma atômica — o primeiro a confirmar leva.
  update public.availability_requests
    set status = 'preenchida', accepted_by = v_uid, accepted_at = now()
    where id = p_request_id and status = 'aberta';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return 'ja_preenchida';
  end if;

  -- Vincula o profissional ao agendamento.
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

  -- Avisa quem abriu (se não for o próprio).
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

  -- Avisa os gestores do centro (sem duplicar o criador).
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

  -- Encerra as notificações de disponibilidade pendentes deste chamado.
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
-- 6) Quem enxerga as solicitações (RLS). Para DIRIGIDA, só os escolhidos;
--    para ABERTA por função, todos daquela função. Sempre gestor, criador
--    e associados ao agendamento.
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

-- =====================================================================
-- 7) PRIVACIDADE DA AGENDA — garantia no banco.
--    Detalhes de um agendamento só para o gestor e os associados
--    (criador, cirurgião, profissionais do agendamento). Os demais só
--    enxergam a ocupação neutra ("Indisponível") via get_occupancy.
-- =====================================================================
drop policy if exists appt_select on public.appointments;
create policy appt_select on public.appointments
  for select using (
    surgical_center_id = public.current_center_id()
    and public.is_active_user()
    and (public.is_gestor() or public.is_associated(id))
  );

-- Bloqueios: detalhes (motivo, reservado para quem) só para o gestor e o
-- usuário reservado. Os demais veem apenas a ocupação neutra (get_occupancy).
drop policy if exists rb_select on public.room_blocks;
create policy rb_select on public.room_blocks
  for select using (
    surgical_center_id = public.current_center_id()
    and public.is_active_user()
    and (public.is_gestor() or reserved_user_id = auth.uid())
  );
