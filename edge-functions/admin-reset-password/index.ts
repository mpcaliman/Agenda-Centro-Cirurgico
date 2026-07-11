// =====================================================================
//  Edge Function: admin-reset-password
//  Ações administrativas do GESTOR sobre usuários do seu centro:
//   - action 'reset'  (padrão): define uma nova senha temporária na hora
//     e confirma o e-mail (email_confirm).
//   - action 'delete': exclui de vez a conta de acesso do usuário. Só
//     funciona se o usuário NÃO tiver registros vinculados (agendamentos,
//     arquivos, histórico); caso contrário o banco bloqueia e o gestor
//     deve usar "Inativar".
//
//  Segurança:
//   - A chave de serviço (service_role) fica SOMENTE aqui, no servidor,
//     via variável de ambiente. NUNCA vai para o site/HTML.
//   - Confirma que quem chama está logado, está ativo e tem a função
//     'gestor', e que o usuário-alvo pertence ao MESMO centro cirúrgico.
//
//  Deploy:
//   1) Supabase → Edge Functions → Deploy a new function → nome
//      "admin-reset-password" → cole este arquivo → Deploy.
//   2) Não precisa cadastrar segredos: SUPABASE_URL, SUPABASE_ANON_KEY e
//      SUPABASE_SERVICE_ROLE_KEY já existem no ambiente da função.
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Método não permitido.' });

  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // 1) Identifica quem está chamando (pelo token do próprio usuário).
    const authHeader = req.headers.get('Authorization') ?? '';
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await caller.auth.getUser();
    const callerUser = userData?.user;
    if (userErr || !callerUser) return json(401, { error: 'Não autenticado.' });

    // 2) Cliente administrativo (chave de serviço) — só no servidor.
    const admin = createClient(url, serviceKey);

    // 3) Confirma que o chamador é gestor ativo.
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('surgical_center_id, status')
      .eq('id', callerUser.id)
      .single();
    if (!callerProfile || callerProfile.status !== 'ativo') {
      return json(403, { error: 'Sem permissão.' });
    }
    const { data: gestorRole } = await admin
      .from('user_roles')
      .select('role')
      .eq('user_id', callerUser.id)
      .eq('role', 'gestor')
      .maybeSingle();
    if (!gestorRole) return json(403, { error: 'Apenas o gestor pode redefinir senhas.' });

    // 4) Valida a entrada.
    const payload = await req.json().catch(() => ({}));
    const action = payload?.action ?? 'reset';
    const userId = payload?.user_id;
    if (!userId) return json(400, { error: 'Usuário não informado.' });

    // 5) Garante que o alvo é do MESMO centro cirúrgico.
    const { data: target } = await admin
      .from('profiles')
      .select('surgical_center_id')
      .eq('id', userId)
      .single();
    if (!target || target.surgical_center_id !== callerProfile.surgical_center_id) {
      return json(403, { error: 'Usuário não pertence ao seu centro cirúrgico.' });
    }

    // 6a) Excluir a conta de acesso de vez.
    if (action === 'delete') {
      if (userId === callerUser.id) {
        return json(400, { error: 'Você não pode excluir o seu próprio usuário.' });
      }
      const { error: delErr } = await admin.auth.admin.deleteUser(userId);
      if (delErr) {
        const m = (delErr.message || '').toLowerCase();
        if (m.includes('foreign key') || m.includes('violates') || m.includes('constraint')) {
          return json(409, {
            error: 'Não é possível excluir: este usuário tem agendamentos ou registros ' +
              'no histórico. Use "Inativar" para bloquear o acesso sem apagar o histórico.',
          });
        }
        if (m.includes('gestor')) {
          return json(409, { error: 'Não é possível excluir o único gestor do centro.' });
        }
        return json(400, { error: delErr.message });
      }
      return json(200, { ok: true });
    }

    // 6b) Redefinir a senha e confirmar o e-mail (ação padrão).
    const newPassword = payload?.new_password;
    if (typeof newPassword !== 'string' || newPassword.length < 6) {
      return json(400, { error: 'Dados inválidos (senha mínima de 6 caracteres).' });
    }
    const { error: updErr } = await admin.auth.admin.updateUserById(userId, {
      password: newPassword,
      email_confirm: true,
    });
    if (updErr) return json(400, { error: updErr.message });

    return json(200, { ok: true });
  } catch (e) {
    return json(500, { error: String((e as Error)?.message ?? e) });
  }
});
