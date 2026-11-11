import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { hashCpf, isValidCpf, maskCpf, normalizeCpf } from '../src/cpf';
import { ORG_A, ORG_B, UNIT_1, env, makeDeps } from './fakes';

const CPF_OK = '529.982.247-25'; // CPF de exemplo público (sintético)
const setup = () => { const d = makeDeps(); return { ...d, app: createApp(d.deps) }; };
const call = (app: ReturnType<typeof createApp>, path: string, o: { token?: string; org?: string; method?: string; body?: unknown; key?: string; e?: typeof env } = {}) => {
  const h: Record<string, string> = {};
  if (o.token) h.authorization = `Bearer ${o.token}`;
  if (o.org) h['x-organization-id'] = o.org;
  if (o.key) h['idempotency-key'] = o.key;
  if (o.body !== undefined) h['content-type'] = 'application/json';
  return app.request(path, { method: o.method ?? 'GET', headers: h, body: o.body === undefined ? undefined : JSON.stringify(o.body) }, o.e ?? env);
};
const newPatient = (app: ReturnType<typeof createApp>, body: Record<string, unknown> = {}, token = 'tok-front') =>
  call(app, '/api/org/patients', { token, org: ORG_A, method: 'POST', body: { full_name: 'Maria Teste', birth_date: '1990-05-10', ...body } });

describe('cpf', () => {
  it('valida dígitos, rejeita repetidos e formatos inválidos', () => {
    expect(isValidCpf(normalizeCpf(CPF_OK))).toBe(true);
    expect(isValidCpf('11144477735')).toBe(true);
    expect(isValidCpf('52998224726')).toBe(false);
    expect(isValidCpf('11111111111')).toBe(false);
    expect(isValidCpf('123')).toBe(false);
    expect(isValidCpf('5299822472a')).toBe(false);
  });
  it('máscara só expõe os dois últimos dígitos; hash é determinístico e separado por organização', async () => {
    expect(maskCpf('52998224725')).toBe('***.***.***-25');
    const k = 'k'.repeat(40);
    const a1 = await hashCpf(k, ORG_A, '52998224725');
    expect(a1).toMatch(/^[0-9a-f]{64}$/);
    expect(await hashCpf(k, ORG_A, '52998224725')).toBe(a1);
    expect(await hashCpf(k, ORG_B, '52998224725')).not.toBe(a1);
    expect(await hashCpf('z'.repeat(40), ORG_A, '52998224725')).not.toBe(a1);
  });
});

