import { createClient } from '@supabase/supabase-js';

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL ?? '',
  import.meta.env.VITE_SUPABASE_ANON_KEY ?? '',
);

export type OrgContext = {
  organization_id: string; organization_name: string; organization_status: string;
  permissions: string[]; unit_scopes: { unit_id: string; permissions: string[] }[];
};
export type Unit = { id: string; name: string; timezone: string; status: string };

export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** Todas as chamadas levam o JWT do usuário; a organização é só uma seleção validada pelo servidor. */
export async function api<T>(path: string, init: { method?: string; org?: string; body?: unknown; idempotencyKey?: string } = {}): Promise<T> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new ApiError(401, 'Sessão expirada');
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (init.org) headers['X-Organization-Id'] = init.org;
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  if (init.idempotencyKey) headers['Idempotency-Key'] = init.idempotencyKey;
  const res = await fetch(`/api${path}`, { method: init.method ?? 'GET', headers, body: init.body === undefined ? undefined : JSON.stringify(init.body) });
  if (!res.ok) {
    const p = (await res.json().catch(() => ({}))) as { title?: string; detail?: string };
    throw new ApiError(res.status, [p.title, p.detail].filter(Boolean).join(': ') || `Erro ${res.status}`);
  }
  return (await res.json()) as T;
}
