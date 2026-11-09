import type { Bindings } from './types';

/** Separação estrutural de ambientes: o Worker só opera contra o projeto Supabase esperado. */
export function validateConfig(env: Partial<Bindings>): string | null {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.APP_ENV || !env.EXPECTED_PROJECT_REF) {
    return 'missing required bindings';
  }
  if (env.APP_ENV !== 'hml' && env.APP_ENV !== 'prod') return 'invalid APP_ENV';
  let url: URL;
  try {
    url = new URL(env.SUPABASE_URL);
  } catch {
    return 'invalid SUPABASE_URL';
  }
  if (url.protocol !== 'https:') return 'SUPABASE_URL must be https';
  if (url.hostname !== `${env.EXPECTED_PROJECT_REF}.supabase.co`) {
    return 'SUPABASE_URL does not match EXPECTED_PROJECT_REF';
  }
  return null;
}
