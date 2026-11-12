import { HttpError } from '../src/errors';
import type { AuditEntry, BookInput, PortalAppointment, Consent, Guardianship, IdemRecord, Repo, Row, SchedEvent, Unit } from '../src/repo';
import type { Bindings, Deps, OrgContext, RateLimiter } from '../src/types';

export const ORG_A = '11111111-1111-4111-8111-111111111111';
export const ORG_B = '22222222-2222-4222-8222-222222222222';
export const UNIT_1 = '33333333-3333-4333-8333-333333333331';
export const UNIT_2 = '33333333-3333-4333-8333-333333333332';

export const env: Bindings = {
  SUPABASE_URL: 'https://abcdefghij.supabase.co',
  SUPABASE_ANON_KEY: 'anon',
  APP_ENV: 'hml',
  EXPECTED_PROJECT_REF: 'abcdefghij',
  CPF_HMAC_KEY: 'test-only-key-0123456789-0123456789-abcdef',
};

const ctx = (org: string, permissions: string[], unit_scopes: OrgContext['unit_scopes'] = [], status = 'active'): OrgContext => ({
  organization_id: org, organization_name: `Org ${org.slice(0, 4)}`, organization_status: status, member_id: 'm-' + org.slice(0, 4),
  permissions, unit_scopes,
});

export const OWNER = ['org.read', 'org.manage', 'unit.read', 'unit.write', 'member.read', 'member.manage', 'role.read', 'role.manage', 'audit.read',
  'professional.read', 'professional.write', 'resource.read', 'resource.write', 'service.read', 'service.write', 'agenda.read', 'agenda.write',
  'patient.read', 'patient.write', 'checkin.write'];
export const FRONTDESK = ['org.read', 'unit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read', 'agenda.write', 'patient.read', 'patient.write', 'checkin.write'];
export const READONLY_AGENDA = ['org.read', 'unit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read'];
export const DOCTOR = ['org.read', 'unit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read', 'clinical.read', 'clinical.write', 'clinical.emergency'];
export const AUDITOR = ['org.read', 'unit.read', 'member.read', 'role.read', 'audit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read', 'care.read', 'clinical.audit'];
export const CARE_ADMIN = ['org.read', 'unit.read', 'patient.read', 'care.read', 'care.assign'];
export const PAT_A = '77777777-7777-4777-8777-777777777771';
export const PAT_DEP = '77777777-7777-4777-8777-777777777772';
export const PAT_OTHER = '77777777-7777-4777-8777-777777777773';
export const EV_PAT = '88888888-8888-4888-8888-888888888881';
export const EV_OTHER = '88888888-8888-4888-8888-888888888882';
export const RECEPTION = ['org.read', 'unit.read'];

export type PortalWorld = { appts: (PortalAppointment & { patient: string })[]; calls: { fn: string; args: unknown[] }[]; turnstile: string[] };
export type World = {
  portal: PortalWorld;
  units: Unit[]; events: SchedEvent[]; consents: Consent[]; guardians: Guardianship[]; links: { id: string; patient: string; user: string; revoked: boolean }[]; checkins: Set<string>; busy: { res: string; from: number; to: number; ev: string }[]; catalog: Record<string, Row[]>; audits: AuditEntry[]; calls: string[]; metas: { correlationId: string; ip: string | null; userAgent: string | null }[]; idem: Map<string, IdemRecord & { key: string; lockedAt: number }>; failNextCreate: boolean; clinicalError: HttpError | null; clinicalArgs: { fn: string; args: unknown[] }[];
};

