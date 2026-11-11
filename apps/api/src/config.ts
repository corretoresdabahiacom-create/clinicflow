import type { Bindings } from './types';

/** Separação estrutural de ambientes: o Worker só opera contra o projeto Supabase esperado. */
export function validateConfig(env: Partial<Bindings>): string | null {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.APP_ENV || !env.EXPECTED_PROJECT_REF) {
    return 'missing required bindings';
  }
  if (env.APP_ENV !== 'hml' && env.APP_ENV !== 'prod' && env.APP_ENV !== 'ci') return 'invalid APP_ENV';
  let url: URL;
  try {
    url = new URL(env.SUPABASE_URL);
  } catch {
    return 'invalid SUPABASE_URL';
  }
  // 'ci' existe só para o teste ponta a ponta contra o Supabase local: exige loopback e nunca aponta para a nuvem.
  if (env.APP_ENV === 'ci') {
    return url.hostname === '127.0.0.1' || url.hostname === 'localhost' ? null : 'APP_ENV=ci requires a loopback SUPABASE_URL';
  }
  if (url.protocol !== 'https:') return 'SUPABASE_URL must be https';
  if (url.hostname !== `${env.EXPECTED_PROJECT_REF}.supabase.co`) {
    return 'SUPABASE_URL does not match EXPECTED_PROJECT_REF';
  }
  return null;
}
