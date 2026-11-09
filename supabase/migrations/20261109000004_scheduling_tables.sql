-- 1B / migration 4: cadastros (profissionais, salas, equipamentos, serviços) e núcleo de agenda
-- Justificativa tabela a tabela em docs/DATABASE.md (seção Fase 1B).
create extension if not exists btree_gist with schema extensions;

create table public.professionals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  member_id uuid,
  full_name text not null check (length(trim(full_name)) between 2 and 200),
  council text check (council in ('CRM','COREN','CRF','CRP','CREFITO','CRN','OUTRO')),
  council_number text check (council_number ~ '^[0-9A-Za-z.-]{1,20}$'),
  council_uf text check (council_uf ~ '^[A-Z]{2}$'),
  specialty text check (specialty is null or length(trim(specialty)) between 2 and 120),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((council is null) = (council_number is null) and (council is null) = (council_uf is null)),
  unique (organization_id, id),
  foreign key (organization_id, member_id) references public.organization_members (organization_id, id)
);
create unique index professionals_member_uq on public.professionals (organization_id, member_id) where member_id is not null;

create table public.professional_units (
  organization_id uuid not null,
  professional_id uuid not null,
  unit_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (professional_id, unit_id),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id),
  foreign key (organization_id, unit_id) references public.units (organization_id, id)
);
create index professional_units_unit_idx on public.professional_units (organization_id, unit_id);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  unit_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 120),
  capacity int not null default 1 check (capacity >= 1),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, unit_id, name),
  foreign key (organization_id, unit_id) references public.units (organization_id, id)
);

create table public.equipment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  unit_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 120),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, unit_id, name),
  foreign key (organization_id, unit_id) references public.units (organization_id, id)
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (length(trim(name)) between 2 and 200),
  kind text not null check (kind in ('consultation','exam','procedure')),
  duration_minutes int not null check (duration_minutes between 5 and 720),
  buffer_before_minutes int not null default 0 check (buffer_before_minutes between 0 and 120),
  buffer_after_minutes int not null default 0 check (buffer_after_minutes between 0 and 120),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, name)
);

create table public.service_resource_requirements (
  organization_id uuid not null,
  service_id uuid not null,
  resource_type text not null check (resource_type in ('professional','room','equipment')),
  primary key (service_id, resource_type),
  foreign key (organization_id, service_id) references public.services (organization_id, id)
);

create table public.scheduling_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  unit_id uuid not null,
  kind text not null check (kind in ('appointment','block','maintenance')),
  service_id uuid,
  status text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  title text check (title is null or length(trim(title)) between 2 and 200),
  patient_id uuid,  -- FK para pacientes será criada na 1C; sem dado de paciente nesta fase
  rescheduled_from uuid,
  cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 300),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at and ends_at - starts_at <= interval '12 hours'),
  check (kind = 'appointment' or service_id is null),
  check (kind = 'appointment' or title is not null),
  check ((status = 'cancelled') = (cancel_reason is not null)),
  unique (organization_id, id),
  foreign key (organization_id, unit_id) references public.units (organization_id, id),
  foreign key (organization_id, service_id) references public.services (organization_id, id),
  foreign key (organization_id, rescheduled_from) references public.scheduling_events (organization_id, id)
);
create index sched_events_unit_time_idx on public.scheduling_events (organization_id, unit_id, starts_at);

create table public.resource_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  resource_type text not null check (resource_type in ('professional','room','equipment')),
  resource_id uuid not null,
  period tstzrange not null check (not isempty(period) and lower_inc(period) and not upper_inc(period)
                                   and lower(period) is not null and upper(period) is not null),
  status text not null default 'active' check (status in ('active','released')),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  foreign key (organization_id, event_id) references public.scheduling_events (organization_id, id),
  constraint resource_no_overlap exclude using gist (
    organization_id with =, resource_type with =, resource_id with =, period with &&
  ) where (status = 'active')
);
create index resource_alloc_event_idx on public.resource_allocations (organization_id, event_id);

create table public.appointment_status_history (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  event_id uuid not null,
  from_status text,
  to_status text not null,
  reason text,
  changed_by uuid,
  at timestamptz not null default now(),
  foreign key (organization_id, event_id) references public.scheduling_events (organization_id, id)
);
create index appt_hist_event_idx on public.appointment_status_history (organization_id, event_id, at);
