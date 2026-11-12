import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { ORG_A, ORG_B, PAT_A, PAT_DEP, PAT_OTHER, EV_PAT, EV_OTHER, UNIT_1, env, makeDeps } from './fakes';
import type { Bindings } from '../src/types';

const SV = '99999999-9999-4999-8999-999999999991';
const PR = '99999999-9999-4999-8999-999999999992';
const envTs: Bindings = { ...env, TURNSTILE_SECRET: 'secret-test' };
const setup = (o: Parameters<typeof makeDeps>[0] = {}) => { const d = makeDeps(o); return { ...d, app: createApp(d.deps) }; };
type O = { token?: string; method?: string; body?: unknown; e?: Bindings; ts?: string };
const call = (app: ReturnType<typeof createApp>, path: string, o: O = {}) => {
  const h: Record<string, string> = {};
  if (o.token) h.authorization = `Bearer ${o.token}`;
  if (o.ts) h['x-turnstile-token'] = o.ts;
  if (o.body !== undefined) h['content-type'] = 'application/json';
  return app.request(path, { method: o.method ?? 'GET', headers: h, body: o.body === undefined ? undefined : JSON.stringify(o.body) }, o.e ?? envTs);
};
const book = { unit_id: UNIT_1, service_id: SV, professional_id: PR, starts_at: '2030-02-01T13:00:00Z' };

describe('portal: autenticação e escopo', () => {
  it('exige login em todas as rotas e não depende de X-Organization-Id', async () => {
    const { app } = setup();
    for (const [m, p] of [['GET', '/api/portal/context'], ['GET', `/api/portal/orgs/${ORG_A}/catalog`],
      ['GET', `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`], ['POST', `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/cancel`]] as const) {
      expect((await call(app, p, { method: m, body: m === 'POST' ? {} : undefined })).status, p).toBe(401);
    }
    const r = await call(app, '/api/portal/context', { token: 'tok-pat' });
    expect(r.status).toBe(200);
    expect(((await r.json()) as { items: { relation: string }[] }).items.map((i) => i.relation)).toEqual(['self', 'dependent']);
  });
  it('usuário sem vínculo recebe lista vazia e 404 nas demais rotas (não revela existência)', async () => {
    const { app } = setup();
    expect(((await (await call(app, '/api/portal/context', { token: 'tok-pat2' })).json()) as { items: unknown[] }).items).toEqual([]);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/catalog`, { token: 'tok-pat2' })).status).toBe(404);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`, { token: 'tok-pat2' })).status).toBe(404);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/cancel`, { token: 'tok-pat2', method: 'POST', body: {} })).status).toBe(404);
  });
  it('membro da equipe sem vínculo de paciente não usa o portal; paciente não acessa rotas da equipe', async () => {
    const { app } = setup();
    expect((await call(app, `/api/portal/orgs/${ORG_A}/catalog`, { token: 'tok-owner' })).status).toBe(404);
    expect((await call(app, '/api/org/units', { token: 'tok-pat' })).status).toBe(400); // sem X-Organization-Id
    const r = await app.request('/api/org/units', { headers: { authorization: 'Bearer tok-pat', 'x-organization-id': ORG_A } }, envTs);
    expect(r.status).toBe(403);
  });
  it('paciente lê só os próprios agendamentos e os do dependente; nunca de outro paciente', async () => {
    const { app } = setup();
    const own = await call(app, `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`, { token: 'tok-pat' });
    expect(((await own.json()) as { items: { event_id: string }[] }).items.map((i) => i.event_id)).toEqual([EV_PAT]);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/patients/${PAT_DEP}/appointments`, { token: 'tok-pat' })).status).toBe(200);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/patients/${PAT_OTHER}/appointments`, { token: 'tok-pat' })).status).toBe(404);
    expect((await call(app, `/api/portal/orgs/${ORG_B}/patients/${PAT_A}/appointments`, { token: 'tok-pat' })).status).toBe(404);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_OTHER}/cancel`, { token: 'tok-pat', method: 'POST', body: {} })).status).toBe(404);
  });
  it('resposta não traz campo clínico nem dado cadastral do paciente além do nome do contexto', async () => {
    const { app } = setup();
    const body = JSON.stringify(await (await call(app, `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`, { token: 'tok-pat' })).json());
    for (const k of ['cpf', 'record', 'prontuario', 'clinical', 'body', 'phone', 'email', 'birth']) expect(body.toLowerCase()).not.toContain(k);
    expect((await call(app, `/api/portal/context`, { token: 'tok-pat' })).headers.get('cache-control')).toBe('no-store');
  });
});

