import type { OrgContext } from './types';

export type Org = {
  id: string; name: string; legal_name: string | null; cnpj: string | null;
  timezone: string; status: string; created_at: string; updated_at: string;
};
export type Unit = {
  id: string; name: string; timezone: string; status: string; created_at: string; updated_at: string;
};
export type AuditRow = {
  id: number; at: string; organization_id: string; unit_id: string | null; actor_id: string | null;
  action: string; resource_type: string | null; resource_id: string | null; result: string;
  correlation_id: string | null;
};
export type AuditEntry = {
  organizationId: string; unitId?: string | null; action: string; resourceType: string; resourceId: string;
  result: 'success' | 'denied' | 'error'; ip?: string | null; userAgent?: string | null;
  correlationId: string; metadata?: Record<string, unknown>;
};
export type IdemRecord = {
  id: string; requestHash: string; status: 'processing' | 'completed' | 'failed';
  responseStatus: number | null; responseBody: unknown;
};

export type CatalogTable = 'professionals' | 'rooms' | 'equipment' | 'services' | 'patients';
export type Row = Record<string, unknown>;
export type SchedEvent = {
  id: string; organization_id: string; unit_id: string; kind: string; service_id: string | null; patient_id: string | null; status: string;
  starts_at: string; ends_at: string; title: string | null; rescheduled_from: string | null; cancel_reason: string | null;
  created_at: string;
};
export type BookInput = {
  unitId: string; kind: 'appointment' | 'block' | 'maintenance'; serviceId: string | null; startsAt: string; endsAt: string | null;
  resources: { type: 'professional' | 'room' | 'equipment'; id: string }[]; title: string | null;
};

export type PatientQuery = { q?: string; cpfHash?: string; birthDate?: string; limit: number; offset: number };
export type Consent = { id: string; patient_id: string; purpose: string; granted: boolean; source: string; recorded_at: string };
export type Guardianship = {
  id: string; guardian_patient_id: string; dependent_patient_id: string; relationship: string;
  valid_from: string; valid_to: string | null; revoked_at: string | null;
};

/** Acesso a dados sempre com o JWT do usuário (RLS aplicada). */
export interface Repo {
  getContexts(): Promise<OrgContext[]>;
  getOrganization(orgId: string): Promise<Org | null>;
  updateOrganization(orgId: string, patch: Record<string, unknown>): Promise<Org | null>;
  listUnits(orgId: string): Promise<Unit[]>;
  createUnit(orgId: string, input: { name: string; timezone?: string }): Promise<Unit>;
  updateUnit(orgId: string, id: string, patch: Record<string, unknown>): Promise<Unit | null>;
  listCatalog(table: CatalogTable, orgId: string, unitId?: string): Promise<Row[]>;
  createCatalog(table: CatalogTable, orgId: string, input: Row): Promise<Row>;
  updateCatalog(table: CatalogTable, orgId: string, id: string, patch: Row): Promise<Row | null>;
  linkProfessionalUnit(orgId: string, professionalId: string, unitId: string): Promise<void>;
  addServiceRequirement(orgId: string, serviceId: string, resourceType: string): Promise<void>;
  listEvents(orgId: string, q: { unitId?: string; from: string; to: string; limit: number }): Promise<SchedEvent[]>;
  bookEvent(orgId: string, input: BookInput): Promise<SchedEvent>;
  cancelEvent(orgId: string, id: string, reason: string): Promise<void>;
  rescheduleEvent(orgId: string, id: string, startsAt: string, endsAt: string | null): Promise<SchedEvent>;
  listPatients(orgId: string, q: PatientQuery): Promise<Row[]>;
  getPatient(orgId: string, id: string): Promise<Row | null>;
  listConsents(orgId: string, patientId: string): Promise<Consent[]>;
  addConsent(orgId: string, patientId: string, input: { purpose: string; granted: boolean; source: string }): Promise<Consent>;
  listGuardianships(orgId: string, patientId: string): Promise<Guardianship[]>;
  addGuardianship(orgId: string, input: { guardianId: string; dependentId: string; relationship: string; validTo: string | null }): Promise<Guardianship>;
  revokeGuardianship(orgId: string, id: string): Promise<boolean>;
  linkPatientAccount(orgId: string, patientId: string, userId: string): Promise<string>;
  revokePatientLink(orgId: string, linkId: string): Promise<void>;
  bookEventForPatient(orgId: string, patientId: string, input: BookInput): Promise<SchedEvent>;
  checkIn(orgId: string, eventId: string): Promise<string>;
  listAudit(orgId: string, limit: number, before?: number): Promise<AuditRow[]>;
  writeAudit(entry: AuditEntry): Promise<void>;
  idemBegin(p: { orgId: string; userId: string; scope: string; key: string; hash: string }):
    Promise<{ created: true; id: string } | { created: false; record: IdemRecord | null }>;
  idemComplete(id: string, status: number, body: unknown): Promise<void>;
  idemFail(id: string): Promise<void>;
  /** Retorna true somente se a chave estava 'failed', ou 'processing' travada desde antes de staleBefore (ISO), e foi reaberta. */
  idemRestart(id: string, staleBefore: string): Promise<boolean>;
}
