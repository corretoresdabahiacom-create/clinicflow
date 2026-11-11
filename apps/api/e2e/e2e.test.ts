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
  type U = { id: string; email: string; token: string; org: string };
  const mkU = (k: string): U => ({ id: '', email: `${k}-${tag}@e2e.test`, token: '', org: '' });
  const users: Record<'a' | 'b' | 'd' | 'd2' | 'au', U> = { a: mkU('a'), b: mkU('b'), d: mkU('d'), d2: mkU('d2'), au: mkU('au') };
  const members: Record<string, string> = {};
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
    // profissionais de saúde e auditor da organização A (fixtures via service_role; papéis de sistema do provisionamento)
    const { data: roles } = await admin.from('roles').select('id,key').eq('organization_id', users.a.org);
    const roleId = (key: string) => roles!.find((r) => r.key === key)!.id as string;
    for (const [k, role] of [['d', 'doctor'], ['d2', 'doctor'], ['au', 'auditor']] as const) {
      const u = users[k];
      const { data, error } = await admin.auth.admin.createUser({ email: u.email, password: PASSWORD, email_confirm: true });
      if (error) throw error;
      u.id = data.user.id; u.org = users.a.org;
      const { data: m, error: e2 } = await admin.from('organization_members').insert({ organization_id: u.org, user_id: u.id }).select('id').single();
      if (e2) throw e2;
      members[k] = m.id as string;
      const { error: e3 } = await admin.from('user_role_assignments').insert({ organization_id: u.org, member_id: m.id, role_id: roleId(role) });
      if (e3) throw e3;
      const anon = createClient(URL_!, ANON!, { auth: { persistSession: false } });
      const { data: s, error: e4 } = await anon.auth.signInWithPassword({ email: u.email, password: PASSWORD });
      if (e4) throw e4;
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

  it('1D vínculo assistencial + prontuário: fluxo completo com vínculo automático, finalidade, emergência, auditoria e bloqueios', async () => {
    const A = users.a.org; const secret = `SEGREDO-CLINICO-${tag}`;
    const get = (path: string, tok: string, headers: Record<string, string> = {}) => call(path, { token: tok, org: A, headers });
    const post = (path: string, tok: string, body: unknown, key?: string, headers: Record<string, string> = {}) =>
      call(path, { token: tok, org: A, method: 'POST', body, headers: { ...(key ? { 'idempotency-key': `${key}-${tag}` } : {}), ...headers } });
    const prof = async (k: 'd' | 'd2', name: string) => {
      const { data, error } = await admin.from('professionals').insert({ organization_id: A, full_name: name, member_id: members[k] }).select('id').single();
      if (error) throw error;
      const { error: e2 } = await admin.from('professional_units').insert({ organization_id: A, professional_id: data.id, unit_id: ids.unit });
      if (e2) throw e2;
      return data.id as string;
    };
    const pd = await prof('d', 'Dr. Vinculado'); await prof('d2', 'Dra. Sem Vinculo');

    // agendamento do paciente com o profissional do médico => vínculo automático (somente dele)
    const start = new Date(Math.ceil(Date.now() / 3_600_000) * 3_600_000 + 5 * 3_600_000).toISOString();
    const b = await post('/api/org/events', users.a.token, { unit_id: ids.unit, service_id: ids.svc, starts_at: start, patient_id: ids.pat,
      resources: [{ type: 'professional', id: pd }, { type: 'room', id: ids.room }] }, 'idem-1d-book');
    expect(b.status).toBe(201);
    ids.ev2 = (await json(b)).id;
    const rel = await json(await get(`/api/org/care-relationships?patient_id=${ids.pat}`, users.au.token));
    const active = (rel.items as any[]).filter((r) => !r.revoked_at);
    expect(active).toHaveLength(1);
    expect(active[0]).toMatchObject({ professional_id: pd, source: 'appointment', event_id: ids.ev2 });

    // o médico vinculado enxerga o cadastro do paciente; o não vinculado não
    const pv = await get(`/api/org/patients/${ids.pat}`, users.d.token);
    expect(pv.status).toBe(200);
    expect((await json(pv)).cpf_masked).toBe('***.***.***-25');
    expect((await get(`/api/org/patients/${ids.pat}`, users.d2.token)).status).toBe(404);

    // rascunho -> edição -> finalização -> adendo -> leitura com finalidade
    const rc = await post(`/api/org/patients/${ids.pat}/clinical-records`, users.d.token, { kind: 'evolution', title: 'Evolucao E2E', body: `Relato ${secret}`, event_id: ids.ev2 }, 'idem-1d-rec');
    expect(rc.status).toBe(201);
    ids.rec = (await json(rc)).id;
    expect((await call(`/api/org/clinical-records/${ids.rec}`, { token: users.d.token, org: A, method: 'PATCH', body: { title: 'Evolucao E2E', body: `Relato revisado ${secret}` } })).status).toBe(200);
    const fin = await post(`/api/org/clinical-records/${ids.rec}/finalize`, users.d.token, {}, 'idem-1d-fin');
    expect(fin.status).toBe(200);
    expect((await json(fin)).content_hash).toMatch(/^[0-9a-f]{64}$/);
    expect((await call(`/api/org/clinical-records/${ids.rec}`, { token: users.d.token, org: A, method: 'PATCH', body: { title: 'Outro', body: 'Alterado depois de finalizar' } })).status).toBe(409);
    const ad = await post(`/api/org/clinical-records/${ids.rec}/addenda`, users.d.token, { reason: 'correcao de dose', body: 'Dose ajustada' }, 'idem-1d-add');
    expect(ad.status).toBe(201);
    expect((await json(ad)).seq).toBe(1);
    const rd = await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d.token, { 'x-request-id': `e2e-clin-${tag}` });
    const rdj = await json(rd);
    expect(rd.status).toBe(200);
    expect(rdj.record.body).toContain(secret);
    expect(rdj.record.status).toBe('finalized');
    expect(rdj.integrity).toBe('ok');
    expect(rdj.addenda).toHaveLength(1);
    expect(rd.headers.get('cache-control')).toBe('no-store');

    // negados: sem vínculo, sem papel clínico (proprietário/auditor) e sem finalidade válida
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d2.token)).status).toBe(403);
    expect((await get(`/api/org/patients/${ids.pat}/clinical-records?purpose=care`, users.d2.token)).status).toBe(403);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.a.token)).status).toBe(403);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.au.token)).status).toBe(403);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=audit`, users.d.token)).status).toBe(422);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=emergency`, users.d.token)).status).toBe(403);

    // acesso de emergência: justificado, temporário, só leitura, revisado por quem audita
    expect((await post(`/api/org/patients/${ids.pat}/emergency-access`, users.d2.token, { justification: 'curta demais' }, 'idem-1d-em0')).status).toBe(422);
    const em = await post(`/api/org/patients/${ids.pat}/emergency-access`, users.d2.token, { justification: 'Paciente instavel, historico necessario para conduta imediata' }, 'idem-1d-em1');
    expect(em.status).toBe(201);
    const grant = (await json(em)).id as string;
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=emergency`, users.d2.token)).status).toBe(200);
    expect((await get(`/api/org/patients/${ids.pat}/clinical-records?purpose=emergency`, users.d2.token)).status).toBe(200);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d2.token)).status).toBe(403);
    expect((await post(`/api/org/patients/${ids.pat}/clinical-records`, users.d2.token, { kind: 'evolution', title: 'Tentativa', body: 'x' }, 'idem-1d-em2')).status).toBe(403);
    expect((await post(`/api/org/emergency-access/${grant}/review`, users.d2.token, { outcome: 'justified' })).status).toBe(403);
    const pend = await json(await get('/api/org/emergency-access', users.au.token));
    expect((pend.items as any[]).some((g) => g.id === grant)).toBe(true);
    expect((await post(`/api/org/emergency-access/${grant}/review`, users.au.token, { outcome: 'justified', note: 'Parada documentada' })).status).toBe(200);
    expect((await post(`/api/org/emergency-access/${grant}/review`, users.au.token, { outcome: 'not_justified' })).status).toBe(409);

    // integridade e log de acesso (sem conteúdo)
    const vr = await json(await post(`/api/org/clinical-records/${ids.rec}/verify`, users.au.token, {}));
    expect(vr.intact).toBe(true);
    const lg = await get(`/api/org/clinical-access-logs?patient_id=${ids.pat}`, users.au.token);
    const logs = (await json(lg)).items as any[];
    const acts = new Set(logs.map((l) => `${l.action}:${l.purpose}`));
    for (const a of ['create_draft:care', 'update_draft:care', 'finalize:care', 'addendum:care', 'view:care', 'view:emergency', 'list:emergency',
      'emergency_grant:emergency', 'emergency_review:audit', 'integrity_check:audit']) expect(acts.has(a), a).toBe(true);
    expect(logs.find((l) => l.action === 'view' && l.purpose === 'care')!.correlation_id).toBe(`e2e-clin-${tag}`);
    expect(logs.find((l) => l.action === 'view' && l.purpose === 'emergency')!.basis).toBe('emergency');
    expect(JSON.stringify(logs)).not.toContain(secret);
    expect((await get(`/api/org/clinical-access-logs`, users.d.token)).status).toBe(403);
    const { data: audRows } = await admin.from('audit_logs').select('*').eq('organization_id', A);
    expect(JSON.stringify(audRows)).not.toContain(secret);

    // contorno direto (PostgREST): nem o médico, nem o service_role, nem anon alcançam o conteúdo por tabela/RPC
    const direct = createClient(URL_!, ANON!, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${users.d.token}` } } });
    const t1 = await direct.from('clinical_records').select('id,body');
    expect(t1.error?.code).toBe('42501');
    expect((await direct.from('clinical_addenda').select('id')).error?.code).toBe('42501');
    expect((await direct.from('clinical_records').update({ body: 'x' }).eq('id', ids.rec)).error?.code).toBe('42501');
    expect((await admin.from('clinical_records').select('id')).error?.code).toBe('42501');
    const anon = createClient(URL_!, ANON!, { auth: { persistSession: false } });
    const ar = await anon.rpc('rpc_get_clinical_record', { p_org: A, p_record: ids.rec, p_purpose: 'care' });
    expect(ar.error).toBeTruthy();
    expect(ar.data).toBeNull();

    // cancelamento do agendamento revoga o vínculo; vínculo manual devolve e a revogação tira de novo
    expect((await post(`/api/org/events/${ids.ev2}/cancel`, users.a.token, { reason: 'Paciente desistiu' }, 'idem-1d-cancel')).status).toBe(200);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d.token)).status).toBe(403);
    expect((await get(`/api/org/patients/${ids.pat}`, users.d.token)).status).toBe(404);
    expect((await post(`/api/org/patients/${ids.pat}/care-relationships`, users.d.token, { professional_id: pd, reason: 'Equipe do caso' }, 'idem-1d-man0')).status).toBe(403);
    const man = await post(`/api/org/patients/${ids.pat}/care-relationships`, users.a.token, { professional_id: pd, reason: 'Acompanhamento continuado' }, 'idem-1d-man1');
    expect(man.status).toBe(201);
    const link = (await json(man)).id as string;
    expect((await post(`/api/org/patients/${ids.pat}/care-relationships`, users.a.token, { professional_id: pd, reason: 'Acompanhamento continuado' }, 'idem-1d-man2')).status).toBe(409);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d.token)).status).toBe(200);
    expect((await post(`/api/org/care-relationships/${link}/revoke`, users.a.token, { reason: 'fim do acompanhamento' })).status).toBe(200);
    expect((await get(`/api/org/clinical-records/${ids.rec}?purpose=care`, users.d.token)).status).toBe(403);
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
    const { data: ownerRole } = await admin.from('roles').select('id').eq('organization_id', users.a.org).eq('key', 'owner').single();
    const { data: asg } = await admin.from('user_role_assignments').select('id').eq('organization_id', users.a.org).eq('role_id', ownerRole!.id);
    expect(asg).toHaveLength(1);
    const { error } = await userClient.from('user_role_assignments').update({ revoked_at: new Date().toISOString() }).eq('id', asg![0]!.id);
    expect(error?.code).toBe('CF409');
  });
});
