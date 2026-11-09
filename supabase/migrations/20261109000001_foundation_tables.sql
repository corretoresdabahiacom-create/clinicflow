-- 1A / migration 1: tabelas da fundação (multi-tenancy, RBAC, auditoria, infra)
create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 200),
  legal_name text,
  cnpj text check (cnpj is null or cnpj ~ '^[0-9]{14}$'),
  timezone text not null default 'America/Sao_Paulo',
  status text not null default 'active' check (status in ('active','suspended','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (length(trim(name)) between 2 and 200),
  timezone text not null default 'America/Sao_Paulo',
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index units_org_idx on public.units (organization_id);

create table public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id),
  status text not null default 'active' check (status in ('active','suspended','revoked')),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id),
  unique (organization_id, id)
);
create index org_members_user_idx on public.organization_members (user_id);

create table public.permissions (
  key text primary key check (key ~ '^[a-z_]+(\.[a-z_]+)+$'),
  description text not null
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  key text not null check (key ~ '^[a-z_]+$'),
  name text not null,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, key)
);

create table public.role_permissions (
  organization_id uuid not null,
  role_id uuid not null,
  permission_key text not null references public.permissions(key),
  primary key (role_id, permission_key),
  foreign key (organization_id, role_id) references public.roles (organization_id, id)
);

create table public.user_role_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  member_id uuid not null,
  role_id uuid not null,
  unit_id uuid,
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  revoked_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  foreign key (organization_id, member_id) references public.organization_members (organization_id, id),
  foreign key (organization_id, role_id) references public.roles (organization_id, id),
  foreign key (organization_id, unit_id) references public.units (organization_id, id)
);
create index ura_member_idx on public.user_role_assignments (member_id);
create index ura_org_role_idx on public.user_role_assignments (organization_id, role_id);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  organization_id uuid not null references public.organizations(id),
  unit_id uuid,
  actor_id uuid,
  action text not null,
  resource_type text,
  resource_id text,
  result text not null check (result in ('success','denied','error')),
  ip inet,
  user_agent text,
  correlation_id text,
  metadata jsonb not null default '{}'::jsonb check (pg_column_size(metadata) < 8192),
  foreign key (organization_id, unit_id) references public.units (organization_id, id)
);
create index audit_org_at_idx on public.audit_logs (organization_id, at desc);

create table public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  organization_id uuid references public.organizations(id),
  enabled boolean not null default false,
  description text
);
create unique index feature_flags_key_scope_uq
  on public.feature_flags (key, coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table public.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null,
  scope text not null,
  key text not null,
  request_hash text not null,
  status text not null default 'processing' check (status in ('processing','completed','failed')),
  response_status int,
  response_body jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  unique (organization_id, scope, key)
);
create index idem_expires_idx on public.idempotency_keys (expires_at);

create table public.rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (bucket, window_start)
);
