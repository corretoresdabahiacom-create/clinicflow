-- 1D / migration 10: vínculo assistencial, prontuário (sintético), adendos, acesso de emergência e log de acesso a dados clínicos.
-- Regras (docs/CLINICAL_DATA_GOVERNANCE.md): rascunho -> finalizado; finalizado é imutável; correção só por adendo;
-- leitura/escrita clínica somente por RPC, com vínculo ativo (ou acesso de emergência) + finalidade declarada + registro.
-- Nenhuma permissão de tabela é concedida a anon/authenticated/service_role nas tabelas de conteúdo clínico.

-- ---------------------------------------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------------------------------------
insert into public.permissions (key, description) values
  ('care.read', 'Ver vínculos assistenciais (quem pode acessar qual paciente)'),
  ('care.assign', 'Criar e revogar vínculos assistenciais manuais'),
  ('clinical.read', 'Ler prontuário de pacientes com vínculo assistencial ativo'),
  ('clinical.write', 'Registrar rascunhos, finalizar e adendar prontuário de pacientes com vínculo ativo'),
  ('clinical.emergency', 'Solicitar acesso de emergência (justificado, temporário e auditado)'),
  ('clinical.audit', 'Ver o log de acesso a dados clínicos, revisar acessos de emergência e verificar integridade (sem ler conteúdo)');

-- Papéis de sistema (definição única). Proprietário/administrador NÃO leem conteúdo clínico (minimização): auditam acessos.
-- Médico/enfermeiro não têm care.read: enxergam apenas os próprios vínculos (política care_select).
create or replace function app.system_role_permissions() returns table (role_key text, role_name text, perms text[])
language sql immutable set search_path = '' as $$
  select * from (values
    ('owner', 'Proprietário', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','role.manage','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write','care.read','care.assign','clinical.audit']),
    ('admin', 'Administrador geral', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write','care.read','care.assign']),
    ('unit_manager', 'Gerente de unidade', array['unit.read','unit.write','member.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write','care.read','care.assign']),
    ('receptionist', 'Recepcionista', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write']),
    ('doctor', 'Médico', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read',
       'clinical.read','clinical.write','clinical.emergency']),
    ('nurse', 'Enfermeiro', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read',
       'clinical.read','clinical.write','clinical.emergency']),
    ('exam_tech', 'Técnico de exames', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('finance', 'Financeiro', array['org.read','unit.read','professional.read','resource.read','service.read']),
    ('auditor', 'Auditor/compliance', array['org.read','unit.read','member.read','role.read','audit.read','professional.read','resource.read','service.read','agenda.read',
       'care.read','clinical.audit'])
  ) as t(role_key, role_name, perms);
$$;

insert into public.role_permissions (organization_id, role_id, permission_key)
select r.organization_id, r.id, p
from public.roles r
join app.system_role_permissions() s on s.role_key = r.key
cross join lateral unnest(s.perms) as p
where r.is_system
on conflict do nothing;

-- ---------------------------------------------------------------------------------------------------------
-- Vínculo assistencial
-- ---------------------------------------------------------------------------------------------------------
create table public.care_relationships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  patient_id uuid not null,
  professional_id uuid not null,
  source text not null check (source in ('appointment','manual')),
  event_id uuid,
  reason text check (reason is null or length(trim(reason)) between 5 and 300),
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text check (revoke_reason is null or length(trim(revoke_reason)) between 3 and 300),
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((source = 'appointment') = (event_id is not null)),
  check (source <> 'manual' or reason is not null),
  check (valid_to is null or valid_to > valid_from),
  check ((revoked_at is null) = (revoke_reason is null)),
  unique (organization_id, id),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id),
  foreign key (organization_id, event_id) references public.scheduling_events (organization_id, id)
);
create unique index care_rel_appointment_uq on public.care_relationships (organization_id, event_id, professional_id) where source = 'appointment';
create unique index care_rel_manual_active_uq on public.care_relationships (organization_id, patient_id, professional_id)
  where source = 'manual' and revoked_at is null;
create index care_rel_lookup_idx on public.care_relationships (organization_id, professional_id, patient_id);

-- ---------------------------------------------------------------------------------------------------------
-- Prontuário: registros (rascunho -> finalizado) e adendos
-- ---------------------------------------------------------------------------------------------------------
create table public.clinical_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  patient_id uuid not null,
  professional_id uuid not null,
  event_id uuid,
  kind text not null check (kind in ('anamnesis','evolution','conduct')),
  title text not null check (length(trim(title)) between 2 and 200),
  body text not null check (length(trim(body)) between 1 and 20000),
  status text not null default 'draft' check (status in ('draft','finalized')),
  content_hash text check (content_hash ~ '^[0-9a-f]{64}$'),
  finalized_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'finalized') = (content_hash is not null and finalized_at is not null)),
  unique (organization_id, id),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id),
  foreign key (organization_id, event_id) references public.scheduling_events (organization_id, id)
);
create index clinical_records_patient_idx on public.clinical_records (organization_id, patient_id, created_at desc);

