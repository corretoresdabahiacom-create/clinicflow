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

/** Acesso a dados sempre com o JWT do usuário (RLS aplicada). */
export interface Repo {
  getContexts(): Promise<OrgContext[]>;
  getOrganization(orgId: string): Promise<Org | null>;
  updateOrganization(orgId: string, patch: Record<string, unknown>): Promise<Org | null>;
  listUnits(orgId: string): Promise<Unit[]>;
  createUnit(orgId: string, input: { name: string; timezone?: string }): Promise<Unit>;
  updateUnit(orgId: string, id: string, patch: Record<string, unknown>): Promise<Unit | null>;
  listAudit(orgId: string, limit: number, before?: number): Promise<AuditRow[]>;
  writeAudit(entry: AuditEntry): Promise<void>;
  idemBegin(p: { orgId: string; userId: string; scope: string; key: string; hash: string }):
    Promise<{ created: true; id: string } | { created: false; record: IdemRecord | null }>;
  idemComplete(id: string, status: number, body: unknown): Promise<void>;
  idemFail(id: string): Promise<void>;
  /** Retorna true somente se a chave estava 'failed' e foi reaberta (evita execução dupla). */
  idemRestart(id: string): Promise<boolean>;
}
