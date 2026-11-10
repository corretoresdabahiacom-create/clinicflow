import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { HttpError } from './errors';
import type { AuditEntry, AuditRow, BookInput, CatalogTable, Consent, Guardianship, PatientQuery, IdemRecord, Org, Repo, Row, SchedEvent, Unit } from './repo';
import type { Bindings, Deps, OrgContext, RateLimiter } from './types';

const ORG_COLS = 'id,name,legal_name,cnpj,timezone,status,created_at,updated_at';
const UNIT_COLS = 'id,name,timezone,status,created_at,updated_at';
const AUDIT_COLS = 'id,at,organization_id,unit_id,actor_id,action,resource_type,resource_id,result,correlation_id';
const COLS: Record<CatalogTable, string> = {
  professionals: 'id,member_id,full_name,council,council_number,council_uf,specialty,status,created_at,updated_at',
  rooms: 'id,unit_id,name,capacity,status,created_at,updated_at',
  equipment: 'id,unit_id,name,status,created_at,updated_at',
  patients: 'id,full_name,social_name,birth_date,cpf_masked,phone,email,status,created_at,updated_at',
  services: 'id,name,kind,duration_minutes,buffer_before_minutes,buffer_after_minutes,status,created_at,updated_at',
};
const EVENT_COLS = 'id,organization_id,unit_id,kind,service_id,patient_id,status,starts_at,ends_at,title,rescheduled_from,cancel_reason,created_at';

