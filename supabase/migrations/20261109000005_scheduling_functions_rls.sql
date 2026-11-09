-- 1B / migration 5: permissões, RLS, guardas e RPCs transacionais da agenda

-- Catálogo
insert into public.permissions (key, description) values
  ('professional.read', 'Ver profissionais'),
  ('professional.write', 'Cadastrar e editar profissionais'),
  ('resource.read', 'Ver salas e equipamentos'),
  ('resource.write', 'Cadastrar e editar salas e equipamentos'),
  ('service.read', 'Ver serviços'),
  ('service.write', 'Cadastrar e editar serviços'),
  ('agenda.read', 'Ver agenda'),
  ('agenda.write', 'Agendar, remarcar, cancelar e bloquear');

-- Papéis de sistema: definição única usada no provisionamento e no backfill
create function app.system_role_permissions() returns table (role_key text, role_name text, perms text[])
language sql immutable set search_path = '' as $$
  select * from (values
    ('owner', 'Proprietário', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','role.manage','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write']),
    ('admin', 'Administrador geral', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','audit.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write']),
    ('unit_manager', 'Gerente de unidade', array['unit.read','unit.write','member.read',
       'professional.read','professional.write','resource.read','resource.write','service.read','service.write','agenda.read','agenda.write']),
    ('receptionist', 'Recepcionista', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read','agenda.write']),
    ('doctor', 'Médico', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('nurse', 'Enfermeiro', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('exam_tech', 'Técnico de exames', array['org.read','unit.read','professional.read','resource.read','service.read','agenda.read']),
    ('finance', 'Financeiro', array['org.read','unit.read','professional.read','resource.read','service.read']),
    ('auditor', 'Auditor/compliance', array['org.read','unit.read','member.read','role.read','audit.read','professional.read','resource.read','service.read','agenda.read'])
  ) as t(role_key, role_name, perms);
$$;

-- Backfill das organizações existentes (migration roda sem JWT de usuário: guardas permitem)
insert into public.role_permissions (organization_id, role_id, permission_key)
select r.organization_id, r.id, p
from public.roles r
join app.system_role_permissions() s on s.role_key = r.key
cross join lateral unnest(s.perms) as p
where r.is_system
on conflict do nothing;

-- Provisionamento passa a usar a definição única
create or replace function public.rpc_provision_organization(p_user uuid, p_name text, p_timezone text default 'America/Sao_Paulo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_member uuid; v_role uuid; r record;
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'invalid name' using errcode = '22023'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'invalid timezone' using errcode = '22023';
  end if;
  insert into public.organizations (name, timezone) values (trim(p_name), p_timezone) returning id into v_org;
  insert into public.organization_members (organization_id, user_id) values (v_org, p_user) returning id into v_member;
  for r in select * from app.system_role_permissions() loop
    insert into public.roles (organization_id, key, name, is_system) values (v_org, r.role_key, r.role_name, true) returning id into v_role;
    insert into public.role_permissions (organization_id, role_id, permission_key) select v_org, v_role, unnest(r.perms);
    if r.role_key = 'owner' then
      insert into public.user_role_assignments (organization_id, member_id, role_id, created_by) values (v_org, v_member, v_role, p_user);
    end if;
  end loop;
  insert into public.audit_logs (organization_id, actor_id, action, resource_type, resource_id, result)
    values (v_org, p_user, 'organization.provision', 'organization', v_org::text, 'success');
  return v_org;
end $$;

-- Permissão em qualquer escopo (leitura de cadastros globais da organização)
create function app.has_perm_any(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id and o.status = 'active'
    join public.user_role_assignments a on a.organization_id = m.organization_id and a.member_id = m.id
    join public.role_permissions rp on rp.organization_id = a.organization_id and rp.role_id = a.role_id
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active'
      and a.revoked_at is null and a.valid_from <= now() and (a.valid_to is null or a.valid_to > now())
      and rp.permission_key = p_perm
  );
$$;

-- Triggers genéricos
create trigger professionals_touch before update on public.professionals for each row execute function app.touch_updated_at();
create trigger rooms_touch before update on public.rooms for each row execute function app.touch_updated_at();
create trigger equipment_touch before update on public.equipment for each row execute function app.touch_updated_at();
create trigger services_touch before update on public.services for each row execute function app.touch_updated_at();
create trigger events_touch before update on public.scheduling_events for each row execute function app.touch_updated_at();
create trigger appt_history_immutable before update or delete on public.appointment_status_history for each row execute function app.forbid_mutation();

-- Evento: só pode ir de scheduled para cancelled; horários/unidade/serviço imutáveis (remarcar = novo evento)
create function app.guard_event_update() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id <> old.organization_id or new.unit_id <> old.unit_id or new.kind <> old.kind
     or new.service_id is distinct from old.service_id or new.starts_at <> old.starts_at or new.ends_at <> old.ends_at
     or new.patient_id is distinct from old.patient_id or new.rescheduled_from is distinct from old.rescheduled_from then
    raise exception 'scheduling event is immutable except for cancellation' using errcode = '42501';
  end if;
  if old.status = 'cancelled' and new.status <> 'cancelled' then
    raise exception 'cancelled event cannot be reopened' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger events_guard before update on public.scheduling_events for each row execute function app.guard_event_update();

-- Alocação: recurso válido, ativo, na mesma organização e unidade; período contém o evento; só pode ser liberada
create function app.validate_allocation() returns trigger language plpgsql security definer set search_path = '' as $$
declare e record; v_ok boolean := false;
begin
  if tg_op = 'UPDATE' then
    if new.organization_id <> old.organization_id or new.event_id <> old.event_id or new.resource_type <> old.resource_type
       or new.resource_id <> old.resource_id or new.period <> old.period or (old.status = 'released' and new.status <> 'released') then
      raise exception 'allocation is immutable except for release' using errcode = '42501';
    end if;
    return new;
  end if;
  select unit_id, starts_at, ends_at into e from public.scheduling_events
    where id = new.event_id and organization_id = new.organization_id;
  if not found then raise exception 'event not found' using errcode = 'CF404'; end if;
  if not (new.period @> tstzrange(e.starts_at, e.ends_at, '[)')) then
    raise exception 'allocation period must contain the event' using errcode = 'CF422';
  end if;
  if new.resource_type = 'room' then
    select exists (select 1 from public.rooms r where r.id = new.resource_id and r.organization_id = new.organization_id
      and r.unit_id = e.unit_id and r.status = 'active') into v_ok;
  elsif new.resource_type = 'equipment' then
    select exists (select 1 from public.equipment q where q.id = new.resource_id and q.organization_id = new.organization_id
      and q.unit_id = e.unit_id and q.status = 'active') into v_ok;
  else
    select exists (select 1 from public.professionals p
      join public.professional_units pu on pu.professional_id = p.id and pu.organization_id = p.organization_id
      where p.id = new.resource_id and p.organization_id = new.organization_id and p.status = 'active'
        and pu.unit_id = e.unit_id) into v_ok;
  end if;
  if not v_ok then raise exception 'invalid resource for this unit' using errcode = 'CF422'; end if;
  return new;
end $$;
create trigger alloc_validate before insert or update on public.resource_allocations for each row execute function app.validate_allocation();

-- RLS
do $$ declare t text; begin
  foreach t in array array['professionals','professional_units','rooms','equipment','services','service_resource_requirements',
    'scheduling_events','resource_allocations','appointment_status_history'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- professionals / services: leitura em qualquer escopo; escrita só escopo organizacional
create policy prof_select on public.professionals for select to authenticated using (app.has_perm_any(organization_id, 'professional.read'));
create policy prof_insert on public.professionals for insert to authenticated with check (app.has_perm(organization_id, 'professional.write'));
create policy prof_update on public.professionals for update to authenticated
  using (app.has_perm(organization_id, 'professional.write')) with check (app.has_perm(organization_id, 'professional.write'));
grant select, insert (organization_id, member_id, full_name, council, council_number, council_uf, specialty) on public.professionals to authenticated;
grant update (full_name, council, council_number, council_uf, specialty, status) on public.professionals to authenticated;

create policy pu_select on public.professional_units for select to authenticated using (app.has_perm_any(organization_id, 'professional.read'));
create policy pu_insert on public.professional_units for insert to authenticated with check (app.has_perm(organization_id, 'professional.write', unit_id));
create policy pu_delete on public.professional_units for delete to authenticated using (app.has_perm(organization_id, 'professional.write', unit_id));
grant select, insert (organization_id, professional_id, unit_id), delete on public.professional_units to authenticated;

create policy svc_select on public.services for select to authenticated using (app.has_perm_any(organization_id, 'service.read'));
create policy svc_insert on public.services for insert to authenticated with check (app.has_perm(organization_id, 'service.write'));
create policy svc_update on public.services for update to authenticated
  using (app.has_perm(organization_id, 'service.write')) with check (app.has_perm(organization_id, 'service.write'));
grant select, insert (organization_id, name, kind, duration_minutes, buffer_before_minutes, buffer_after_minutes) on public.services to authenticated;
grant update (name, duration_minutes, buffer_before_minutes, buffer_after_minutes, status) on public.services to authenticated;

create policy srr_select on public.service_resource_requirements for select to authenticated using (app.has_perm_any(organization_id, 'service.read'));
create policy srr_insert on public.service_resource_requirements for insert to authenticated with check (app.has_perm(organization_id, 'service.write'));
create policy srr_delete on public.service_resource_requirements for delete to authenticated using (app.has_perm(organization_id, 'service.write'));
grant select, insert (organization_id, service_id, resource_type), delete on public.service_resource_requirements to authenticated;

-- salas / equipamentos: escopo por unidade
create policy rooms_select on public.rooms for select to authenticated using (app.has_perm(organization_id, 'resource.read', unit_id));
create policy rooms_insert on public.rooms for insert to authenticated with check (app.has_perm(organization_id, 'resource.write', unit_id));
create policy rooms_update on public.rooms for update to authenticated
  using (app.has_perm(organization_id, 'resource.write', unit_id)) with check (app.has_perm(organization_id, 'resource.write', unit_id));
grant select, insert (organization_id, unit_id, name, capacity) on public.rooms to authenticated;
grant update (name, capacity, status) on public.rooms to authenticated;

create policy equip_select on public.equipment for select to authenticated using (app.has_perm(organization_id, 'resource.read', unit_id));
create policy equip_insert on public.equipment for insert to authenticated with check (app.has_perm(organization_id, 'resource.write', unit_id));
create policy equip_update on public.equipment for update to authenticated
  using (app.has_perm(organization_id, 'resource.write', unit_id)) with check (app.has_perm(organization_id, 'resource.write', unit_id));
grant select, insert (organization_id, unit_id, name) on public.equipment to authenticated;
grant update (name, status) on public.equipment to authenticated;

-- agenda: leitura por unidade; escrita SOMENTE via RPC (sem grants de escrita)
create policy events_select on public.scheduling_events for select to authenticated using (app.has_perm(organization_id, 'agenda.read', unit_id));
grant select on public.scheduling_events to authenticated;
create policy alloc_select on public.resource_allocations for select to authenticated
  using (exists (select 1 from public.scheduling_events e where e.id = event_id and e.organization_id = resource_allocations.organization_id));
grant select on public.resource_allocations to authenticated;
create policy hist_select on public.appointment_status_history for select to authenticated
  using (exists (select 1 from public.scheduling_events e where e.id = event_id and e.organization_id = appointment_status_history.organization_id));
grant select on public.appointment_status_history to authenticated;

-- RPC: agendar/bloquear (tudo-ou-nada, transacional)
create function public.rpc_book_event(
  p_org uuid, p_unit uuid, p_kind text, p_service uuid, p_starts timestamptz, p_ends timestamptz,
  p_resources jsonb, p_title text default null, p_rescheduled_from uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_svc record; v_ends timestamptz := p_ends; v_event uuid; r record;
  v_before interval := interval '0'; v_after interval := interval '0'; v_n int; v_types text[];
begin
  if not app.has_perm(p_org, 'agenda.write', p_unit) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_kind not in ('appointment','block','maintenance') then raise exception 'invalid kind' using errcode = 'CF422'; end if;
  if not exists (select 1 from public.units u where u.id = p_unit and u.organization_id = p_org and u.status = 'active') then
    raise exception 'unit not found or inactive' using errcode = 'CF404';
  end if;
  if jsonb_typeof(p_resources) is distinct from 'array' then raise exception 'resources must be an array' using errcode = 'CF422'; end if;
  v_n := jsonb_array_length(p_resources);
  if v_n < 1 or v_n > 20 then raise exception 'between 1 and 20 resources required' using errcode = 'CF422'; end if;

  if p_kind = 'appointment' then
    select * into v_svc from public.services s where s.id = p_service and s.organization_id = p_org and s.status = 'active';
    if not found then raise exception 'service not found or inactive' using errcode = 'CF404'; end if;
    v_ends := coalesce(p_ends, p_starts + make_interval(mins => v_svc.duration_minutes));
    v_before := make_interval(mins => v_svc.buffer_before_minutes);
    v_after := make_interval(mins => v_svc.buffer_after_minutes);
    select array_agg(distinct x->>'type') into v_types from jsonb_array_elements(p_resources) x;
    if exists (select 1 from public.service_resource_requirements q
               where q.service_id = p_service and q.organization_id = p_org and q.resource_type <> all (coalesce(v_types, '{}'))) then
      raise exception 'service requires resource types not provided' using errcode = 'CF422';
    end if;
  elsif p_service is not null or p_ends is null then
    raise exception 'block/maintenance require end time and no service' using errcode = 'CF422';
  end if;

  if (select count(*) from (select distinct x->>'type', x->>'id' from jsonb_array_elements(p_resources) x) d) <> v_n then
    raise exception 'duplicate resources' using errcode = 'CF422';
  end if;

  begin
    insert into public.scheduling_events (organization_id, unit_id, kind, service_id, starts_at, ends_at, title, rescheduled_from, created_by)
      values (p_org, p_unit, p_kind, p_service, p_starts, v_ends, p_title, p_rescheduled_from, (select auth.uid()))
      returning id into v_event;
    for r in select x->>'type' as t, (x->>'id')::uuid as id from jsonb_array_elements(p_resources) x loop
      insert into public.resource_allocations (organization_id, event_id, resource_type, resource_id, period)
        values (p_org, v_event, r.t, r.id, tstzrange(p_starts - v_before, v_ends + v_after, '[)'));
    end loop;
  exception
    when exclusion_violation then
      raise exception 'resource conflict' using errcode = 'CF409';
    when invalid_text_representation or check_violation or foreign_key_violation or not_null_violation then
      raise exception 'invalid request' using errcode = 'CF422';
  end;

  insert into public.appointment_status_history (organization_id, event_id, from_status, to_status, changed_by)
    values (p_org, v_event, null, 'scheduled', (select auth.uid()));
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, p_unit, (select auth.uid()), case when p_rescheduled_from is null then 'agenda.book' else 'agenda.reschedule' end,
            'scheduling_event', v_event::text, 'success');
  return v_event;
end $$;

-- RPC: cancelar (libera os recursos)
create function public.rpc_cancel_event(p_org uuid, p_event uuid, p_reason text, p_audit_action text default 'agenda.cancel')
returns void language plpgsql security definer set search_path = '' as $$
declare e record;
begin
  select * into e from public.scheduling_events where id = p_event and organization_id = p_org for update;
  if not found or not app.is_member(p_org) then raise exception 'event not found' using errcode = 'CF404'; end if;
  if not app.has_perm(p_org, 'agenda.write', e.unit_id) then raise exception 'permission denied' using errcode = '42501'; end if;
  if e.status <> 'scheduled' then raise exception 'event is not scheduled' using errcode = 'CF409'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'reason required' using errcode = 'CF422'; end if;
  update public.resource_allocations set status = 'released', released_at = now()
    where organization_id = p_org and event_id = p_event and status = 'active';
  update public.scheduling_events set status = 'cancelled', cancel_reason = left(trim(p_reason), 300) where id = p_event;
  insert into public.appointment_status_history (organization_id, event_id, from_status, to_status, reason, changed_by)
    values (p_org, p_event, 'scheduled', 'cancelled', left(trim(p_reason), 300), (select auth.uid()));
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, e.unit_id, (select auth.uid()), p_audit_action, 'scheduling_event', p_event::text, 'success');
end $$;

-- RPC: remarcar (atômico: se o novo horário conflitar, nada muda)
create function public.rpc_reschedule_event(p_org uuid, p_event uuid, p_starts timestamptz, p_ends timestamptz default null)
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
  return v_new;
end $$;

grant execute on function app.has_perm_any(uuid, text) to authenticated, service_role;
grant execute on function app.system_role_permissions() to authenticated, service_role;
grant execute on function public.rpc_book_event(uuid, uuid, text, uuid, timestamptz, timestamptz, jsonb, text, uuid) to authenticated, service_role;
grant execute on function public.rpc_cancel_event(uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.rpc_reschedule_event(uuid, uuid, timestamptz, timestamptz) to authenticated, service_role;
revoke execute on function app.guard_event_update() from public;
grant select, insert, update, delete on all tables in schema public to service_role;
