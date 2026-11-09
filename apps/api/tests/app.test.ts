import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { ORG_A, ORG_B, UNIT_1, UNIT_2, env, makeDeps } from './fakes';

const call = (app: ReturnType<typeof createApp>, path: string, init: { token?: string; org?: string; method?: string; body?: unknown; headers?: Record<string, string>; e?: typeof env } = {}) => {
  const headers: Record<string, string> = { ...(init.headers ?? {}) };
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  if (init.org) headers['x-organization-id'] = init.org;
  if (init.body !== undefined) headers['content-type'] = 'application/json';
  return app.request(path, { method: init.method ?? 'GET', headers, body: init.body === undefined ? undefined : JSON.stringify(init.body) }, init.e ?? env);
};

describe('autenticação e configuração', () => {
  it('health é público', async () => {
    const { deps } = makeDeps();
    const r = await call(createApp(deps), '/api/health');
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ status: 'ok', env: 'hml' });
  });
  it('sem token → 401; token inválido → 401', async () => {
    const app = createApp(makeDeps().deps);
    expect((await call(app, '/api/me')).status).toBe(401);
    expect((await call(app, '/api/me', { token: 'bogus' })).status).toBe(401);
  });
  it('configuração apontando para outro projeto Supabase → 500 sem tocar em dados', async () => {
    const { deps, world } = makeDeps();
    const r = await call(createApp(deps), '/api/me', { token: 'tok-owner', e: { ...env, EXPECTED_PROJECT_REF: 'prodprodpr' } });
    expect(r.status).toBe(500);
    expect(world.calls).toEqual([]);
  });
  it('APP_ENV inválido → 500', async () => {
    const r = await call(createApp(makeDeps().deps), '/api/health', { e: { ...env, APP_ENV: 'staging' } });
    expect(r.status).toBe(500);
  });
  it('cabeçalhos de segurança e request id presentes', async () => {
    const r = await call(createApp(makeDeps().deps), '/api/health');
    expect(r.headers.get('x-content-type-options')).toBe('nosniff');
    expect(r.headers.get('x-request-id')).toBeTruthy();
  });
  it('/api/me lista só as organizações do usuário', async () => {
    const r = await call(createApp(makeDeps().deps), '/api/me', { token: 'tok-owner' });
    const body = (await r.json()) as { organizations: { organization_id: string }[] };
    expect(body.organizations.map((o) => o.organization_id)).toEqual([ORG_A]);
  });
});

describe('tenant e permissões', () => {
  const app = () => createApp(makeDeps().deps);
  it('sem X-Organization-Id → 400', async () => {
    expect((await call(app(), '/api/org', { token: 'tok-owner' })).status).toBe(400);
  });
  it('organização sem vínculo (spoof) → 403', async () => {
    expect((await call(app(), '/api/org', { token: 'tok-owner', org: ORG_B })).status).toBe(403);
    expect((await call(app(), '/api/org/units', { token: 'tok-other', org: ORG_A })).status).toBe(403);
    expect((await call(app(), '/api/org', { token: 'tok-none', org: ORG_A })).status).toBe(403);
  });
  it('organização suspensa → 403', async () => {
    expect((await call(app(), '/api/org', { token: 'tok-susp', org: ORG_A })).status).toBe(403);
  });
  it('recepcionista lê unidades mas não edita organização nem cria unidade', async () => {
    const a = app();
    expect((await call(a, '/api/org/units', { token: 'tok-recep', org: ORG_A })).status).toBe(200);
    expect((await call(a, '/api/org', { token: 'tok-recep', org: ORG_A, method: 'PATCH', body: { name: 'Novo' } })).status).toBe(403);
    expect((await call(a, '/api/org/units', { token: 'tok-recep', org: ORG_A, method: 'POST', body: { name: 'Nova' } })).status).toBe(403);
    expect((await call(a, '/api/org/audit-logs', { token: 'tok-recep', org: ORG_A })).status).toBe(403);
  });
  it('gerente de unidade edita só a própria unidade e não cria unidade', async () => {
    const a = app();
    expect((await call(a, `/api/org/units/${UNIT_1}`, { token: 'tok-unit', org: ORG_A, method: 'PATCH', body: { name: 'Renomeada' } })).status).toBe(200);
    expect((await call(a, `/api/org/units/${UNIT_2}`, { token: 'tok-unit', org: ORG_A, method: 'PATCH', body: { name: 'Hack' } })).status).toBe(403);
    expect((await call(a, '/api/org/units', { token: 'tok-unit', org: ORG_A, method: 'POST', body: { name: 'Nova' } })).status).toBe(403);
    expect((await call(a, '/api/org/units', { token: 'tok-unit', org: ORG_A })).status).toBe(200);
  });
  it('ids malformados → 400', async () => {
    expect((await call(app(), '/api/org/units/not-a-uuid', { token: 'tok-owner', org: ORG_A, method: 'PATCH', body: { name: 'Xx' } })).status).toBe(400);
  });
  it('negação gera auditoria com resultado denied', async () => {
    const { deps, world } = makeDeps();
    await call(createApp(deps), '/api/org', { token: 'tok-recep', org: ORG_A, method: 'PATCH', body: { name: 'Novo' } });
    expect(world.audits.at(-1)).toMatchObject({ result: 'denied', organizationId: ORG_A, action: 'denied:org.manage' });
  });
});

