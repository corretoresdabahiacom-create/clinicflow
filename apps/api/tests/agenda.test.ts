import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { ORG_A, ORG_B, UNIT_1, UNIT_2, env, makeDeps } from './fakes';

const PROF = '77777777-7777-4777-8777-777777777771';
const ROOM = '77777777-7777-4777-8777-777777777772';
const SVC = '77777777-7777-4777-8777-777777777773';

const setup = () => { const d = makeDeps(); return { ...d, app: createApp(d.deps) }; };
const call = (app: ReturnType<typeof createApp>, path: string, o: { token?: string; org?: string; method?: string; body?: unknown; key?: string } = {}) => {
  const h: Record<string, string> = {};
  if (o.token) h.authorization = `Bearer ${o.token}`;
  if (o.org) h['x-organization-id'] = o.org;
  if (o.key) h['idempotency-key'] = o.key;
  if (o.body !== undefined) h['content-type'] = 'application/json';
  return app.request(path, { method: o.method ?? 'GET', headers: h, body: o.body === undefined ? undefined : JSON.stringify(o.body) }, env);
};
const book = (over: Record<string, unknown> = {}) => ({
  unit_id: UNIT_1, service_id: SVC, starts_at: '2027-03-01T13:00:00Z',
  resources: [{ type: 'professional', id: PROF }, { type: 'room', id: ROOM }], ...over,
});

describe('cadastros: permissões e validação', () => {
  it('recepção (FRONTDESK) lê cadastros mas não cria profissional, serviço ou sala', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/professionals', { token: 'tok-front', org: ORG_A })).status).toBe(200);
    expect((await call(app, '/api/org/professionals', { token: 'tok-front', org: ORG_A, method: 'POST', body: { full_name: 'Dr. X' } })).status).toBe(403);
    expect((await call(app, '/api/org/services', { token: 'tok-front', org: ORG_A, method: 'POST', body: { name: 'Exame', kind: 'exam', duration_minutes: 20 } })).status).toBe(403);
    expect((await call(app, '/api/org/rooms', { token: 'tok-front', org: ORG_A, method: 'POST', body: { unit_id: UNIT_1, name: 'S1' } })).status).toBe(403);
  });
  it('sem permissão de leitura (tok-recep) → 403 em todas as listas', async () => {
    const { app } = setup();
    for (const p of ['professionals', 'rooms', 'equipment', 'services', 'events?from=2027-03-01T00:00:00Z&to=2027-03-02T00:00:00Z'])
      expect((await call(app, `/api/org/${p}`, { token: 'tok-recep', org: ORG_A })).status).toBe(403);
  });
  it('proprietário cadastra; payload com campo extra (organization_id) é rejeitado', async () => {
    const { app, world } = setup();
    const ok = await call(app, '/api/org/professionals', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { full_name: 'Dra. Ana', council: 'CRM', council_number: '123', council_uf: 'BA' } });
    expect(ok.status).toBe(201);
    expect(world.audits.some((a) => a.action === 'professional.create')).toBe(true);
    const bad = await call(app, '/api/org/professionals', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { full_name: 'Dra. Ana', organization_id: ORG_B } });
    expect(bad.status).toBe(422);
    const half = await call(app, '/api/org/professionals', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { full_name: 'Dra. Ana', council: 'CRM' } });
    expect(half.status).toBe(422);
  });
  it('sala exige escopo na unidade informada', async () => {
    const { app } = setup();
    // gerente restrito à unidade 1 (tok-unit tem unit.write apenas; sem resource.write) → 403
    expect((await call(app, '/api/org/rooms', { token: 'tok-unit', org: ORG_A, method: 'POST', body: { unit_id: UNIT_1, name: 'S1' } })).status).toBe(403);
    expect((await call(app, '/api/org/rooms', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { unit_id: UNIT_1, name: 'S1', capacity: 0 } })).status).toBe(422);
    expect((await call(app, '/api/org/rooms', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { unit_id: UNIT_1, name: 'S1' } })).status).toBe(201);
  });
  it('outro tenant não acessa a organização (403) e id inválido → 400', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/professionals', { token: 'tok-other', org: ORG_A })).status).toBe(403);
    expect((await call(app, '/api/org/professionals/xyz', { token: 'tok-owner', org: ORG_A, method: 'PATCH', body: { status: 'inactive' } })).status).toBe(400);
  });
});

