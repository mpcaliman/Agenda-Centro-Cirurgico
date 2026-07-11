-- =====================================================================
--  CORREÇÃO: erro "new row violates row-level security policy for table
--  appointments" ao criar agendamento.
--
--  A função save_appointment já valida o centro e define o criador; basta
--  torná-la SECURITY DEFINER para a gravação controlada não ser barrada
--  pela RLS. Rode este comando no Supabase → SQL Editor → Run.
-- =====================================================================

alter function public.save_appointment(jsonb, text) security definer;