describe('pacientes', () => {
  it('só quem tem patient.write cadastra; leitores sem patient.read não listam', async () => {
    const { app } = setup();
    expect((await newPatient(app, {}, 'tok-ro')).status).toBe(403);
    expect((await call(app, '/api/org/patients?q=Ma', { token: 'tok-ro', org: ORG_A })).status).toBe(403);
    expect((await newPatient(app)).status).toBe(201);
  });
  it('CPF nunca volta em claro nem como hash; só máscara', async () => {
    const { app, world } = setup();
    const r = await newPatient(app, { cpf: CPF_OK });
    const body = (await r.json()) as Record<string, unknown>;
    expect(r.status).toBe(201);
    expect(body.cpf_masked).toBe('***.***.***-25');
    expect(JSON.stringify(body)).not.toContain('52998224725');
    expect(JSON.stringify(body)).not.toContain('cpf_hash');
    const stored = world.catalog.patients![0]!;
    expect(String(stored.cpf_hash)).toMatch(/^[0-9a-f]{64}$/);
    expect(stored.cpf_key_version).toBe(1);
    expect(JSON.stringify(stored)).not.toContain('52998224725');
    expect(world.audits.some((a) => JSON.stringify(a).includes('5299822'))).toBe(false);
  });
  it('CPF inválido → 422; campo desconhecido (organization_id, cpf_hash) → 422; data futura → 422', async () => {
    const { app } = setup();
    expect((await newPatient(app, { cpf: '52998224726' })).status).toBe(422);
    expect((await newPatient(app, { organization_id: ORG_B })).status).toBe(422);
    expect((await newPatient(app, { cpf_hash: 'a'.repeat(64) })).status).toBe(422);
    expect((await newPatient(app, { birth_date: '2999-01-01' })).status).toBe(422);
    expect((await newPatient(app, { birth_date: '1990-02-31' })).status).toBe(422);
    expect((await newPatient(app, { phone: 'abc' })).status).toBe(422);
  });
  it('CPF duplicado → 409; possível duplicado (nome+nascimento) exige confirmação explícita', async () => {
    const { app } = setup();
    expect((await newPatient(app, { cpf: CPF_OK })).status).toBe(201);
    expect((await newPatient(app, { full_name: 'Outra Pessoa', cpf: CPF_OK })).status).toBe(409);
    const dup = await newPatient(app);   // Maria Teste 1990-05-10 já existe
    expect(dup.status).toBe(409);
    expect((await newPatient(app, { confirm_possible_duplicate: true })).status).toBe(201);
  });
  it('busca exige filtro, por CPF usa hash, por nome usa prefixo; GET por id audita leitura sem PII', async () => {
    const { app, world } = setup();
    const created = (await (await newPatient(app, { cpf: CPF_OK })).json()) as { id: string };
    expect((await call(app, '/api/org/patients', { token: 'tok-front', org: ORG_A })).status).toBe(422);
    const byCpf = (await (await call(app, `/api/org/patients?cpf=${encodeURIComponent(CPF_OK)}`, { token: 'tok-front', org: ORG_A })).json()) as { items: unknown[] };
    expect(byCpf.items).toHaveLength(1);
    const byName = (await (await call(app, '/api/org/patients?q=mar', { token: 'tok-front', org: ORG_A })).json()) as { items: unknown[] };
    expect(byName.items).toHaveLength(1);
    expect((await call(app, `/api/org/patients/${created.id}`, { token: 'tok-front', org: ORG_A })).status).toBe(200);
    expect(world.audits.some((a) => a.action === 'patient.read' && a.resourceId === created.id)).toBe(true);
    expect((await call(app, '/api/org/patients/not-a-uuid', { token: 'tok-front', org: ORG_A })).status).toBe(400);
    expect((await call(app, `/api/org/patients/${ORG_B}`, { token: 'tok-front', org: ORG_A })).status).toBe(404);
  });
  it('sem CPF_HMAC_KEY configurada, cadastro com CPF falha fechado (503) sem gravar', async () => {
    const { app, world } = setup();
    const { CPF_HMAC_KEY: _k, ...noKey } = env;
    const r = await call(app, '/api/org/patients', { token: 'tok-front', org: ORG_A, method: 'POST', body: { full_name: 'Sem Chave', birth_date: '1990-01-01', cpf: CPF_OK }, e: noKey as typeof env });
    expect(r.status).toBe(503);
    expect(world.catalog.patients ?? []).toHaveLength(0);
    const ok = await call(app, '/api/org/patients', { token: 'tok-front', org: ORG_A, method: 'POST', body: { full_name: 'Sem Cpf', birth_date: '1990-01-01' }, e: noKey as typeof env });
    expect(ok.status).toBe(201);
  });
  it('outro tenant não acessa (403)', async () => {
    const { app } = setup();
    expect((await call(app, '/api/org/patients?q=Ma', { token: 'tok-other', org: ORG_A })).status).toBe(403);
  });
});

