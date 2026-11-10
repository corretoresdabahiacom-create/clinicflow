-- 1C / migration 7: pacientes, consentimentos, responsáveis, vínculo de conta e check-in
-- Dados pessoais mínimos (sem endereço/RG/prontuário). Somente dados sintéticos até o Gate de Produção.

-- CPF NÃO é armazenado em claro: somente HMAC-SHA256 (chave no Worker, fora do banco) + máscara para exibição.
-- A validação dos dígitos do CPF é feita na API (o banco nunca vê o número).
create table public.patients (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  full_name text not null check (length(trim(full_name)) between 2 and 200),
  social_name text check (social_name is null or length(trim(social_name)) between 2 and 200),
  birth_date date not null check (birth_date >= date '1900-01-01'),
  cpf_hash text check (cpf_hash is null or cpf_hash ~ '^[0-9a-f]{64}$'),
  cpf_masked text check (cpf_masked is null or cpf_masked ~ '^\*\*\*\.\*\*\*\.\*\*\*-[0-9]{2}$'),
  phone text check (phone is null or phone ~ '^[0-9]{10,13}$'),
  email text check (email is null or (length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((cpf_hash is null) = (cpf_masked is null)),
  unique (organization_id, id)
);
create unique index patients_cpf_uq on public.patients (organization_id, cpf_hash) where cpf_hash is not null;
create index patients_name_idx on public.patients (organization_id, lower(full_name) text_pattern_ops);
create index patients_birth_idx on public.patients (organization_id, birth_date);

create table public.patient_consents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  patient_id uuid not null,
  purpose text not null check (purpose in ('care_data','communication','data_sharing','research')),
  granted boolean not null,
  source text not null check (source in ('in_person','portal','phone')),
  recorded_by uuid not null default auth.uid(),
  recorded_at timestamptz not null default now(),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id)
);
create index patient_consents_idx on public.patient_consents (organization_id, patient_id, purpose, recorded_at desc);

create table public.patient_guardianships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  guardian_patient_id uuid not null,
  dependent_patient_id uuid not null,
  relationship text not null check (relationship in ('parent','legal_guardian','curator','other')),
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  revoked_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (guardian_patient_id <> dependent_patient_id),
  check (valid_to is null or valid_to > valid_from),
  foreign key (organization_id, guardian_patient_id) references public.patients (organization_id, id),
  foreign key (organization_id, dependent_patient_id) references public.patients (organization_id, id)
);
create unique index patient_guardianship_active_uq on public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id)
  where revoked_at is null;
create index patient_guardianship_dep_idx on public.patient_guardianships (organization_id, dependent_patient_id);

create table public.patient_identity_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  patient_id uuid not null,
  user_id uuid not null references auth.users(id),
  verified_by uuid not null,
  verified_at timestamptz not null default now(),
  revoked_at timestamptz,
  foreign key (organization_id, patient_id) references public.patients (organization_id, id)
);
create unique index patient_link_user_uq on public.patient_identity_links (organization_id, user_id) where revoked_at is null;
create unique index patient_link_patient_uq on public.patient_identity_links (organization_id, patient_id) where revoked_at is null;

alter table public.scheduling_events
  add constraint scheduling_events_patient_fk foreign key (organization_id, patient_id) references public.patients (organization_id, id);

create table public.patient_checkins (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  unit_id uuid not null,
  event_id uuid not null,
  patient_id uuid not null,
  checked_in_at timestamptz not null default now(),
  checked_in_by uuid not null,
  foreign key (organization_id, event_id) references public.scheduling_events (organization_id, id),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id),
  foreign key (organization_id, unit_id) references public.units (organization_id, id),
  unique (organization_id, event_id)
);