create table public.clinical_addenda (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  record_id uuid not null,
  seq integer not null check (seq >= 1),
  professional_id uuid not null,
  reason text not null check (length(trim(reason)) between 3 and 300),
  body text not null check (length(trim(body)) between 1 and 10000),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (record_id, seq),
  foreign key (organization_id, record_id) references public.clinical_records (organization_id, id),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id)
);

-- ---------------------------------------------------------------------------------------------------------
-- Acesso de emergência (break-glass): temporário, justificado, revisado depois
-- ---------------------------------------------------------------------------------------------------------
create table public.emergency_access_grants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  patient_id uuid not null,
  professional_id uuid not null,
  justification text not null check (length(trim(justification)) between 20 and 1000),
  granted_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_by uuid not null,
  reviewed_at timestamptz,
  reviewed_by uuid,
  review_outcome text check (review_outcome in ('justified','not_justified')),
  review_note text check (review_note is null or length(review_note) <= 500),
  check (expires_at > granted_at and expires_at <= granted_at + interval '12 hours'),
  check ((reviewed_at is null) = (review_outcome is null) and (reviewed_at is null) = (reviewed_by is null)),
  unique (organization_id, id),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id)
);
create index emergency_grants_lookup_idx on public.emergency_access_grants (organization_id, professional_id, patient_id, expires_at);

-- ---------------------------------------------------------------------------------------------------------
-- Log de acesso a dados clínicos (append-only). Só acessos efetivados; negações ficam no audit_logs (Worker).
-- Nunca contém conteúdo clínico.
-- ---------------------------------------------------------------------------------------------------------
create table public.data_access_logs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  organization_id uuid not null references public.organizations(id),
  patient_id uuid not null,
  actor_id uuid,
  professional_id uuid,
  action text not null check (action in ('list','view','create_draft','update_draft','finalize','addendum',
                                         'emergency_grant','emergency_review','care_assign','care_revoke','integrity_check')),
  resource_type text not null check (resource_type in ('clinical_record','patient','emergency_grant','care_relationship')),
  resource_id text,
  purpose text not null check (purpose in ('care','emergency','audit','administration')),
  basis text not null check (basis in ('relationship','emergency','audit_role','administrative_role')),
  relationship_id uuid,
  grant_id uuid,
  correlation_id text check (correlation_id is null or length(correlation_id) <= 100),
  ip inet,
  user_agent text check (user_agent is null or length(user_agent) <= 300),
  foreign key (organization_id, patient_id) references public.patients (organization_id, id)
);
create index data_access_logs_patient_idx on public.data_access_logs (organization_id, patient_id, id desc);
create index data_access_logs_actor_idx on public.data_access_logs (organization_id, actor_id, id desc);

-- ---------------------------------------------------------------------------------------------------------
-- Guardas de integridade
-- ---------------------------------------------------------------------------------------------------------
create trigger data_access_logs_immutable before update or delete on public.data_access_logs for each row execute function app.forbid_mutation();
create trigger clinical_addenda_immutable before update or delete on public.clinical_addenda for each row execute function app.forbid_mutation();
create trigger clinical_records_no_delete before delete on public.clinical_records for each row execute function app.forbid_mutation();
create trigger care_relationships_no_delete before delete on public.care_relationships for each row execute function app.forbid_mutation();
create trigger emergency_grants_no_delete before delete on public.emergency_access_grants for each row execute function app.forbid_mutation();

create function app.clinical_content_hash(p_title text, p_body text) returns text
language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(p_title || E'\n' || p_body, 'UTF8')), 'hex');
$$;

-- Registro finalizado é imutável. Rascunho: só título/corpo mudam, e a única transição é para finalizado com hash correto.
create function app.guard_clinical_record() returns trigger language plpgsql set search_path = '' as $$
begin
  if old.status = 'finalized' then
    raise exception 'finalized clinical record is immutable; use an addendum' using errcode = '42501';
  end if;
  if new.organization_id <> old.organization_id or new.patient_id <> old.patient_id or new.professional_id <> old.professional_id
     or new.event_id is distinct from old.event_id or new.kind <> old.kind or new.created_by <> old.created_by
     or new.created_at <> old.created_at then
    raise exception 'clinical record identity is immutable' using errcode = '42501';
  end if;
  if new.status = 'finalized' then
    if new.content_hash is distinct from app.clinical_content_hash(new.title, new.body) then
      raise exception 'content hash mismatch' using errcode = '23514';
    end if;
  elsif new.content_hash is not null or new.finalized_at is not null then
    raise exception 'draft cannot carry finalization data' using errcode = '23514';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger clinical_records_guard before update on public.clinical_records for each row execute function app.guard_clinical_record();

