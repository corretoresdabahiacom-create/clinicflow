-- 1C / migration 8: permissões, RLS, guardas e RPCs de pacientes e recepção
insert into public.permissions (key, description) values
  ('patient.read', 'Ver cadastro administrativo de pacientes'),
  ('patient.write', 'Cadastrar e editar pacientes, consentimentos, responsáveis e vínculos de conta'),
  ('checkin.write', 'Registrar chegada (check-in) do paciente');

-- Papéis de sistema (definição única). Médico/enfermeiro/técnico NÃO recebem patient.read ainda:
-- acesso por vínculo assistencial só existe a partir da 1D.
create or replace function app.system_role_permissions() returns table (role_key text, role_name text, perms text[])
language sql immutable set search_path = '' as $$
  select * from (values
    ('owner', 'Proprietário', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','role.manage','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write']),
    ('admin', 'Administrador geral', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write']),
    ('unit_manager', 'Gerente de unidade', array['unit.read','unit.write','member.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write']),
    ('receptionist', 'Recepcionista', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read','agenda.write',
       'patient.read','patient.write','checkin.write']),
    ('doctor', 'Médico', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('nurse', 'Enfermeiro', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('exam_tech', 'Técnico de exames', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('finance', 'Financeiro', array['org.read','unit.read','professional.read','resource.read','service.read']),
    ('auditor', 'Auditor/compliance', array['org.read','unit.read','member.read','role.read','audit.read','professional.read','resource.read','service.read','agenda.read'])
  ) as t(role_key, role_name, perms);
$$;

insert into public.role_permissions (organization_id, role_id, permission_key)
select r.organization_id, r.id, p
from public.roles r
join app.system_role_permissions() s on s.role_key = r.key
cross join lateral unnest(s.perms) as p
where r.is_system
on conflict do nothing;

-- Acesso do próprio titular (conta vinculada) ou de responsável ativo ao paciente
create function app.patient_self_access(p_org uuid, p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organizations o where o.id = p_org and o.status = 'active')
    and exists (
      select 1 from public.patient_identity_links l
      where l.organization_id = p_org and l.user_id = (select auth.uid()) and l.revoked_at is null
        and (l.patient_id = p_patient or exists (
          select 1 from public.patient_guardianships g
          where g.organization_id = p_org and g.guardian_patient_id = l.patient_id and g.dependent_patient_id = p_patient
            and g.revoked_at is null and g.valid_from <= now() and (g.valid_to is null or g.valid_to > now())))
    );
$$;

create trigger patients_touch before update on public.patients for each row execute function app.touch_updated_at();
create trigger patient_consents_immutable before update or delete on public.patient_consents for each row execute function app.forbid_mutation();
create trigger patient_checkins_immutable before update or delete on public.patient_checkins for each row execute function app.forbid_mutation();

create function app.guard_patient() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.birth_date > current_date then
    raise exception 'birth_date in the future' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger patients_guard before insert or update on public.patients for each row execute function app.guard_patient();

create function app.guard_guardianship() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id <> old.organization_id or new.guardian_patient_id <> old.guardian_patient_id
     or new.dependent_patient_id <> old.dependent_patient_id or new.relationship <> old.relationship
     or new.valid_from <> old.valid_from or new.created_by is distinct from old.created_by then
    raise exception 'guardianship is immutable except for validity/revocation' using errcode = '42501';
  end if;
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'guardianship already revoked' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger patient_guardianships_guard before update on public.patient_guardianships for each row execute function app.guard_guardianship();
create trigger patient_guardianships_no_delete before delete on public.patient_guardianships for each row execute function app.forbid_mutation();
create trigger patient_links_no_delete before delete on public.patient_identity_links for each row execute function app.forbid_mutation();

-- Evento: patient_id só pode ir de nulo para um paciente (nunca trocar nem remover)
create or replace function app.guard_event_update() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id <> old.organization_id or new.unit_id <> old.unit_id or new.kind <> old.kind
     or new.service_id is distinct from old.service_id or new.starts_at <> old.starts_at or new.ends_at <> old.ends_at
     or new.rescheduled_from is distinct from old.rescheduled_from
     or (new.patient_id is distinct from old.patient_id and old.patient_id is not null) then
    raise exception 'scheduling event is immutable except for cancellation and first patient assignment' using errcode = '42501';
  end if;
  if old.status = 'cancelled' and new.status <> 'cancelled' then
    raise exception 'cancelled event cannot be reopened' using errcode = '42501';
  end if;
  return new;
end $$;

-- RLS
do $$ declare t text; begin
  foreach t in array array['patients','patient_consents','patient_guardianships','patient_identity_links','patient_checkins'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- Pacientes são entidades da organização: permissão em qualquer escopo (recepção por unidade também cadastra)
create policy patients_select on public.patients for select to authenticated
  using (app.has_perm_any(organization_id, 'patient.read') or app.patient_self_access(organization_id, id));
create policy patients_insert on public.patients for insert to authenticated with check (app.has_perm_any(organization_id, 'patient.write'));
create policy patients_update on public.patients for update to authenticated
  using (app.has_perm_any(organization_id, 'patient.write')) with check (app.has_perm_any(organization_id, 'patient.write'));
grant select, insert (organization_id, full_name, social_name, birth_date, cpf_hash, cpf_masked, phone, email) on public.patients to authenticated;
grant update (full_name, social_name, birth_date, cpf_hash, cpf_masked, phone, email, status) on public.patients to authenticated;

create policy consents_select on public.patient_consents for select to authenticated
  using (app.has_perm_any(organization_id, 'patient.read') or app.patient_self_access(organization_id, patient_id));
create policy consents_insert on public.patient_consents for insert to authenticated
  with check (app.has_perm_any(organization_id, 'patient.write') and recorded_by = (select auth.uid()));
grant select, insert (organization_id, patient_id, purpose, granted, source) on public.patient_consents to authenticated;

create policy guardian_select on public.patient_guardianships for select to authenticated
  using (app.has_perm_any(organization_id, 'patient.read') or app.patient_self_access(organization_id, guardian_patient_id));
create policy guardian_insert on public.patient_guardianships for insert to authenticated with check (app.has_perm_any(organization_id, 'patient.write'));
create policy guardian_update on public.patient_guardianships for update to authenticated
  using (app.has_perm_any(organization_id, 'patient.write')) with check (app.has_perm_any(organization_id, 'patient.write'));
grant select, insert (organization_id, guardian_patient_id, dependent_patient_id, relationship, valid_to) on public.patient_guardianships to authenticated;
grant update (valid_to, revoked_at) on public.patient_guardianships to authenticated;

create policy links_select on public.patient_identity_links for select to authenticated
  using (app.has_perm_any(organization_id, 'patient.read') or user_id = (select auth.uid()));
grant select on public.patient_identity_links to authenticated;   -- escrita somente via RPC

create policy checkins_select on public.patient_checkins for select to authenticated
  using (app.has_perm(organization_id, 'agenda.read', unit_id));
grant select on public.patient_checkins to authenticated;          -- escrita somente via RPC

-- RPC: agendar consulta já com paciente (atômico)
create function public.rpc_book_event_for_patient(
  p_org uuid, p_unit uuid, p_service uuid, p_starts timestamptz, p_ends timestamptz, p_resources jsonb, p_patient uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not app.has_perm_any(p_org, 'patient.read') then raise exception 'permission denied' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients where id = p_patient and organization_id = p_org and status = 'active') then
    raise exception 'patient not found' using errcode = 'CF404';
  end if;
  v := public.rpc_book_event(p_org, p_unit, 'appointment', p_service, p_starts, p_ends, p_resources, null, null);
  update public.scheduling_events set patient_id = p_patient where id = v;
  return v;
end $$;

-- RPC: remarcar preservando o paciente
create or replace function public.rpc_reschedule_event(p_org uuid, p_event uuid, p_starts timestamptz, p_ends timestamptz default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare e record; v_res jsonb; v_ends timestamptz; v_new uuid;
begin
  select * into e from public.scheduling_events where id = p_event and organization_id = p_org for update;
  if not found or not app.is_member(p_org) then raise exception 'event not found' using errcode = 'CF404'; end if;
  if not app.has_perm(p_org, 'agenda.write', e.unit_id) then raise exception 'permission denied' using errcode = '42501'; end if;
  if e.status <> 'scheduled' then raise exception 'event is not scheduled' using errcode = 'CF409'; end if;
  select jsonb_agg(jsonb_build_object('type', resource_type, 'id', resource_id)) into v_res
    from public.resource_allocations where organization_id = p_org and event_id = p_event and status = 'active';
  v_ends := coalesce(p_ends, p_starts + (e.ends_at - e.starts_at));
  perform public.rpc_cancel_event(p_org, p_event, 'rescheduled', 'agenda.reschedule_release');
  v_new := public.rpc_book_event(p_org, e.unit_id, e.kind, e.service_id, p_starts, v_ends, v_res, e.title, p_event);
  if e.patient_id is not null then
    update public.scheduling_events set patient_id = e.patient_id where id = v_new;
  end if;
  return v_new;
end $$;

-- RPC: check-in (janela: 3h antes do início até o fim; uma vez por agendamento)
create function public.rpc_check_in(p_org uuid, p_event uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare e record; v uuid;
begin
  select * into e from public.scheduling_events where id = p_event and organization_id = p_org for update;
  if not found or not app.is_member(p_org) then raise exception 'event not found' using errcode = 'CF404'; end if;
  if not app.has_perm(p_org, 'checkin.write', e.unit_id) then raise exception 'permission denied' using errcode = '42501'; end if;
  if e.kind <> 'appointment' or e.status <> 'scheduled' then raise exception 'event cannot be checked in' using errcode = 'CF409'; end if;
  if e.patient_id is null then raise exception 'event has no patient' using errcode = 'CF422'; end if;
  if now() < e.starts_at - interval '3 hours' or now() > e.ends_at then
    raise exception 'outside check-in window' using errcode = 'CF422';
  end if;
  begin
    insert into public.patient_checkins (organization_id, unit_id, event_id, patient_id, checked_in_by)
      values (p_org, e.unit_id, p_event, e.patient_id, (select auth.uid())) returning id into v;
  exception when unique_violation then
    raise exception 'already checked in' using errcode = 'CF409';
  end;
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, e.unit_id, (select auth.uid()), 'checkin.create', 'scheduling_event', p_event::text, 'success');
  return v;
end $$;

-- RPC: vincular conta de usuário a paciente (confirmação presencial pela recepção) e revogar
create function public.rpc_link_patient_account(p_org uuid, p_patient uuid, p_user uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not app.has_perm_any(p_org, 'patient.write') then raise exception 'permission denied' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients where id = p_patient and organization_id = p_org and status = 'active') then
    raise exception 'patient not found' using errcode = 'CF404';
  end if;
  begin
    insert into public.patient_identity_links (organization_id, patient_id, user_id, verified_by)
      values (p_org, p_patient, p_user, (select auth.uid())) returning id into v;
  exception
    when unique_violation then raise exception 'already linked' using errcode = 'CF409';
    when foreign_key_violation then raise exception 'invalid user' using errcode = 'CF422';
  end;
  insert into public.audit_logs (organization_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, (select auth.uid()), 'patient.link_account', 'patient', p_patient::text, 'success');
  return v;
end $$;

create function public.rpc_revoke_patient_link(p_org uuid, p_link uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_patient uuid;
begin
  if not app.has_perm_any(p_org, 'patient.write') then raise exception 'permission denied' using errcode = '42501'; end if;
  update public.patient_identity_links set revoked_at = now()
    where id = p_link and organization_id = p_org and revoked_at is null returning patient_id into v_patient;
  if not found then raise exception 'link not found' using errcode = 'CF404'; end if;
  insert into public.audit_logs (organization_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, (select auth.uid()), 'patient.revoke_link', 'patient', v_patient::text, 'success');
end $$;

-- Grants (funções novas nunca para PUBLIC/anon)
revoke execute on all functions in schema app from public, anon;
grant execute on function app.patient_self_access(uuid, uuid) to authenticated, service_role;
revoke execute on function public.rpc_book_event_for_patient(uuid, uuid, uuid, timestamptz, timestamptz, jsonb, uuid) from public, anon;
revoke execute on function public.rpc_check_in(uuid, uuid) from public, anon;
revoke execute on function public.rpc_link_patient_account(uuid, uuid, uuid) from public, anon;
revoke execute on function public.rpc_revoke_patient_link(uuid, uuid) from public, anon;
revoke execute on function public.rpc_reschedule_event(uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.rpc_book_event_for_patient(uuid, uuid, uuid, timestamptz, timestamptz, jsonb, uuid) to authenticated, service_role;
grant execute on function public.rpc_check_in(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_link_patient_account(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_revoke_patient_link(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_reschedule_event(uuid, uuid, timestamptz, timestamptz) to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