describe('validação', () => {
  const app = () => createApp(makeDeps().deps);
  const post = (body: unknown) => call(app(), '/api/org/units', { token: 'tok-owner', org: ORG_A, method: 'POST', body });
  it('nome curto, timezone inválido e campos extras → 422', async () => {
    expect((await post({ name: 'x' })).status).toBe(422);
    expect((await post({ name: 'Unidade', timezone: 'Mars/Base' })).status).toBe(422);
    expect((await post({ name: 'Unidade', organization_id: ORG_B })).status).toBe(422);
    expect((await post({ name: 'Unidade', status: 'inactive' })).status).toBe(422);
  });
  it('JSON inválido → 400; cnpj inválido → 422; patch vazio → 422', async () => {
    const r = await app().request('/api/org/units', { method: 'POST', headers: { authorization: 'Bearer tok-owner', 'x-organization-id': ORG_A }, body: '{' }, env);
    expect(r.status).toBe(400);
    expect((await call(app(), '/api/org', { token: 'tok-owner', org: ORG_A, method: 'PATCH', body: { cnpj: '123' } })).status).toBe(422);
    expect((await call(app(), '/api/org', { token: 'tok-owner', org: ORG_A, method: 'PATCH', body: {} })).status).toBe(422);
  });
  it('erros usam application/problem+json e não vazam detalhes internos', async () => {
    const { deps, world } = makeDeps();
    world.failNextCreate = true;
    const r = await call(createApp(deps), '/api/org/units', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { name: 'Unidade' } });
    expect(r.status).toBe(500);
    expect(r.headers.get('content-type')).toContain('application/problem+json');
    expect(JSON.stringify(await r.json())).not.toContain('db down');
  });
});

describe('auditoria e idempotência', () => {
  it('criação grava auditoria com ator/organização/correlação', async () => {
    const { deps, world } = makeDeps();
    const r = await call(createApp(deps), '/api/org/units', { token: 'tok-owner', org: ORG_A, method: 'POST', body: { name: 'Nova Unidade' }, headers: { 'x-request-id': 'req-12345678' } });
    expect(r.status).toBe(201);
    expect(world.audits.at(-1)).toMatchObject({ action: 'unit.create', result: 'success', organizationId: ORG_A, correlationId: 'req-12345678' });
  });
  it('mesma Idempotency-Key cria uma única unidade e reaproveita a resposta', async () => {
    const { deps, world } = makeDeps();
    const a = createApp(deps);
    const opts = { token: 'tok-owner', org: ORG_A, method: 'POST', body: { name: 'Unica' }, headers: { 'idempotency-key': 'key-abcdefgh' } };
    const r1 = await call(a, '/api/org/units', opts);
    const r2 = await call(a, '/api/org/units', opts);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);
    expect(r2.headers.get('idempotent-replayed')).toBe('true');
    expect(await r2.json()).toEqual(await r1.json());
    expect(world.calls.filter((c) => c === 'createUnit')).toHaveLength(1);
  });
  it('mesma chave com payload diferente → 422; chave malformada → 400', async () => {
    const a = createApp(makeDeps().deps);
    const base = { token: 'tok-owner', org: ORG_A, method: 'POST', headers: { 'idempotency-key': 'key-abcdefgh' } };
    await call(a, '/api/org/units', { ...base, body: { name: 'Primeira' } });
    expect((await call(a, '/api/org/units', { ...base, body: { name: 'Segunda' } })).status).toBe(422);
    expect((await call(a, '/api/org/units', { ...base, body: { name: 'Terceira' }, headers: { 'idempotency-key': 'curta' } })).status).toBe(400);
  });
  it('falha na execução permite nova tentativa com a mesma chave (sem duplicar)', async () => {
    const { deps, world } = makeDeps();
    const a = createApp(deps);
    const opts = { token: 'tok-owner', org: ORG_A, method: 'POST', body: { name: 'Retry' }, headers: { 'idempotency-key': 'key-retry-001' } };
    world.failNextCreate = true;
    expect((await call(a, '/api/org/units', opts)).status).toBe(500);
    expect((await call(a, '/api/org/units', opts)).status).toBe(201);
    expect(world.units.filter((u) => u.name === 'Retry')).toHaveLength(1);
  });
});

describe('rate limit', () => {
  it('limite excedido → 429 com Retry-After; falha do limitador → 503 (fail-closed)', async () => {
    const blocked = createApp(makeDeps({ limiter: { hit: async () => false } }).deps);
    const r = await call(blocked, '/api/me', { token: 'tok-owner' });
    expect(r.status).toBe(429);
    expect(r.headers.get('retry-after')).toBe('60');
    const broken = createApp(makeDeps({ limiter: { hit: async () => { throw new Error('x'); } } }).deps);
    expect((await call(broken, '/api/me', { token: 'tok-owner' })).status).toBe(503);
  });
  it('não consulta o limitador sem autenticação válida', async () => {
    let hits = 0;
    const app = createApp(makeDeps({ limiter: { hit: async () => { hits++; return true; } } }).deps);
    await call(app, '/api/me');
    expect(hits).toBe(0);
  });
});
