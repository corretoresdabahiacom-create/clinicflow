import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app';
import { HttpError } from '../src/errors';
import { ORG_A, ORG_B, env, makeDeps } from './fakes';

const PAT = '66666666-6666-4666-8666-666666666601';
const REC = '66666666-6666-4666-8666-666666666602';
const PROF = '66666666-6666-4666-8666-666666666603';
const setup = () => { const d = makeDeps(); return { ...d, app: createApp(d.deps) }; };
type O = { token?: string; org?: string; method?: string; body?: unknown; key?: string; headers?: Record<string, string> };
const call = (app: ReturnType<typeof createApp>, path: string, o: O = {}) => {
  const h: Record<string, string> = { ...(o.headers ?? {}) };
  if (o.token) h.authorization = `Bearer ${o.token}`;
  if (o.org !== undefined || o.token) h['x-organization-id'] = o.org ?? ORG_A;
  if (o.key) h['idempotency-key'] = o.key;
  if (o.body !== undefined) h['content-type'] = 'application/json';
  return app.request(path, { method: o.method ?? 'GET', headers: h, body: o.body === undefined ? undefined : JSON.stringify(o.body) }, env);
};
const newRec = { kind: 'evolution', title: 'Evolucao', body: 'Texto clinico sintetico' };

describe('prontuário: permissões (o banco repete a checagem)', () => {
  it('só quem tem clinical.* alcança as rotas; proprietário, recepção e leitura de agenda não leem nem escrevem conteúdo', async () => {
    const { app, world } = setup();
    for (const tok of ['tok-owner', 'tok-front', 'tok-ro', 'tok-auditor', 'tok-careadmin']) {
      expect((await call(app, `/api/org/patients/${PAT}/clinical-records?purpose=care`, { token: tok })).status, tok).toBe(403);
      expect((await call(app, `/api/org/clinical-records/${REC}?purpose=care`, { token: tok })).status, tok).toBe(403);
      expect((await call(app, `/api/org/patients/${PAT}/clinical-records`, { token: tok, method: 'POST', key: 'key-12345678', body: newRec })).status, tok).toBe(403);
      expect((await call(app, `/api/org/patients/${PAT}/emergency-access`, { token: tok, method: 'POST', key: 'key-12345678', body: { justification: 'x'.repeat(30) } })).status, tok).toBe(403);
    }
    expect(world.clinicalArgs).toHaveLength(0);
  });
  it('médico lê e escreve; auditor audita (log, revisão, integridade) mas não lê conteúdo; gestão de vínculo é separada', async () => {
    const { app, world } = setup();
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records?purpose=care`, { token: 'tok-doctor' })).status).toBe(200);
    expect((await call(app, `/api/org/clinical-records/${REC}?purpose=emergency`, { token: 'tok-doctor' })).status).toBe(200);
    expect((await call(app, '/api/org/clinical-access-logs', { token: 'tok-doctor' })).status).toBe(403);
    expect((await call(app, `/api/org/clinical-records/${REC}/verify`, { token: 'tok-doctor', method: 'POST' })).status).toBe(403);
    expect((await call(app, `/api/org/emergency-access/${REC}/review`, { token: 'tok-doctor', method: 'POST', body: { outcome: 'justified' } })).status).toBe(403);
    expect((await call(app, '/api/org/clinical-access-logs?limit=10', { token: 'tok-auditor' })).status).toBe(200);
    expect((await call(app, '/api/org/emergency-access', { token: 'tok-auditor' })).status).toBe(200);
    const v = await call(app, `/api/org/clinical-records/${REC}/verify`, { token: 'tok-auditor', method: 'POST' });
    expect(v.status).toBe(200);
    expect(await v.json()).toEqual({ id: REC, intact: true });
    expect((await call(app, `/api/org/emergency-access/${REC}/review`, { token: 'tok-auditor', method: 'POST', body: { outcome: 'justified', note: 'ok' } })).status).toBe(200);
    // vínculo: doctor/auditor não atribuem; care.assign sim
    const body = { professional_id: PROF, reason: 'Equipe compartilhada' };
    expect((await call(app, `/api/org/patients/${PAT}/care-relationships`, { token: 'tok-doctor', method: 'POST', key: 'key-care-0001', body })).status).toBe(403);
    expect((await call(app, `/api/org/patients/${PAT}/care-relationships`, { token: 'tok-careadmin', method: 'POST', key: 'key-care-0001', body })).status).toBe(201);
    expect((await call(app, `/api/org/care-relationships/${REC}/revoke`, { token: 'tok-careadmin', method: 'POST', body: { reason: 'fim' } })).status).toBe(200);
    expect(world.calls).toContain('verifyClinicalRecord');
  });
  it('outra organização e organização suspensa continuam bloqueadas', async () => {
    const { app } = setup();
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records?purpose=care`, { token: 'tok-doctor', org: ORG_B })).status).toBe(403);
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records?purpose=care`, { token: 'tok-susp' })).status).toBe(403);
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records?purpose=care`)).status).toBe(401);
  });
});