export function makeDeps(opts: { limiter?: RateLimiter | null; turnstile?: (token: string) => boolean } = {}) {
  const users: Record<string, { userId: string; contexts: OrgContext[] }> = {
    'tok-owner': { userId: 'u-owner', contexts: [ctx(ORG_A, OWNER)] },
    'tok-recep': { userId: 'u-recep', contexts: [ctx(ORG_A, RECEPTION)] },
    'tok-unit': { userId: 'u-unit', contexts: [ctx(ORG_A, [], [{ unit_id: UNIT_1, permissions: ['unit.read', 'unit.write'] }])] },
    'tok-front': { userId: 'u-front', contexts: [ctx(ORG_A, FRONTDESK)] },
    'tok-ro': { userId: 'u-ro', contexts: [ctx(ORG_A, READONLY_AGENDA)] },
    'tok-front1': { userId: 'u-front1', contexts: [ctx(ORG_A, ['org.read', 'unit.read'], [{ unit_id: UNIT_1, permissions: ['agenda.read', 'agenda.write', 'unit.read'] }])] },
    'tok-other': { userId: 'u-other', contexts: [ctx(ORG_B, OWNER)] },
    'tok-susp': { userId: 'u-susp', contexts: [ctx(ORG_A, OWNER, [], 'suspended')] },
    'tok-doctor': { userId: 'u-doctor', contexts: [ctx(ORG_A, DOCTOR)] },
    'tok-auditor': { userId: 'u-auditor', contexts: [ctx(ORG_A, AUDITOR)] },
    'tok-careadmin': { userId: 'u-careadmin', contexts: [ctx(ORG_A, CARE_ADMIN)] },
    'tok-none': { userId: 'u-none', contexts: [] },
    'tok-pat': { userId: 'u-pat', contexts: [] },
    'tok-pat2': { userId: 'u-pat2', contexts: [] },
  };
  const world: World = {
    units: [
      { id: UNIT_1, name: 'Unidade 1', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
      { id: UNIT_2, name: 'Unidade 2', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
    ],
    portal: { appts: [{ event_id: EV_PAT, patient: PAT_A, status: 'scheduled', starts_at: '2030-01-01T13:00:00Z', ends_at: '2030-01-01T13:30:00Z', unit_id: UNIT_1, unit_name: 'Unidade 1', service_id: 'sv', service_name: 'Consulta', professional_id: 'pr', professional_name: 'Dra. Sintetica', can_cancel: true },
      { event_id: EV_OTHER, patient: PAT_OTHER, status: 'scheduled', starts_at: '2030-01-02T13:00:00Z', ends_at: '2030-01-02T13:30:00Z', unit_id: UNIT_1, unit_name: 'Unidade 1', service_id: 'sv', service_name: 'Consulta', professional_id: 'pr', professional_name: 'Dra. Sintetica', can_cancel: true }], calls: [], turnstile: [] },
    events: [], consents: [], guardians: [], links: [], checkins: new Set(), busy: [], catalog: {}, audits: [], calls: [], metas: [], idem: new Map(), failNextCreate: false, clinicalError: null, clinicalArgs: [],
  };
  let seq = 100;

  const clin = <T>(fn: string, args: unknown[], ret: T): T => {
    world.calls.push(fn); world.clinicalArgs.push({ fn, args });
    if (world.clinicalError) throw world.clinicalError;
    return ret;
  };
  const repoFor = (token: string): Repo => {
    const u = users[token]!;
    return {
      async getContexts() { return u.contexts; },
      async getOrganization(id) { world.calls.push('getOrganization:' + id); return { id, name: 'Org', legal_name: null, cnpj: null, timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' }; },
      async updateOrganization(id, patch) { world.calls.push('updateOrganization:' + id); return { id, name: String(patch.name ?? 'Org'), legal_name: null, cnpj: null, timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' }; },
      async listUnits() { return world.units; },
      async createUnit(_o, input) {
        world.calls.push('createUnit');
        if (world.failNextCreate) { world.failNextCreate = false; throw new Error('db down'); }
        const unit: Unit = { id: `44444444-4444-4444-8444-${String(++seq).padStart(12, '0')}`, name: input.name, timezone: input.timezone ?? 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' };
        world.units.push(unit); return unit;
      },
      async updateUnit(_o, id, patch) { const x = world.units.find((r) => r.id === id); if (!x) return null; Object.assign(x, patch); return x; },
      async listCatalog(table, _o, unit) { return (world.catalog[table] ?? []).filter((r) => !unit || r.unit_id === unit); },
      async createCatalog(table, _o, input) {
        if (table === 'patients' && input.cpf_hash && (world.catalog.patients ?? []).some((p) => p.cpf_hash === input.cpf_hash)) throw new HttpError(409, 'Conflict');
        const row = { id: `55555555-5555-4555-8555-${String(++seq).padStart(12, '0')}`, status: 'active', ...input };
        (world.catalog[table] ??= []).push(row); return row;
      },
      async updateCatalog(table, _o, id, patch) { const r = (world.catalog[table] ?? []).find((x) => x.id === id); if (!r) return null; Object.assign(r, patch); return r; },
      async linkProfessionalUnit() { world.calls.push('linkProfessionalUnit'); },
      async addServiceRequirement() { world.calls.push('addServiceRequirement'); },
      async listEvents(_o, q) { return world.events.filter((e) => !q.unitId || e.unit_id === q.unitId); },
      async bookEvent(_o, i: BookInput) {
        world.calls.push('bookEvent');
        const from = Date.parse(i.startsAt), to = i.endsAt ? Date.parse(i.endsAt) : from + 30 * 60_000;
        for (const r of i.resources) if (world.busy.some((b) => b.res === r.id && from < b.to && to > b.from)) throw new HttpError(409, 'Conflict');
        const ev: SchedEvent = { id: `66666666-6666-4666-8666-${String(++seq).padStart(12, '0')}`, organization_id: ORG_A, unit_id: i.unitId, kind: i.kind,
          service_id: i.serviceId, patient_id: null, status: 'scheduled', starts_at: i.startsAt, ends_at: new Date(to).toISOString(), title: i.title, rescheduled_from: null, cancel_reason: null, created_at: 't' };
        world.events.push(ev); for (const r of i.resources) world.busy.push({ res: r.id, from, to, ev: ev.id }); return ev;
      },
      async cancelEvent(_o, id, reason) {
        world.calls.push('cancelEvent');
        const ev = world.events.find((e) => e.id === id); if (!ev) throw new HttpError(404, 'Not found');
        if (ev.status !== 'scheduled') throw new HttpError(409, 'Conflict');
        ev.status = 'cancelled'; ev.cancel_reason = reason; world.busy = world.busy.filter((b) => b.ev !== id);
      },
      async rescheduleEvent(_o, id, startsAt) {
        const ev = world.events.find((e) => e.id === id); if (!ev) throw new HttpError(404, 'Not found');
        if (ev.status !== 'scheduled') throw new HttpError(409, 'Conflict');
        const mine = world.busy.filter((b) => b.ev === id); const from = Date.parse(startsAt); const to = from + (Date.parse(ev.ends_at) - Date.parse(ev.starts_at));
        if (world.busy.some((b) => b.ev !== id && mine.some((m) => m.res === b.res) && from < b.to && to > b.from)) throw new HttpError(409, 'Conflict');
        ev.status = 'cancelled'; ev.cancel_reason = 'rescheduled'; world.busy = world.busy.filter((b) => b.ev !== id);
        const n: SchedEvent = { ...ev, id: `66666666-6666-4666-8666-${String(++seq).padStart(12, '0')}`, status: 'scheduled', cancel_reason: null, starts_at: startsAt, ends_at: new Date(to).toISOString(), rescheduled_from: id };
        world.events.push(n); for (const m of mine) world.busy.push({ res: m.res, from, to, ev: n.id }); return n;
      },
      async listPatients(_o, q) {
        return (world.catalog.patients ?? []).filter((p) => (!q.q || String(p.full_name).toLowerCase().startsWith(q.q.toLowerCase()))
          && (!q.cpfHash || p.cpf_hash === q.cpfHash) && (!q.birthDate || p.birth_date === q.birthDate))
          .map(({ cpf_hash: _h, ...r }) => r).slice(q.offset, q.offset + q.limit);
      },
      async getPatient(_o, id) { const p = (world.catalog.patients ?? []).find((x) => x.id === id); if (!p) return null; const { cpf_hash: _h, ...r } = p; return r; },
      async listConsents(_o, pid) { return world.consents.filter((c) => c.patient_id === pid); },
      async addConsent(_o, pid, i) { const c: Consent = { id: crypto.randomUUID(), patient_id: pid, recorded_at: 't', ...i }; world.consents.push(c); return c; },
      async listGuardianships(_o, pid) { return world.guardians.filter((g) => g.guardian_patient_id === pid || g.dependent_patient_id === pid); },
      async addGuardianship(_o, i) {
        if (i.guardianId === i.dependentId) throw new HttpError(422, 'Invalid request');
        const g: Guardianship = { id: crypto.randomUUID(), guardian_patient_id: i.guardianId, dependent_patient_id: i.dependentId, relationship: i.relationship, valid_from: 't', valid_to: i.validTo, revoked_at: null };
        world.guardians.push(g); return g;
      },
      async revokeGuardianship(_o, id) { const g = world.guardians.find((x) => x.id === id && !x.revoked_at); if (!g) return false; g.revoked_at = 't'; return true; },
      // ---- 1D (o fake só registra chamadas; vínculo/finalidade/imutabilidade são provados no banco e no E2E) ----
      async listCareRelationships(...a) { return clin('listCareRelationships', a, []); },
      async assignCare(...a) { return clin('assignCare', a, '55555555-5555-4555-8555-555555555501'); },
      async revokeCare(...a) { return clin('revokeCare', a, undefined); },
      async createClinicalRecord(...a) { return clin('createClinicalRecord', a, '55555555-5555-4555-8555-555555555502'); },
      async updateClinicalDraft(...a) { return clin('updateClinicalDraft', a, undefined); },
      async finalizeClinicalRecord(...a) { return clin('finalizeClinicalRecord', a, 'a'.repeat(64)); },
      async addClinicalAddendum(...a) { return clin('addClinicalAddendum', a, 1); },
      async listClinicalRecords(...a) { return clin('listClinicalRecords', a, []); },
      async getClinicalRecord(...a) { return clin('getClinicalRecord', a, { record: { id: 'r', body: 'x' }, addenda: [], integrity: 'ok' }); },
      async emergencyAccess(...a) { return clin('emergencyAccess', a, '55555555-5555-4555-8555-555555555503'); },
      async reviewEmergencyAccess(...a) { return clin('reviewEmergencyAccess', a, undefined); },
      async verifyClinicalRecord(...a) { return clin('verifyClinicalRecord', a, true); },
      async listEmergencyGrants(...a) { return clin('listEmergencyGrants', a, []); },
      async listAccessLogs(...a) { return clin('listAccessLogs', a, []); },
      async linkPatientAccount(_o, patient, user) {
        if (world.links.some((l) => !l.revoked && (l.patient === patient || l.user === user))) throw new HttpError(409, 'Conflict');
        const l = { id: crypto.randomUUID(), patient, user, revoked: false }; world.links.push(l); return l.id;
      },
      async revokePatientLink(_o, id) { const l = world.links.find((x) => x.id === id && !x.revoked); if (!l) throw new HttpError(404, 'Not found'); l.revoked = true; },
      async bookEventForPatient(o, patientId, i) {
        if (!(world.catalog.patients ?? []).some((p) => p.id === patientId && p.status === 'active')) throw new HttpError(404, 'Not found');
        const ev = await (repoFor(token).bookEvent(o, i)); ev.patient_id = patientId; return ev;
      },
      async checkIn(_o, id) {
        world.calls.push('checkIn');
        const ev = world.events.find((e) => e.id === id); if (!ev) throw new HttpError(404, 'Not found');
        if (ev.status !== 'scheduled' || world.checkins.has(id)) throw new HttpError(409, 'Conflict');
        if (!ev.patient_id) throw new HttpError(422, 'Invalid request');
        world.checkins.add(id); return crypto.randomUUID();
      },
      async listAudit() { return []; },
      async portalContext() {
        world.portal.calls.push({ fn: 'portalContext', args: [] });
        if (u.userId !== 'u-pat') return [];
        return [
          { organization_id: ORG_A, organization_name: 'Org A', patient_id: PAT_A, patient_name: 'Paciente A', relation: 'self' as const },
          { organization_id: ORG_A, organization_name: 'Org A', patient_id: PAT_DEP, patient_name: 'Dependente', relation: 'dependent' as const },
        ];
      },
      async portalCatalog(o) {
        world.portal.calls.push({ fn: 'portalCatalog', args: [o] });
        if (u.userId !== 'u-pat' || o !== ORG_A) throw new HttpError(404, 'Not found');
        return [{ unit_id: UNIT_1, unit_name: 'Unidade 1', service_id: 'sv', service_name: 'Consulta', duration_minutes: 30, professional_id: 'pr', professional_name: 'Dra. Sintetica', specialty: null }];
      },
      async portalSlots(o, q) {
        world.portal.calls.push({ fn: 'portalSlots', args: [o, q] });
        if (u.userId !== 'u-pat' || o !== ORG_A) throw new HttpError(404, 'Not found');
        return [{ starts_at: '2030-01-03T13:00:00Z', ends_at: '2030-01-03T13:30:00Z' }];
      },
      async portalAppointments(o, patient) {
        world.portal.calls.push({ fn: 'portalAppointments', args: [o, patient] });
        if (u.userId !== 'u-pat' || o !== ORG_A || (patient !== PAT_A && patient !== PAT_DEP)) throw new HttpError(404, 'Not found');
        return world.portal.appts.filter((a) => a.patient === patient).map(({ patient: _p, ...a }) => a);
      },
      async portalBook(o, patient, i) {
        world.portal.calls.push({ fn: 'portalBook', args: [o, patient, i] });
        if (u.userId !== 'u-pat' || o !== ORG_A || (patient !== PAT_A && patient !== PAT_DEP)) throw new HttpError(404, 'Not found');
        return EV_PAT;
      },
      async portalCancel(o, ev, reason) {
        world.portal.calls.push({ fn: 'portalCancel', args: [o, ev, reason] });
        const a = world.portal.appts.find((x) => x.event_id === ev);
        if (u.userId !== 'u-pat' || !a || (a.patient !== PAT_A && a.patient !== PAT_DEP)) throw new HttpError(404, 'Not found');
      },
      async portalReschedule(o, ev, startsAt) {
        world.portal.calls.push({ fn: 'portalReschedule', args: [o, ev, startsAt] });
        const a = world.portal.appts.find((x) => x.event_id === ev);
        if (u.userId !== 'u-pat' || !a || (a.patient !== PAT_A && a.patient !== PAT_DEP)) throw new HttpError(404, 'Not found');
        return EV_PAT;
      },
      async setAvailability(o, unit, prof, w) { world.portal.calls.push({ fn: 'setAvailability', args: [o, unit, prof, w] }); return w.length; },
      async setPortalSettings(o, s) { world.portal.calls.push({ fn: 'setPortalSettings', args: [o, s] }); },
      async writeAudit(e) { world.audits.push(e); },
      async idemBegin(p) {
        const k = `${p.orgId}|${p.scope}|${p.key}`;
        const ex = world.idem.get(k);
        if (ex) return { created: false, record: ex };
        const rec = { id: 'i' + ++seq, key: k, requestHash: p.hash, status: 'processing' as const, responseStatus: null, responseBody: null, lockedAt: Date.now() };
        world.idem.set(k, rec); return { created: true, id: rec.id };
      },
      async idemComplete(id, status, body) { for (const r of world.idem.values()) if (r.id === id) Object.assign(r, { status: 'completed', responseStatus: status, responseBody: body }); },
      async idemFail(id) { for (const r of world.idem.values()) if (r.id === id) r.status = 'failed'; },
      async idemRestart(id, staleBefore) { for (const r of world.idem.values()) if (r.id === id && (r.status === 'failed' || (r.status === 'processing' && r.lockedAt < Date.parse(staleBefore)))) { r.status = 'processing'; r.lockedAt = Date.now(); return true; } return false; },
    };
  };

  const deps: Deps = {
    async verifyToken(_e, jwt) { const u = users[jwt]; return u ? { userId: u.userId } : null; },
    makeRepo: (_e, jwt, meta) => { if (meta) world.metas.push(meta); return repoFor(jwt); },
    makeRateLimiter: () => opts.limiter ?? null,
    verifyTurnstile: async (_e, token) => { world.portal.turnstile.push(token); return (opts.turnstile ?? ((tk) => tk === 'ok-token'))(token); },
  };
  return { deps, world };
}