-- Adendo só em registro finalizado
create function app.guard_clinical_addendum() returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.clinical_records r where r.organization_id = new.organization_id and r.id = new.record_id and r.status = 'finalized') then
    raise exception 'addendum requires a finalized record' using errcode = 'CF409';
  end if;
  return new;
end $$;
create trigger clinical_addenda_guard before insert on public.clinical_addenda for each row execute function app.guard_clinical_addendum();

-- Vínculo: só a revogação muda (uma vez)
create function app.guard_care_relationship() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id <> old.organization_id or new.patient_id <> old.patient_id or new.professional_id <> old.professional_id
     or new.source <> old.source or new.event_id is distinct from old.event_id or new.reason is distinct from old.reason
     or new.valid_from <> old.valid_from or new.valid_to is distinct from old.valid_to or new.created_by is distinct from old.created_by then
    raise exception 'care relationship is immutable except for revocation' using errcode = '42501';
  end if;
  if old.revoked_at is not null and (new.revoked_at is distinct from old.revoked_at or new.revoke_reason is distinct from old.revoke_reason) then
    raise exception 'care relationship already revoked' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger care_relationships_guard before update on public.care_relationships for each row execute function app.guard_care_relationship();

-- Acesso de emergência: só a revisão muda (uma vez)
create function app.guard_emergency_grant() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id <> old.organization_id or new.patient_id <> old.patient_id or new.professional_id <> old.professional_id
     or new.justification <> old.justification or new.granted_at <> old.granted_at or new.expires_at <> old.expires_at
     or new.created_by <> old.created_by then
    raise exception 'emergency grant is immutable except for review' using errcode = '42501';
  end if;
  if old.reviewed_at is not null then
    raise exception 'emergency grant already reviewed' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger emergency_grants_guard before update on public.emergency_access_grants for each row execute function app.guard_emergency_grant();

-- ---------------------------------------------------------------------------------------------------------
-- Vínculo automático pelo agendamento: profissional alocado + paciente no evento => vínculo até 30 dias após o fim.
-- Cancelamento do evento revoga o vínculo gerado por ele (remarcação = cancela + agenda de novo).
-- ---------------------------------------------------------------------------------------------------------
create function app.sync_appointment_links(p_org uuid, p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.care_relationships (organization_id, patient_id, professional_id, source, event_id, valid_to)
  select e.organization_id, e.patient_id, a.resource_id, 'appointment', e.id, greatest(e.ends_at + interval '30 days', now() + interval '1 day')
  from public.scheduling_events e
  join public.resource_allocations a on a.organization_id = e.organization_id and a.event_id = e.id
       and a.resource_type = 'professional' and a.status = 'active'
  where e.organization_id = p_org and e.id = p_event and e.kind = 'appointment' and e.status = 'scheduled' and e.patient_id is not null
  on conflict (organization_id, event_id, professional_id) where source = 'appointment' do nothing;
end $$;

create function app.trg_alloc_care_link() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app.sync_appointment_links(new.organization_id, new.event_id);
  return null;
end $$;
create trigger resource_allocations_care_link after insert on public.resource_allocations
  for each row when (new.resource_type = 'professional') execute function app.trg_alloc_care_link();

create function app.trg_event_patient_care_link() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app.sync_appointment_links(new.organization_id, new.id);
  return null;
end $$;
create trigger scheduling_events_care_link after update of patient_id on public.scheduling_events
  for each row when (old.patient_id is null and new.patient_id is not null) execute function app.trg_event_patient_care_link();

create function app.trg_event_cancel_care_revoke() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.care_relationships
     set revoked_at = now(), revoke_reason = 'appointment_cancelled'
   where organization_id = new.organization_id and event_id = new.id and revoked_at is null;
  return null;
end $$;
create trigger scheduling_events_care_revoke after update of status on public.scheduling_events
  for each row when (new.status = 'cancelled' and old.status <> 'cancelled') execute function app.trg_event_cancel_care_revoke();

-- Auditoria transacional (nomes de colunas apenas) de vínculos e acessos de emergência
create trigger care_relationships_audit after insert or update on public.care_relationships
  for each row execute function app.audit_row('care.link', 'care.link_change', 'care_relationship', 'id', '', '');
create trigger emergency_grants_audit after insert or update on public.emergency_access_grants
  for each row execute function app.audit_row('clinical.emergency_access', 'clinical.emergency_review', 'emergency_grant', 'id', '', '');

-- ---------------------------------------------------------------------------------------------------------
-- RLS: conteúdo clínico NÃO é acessível por tabela. Vínculos, emergências e log têm leitura restrita.
-- ---------------------------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['care_relationships','clinical_records','clinical_addenda','emergency_access_grants','data_access_logs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on public.clinical_records, public.clinical_addenda from service_role;
