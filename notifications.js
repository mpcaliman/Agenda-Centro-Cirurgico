// =====================================================================
//  notifications.js
//  Notificações internas do usuário, com atualização em tempo real
//  (Supabase Realtime). Cada usuário só acessa as próprias (RLS).
// =====================================================================

import { supabase, state, escapeHtml, toast, formatDateBR } from './supabase-client.js';

let channel = null;
let badgeEl = null;

// Inicializa o contador do menu e a assinatura em tempo real.
export async function initNotifications(badge) {
  badgeEl = badge;
  await updateBadge();

  if (channel) supabase.removeChannel(channel);
  channel = supabase
    .channel('notif-realtime')
    .on('postgres_changes', {
      event: 'INSERT', schema: 'public', table: 'notifications',
      filter: `user_id=eq.${state.profile.id}`,
    }, (payload) => {
      toast('🔔 ' + (payload.new.title ?? 'Nova notificação'), 'info', 5000);
      updateBadge();
    })
    .subscribe();
}

export function destroyNotifications() {
  if (channel) { supabase.removeChannel(channel); channel = null; }
}

async function updateBadge() {
  const { count } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', state.profile.id)
    .eq('is_read', false);
  if (badgeEl) {
    badgeEl.textContent = count || '';
    badgeEl.style.display = count ? 'inline-flex' : 'none';
  }
}

// Renderiza a lista de notificações no container do módulo.
export async function renderNotifications(container) {
  const { data, error } = await supabase
    .from('notifications')
    .select('*')
    .eq('user_id', state.profile.id)
    .order('created_at', { ascending: false })
    .limit(200);

  if (error) {
    container.innerHTML = `<p class="error">Erro ao carregar notificações: ${escapeHtml(error.message)}</p>`;
    return;
  }

  const rows = data ?? [];

  // Estado das solicitações de disponibilidade ligadas às notificações,
  // para decidir se ainda dá para confirmar (vaga em aberto).
  const reqIds = [...new Set(rows
    .filter((n) => n.type === 'disponibilidade' && n.related_request_id)
    .map((n) => n.related_request_id))];
  const reqStatus = {};
  if (reqIds.length) {
    const { data: reqs } = await supabase
      .from('availability_requests')
      .select('id, status, accepted_by')
      .in('id', reqIds);
    (reqs ?? []).forEach((r) => { reqStatus[r.id] = r; });
  }

  const availActions = (n) => {
    if (n.type !== 'disponibilidade' || !n.related_request_id) return '';
    const r = reqStatus[n.related_request_id];
    if (!r || r.status === 'aberta') {
      return `<div class="avail-actions">
        <button class="btn small primary" data-accept="${n.related_request_id}" data-nid="${n.id}">✅ Confirmar</button>
        <button class="btn small ghost" data-decline="${n.related_request_id}" data-nid="${n.id}">❌ Não posso</button>
      </div>`;
    }
    return `<div class="avail-actions"><span class="badge ${r.accepted_by === state.profile.id ? 'ok' : 'off'}">${r.accepted_by === state.profile.id ? 'Você assumiu esta vaga' : 'Vaga já preenchida'}</span></div>`;
  };

  container.innerHTML = `
    <div class="module-head">
      <h1>Notificações</h1>
      <button class="btn small ghost" id="mark-all">Marcar todas como lidas</button>
    </div>
    <ul class="notif-list">
      ${rows.length ? rows.map((n) => `
        <li class="notif ${n.is_read ? '' : 'unread'}" data-id="${n.id}">
          <div class="notif-main">
            <strong>${escapeHtml(n.title)}</strong>
            <p>${escapeHtml(n.body ?? '')}</p>
            ${availActions(n)}
            <span class="notif-date">${formatDateBR(n.created_at)}</span>
          </div>
          <div class="notif-actions">
            ${n.is_read ? '' : `<button class="btn-link" data-read="${n.id}">Marcar como lida</button>`}
            <button class="btn-link danger" data-del="${n.id}">Excluir</button>
          </div>
        </li>`).join('') : '<li class="empty">Você não possui notificações.</li>'}
    </ul>`;

  container.querySelectorAll('[data-accept]').forEach((b) => {
    b.onclick = async () => {
      b.disabled = true;
      const { data: res, error } = await supabase.rpc('respond_availability', {
        p_request_id: b.dataset.accept, p_accept: true,
      });
      if (error) { toast('Erro: ' + error.message, 'error'); b.disabled = false; return; }
      if (res === 'preenchida') {
        toast('Você confirmou! Quem agendou e o gestor foram avisados.', 'success', 6000);
      } else if (res === 'ja_preenchida') {
        toast('Esta vaga já foi preenchida por outra pessoa.', 'warn', 6000);
      }
      await supabase.from('notifications').update({ is_read: true }).eq('id', b.dataset.nid);
      await renderNotifications(container);
      updateBadge();
    };
  });

  container.querySelectorAll('[data-decline]').forEach((b) => {
    b.onclick = async () => {
      b.disabled = true;
      const { error } = await supabase.rpc('respond_availability', {
        p_request_id: b.dataset.decline, p_accept: false,
      });
      if (error) { toast('Erro: ' + error.message, 'error'); b.disabled = false; return; }
      toast('Você recusou. A disponibilidade continua aberta para os demais.', 'info', 5000);
      await supabase.from('notifications').update({ is_read: true }).eq('id', b.dataset.nid);
      await renderNotifications(container);
      updateBadge();
    };
  });

  container.querySelector('#mark-all')?.addEventListener('click', async () => {
    await supabase.from('notifications').update({ is_read: true })
      .eq('user_id', state.profile.id).eq('is_read', false);
    await renderNotifications(container);
    updateBadge();
  });

  container.querySelectorAll('[data-read]').forEach((b) => {
    b.onclick = async () => {
      await supabase.from('notifications').update({ is_read: true }).eq('id', b.dataset.read);
      await renderNotifications(container);
      updateBadge();
    };
  });
  container.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      await supabase.from('notifications').delete().eq('id', b.dataset.del);
      await renderNotifications(container);
      updateBadge();
    };
  });
}
