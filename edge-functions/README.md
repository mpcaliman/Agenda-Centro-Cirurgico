# Edge Functions

Funções que rodam no servidor do Supabase (Deno). Servem para tarefas que
exigem a **chave de serviço** (`service_role`) — que **nunca** pode ficar no
site/HTML.

## admin-reset-password

Permite ao **gestor** redefinir a senha de um usuário do seu centro,
definindo uma nova senha temporária na hora (entregue por WhatsApp). Não
depende de e-mail.

### Como instalar (uma vez só)

1. Acesse **supabase.com → seu projeto → Edge Functions**.
2. Clique em **Deploy a new function** (ou **Create function**).
3. Nome exatamente: `admin-reset-password`.
4. Cole o conteúdo de `admin-reset-password/index.ts`.
5. Clique em **Deploy**.

Não é preciso cadastrar segredos: `SUPABASE_URL`, `SUPABASE_ANON_KEY` e
`SUPABASE_SERVICE_ROLE_KEY` já existem no ambiente das funções.

### Segurança

- A função confere que quem chama está **logado**, está **ativo** e tem a
  função **gestor**, e que o usuário-alvo pertence ao **mesmo centro
  cirúrgico**.
- Ao redefinir, também marca o e-mail como confirmado (`email_confirm`),
  resolvendo contas que nasceram "não confirmadas".
- A `service_role` fica só no servidor. O site continua sem segredos.
