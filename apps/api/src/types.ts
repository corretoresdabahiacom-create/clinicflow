import type { Repo } from './repo';

export type Bindings = {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string; // chave publicável (pública por desenho)
  SUPABASE_SERVICE_ROLE_KEY?: string; // segredo; só rate limit/provisionamento (ADR-003)
  APP_ENV: string;
  EXPECTED_PROJECT_REF: string;
  CPF_HMAC_KEY?: string; // segredo (>= 32 caracteres) para o HMAC do CPF; nunca no repositório
  CPF_HMAC_KEY_VERSION?: string; // inteiro 1..32767 da chave atual (gravado em patients.cpf_key_version)
  ALLOWED_ORIGIN?: string; // apenas para desenvolvimento local
};

export type OrgContext = {
  organization_id: string;
  organization_name: string;
  organization_status: string;
  member_id: string;
  permissions: string[];
  unit_scopes: { unit_id: string; permissions: string[] }[];
};

export type RateLimiter = {
  hit(bucket: string, windowSeconds: number, max: number): Promise<boolean>;
};

/** Contexto da requisição repassado ao PostgREST para a auditoria transacional (sem PII). */
export type RequestMeta = { correlationId: string; ip: string | null; userAgent: string | null };

export type Deps = {
  verifyToken(env: Bindings, jwt: string): Promise<{ userId: string } | null>;
  makeRepo(env: Bindings, jwt: string, meta?: RequestMeta): Repo;
  makeRateLimiter?(env: Bindings): RateLimiter | null;
};

export type Variables = {
  requestId: string;
  jwt: string;
  userId: string;
  repo: Repo;
  org?: OrgContext;
};