describe('portal: validação e horários', () => {
  it('valida ids e intervalo de consulta de horários', async () => {
    const { app } = setup();
    expect((await call(app, '/api/portal/orgs/xx/catalog', { token: 'tok-pat' })).status).toBe(400);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/slots?unit_id=${UNIT_1}`, { token: 'tok-pat' })).status).toBe(422);
    const ok = await call(app, `/api/portal/orgs/${ORG_A}/slots?unit_id=${UNIT_1}&service_id=${SV}&professional_id=${PR}&from=2030-01-03&to=2030-01-04`, { token: 'tok-pat' });
    expect(ok.status).toBe(200);
  });
  it('rejeita corpo com campo extra ou inválido ao agendar/remarcar/cancelar', async () => {
    const { app, world } = setup();
    const u = `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`;
    for (const b of [{ ...book, patient_id: PAT_OTHER }, { ...book, starts_at: 'amanha' }, { unit_id: UNIT_1 }]) {
      expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: b, ts: 'ok-token' })).status).toBe(422);
    }
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/reschedule`, { token: 'tok-pat', method: 'POST', body: { starts_at: 'x' }, ts: 'ok-token' })).status).toBe(422);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/cancel`, { token: 'tok-pat', method: 'POST', body: { reason: 'x' } })).status).toBe(422);
    expect(world.portal.calls.filter((c) => c.fn === 'portalBook' || c.fn === 'portalReschedule' || c.fn === 'portalCancel')).toHaveLength(0);
  });
});

describe('portal: antiabuso (Turnstile fail-closed + rate limit)', () => {
  const u = `/api/portal/orgs/${ORG_A}/patients/${PAT_A}/appointments`;
  it('com Turnstile válido agenda e remarca; cancelar não exige', async () => {
    const { app, world } = setup();
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'ok-token' })).status).toBe(201);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/reschedule`, { token: 'tok-pat', method: 'POST', body: { starts_at: '2030-02-02T13:00:00Z' }, ts: 'ok-token' })).status).toBe(201);
    expect((await call(app, `/api/portal/orgs/${ORG_A}/appointments/${EV_PAT}/cancel`, { token: 'tok-pat', method: 'POST', body: {} })).status).toBe(200);
    expect(world.portal.turnstile).toEqual(['ok-token', 'ok-token']);
  });
  it('sem token ou token inválido: 403 e nada é gravado', async () => {
    const { app, world } = setup();
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book })).status).toBe(403);
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'forjado' })).status).toBe(403);
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'x'.repeat(3000) })).status).toBe(403);
    expect(world.portal.calls.filter((c) => c.fn === 'portalBook')).toHaveLength(0);
  });
  it('sem segredo configurado, o agendamento fica fechado (503) em hml e prod', async () => {
    for (const appEnv of ['hml', 'prod']) {
      const { app, world } = setup();
      const e: Bindings = { ...env, APP_ENV: appEnv, EXPECTED_PROJECT_REF: 'abcdefghij' };
      expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'ok-token', e })).status, appEnv).toBe(503);
      expect(world.portal.calls.filter((c) => c.fn === 'portalBook')).toHaveLength(0);
    }
  });
  it('APP_ENV=ci (somente Supabase local) dispensa o Turnstile quando não há segredo', async () => {
    const { app } = setup();
    const e: Bindings = { ...env, APP_ENV: 'ci', SUPABASE_URL: 'http://127.0.0.1:54521' };
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, e })).status).toBe(201);
  });
  it('limite de escritas por usuário devolve 429 antes de qualquer gravação', async () => {
    let n = 0;
    const limiter = { hit: async (b: string) => { n++; return !b.startsWith('portal:'); } };
    const { app, world } = setup({ limiter });
    const r = await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'ok-token' });
    expect(r.status).toBe(429); expect(r.headers.get('retry-after')).toBe('60');
    expect(world.portal.calls.filter((c) => c.fn === 'portalBook')).toHaveLength(0);
    expect(n).toBeGreaterThan(0);
  });
  it('falha do limitador não libera a escrita (503)', async () => {
    const { app } = setup({ limiter: { hit: async () => { throw new Error('db down'); } } });
    expect((await call(app, u, { token: 'tok-pat', method: 'POST', body: book, ts: 'ok-token' })).status).toBe(503);
  });
});

describe('equipe: disponibilidade e parâmetros', () => {
  const h = (tok: string) => ({ authorization: `Bearer ${tok}`, 'x-organization-id': ORG_A, 'content-type': 'application/json' });
  const put = (app: ReturnType<typeof createApp>, path: string, tok: string, body: unknown) =>
    app.request(path, { method: 'PUT', headers: h(tok), body: JSON.stringify(body) }, envTs);
  it('disponibilidade: só quem escreve agenda; valida janelas', async () => {
    const { app, world } = setup();
    const ok = { unit_id: UNIT_1, windows: [{ weekday: 1, start: '08:00', end: '12:00' }] };
    expect((await put(app, `/api/org/professionals/${PR}/availability`, 'tok-ro', ok)).status).toBe(403);
    expect((await put(app, `/api/org/professionals/${PR}/availability`, 'tok-front', ok)).status).toBe(200);
    expect((await put(app, `/api/org/professionals/${PR}/availability`, 'tok-front', { ...ok, windows: [{ weekday: 9, start: '08:00', end: '12:00' }] })).status).toBe(422);
    expect((await put(app, `/api/org/professionals/${PR}/availability`, 'tok-front', { ...ok, windows: [{ weekday: 1, start: '12:00', end: '08:00' }] })).status).toBe(422);
    expect(world.portal.calls.filter((c) => c.fn === 'setAvailability')).toHaveLength(1);
  });
  it('parâmetros do portal: só org.manage', async () => {
    const { app } = setup();
    const b = { min_lead_hours: 2, cancel_min_hours: 24, horizon_days: 60, max_active_per_patient: 5, max_reschedules: 2 };
    expect((await put(app, '/api/org/portal-settings', 'tok-front', b)).status).toBe(403);
    expect((await put(app, '/api/org/portal-settings', 'tok-owner', b)).status).toBe(200);
    expect((await put(app, '/api/org/portal-settings', 'tok-owner', { ...b, horizon_days: 999 })).status).toBe(422);
  });
});
