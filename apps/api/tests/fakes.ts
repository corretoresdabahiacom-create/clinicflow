import { HttpError } from '../src/errors';
import type { AuditEntry, BookInput, IdemRecord, Repo, Row, SchedEvent, Unit } from '../src/repo';
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
};

const ctx = (org: string, permissions: string[], unit_scopes: OrgContext['unit_scopes'] = [], status = 'active'): OrgContext => ({
  organization_id: org, organization_name: `Org ${org.slice(0, 4)}`, organization_status: status, member_id: 'm-' + org.slice(0, 4),
  permissions, unit_scopes,
});

export const OWNER = ['org.read', 'org.manage', 'unit.read', 'unit.write', 'member.read', 'member.manage', 'role.read', 'role.manage', 'audit.read',
  'professional.read', 'professional.write', 'resource.read', 'resource.write', 'service.read', 'service.write', 'agenda.read', 'agenda.write'];
export const FRONTDESK = ['org.read', 'unit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read', 'agenda.write'];
export const READONLY_AGENDA = ['org.read', 'unit.read', 'professional.read', 'resource.read', 'service.read', 'agenda.read'];
export const RECEPTION = ['org.read', 'unit.read'];

export type World = {
  units: Unit[]; events: SchedEvent[]; busy: { res: string; from: number; to: number; ev: string }[]; catalog: Record<string, Row[]>; audits: AuditEntry[]; calls: string[]; idem: Map<string, IdemRecord & { key: string }>; failNextCreate: boolean;
};

export function makeDeps(opts: { limiter?: RateLimiter | null } = {}) {
  const users: Record<string, { userId: string; contexts: OrgContext[] }> = {
    'tok-owner': { userId: 'u-owner', contexts: [ctx(ORG_A, OWNER)] },
    'tok-recep': { userId: 'u-recep', contexts: [ctx(ORG_A, RECEPTION)] },
    'tok-unit': { userId: 'u-unit', contexts: [ctx(ORG_A, [], [{ unit_id: UNIT_1, permissions: ['unit.read', 'unit.write'] }])] },
    'tok-front': { userId: 'u-front', contexts: [ctx(ORG_A, FRONTDESK)] },
    'tok-ro': { userId: 'u-ro', contexts: [ctx(ORG_A, READONLY_AGENDA)] },
    'tok-front1': { userId: 'u-front1', contexts: [ctx(ORG_A, ['org.read', 'unit.read'], [{ unit_id: UNIT_1, permissions: ['agenda.read', 'agenda.write', 'unit.read'] }])] },
    'tok-other': { userId: 'u-other', contexts: [ctx(ORG_B, OWNER)] },
    'tok-susp': { userId: 'u-susp', contexts: [ctx(ORG_A, OWNER, [], 'suspended')] },
    'tok-none': { userId: 'u-none', contexts: [] },
  };
  const world: World = {
    units: [
      { id: UNIT_1, name: 'Unidade 1', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
      { id: UNIT_2, name: 'Unidade 2', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
    ],
    events: [], busy: [], catalog: {}, audits: [], calls: [], idem: new Map(), failNextCreate: false,
  };
  let seq = 100;

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
          service_id: i.serviceId, status: 'scheduled', starts_at: i.startsAt, ends_at: new Date(to).toISOString(), title: i.title, rescheduled_from: null, cancel_reason: null, created_at: 't' };
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
      async listAudit() { return []; },
      async writeAudit(e) { world.audits.push(e); },
      async idemBegin(p) {
        const k = `${p.orgId}|${p.scope}|${p.key}`;
        const ex = world.idem.get(k);
        if (ex) return { created: false, record: ex };
        const rec = { id: 'i' + ++seq, key: k, requestHash: p.hash, status: 'processing' as const, responseStatus: null, responseBody: null };
        world.idem.set(k, rec); return { created: true, id: rec.id };
      },
      async idemComplete(id, status, body) { for (const r of world.idem.values()) if (r.id === id) Object.assign(r, { status: 'completed', responseStatus: status, responseBody: body }); },
      async idemFail(id) { for (const r of world.idem.values()) if (r.id === id) r.status = 'failed'; },
      async idemRestart(id) { for (const r of world.idem.values()) if (r.id === id && r.status === 'failed') { r.status = 'processing'; return true; } return false; },
    };
  };

  const deps: Deps = {
    async verifyToken(_e, jwt) { const u = users[jwt]; return u ? { userId: u.userId } : null; },
    makeRepo: (_e, jwt) => repoFor(jwt),
    makeRateLimiter: () => opts.limiter ?? null,
  };
  return { deps, world };
}