describe('cadastro do paciente para quem tem clinical.read', () => {
  it('médico consulta pacientes (o banco restringe aos vinculados) mas não cadastra nem edita', async () => {
    const { app } = setup();
    expect((await call(app, `/api/org/patients/${PAT}`, { token: 'tok-doctor' })).status).toBe(404); // fake sem o paciente: passou pela guarda
    expect((await call(app, '/api/org/patients?q=Ma', { token: 'tok-doctor' })).status).toBe(200);
    expect((await call(app, '/api/org/patients', { token: 'tok-doctor', method: 'POST', body: { full_name: 'Novo Paciente', birth_date: '1990-01-01' } })).status).toBe(403);
    expect((await call(app, `/api/org/patients/${PAT}`, { token: 'tok-doctor', method: 'PATCH', body: { full_name: 'Outro Nome' } })).status).toBe(403);
    expect((await call(app, `/api/org/patients/${PAT}`, { token: 'tok-ro' })).status).toBe(403);
  });
});

describe('prontuário: validação e contrato', () => {
  it('finalidade é obrigatória e só aceita care/emergency (leitura)', async () => {
    const { app, world } = setup();
    for (const q of ['', '?purpose=', '?purpose=audit', '?purpose=research', '?purpose=CARE']) {
      expect((await call(app, `/api/org/patients/${PAT}/clinical-records${q}`, { token: 'tok-doctor' })).status, q).toBe(422);
      expect((await call(app, `/api/org/clinical-records/${REC}${q}`, { token: 'tok-doctor' })).status, q).toBe(422);
    }
    expect(world.clinicalArgs).toHaveLength(0);
  });
  it('payloads estritos: campos extras/forjados e valores fora do limite → 422 sem tocar o banco', async () => {
    const { app, world } = setup();
    const post = (body: unknown, k = 'key-12345678') => call(app, `/api/org/patients/${PAT}/clinical-records`, { token: 'tok-doctor', method: 'POST', key: k, body });
    for (const bad of [
      { ...newRec, professional_id: PROF }, { ...newRec, organization_id: ORG_B }, { ...newRec, status: 'finalized' }, { ...newRec, patient_id: PAT },
      { ...newRec, kind: 'receita' }, { ...newRec, title: 'x' }, { ...newRec, body: '   ' }, { ...newRec, body: 'a'.repeat(20001) }, { ...newRec, event_id: 'nao-uuid' },
    ]) expect((await post(bad)).status, JSON.stringify(bad).slice(0, 60)).toBe(422);
    expect((await call(app, `/api/org/clinical-records/${REC}`, { token: 'tok-doctor', method: 'PATCH', body: { title: 'Ok', body: 'ok', status: 'draft' } })).status).toBe(422);
    expect((await call(app, `/api/org/clinical-records/${REC}/addenda`, { token: 'tok-doctor', method: 'POST', key: 'key-12345678', body: { reason: 'ab', body: 'x' } })).status).toBe(422);
    expect((await call(app, `/api/org/patients/${PAT}/emergency-access`, { token: 'tok-doctor', method: 'POST', key: 'key-12345678', body: { justification: 'curta' } })).status).toBe(422);
    expect((await call(app, `/api/org/emergency-access/${REC}/review`, { token: 'tok-auditor', method: 'POST', body: { outcome: 'talvez' } })).status).toBe(422);
    expect((await call(app, `/api/org/patients/nao-uuid/clinical-records?purpose=care`, { token: 'tok-doctor' })).status).toBe(400);
    expect(world.clinicalArgs).toHaveLength(0);
  });
  it('criar, adendar, finalizar e pedir emergência exigem Idempotency-Key; replay não duplica', async () => {
    const { app, world } = setup();
    const p = `/api/org/patients/${PAT}/clinical-records`;
    expect((await call(app, p, { token: 'tok-doctor', method: 'POST', body: newRec })).status).toBe(400);
    const o = { token: 'tok-doctor', method: 'POST', key: 'key-create-001', body: newRec };
    const r1 = await call(app, p, o); const r2 = await call(app, p, o);
    expect(r1.status).toBe(201); expect(r2.status).toBe(201);
    expect(r2.headers.get('idempotent-replayed')).toBe('true');
    expect(world.calls.filter((c) => c === 'createClinicalRecord')).toHaveLength(1);
    expect((await call(app, p, { ...o, body: { ...newRec, body: 'outro texto' } })).status).toBe(422); // mesma chave, outro payload
    expect((await call(app, `/api/org/clinical-records/${REC}/finalize`, { token: 'tok-doctor', method: 'POST' })).status).toBe(400);
    const f = await call(app, `/api/org/clinical-records/${REC}/finalize`, { token: 'tok-doctor', method: 'POST', key: 'key-final-001' });
    expect(f.status).toBe(200);
    expect(((await f.json()) as { content_hash: string }).content_hash).toMatch(/^[0-9a-f]{64}$/);
    expect((await call(app, `/api/org/clinical-records/${REC}/addenda`, { token: 'tok-doctor', method: 'POST', body: { reason: 'correcao', body: 'x' } })).status).toBe(400);
    const a = await call(app, `/api/org/clinical-records/${REC}/addenda`, { token: 'tok-doctor', method: 'POST', key: 'key-add-0001', body: { reason: 'correcao', body: 'texto' } });
    expect(a.status).toBe(201);
    expect(await a.json()).toEqual({ record_id: REC, seq: 1 });
  });
  it('conteúdo clínico não é guardado na idempotência nem vai para auditoria do Worker; respostas são no-store', async () => {
    const { app, world } = setup();
    const secret = 'SEGREDO-CLINICO-ABC';
    const r = await call(app, `/api/org/patients/${PAT}/clinical-records`, { token: 'tok-doctor', method: 'POST', key: 'key-secret-01', body: { ...newRec, body: secret } });
    expect(r.status).toBe(201);
    expect(r.headers.get('cache-control')).toBe('no-store');
    expect(JSON.stringify([...world.idem.values()])).not.toContain(secret);
    expect(JSON.stringify(world.audits)).not.toContain(secret);
    const g = await call(app, `/api/org/clinical-records/${REC}?purpose=care`, { token: 'tok-doctor' });
    expect(g.headers.get('cache-control')).toBe('no-store');
  });
  it('contexto da requisição segue ao banco (correlação, IP, UA) para o log de acesso', async () => {
    const { app, world } = setup();
    await call(app, `/api/org/clinical-records/${REC}?purpose=care`, { token: 'tok-doctor', headers: { 'x-request-id': 'req-clin-0001', 'cf-connecting-ip': '203.0.113.8', 'user-agent': 'ua-clin' } });
    expect(world.metas.at(-1)).toEqual({ correlationId: 'req-clin-0001', ip: '203.0.113.8', userAgent: 'ua-clin' });
  });
});

describe('prontuário: erros do banco viram respostas HTTP corretas', () => {
  it.each([[403, 'Forbidden'], [404, 'Not found'], [409, 'Conflict'], [422, 'Invalid request']])('repo %i → %i', async (status, title) => {
    const { app, world } = setup();
    world.clinicalError = new HttpError(status, title);
    const r = await call(app, `/api/org/clinical-records/${REC}?purpose=care`, { token: 'tok-doctor' });
    expect(r.status).toBe(status);
    expect(r.headers.get('cache-control')).toBe('no-store');
  });
  it('falha do banco numa criação permite nova tentativa com a mesma chave (sem duplicar)', async () => {
    const { app, world } = setup();
    const o = { token: 'tok-doctor', method: 'POST', key: 'key-retry-0001', body: newRec };
    world.clinicalError = new Error('db down') as HttpError;
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records`, o)).status).toBe(500);
    world.clinicalError = null;
    expect((await call(app, `/api/org/patients/${PAT}/clinical-records`, o)).status).toBe(201);
  });
});
