// Teste ponta a ponta REAL: Worker (createApp + SupabaseRepo + realDeps) -> PostgREST -> Postgres/RLS -> GoTrue (JWT).
// Roda no CI contra o Supabase LOCAL (supabase start). Nunca contra hml/produção. Dados sintéticos.
// Variáveis: E2E_SUPABASE_URL, E2E_ANON_KEY, E2E_SERVICE_KEY (esta só para preparar usuários/organizações e conferir auditoria).
import { createClient } from '@supabase/supabase-js';
import { beforeAll, describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { realDeps } from '../src/supabaseRepo';

const PE = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env ?? {};
const URL_ = PE.E2E_SUPABASE_URL;
const ANON = PE.E2E_ANON_KEY;
const SERVICE = PE.E2E_SERVICE_KEY;
const enabled = !!(URL_ && ANON && SERVICE);

const env = {
  SUPABASE_URL: URL_ ?? '', SUPABASE_ANON_KEY: ANON ?? '', APP_ENV: 'ci', EXPECTED_PROJECT_REF: 'local',
  CPF_HMAC_KEY: 'e2e-only-key-0123456789-0123456789-abcdef', CPF_HMAC_KEY_VERSION: '1',
};
const app = createApp(realDeps);
const rnd = () => Math.random().toString(36).slice(2, 10);

type Call = { token?: string; org?: string; method?: string; body?: unknown; headers?: Record<string, string> };
const call = (path: string, o: Call = {}) => {
  const h: Record<string, string> = { ...(o.headers ?? {}) };
  if (o.token) h.authorization = `Bearer ${o.token}`;
  if (o.org) h['x-organization-id'] = o.org;
  if (o.body !== undefined) h['content-type'] = 'application/json';
  return app.request(path, { method: o.method ?? 'GET', headers: h, body: o.body === undefined ? undefined : JSON.stringify(o.body) }, env);
};
const json = async (r: Response) => (await r.json()) as Record<string, any>;

describe.skipIf(!enabled)('ponta a ponta contra Supabase local', () => {
  const admin = createClient(URL_ ?? 'http://x', SERVICE ?? 'x', { auth: { persistSession: false } });
  const tag = rnd();
  const users: Record<'a' | 'b', { id: string; email: string; token: string; org: string }> = {
    a: { id: '', email: `a-${tag}@e2e.test`, token: '', org: '' },
    b: { id: '', email: `b-${tag}@e2e.test`, token: '', org: '' },
  };
  const ids: Record<string, string> = {};
  const PASSWORD = `Pw-${tag}-Ab1!xyz`;

  beforeAll(async () => {
    for (const k of ['a', 'b'] as const) {
      const u = users[k];
      const { data, error } = await admin.auth.admin.createUser({ email: u.email, password: PASSWORD, email_confirm: true });
      if (error) throw error;
      u.id = data.user.id;
      const { data: org, error: e2 } = await admin.rpc('rpc_provision_organization', { p_user: u.id, p_name: `Clinica E2E ${k} ${tag}` });
      if (e2) throw e2;
      u.org = org as string;
      const anon = createClient(URL_!, ANON!, { auth: { persistSession: false } });
      const { data: s, error: e3 } = await anon.auth.signInWithPassword({ email: u.email, password: PASSWORD });
      if (e3) throw e3;
      u.token = s.session!.access_token;
    }
  });

  it('autenticação: sem token ou com token inválido → 401; com token → /api/me lista a organização', async () => {
    expect((await call('/api/me')).status).toBe(401);
    expect((await call('/api/me', { token: 'x.y.z' })).status).toBe(401);
    const r = await call('/api/me', { token: users.a.token });
    expect(r.status).toBe(200);
    expect(JSON.stringify(await r.json())).toContain(users.a.org);
  });

  it('cadastros via API real: unidade (idempotente, auditada por trigger com correlação/IP), profissional, sala, serviço', async () => {
    const headers = { 'idempotency-key': `idem-unit-${tag}`, 'x-request-id': `e2e-corr-${tag}`, 'cf-connecting-ip': '203.0.113.5', 'user-agent': 'e2e-agent' };
    const o = { token: users.a.token, org: users.a.org, method: 'POST', body: { name: `Unidade ${tag}` }, headers };
    const r1 = await call('/api/org/units', o);
    expect(r1.status).toBe(201);
    ids.unit = (await json(r1)).id;
    const r2 = await call('/api/org/units', o);
    expect(r2.status).toBe(201);
    expect(r2.headers.get('idempotent-replayed')).toBe('true');
    const { data: units } = await admin.from('units').select('id').eq('organization_id', users.a.org).eq('name', `Unidade ${tag}`);
    expect(units).toHaveLength(1);

    const { data: aud } = await admin.from('audit_logs').select('actor_id,correlation_id,ip,result,unit_id')
      .eq('organization_id', users.a.org).eq('action', 'unit.create').eq('resource_id', ids.unit);
    expect(aud).toHaveLength(1); // exatamente uma, mesmo com o replay
    expect(aud![0]).toMatchObject({ actor_id: users.a.id, correlation_id: `e2e-corr-${tag}`, result: 'success', unit_id: ids.unit });
    expect(String(aud![0]!.ip)).toContain('203.0.113.5');

    const mk = async (path: string, body: unknown) => { const r = await call(path, { token: users.a.token, org: users.a.org, method: 'POST', body }); expect(r.status, path).toBe(201); return json(r); };
    ids.prof = (await mk('/api/org/professionals', { full_name: 'Dra. Ana E2E', council: 'CRM', council_number: '123', council_uf: 'BA' })).id;
    expect((await call(`/api/org/professionals/${ids.prof}/units`, { token: users.a.token, org: users.a.org, method: 'POST', body: { unit_id: ids.unit } })).status).toBe(201);
    ids.room = (await mk('/api/org/rooms', { unit_id: ids.unit, name: 'Sala 1' })).id;
    ids.svc = (await mk('/api/org/services', { name: 'Consulta', kind: 'consultation', duration_minutes: 30 })).id;
  });

  it('paciente: CPF só como máscara na resposta; hash HMAC + versão no banco; auditoria sem PII', async () => {
    const r = await call('/api/org/patients', { token: users.a.token, org: users.a.org, method: 'POST', body: { full_name: 'Paciente Sintetico E2E', birth_date: '1990-01-01', cpf: '529.982.247-25' } });
    expect(r.status).toBe(201);
    const body = await json(r);
    ids.pat = body.id;
    expect(body.cpf_masked).toBe('***.***.***-25');
    expect(JSON.stringify(body)).not.toMatch(/52998224725|cpf_hash/);
    const { data: row } = await admin.from('patients').select('cpf_hash,cpf_key_version').eq('id', ids.pat).single();
    expect(row!.cpf_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row!.cpf_key_version).toBe(1);
    const { data: aud } = await admin.from('audit_logs').select('metadata,action').eq('organization_id', users.a.org).eq('resource_id', ids.pat);
    expect(aud!.some((a) => a.action === 'patient.create')).toBe(true);
    expect(JSON.stringify(aud)).not.toMatch(/52998224725|Sintetico|\*\*\*/);
    // busca por CPF usa o hash
    const f = await call('/api/org/patients?cpf=52998224725', { token: users.a.token, org: users.a.org });
    expect(((await json(f)).items as unknown[]).length).toBe(1);
  });

  it('agenda: reserva, conflito 409, replay idempotente e check-in', async () => {
    const start = new Date(Math.ceil(Date.now() / 3_600_000) * 3_600_000 + 3_600_000).toISOString();
    const book = { unit_id: ids.unit, service_id: ids.svc, starts_at: start, patient_id: ids.pat,
      resources: [{ type: 'professional', id: ids.prof }, { type: 'room', id: ids.room }] };
    const o = (key: string) => ({ token: users.a.token, org: users.a.org, method: 'POST', body: book, headers: { 'idempotency-key': key } });
    const r1 = await call('/api/org/events', o(`idem-book-1-${tag}`));
    expect(r1.status).toBe(201);
    ids.ev = (await json(r1)).id;
    const replay = await call('/api/org/events', o(`idem-book-1-${tag}`));
    expect(replay.status).toBe(201);
    expect(replay.headers.get('idempotent-replayed')).toBe('true');
    expect((await call('/api/org/events', o(`idem-book-2-${tag}`))).status).toBe(409);
    const { count } = await admin.from('scheduling_events').select('id', { count: 'exact', head: true }).eq('organization_id', users.a.org).eq('status', 'scheduled');
    expect(count).toBe(1);
    const ci = await call(`/api/org/events/${ids.ev}/check-in`, { token: users.a.token, org: users.a.org, method: 'POST', headers: { 'idempotency-key': `idem-ci-${tag}` } });
    expect(ci.status).toBe(201);
    expect((await call(`/api/org/events/${ids.ev}/check-in`, { token: users.a.token, org: users.a.org, method: 'POST', headers: { 'idempotency-key': `idem-ci-2-${tag}` } })).status).toBe(409);
  });

  it('isolamento entre organizações pela API real: B não acessa A e não enxerga seus dados', async () => {
    expect((await call('/api/org/units', { token: users.b.token, org: users.a.org })).status).toBe(403);
    expect((await call(`/api/org/events?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z`, { token: users.b.token, org: users.a.org })).status).toBe(403);
    const mine = await json(await call('/api/org/units', { token: users.b.token, org: users.b.org }));
    expect(JSON.stringify(mine)).not.toContain(ids.unit);
    const pats = await json(await call('/api/org/patients?q=Paciente', { token: users.b.token, org: users.b.org }));
    expect(pats.items).toHaveLength(0);
    expect((await call(`/api/org/patients/${ids.pat}`, { token: users.b.token, org: users.b.org })).status).toBe(404);
  });

  it('proprietário não consegue deixar a organização sem proprietário (banco, via JWT real)', async () => {
    const userClient = createClient(URL_!, ANON!, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${users.a.token}` } } });
    const { data: asg } = await admin.from('user_role_assignments').select('id').eq('organization_id', users.a.org);
    const { error } = await userClient.from('user_role_assignments').update({ revoked_at: new Date().toISOString() }).eq('id', asg![0]!.id);
    expect(error?.code).toBe('CF409');
  });
});
