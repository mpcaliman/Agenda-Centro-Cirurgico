// Configuração padrão. A URL e a chave anônima do Supabase são informadas
// pela própria tela do app (salvas no aparelho). Aqui ficam vazias.
export const CONFIG = {
  SUPABASE_URL: '',
  SUPABASE_ANON_KEY: '',
  STORAGE_BUCKET: 'appointment-files',
  APP_NAME: 'Centro Cirúrgico',
  TIME_ZONE: 'America/Bahia',
  MAX_FILE_SIZE: 10 * 1024 * 1024,
  ALLOWED_FILE_TYPES: ['image/jpeg', 'image/png', 'application/pdf'],
  LOGIN_MAX_ATTEMPTS: 5,
  LOGIN_LOCK_SECONDS: 60,
};
