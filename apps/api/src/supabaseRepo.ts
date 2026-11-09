import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { AuditEntry, AuditRow, IdemRecord, Org, Repo, Unit } from './repo';
import type { Bindings, Deps, OrgContext, RateLimiter } from './types';

const ORG_COLS = 'id,name,legal_name,cnpj,timezone,status,created_at,updated_at';
const UNIT_COLS = 'id,name,timezone,status,created_at,updated_at';
const AUDIT_COLS = 'id,at,organization_id,unit_id,actor_id,action,resource_type,resource_id,result,correlation_id';
const opts = { auth: { persistSession: false, autoRefreshToken: false } } as const;

function userClient(env: Bindings, jwt: string): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { ...opts, global: { headers: { Authorization: `Bearer ${jwt}` } } });
}

export class SupabaseRepo implements Repo {
  constructor(private db: SupabaseClient) {}

  async getContexts(): Promise<OrgContext[]> {
    const { data, error } = await this.db.rpc('rpc_my_context');
    if (error) throw error;
    return (data ?? []) as OrgContext[];
  }
  async getOrganization(orgId: string): Promise<Org | null> {
    const { data, error } = await this.db.from('organizations').select(ORG_COLS).eq('id', orgId).maybeSingle();
    if (error) throw error;
    return data as Org | null;
  }
  async updateOrganization(orgId: string, patch: Record<string, unknown>): Promise<Org | null> {
    const { data, error } = await this.db.from('organizations').update(patch).eq('id', orgId).select(ORG_COLS).maybeSingle();
    if (error) throw error;
    return data as Org | null;
  }
  async listUnits(orgId: string): Promise<Unit[]> {
    const { data, error } = await this.db.from('units').select(UNIT_COLS).eq('organization_id', orgId).order('name');
    if (error) throw error;
    return (data ?? []) as Unit[];
  }
  async createUnit(orgId: string, input: { name: string; timezone?: string }): Promise<Unit> {
    const { data, error } = await this.db.from('units').insert({ organization_id: orgId, ...input }).select(UNIT_COLS).single();
    if (error) throw error;
    return data as Unit;
  }
  async updateUnit(orgId: string, id: string, patch: Record<string, unknown>): Promise<Unit | null> {
    const { data, error } = await this.db.from('units').update(patch).eq('organization_id', orgId).eq('id', id).select(UNIT_COLS).maybeSingle();
    if (error) throw error;
    return data as Unit | null;
  }
  async listAudit(orgId: string, limit: number, before?: number): Promise<AuditRow[]> {
    let q = this.db.from('audit_logs').select(AUDIT_COLS).eq('organization_id', orgId).order('id', { ascending: false }).limit(limit);
    if (before) q = q.lt('id', before);
    const { data, error } = await q;
    if (error) throw error;
    return (data ?? []) as AuditRow[];
  }
  async writeAudit(e: AuditEntry): Promise<void> {
    const { error } = await this.db.rpc('rpc_write_audit', {
      p_org: e.organizationId, p_unit: e.unitId ?? null, p_action: e.action, p_resource_type: e.resourceType,
      p_resource_id: e.resourceId, p_result: e.result, p_ip: e.ip ?? '', p_user_agent: e.userAgent ?? null,
      p_correlation_id: e.correlationId, p_metadata: e.metadata ?? {},
    });
    if (error) throw error;
  }
  async idemBegin(p: { orgId: string; userId: string; scope: string; key: string; hash: string }) {
    const { data, error } = await this.db.from('idempotency_keys')
      .insert({ organization_id: p.orgId, user_id: p.userId, scope: p.scope, key: p.key, request_hash: p.hash })
      .select('id').single();
    if (!error) return { created: true as const, id: (data as { id: string }).id };
    if (error.code !== '23505') throw error;
    const { data: ex, error: e2 } = await this.db.from('idempotency_keys')
      .select('id,request_hash,status,response_status,response_body')
      .eq('organization_id', p.orgId).eq('scope', p.scope).eq('key', p.key).maybeSingle();
    if (e2) throw e2;
    const r = ex as { id: string; request_hash: string; status: IdemRecord['status']; response_status: number | null; response_body: unknown } | null;
    return {
      created: false as const,
      record: r ? { id: r.id, requestHash: r.request_hash, status: r.status, responseStatus: r.response_status, responseBody: r.response_body } : null,
    };
  }
  async idemComplete(id: string, status: number, body: unknown): Promise<void> {
    const { error } = await this.db.from('idempotency_keys').update({ status: 'completed', response_status: status, response_body: body }).eq('id', id);
    if (error) throw error;
  }
  async idemFail(id: string): Promise<void> {
    const { error } = await this.db.from('idempotency_keys').update({ status: 'failed' }).eq('id', id);
    if (error) throw error;
  }
  async idemRestart(id: string): Promise<boolean> {
    const { data, error } = await this.db.from('idempotency_keys').update({ status: 'processing' }).eq('id', id).eq('status', 'failed').select('id');
    if (error) throw error;
    return (data ?? []).length === 1;
  }
}

export const realDeps: Deps = {
  async verifyToken(env, jwt) {
    const { data, error } = await createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, opts).auth.getUser(jwt);
    if (error || !data.user) return null;
    return { userId: data.user.id };
  },
  makeRepo: (env, jwt) => new SupabaseRepo(userClient(env, jwt)),
  makeRateLimiter(env): RateLimiter | null {
    if (!env.SUPABASE_SERVICE_ROLE_KEY) return null; // uso excepcional e restrito de service_role (ADR-003/006)
    const svc = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, opts);
    return {
      async hit(bucket, windowSeconds, max) {
        const { data, error } = await svc.rpc('rpc_rate_limit_hit', { p_bucket: bucket, p_window_seconds: windowSeconds, p_max: max });
        if (error) throw error;
        return data === true;
      },
    };
  },
};
