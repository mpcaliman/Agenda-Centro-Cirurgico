// Configuração padrão. A URL e a chave anônima do Supabase são informadas
// pela própria tela do app (salvas no aparelho). Aqui ficam vazias.
export const CONFIG = {
  // Back end padrão — igual para todos os usuários, em qualquer aparelho/IP.
  // A chave abaixo é a PÚBLICA (publishable/anon): pode ficar no site com
  // segurança. Os dados são protegidos pela RLS no banco. NUNCA coloque aqui
  // a chave secreta (service_role / sb_secret_...).
  SUPABASE_URL: 'https://uurflwmgzvbsaozsuybu.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_P4rDKkPxJ_k9vxkulebC4A_c8TGPFk5',
  STORAGE_BUCKET: 'appointment-files',
  APP_NAME: 'Centro Cirúrgico',
  TIME_ZONE: 'America/Bahia',
  MAX_FILE_SIZE: 10 * 1024 * 1024,
  ALLOWED_FILE_TYPES: ['image/jpeg', 'image/png', 'application/pdf'],
  LOGIN_MAX_ATTEMPTS: 5,
  LOGIN_LOCK_SECONDS: 60,
};
