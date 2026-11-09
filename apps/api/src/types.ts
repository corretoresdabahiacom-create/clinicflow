import type { Repo } from './repo';

export type Bindings = {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string; // chave publicável (pública por desenho)
  SUPABASE_SERVICE_ROLE_KEY?: string; // segredo; só rate limit/provisionamento (ADR-003)
  APP_ENV: string;
  EXPECTED_PROJECT_REF: string;
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

export type Deps = {
  verifyToken(env: Bindings, jwt: string): Promise<{ userId: string } | null>;
  makeRepo(env: Bindings, jwt: string): Repo;
  makeRateLimiter?(env: Bindings): RateLimiter | null;
};

export type Variables = {
  requestId: string;
  jwt: string;
  userId: string;
  repo: Repo;
  org?: OrgContext;
};
