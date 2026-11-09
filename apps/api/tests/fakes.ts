import type { AuditEntry, IdemRecord, Repo, Unit } from '../src/repo';
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

export const OWNER = ['org.read', 'org.manage', 'unit.read', 'unit.write', 'member.read', 'member.manage', 'role.read', 'role.manage', 'audit.read'];
export const RECEPTION = ['org.read', 'unit.read'];

export type World = {
  units: Unit[]; audits: AuditEntry[]; calls: string[]; idem: Map<string, IdemRecord & { key: string }>; failNextCreate: boolean;
};

export function makeDeps(opts: { limiter?: RateLimiter | null } = {}) {
  const users: Record<string, { userId: string; contexts: OrgContext[] }> = {
    'tok-owner': { userId: 'u-owner', contexts: [ctx(ORG_A, OWNER)] },
    'tok-recep': { userId: 'u-recep', contexts: [ctx(ORG_A, RECEPTION)] },
    'tok-unit': { userId: 'u-unit', contexts: [ctx(ORG_A, [], [{ unit_id: UNIT_1, permissions: ['unit.read', 'unit.write'] }])] },
    'tok-other': { userId: 'u-other', contexts: [ctx(ORG_B, OWNER)] },
    'tok-susp': { userId: 'u-susp', contexts: [ctx(ORG_A, OWNER, [], 'suspended')] },
    'tok-none': { userId: 'u-none', contexts: [] },
  };
  const world: World = {
    units: [
      { id: UNIT_1, name: 'Unidade 1', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
      { id: UNIT_2, name: 'Unidade 2', timezone: 'America/Sao_Paulo', status: 'active', created_at: 't', updated_at: 't' },
    ],
    audits: [], calls: [], idem: new Map(), failNextCreate: false,
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