describe('consentimentos, responsáveis e vínculo de conta', () => {
  const mk = async (app: ReturnType<typeof createApp>, name: string, extra: Record<string, unknown> = {}) =>
    ((await (await newPatient(app, { full_name: name, confirm_possible_duplicate: true, ...extra })).json()) as { id: string }).id;

  it('consentimento é registrado com finalidade/origem válidas', async () => {
    const { app } = setup();
    const id = await mk(app, 'Ana Consent');
    const path = `/api/org/patients/${id}/consents`;
    expect((await call(app, path, { token: 'tok-front', org: ORG_A, method: 'POST', body: { purpose: 'care_data', granted: true, source: 'in_person' } })).status).toBe(201);
    expect((await call(app, path, { token: 'tok-front', org: ORG_A, method: 'POST', body: { purpose: 'marketing', granted: true, source: 'in_person' } })).status).toBe(422);
    expect((await call(app, path, { token: 'tok-ro', org: ORG_A, method: 'POST', body: { purpose: 'care_data', granted: true, source: 'in_person' } })).status).toBe(403);
    expect(((await (await call(app, path, { token: 'tok-front', org: ORG_A })).json()) as { items: unknown[] }).items).toHaveLength(1);
  });
  it('responsável: não pode ser o próprio paciente; revogar duas vezes → 404', async () => {
    const { app } = setup();
    const kid = await mk(app, 'Crianca Teste', { birth_date: '2018-03-03' });
    const mom = await mk(app, 'Mae Teste');
    const g = (await (await call(app, `/api/org/patients/${kid}/guardians`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { guardian_patient_id: mom, relationship: 'parent' } })).json()) as { id: string };
    expect((await call(app, `/api/org/patients/${kid}/guardians`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { guardian_patient_id: kid, relationship: 'parent' } })).status).toBe(422);
    expect((await call(app, `/api/org/guardianships/${g.id}/revoke`, { token: 'tok-front', org: ORG_A, method: 'POST' })).status).toBe(200);
    expect((await call(app, `/api/org/guardianships/${g.id}/revoke`, { token: 'tok-front', org: ORG_A, method: 'POST' })).status).toBe(404);
  });
  it('vínculo de conta: idempotente, unicidade (409), revogação; leitor não vincula', async () => {
    const { app } = setup();
    const a = await mk(app, 'Paciente Link A'); const b = await mk(app, 'Paciente Link B');
    const user = '88888888-8888-4888-8888-888888888881';
    const link = (pid: string, key: string, tok = 'tok-front') => call(app, `/api/org/patients/${pid}/account-link`, { token: tok, org: ORG_A, method: 'POST', body: { user_id: user }, key });
    expect((await link(a, 'key-link-0001', 'tok-ro')).status).toBe(403);
    expect((await call(app, `/api/org/patients/${a}/account-link`, { token: 'tok-front', org: ORG_A, method: 'POST', body: { user_id: user } })).status).toBe(400);
    const r1 = await link(a, 'key-link-0002');
    expect(r1.status).toBe(201);
    expect((await link(a, 'key-link-0002')).headers.get('idempotent-replayed')).toBe('true');
    expect((await link(b, 'key-link-0003')).status).toBe(409);
    const { id } = (await r1.json()) as { id: string };
    expect((await call(app, `/api/org/account-links/${id}/revoke`, { token: 'tok-front', org: ORG_A, method: 'POST' })).status).toBe(200);
    expect((await call(app, `/api/org/account-links/${id}/revoke`, { token: 'tok-front', org: ORG_A, method: 'POST' })).status).toBe(404);
    expect((await link(b, 'key-link-0004')).status).toBe(201);
  });
});

describe('agenda com paciente e check-in', () => {
  const PROF = '77777777-7777-4777-8777-777777777771';
  const ROOM = '77777777-7777-4777-8777-777777777772';
  const SVC = '77777777-7777-4777-8777-777777777773';
  const bookBody = (patient_id?: string) => ({
    unit_id: UNIT_1, service_id: SVC, starts_at: '2027-03-01T13:00:00Z', patient_id,
    resources: [{ type: 'professional', id: PROF }, { type: 'room', id: ROOM }],
  });
  it('agenda com paciente; paciente inexistente → 404; patient_id em bloqueio → 422', async () => {
    const { app } = setup();
    const pid = ((await (await newPatient(app)).json()) as { id: string }).id;
    const ok = await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: bookBody(pid), key: 'key-pb-0001' });
    expect(ok.status).toBe(201);
    expect(((await ok.json()) as { patient_id: string }).patient_id).toBe(pid);
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: bookBody(ORG_B), key: 'key-pb-0002' })).status).toBe(404);
    expect((await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', key: 'key-pb-0003',
      body: { ...bookBody(pid), kind: 'block', service_id: undefined, title: 'Bloqueio' } })).status).toBe(422);
  });
  it('check-in exige Idempotency-Key e permissão; repetir → replay; segundo check-in com outra chave → 409', async () => {
    const { app } = setup();
    const pid = ((await (await newPatient(app)).json()) as { id: string }).id;
    const ev = (await (await call(app, '/api/org/events', { token: 'tok-front', org: ORG_A, method: 'POST', body: bookBody(pid), key: 'key-ck-0001' })).json()) as { id: string };
    const ci = (key?: string, tok = 'tok-front') => call(app, `/api/org/events/${ev.id}/check-in`, { token: tok, org: ORG_A, method: 'POST', key });
    expect((await ci()).status).toBe(400);
    expect((await ci('key-ck-0002', 'tok-ro')).status).toBe(403);
    expect((await ci('key-ck-0003')).status).toBe(201);
    expect((await ci('key-ck-0003')).headers.get('idempotent-replayed')).toBe('true');
    expect((await ci('key-ck-0004')).status).toBe(409);
  });
});