describe('agenda', () => {
  it('Idempotency-Key é obrigatória para agendar, cancelar e remarcar', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book() })).status).toBe(400);
    expect((await call(app, `/api/org/events/${PROF}/cancel`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { reason: 'motivo' } })).status).toBe(400);
    expect((await call(app, `/api/org/events/${PROF}/reschedule`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { starts_at: '2027-03-01T15:00:00Z' } })).status).toBe(400);
  });
  it('somente quem tem agenda.write agenda; leitor (médico) → 403', async () => {
    const { app, world } = setup();
    const r = await call(app, '/api/org/events', { token: 'tok-ro', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0001' });
    expect(r.status).toBe(403);
    expect(world.calls).not.toContain('bookEvent');
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0002' })).status).toBe(201);
  });
  it('escopo de unidade: recepção da unidade 1 não agenda na unidade 2', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/events', { token: 'tok-front1', org: ORG_A, method: 'POST', body: book({ unit_id: UNIT_2 }), key: 'key-book-0003' })).status).toBe(403);
    expect((await call(app, '/api/org/events', { token: 'tok-front1', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0004' })).status).toBe(201);
  });
  it('conflito de recurso → 409; cancelar libera; reagendar no mesmo horário funciona', async () => {
    const { app } = setup();
    const a = await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0005' });
    const ev = (await a.json()) as { id: string };
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book({ starts_at: '2027-03-01T13:10:00Z' }), key: 'key-book-0006' })).status).toBe(409);
    expect((await call(app, `/api/org/events/${ev.id}/cancel`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { reason: 'paciente desistiu' }, key: 'key-cancel-01' })).status).toBe(200);
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0007' })).status).toBe(201);
    expect((await call(app, `/api/org/events/${ev.id}/cancel`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { reason: 'de novo' }, key: 'key-cancel-02' })).status).toBe(409);
  });
  it('remarcar em conflito retorna 409 e preserva o original', async () => {
    const { app, world } = setup();
    const a = (await (await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: 'key-book-0008' })).json()) as { id: string };
    await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book({ starts_at: '2027-03-01T15:00:00Z' }), key: 'key-book-0009' });
    const r = await call(app, `/api/org/events/${a.id}/reschedule`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { starts_at: '2027-03-01T15:10:00Z' }, key: 'key-resch-01' });
    expect(r.status).toBe(409);
    expect(world.events.find((e) => e.id === a.id)?.status).toBe('scheduled');
    const ok = await call(app, `/api/org/events/${a.id}/reschedule`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { starts_at: '2027-03-01T17:00:00Z' }, key: 'key-resch-02' });
    expect(ok.status).toBe(201);
    expect(((await ok.json()) as { rescheduled_from: string }).rescheduled_from).toBe(a.id);
  });
  it('mesma Idempotency-Key + mesmo corpo → replay sem novo agendamento; corpo diferente → 422', async () => {
    const { app, world } = setup();
    const k = 'key-book-0010';
    const r1 = await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: k });
    const r2 = await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book(), key: k });
    expect(r1.status).toBe(201); expect(r2.status).toBe(201);
    expect(r2.headers.get('idempotent-replayed')).toBe('true');
    expect(world.calls.filter((c) => c === 'bookEvent')).toHaveLength(1);
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: book({ starts_at: '2027-03-02T13:00:00Z' }), key: k })).status).toBe(422);
  });
  it('validação: horários sem fuso, recursos vazios/duplicados, campos extras, intervalo de consulta', async () => {
    const { app } = setup();
    const p = (body: unknown, key: string) => call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body, key });
    expect((await p(book({ starts_at: '2027-03-01T13:00:00' }), 'key-val-0001')).status).toBe(422);
    expect((await p(book({ resources: [] }), 'key-val-0002')).status).toBe(422);
    expect((await p(book({ patient_id: ROOM }), 'key-val-0003')).status).toBe(422);
    expect((await p(book({ unit_id: 'x' }), 'key-val-0004')).status).toBe(422);
    const q = (qs: string) => call(app, `/api/org/events?${qs}`, { token: 'tok-front', org: ORG_A });
    expect((await q('from=2027-03-01T00:00:00Z&to=2027-03-02T00:00:00Z')).status).toBe(200);
    expect((await q('from=2027-03-02T00:00:00Z&to=2027-03-01T00:00:00Z')).status).toBe(422);
    expect((await q('from=2027-01-01T00:00:00Z&to=2027-12-01T00:00:00Z')).status).toBe(422);
    expect((await q('from=2027-03-01&to=2027-03-02')).status).toBe(422);
  });
  it('organização suspensa ou outro tenant não agenda', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/events', { token: 'tok-susp', org: ORG_A, method: 'POST', body: book(), key: 'key-susp-001' })).status).toBe(403);
    expect((await call(app, '/api/org/events', { token: 'tok-other', org: ORG_A, method: 'POST', body: book(), key: 'key-oth-0001' })).status).toBe(403);
  });
});