/** Traduz erros do banco (códigos próprios das RPCs e SQLSTATE padrão) em erros HTTP sem vazar detalhes internos. */
function dbFail(error: { code?: string }): never {
  switch (error.code) {
    case 'CF409': case '23505': case '23P01': throw new HttpError(409, 'Conflict');
    case 'CF404': throw new HttpError(404, 'Not found');
    case 'CF422': case '23514': case '23503': case '22023': case '22P02': case '22007': case '22008': throw new HttpError(422, 'Invalid request');
    case '42501': throw new HttpError(403, 'Forbidden');
    default: throw error;
  }
}
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
  async listCatalog(table: CatalogTable, orgId: string, unitId?: string): Promise<Row[]> {
    let q = this.db.from(table).select(COLS[table]).eq('organization_id', orgId).order('created_at').limit(500);
    if (unitId && (table === 'rooms' || table === 'equipment')) q = q.eq('unit_id', unitId);
    const { data, error } = await q;
    if (error) dbFail(error);
    return (data ?? []) as unknown as Row[];
  }
  async createCatalog(table: CatalogTable, orgId: string, input: Row): Promise<Row> {
    const { data, error } = await this.db.from(table).insert({ organization_id: orgId, ...input }).select(COLS[table]).single();
    if (error) dbFail(error);
    return data as unknown as Row;
  }
  async updateCatalog(table: CatalogTable, orgId: string, id: string, patch: Row): Promise<Row | null> {
    const { data, error } = await this.db.from(table).update(patch).eq('organization_id', orgId).eq('id', id).select(COLS[table]).maybeSingle();
    if (error) dbFail(error);
    return data as unknown as Row | null;
  }
  async linkProfessionalUnit(orgId: string, professionalId: string, unitId: string): Promise<void> {
    const { error } = await this.db.from('professional_units').insert({ organization_id: orgId, professional_id: professionalId, unit_id: unitId });
    if (error) dbFail(error);
  }
  async addServiceRequirement(orgId: string, serviceId: string, resourceType: string): Promise<void> {
    const { error } = await this.db.from('service_resource_requirements').insert({ organization_id: orgId, service_id: serviceId, resource_type: resourceType });
    if (error) dbFail(error);
  }
  async listEvents(orgId: string, q: { unitId?: string; from: string; to: string; limit: number }): Promise<SchedEvent[]> {
    let b = this.db.from('scheduling_events').select(EVENT_COLS).eq('organization_id', orgId)
      .lt('starts_at', q.to).gt('ends_at', q.from).order('starts_at').limit(q.limit);
    if (q.unitId) b = b.eq('unit_id', q.unitId);
    const { data, error } = await b;
    if (error) dbFail(error);
    return (data ?? []) as unknown as SchedEvent[];
  }
  private async eventById(orgId: string, id: string): Promise<SchedEvent> {
    const { data, error } = await this.db.from('scheduling_events').select(EVENT_COLS).eq('organization_id', orgId).eq('id', id).single();
    if (error) dbFail(error);
    return data as unknown as SchedEvent;
  }
  async bookEvent(orgId: string, i: BookInput): Promise<SchedEvent> {
    const { data, error } = await this.db.rpc('rpc_book_event', {
      p_org: orgId, p_unit: i.unitId, p_kind: i.kind, p_service: i.serviceId, p_starts: i.startsAt, p_ends: i.endsAt,
      p_resources: i.resources, p_title: i.title,
    });
    if (error) dbFail(error);
    return this.eventById(orgId, data as string);
  }
  async cancelEvent(orgId: string, id: string, reason: string): Promise<void> {
    const { error } = await this.db.rpc('rpc_cancel_event', { p_org: orgId, p_event: id, p_reason: reason });
    if (error) dbFail(error);
  }
  async rescheduleEvent(orgId: string, id: string, startsAt: string, endsAt: string | null): Promise<SchedEvent> {
    const { data, error } = await this.db.rpc('rpc_reschedule_event', { p_org: orgId, p_event: id, p_starts: startsAt, p_ends: endsAt });
    if (error) dbFail(error);
    return this.eventById(orgId, data as string);
  }
  async listPatients(orgId: string, q: PatientQuery): Promise<Row[]> {
    let b = this.db.from('patients').select(COLS.patients).eq('organization_id', orgId);
    if (q.q) b = b.ilike('full_name', `${q.q.replace(/[\\%_]/g, (m) => '\\' + m)}%`);
    if (q.cpfHash) b = b.eq('cpf_hash', q.cpfHash);
    if (q.birthDate) b = b.eq('birth_date', q.birthDate);
    const { data, error } = await b.order('full_name').order('id').range(q.offset, q.offset + q.limit - 1);
    if (error) dbFail(error);
    return (data ?? []) as unknown as Row[];
  }
  async getPatient(orgId: string, id: string): Promise<Row | null> {
    const { data, error } = await this.db.from('patients').select(COLS.patients).eq('organization_id', orgId).eq('id', id).maybeSingle();
    if (error) dbFail(error);
    return data as unknown as Row | null;
  }
  async listConsents(orgId: string, patientId: string): Promise<Consent[]> {
    const { data, error } = await this.db.from('patient_consents').select('id,patient_id,purpose,granted,source,recorded_at')
      .eq('organization_id', orgId).eq('patient_id', patientId).order('recorded_at', { ascending: false }).limit(200);
    if (error) dbFail(error);
    return (data ?? []) as Consent[];
  }
  async addConsent(orgId: string, patientId: string, i: { purpose: string; granted: boolean; source: string }): Promise<Consent> {
    const { data, error } = await this.db.from('patient_consents').insert({ organization_id: orgId, patient_id: patientId, ...i })
      .select('id,patient_id,purpose,granted,source,recorded_at').single();
    if (error) dbFail(error);
    return data as Consent;
  }
  async listGuardianships(orgId: string, patientId: string): Promise<Guardianship[]> {
    const { data, error } = await this.db.from('patient_guardianships')
      .select('id,guardian_patient_id,dependent_patient_id,relationship,valid_from,valid_to,revoked_at')
      .eq('organization_id', orgId).or(`guardian_patient_id.eq.${patientId},dependent_patient_id.eq.${patientId}`).limit(200);
    if (error) dbFail(error);
    return (data ?? []) as Guardianship[];
  }
  async addGuardianship(orgId: string, i: { guardianId: string; dependentId: string; relationship: string; validTo: string | null }): Promise<Guardianship> {
    const { data, error } = await this.db.from('patient_guardianships').insert({
      organization_id: orgId, guardian_patient_id: i.guardianId, dependent_patient_id: i.dependentId, relationship: i.relationship, valid_to: i.validTo,
    }).select('id,guardian_patient_id,dependent_patient_id,relationship,valid_from,valid_to,revoked_at').single();
    if (error) dbFail(error);
    return data as Guardianship;
  }
  async revokeGuardianship(orgId: string, id: string): Promise<boolean> {
    const { data, error } = await this.db.from('patient_guardianships').update({ revoked_at: new Date().toISOString() })
      .eq('organization_id', orgId).eq('id', id).is('revoked_at', null).select('id');
    if (error) dbFail(error);
    return (data ?? []).length === 1;
  }
  async linkPatientAccount(orgId: string, patientId: string, userId: string): Promise<string> {
    const { data, error } = await this.db.rpc('rpc_link_patient_account', { p_org: orgId, p_patient: patientId, p_user: userId });
    if (error) dbFail(error);
    return data as string;
  }
  async revokePatientLink(orgId: string, linkId: string): Promise<void> {
    const { error } = await this.db.rpc('rpc_revoke_patient_link', { p_org: orgId, p_link: linkId });
    if (error) dbFail(error);
  }
  async bookEventForPatient(orgId: string, patientId: string, i: BookInput): Promise<SchedEvent> {
    const { data, error } = await this.db.rpc('rpc_book_event_for_patient', {
      p_org: orgId, p_unit: i.unitId, p_service: i.serviceId, p_starts: i.startsAt, p_ends: i.endsAt, p_resources: i.resources, p_patient: patientId,
    });
    if (error) dbFail(error);
    return this.eventById(orgId, data as string);
  }
  async checkIn(orgId: string, eventId: string): Promise<string> {
    const { data, error } = await this.db.rpc('rpc_check_in', { p_org: orgId, p_event: eventId });
    if (error) dbFail(error);
    return data as string;
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
