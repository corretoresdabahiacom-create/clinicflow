-- 1E / migration 12: portal do paciente (agendamento online, meus agendamentos, cancelar e remarcar)
-- Princípios: o paciente NÃO acessa tabelas; só RPCs security definer com verificação de vínculo
-- (app.patient_self_access = titular ou responsável ativo). Nenhum dado clínico é exposto.
-- Dados sintéticos até o Production Gate.

-- ---------------------------------------------------------------------------------------------------------
-- Configuração por organização (padrões seguros quando não há linha)
-- ---------------------------------------------------------------------------------------------------------
create table public.portal_settings (
  organization_id uuid primary key references public.organizations(id),
  min_lead_hours int not null default 2 check (min_lead_hours between 0 and 168),
  cancel_min_hours int not null default 24 check (cancel_min_hours between 0 and 168),
  horizon_days int not null default 60 check (horizon_days between 1 and 365),
  max_active_per_patient int not null default 5 check (max_active_per_patient between 1 and 50),
  max_reschedules int not null default 2 check (max_reschedules between 0 and 10),
  updated_at timestamptz not null default now()
);
alter table public.portal_settings enable row level security;
alter table public.portal_settings force row level security;
create policy portal_settings_select on public.portal_settings for select to authenticated
  using (app.has_perm_any(organization_id, 'org.read'));
grant select on public.portal_settings to authenticated;

-- Serviços liberados para agendamento online (padrão: não)
alter table public.services add column online_booking boolean not null default false;
grant insert (online_booking) on public.services to authenticated;
grant update (online_booking) on public.services to authenticated;

-- Disponibilidade semanal do profissional por unidade (hora local da unidade)
create table public.professional_availability (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  professional_id uuid not null,
  unit_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),   -- 0 = domingo
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  check (end_time > start_time),
  foreign key (organization_id, professional_id) references public.professionals (organization_id, id),
  foreign key (organization_id, unit_id) references public.units (organization_id, id),
  unique (professional_id, unit_id, weekday, start_time)
);
create index prof_avail_idx on public.professional_availability (organization_id, unit_id, professional_id);
alter table public.professional_availability enable row level security;
alter table public.professional_availability force row level security;
create policy prof_avail_select on public.professional_availability for select to authenticated
  using (app.has_perm(organization_id, 'agenda.read', unit_id));
grant select on public.professional_availability to authenticated;

-- ---------------------------------------------------------------------------------------------------------
-- Internas
-- ---------------------------------------------------------------------------------------------------------
create function app.portal_cfg(p_org uuid) returns public.portal_settings
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s from public.portal_settings s where s.organization_id = p_org),
    row(p_org, 2, 24, 60, 5, 2, now())::public.portal_settings);
$$;

-- Vínculo ativo do usuário logado com algum paciente da organização
create function app.portal_has_link(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organizations o where o.id = p_org and o.status = 'active')
    and exists (select 1 from public.patient_identity_links l
                where l.organization_id = p_org and l.user_id = (select auth.uid()) and l.revoked_at is null);
$$;

-- Resolve um horário: valida serviço/profissional/disponibilidade e escolhe sala/equipamento livres.
-- Devolve o array de recursos ou null se o horário não está disponível. Não escreve nada.
create function app.portal_resolve(p_org uuid, p_unit uuid, p_service uuid, p_prof uuid, p_starts timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s record; u record; c public.portal_settings; v_ends timestamptz; v_local timestamp; v_lend timestamp;
  v_before interval; v_after interval; v_period tstzrange; res jsonb; t text; pick uuid;
begin
  c := app.portal_cfg(p_org);
  select * into s from public.services where id = p_service and organization_id = p_org and status = 'active' and online_booking;
  if not found then return null; end if;
  select * into u from public.units where id = p_unit and organization_id = p_org and status = 'active';
  if not found then return null; end if;
  if not exists (select 1 from public.professionals p join public.professional_units pu on pu.professional_id = p.id and pu.unit_id = p_unit
                 where p.id = p_prof and p.organization_id = p_org and p.status = 'active') then return null; end if;
  if date_part('second', p_starts) <> 0 or (extract(minute from p_starts at time zone u.timezone))::int % 5 <> 0 then return null; end if;
  if p_starts < now() + make_interval(hours => c.min_lead_hours) or p_starts > now() + make_interval(days => c.horizon_days) then return null; end if;

  v_ends := p_starts + make_interval(mins => s.duration_minutes);
  v_local := p_starts at time zone u.timezone;
  v_lend := v_ends at time zone u.timezone;
  if v_lend::date <> v_local::date then return null; end if;
  if not exists (select 1 from public.professional_availability a
                 where a.organization_id = p_org and a.professional_id = p_prof and a.unit_id = p_unit
                   and a.weekday = extract(dow from v_local)::int
                   and a.start_time <= v_local::time and a.end_time >= v_lend::time) then return null; end if;

  v_before := make_interval(mins => s.buffer_before_minutes);
  v_after := make_interval(mins => s.buffer_after_minutes);
  v_period := tstzrange(p_starts - v_before, v_ends + v_after, '[)');

  if exists (select 1 from public.resource_allocations ra where ra.organization_id = p_org and ra.status = 'active'
             and ra.resource_type = 'professional' and ra.resource_id = p_prof and ra.period && v_period) then return null; end if;
  res := jsonb_build_array(jsonb_build_object('type', 'professional', 'id', p_prof));

  for t in select q.resource_type from public.service_resource_requirements q
           where q.service_id = p_service and q.organization_id = p_org and q.resource_type <> 'professional' order by 1 loop
    if t = 'room' then
      select r.id into pick from public.rooms r
        where r.organization_id = p_org and r.unit_id = p_unit and r.status = 'active'
          and not exists (select 1 from public.resource_allocations ra where ra.organization_id = p_org and ra.status = 'active'
                          and ra.resource_type = 'room' and ra.resource_id = r.id and ra.period && v_period)
        order by r.name limit 1;
    else
      select e.id into pick from public.equipment e
        where e.organization_id = p_org and e.unit_id = p_unit and e.status = 'active'
          and not exists (select 1 from public.resource_allocations ra where ra.organization_id = p_org and ra.status = 'active'
                          and ra.resource_type = 'equipment' and ra.resource_id = e.id and ra.period && v_period)
        order by e.name limit 1;
    end if;
    if pick is null then return null; end if;
    res := res || jsonb_build_array(jsonb_build_object('type', t, 'id', pick));
  end loop;
  return res;
end $$;

-- Grava o evento do portal (chamada só pelas RPCs abaixo, já autorizadas)
create function app.portal_insert_event(p_org uuid, p_unit uuid, p_service uuid, p_patient uuid, p_starts timestamptz,
                                        p_resources jsonb, p_from uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare s record; v_ends timestamptz; v_before interval; v_after interval; v uuid; r record;
begin
  select * into s from public.services where id = p_service and organization_id = p_org;
  v_ends := p_starts + make_interval(mins => s.duration_minutes);
  v_before := make_interval(mins => s.buffer_before_minutes);
  v_after := make_interval(mins => s.buffer_after_minutes);
  begin
    insert into public.scheduling_events (organization_id, unit_id, kind, service_id, starts_at, ends_at, patient_id, rescheduled_from, created_by)
      values (p_org, p_unit, 'appointment', p_service, p_starts, v_ends, p_patient, p_from, (select auth.uid()))
      returning id into v;
    for r in select x->>'type' as t, (x->>'id')::uuid as id from jsonb_array_elements(p_resources) x loop
      insert into public.resource_allocations (organization_id, event_id, resource_type, resource_id, period)
        values (p_org, v, r.t, r.id, tstzrange(p_starts - v_before, v_ends + v_after, '[)'));
    end loop;
  exception when exclusion_violation then
    raise exception 'slot unavailable' using errcode = 'CF409';
  end;
  insert into public.appointment_status_history (organization_id, event_id, from_status, to_status, changed_by)
    values (p_org, v, null, 'scheduled', (select auth.uid()));
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, p_unit, (select auth.uid()), case when p_from is null then 'portal.book' else 'portal.reschedule' end,
            'scheduling_event', v::text, 'success');
  return v;
end $$;

create function app.portal_cancel_core(p_org uuid, p_event uuid, p_reason text, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare e record;
begin
  select unit_id into e from public.scheduling_events where id = p_event and organization_id = p_org;
  update public.resource_allocations set status = 'released', released_at = now()
    where organization_id = p_org and event_id = p_event and status = 'active';
  update public.scheduling_events set status = 'cancelled', cancel_reason = p_reason where id = p_event;
  insert into public.appointment_status_history (organization_id, event_id, from_status, to_status, reason, changed_by)
    values (p_org, p_event, 'scheduled', 'cancelled', p_reason, (select auth.uid()));
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, e.unit_id, (select auth.uid()), p_action, 'scheduling_event', p_event::text, 'success');
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- RPCs do portal (usuário logado; vínculo verificado dentro da função)
-- ---------------------------------------------------------------------------------------------------------
-- Quem sou eu: pacientes que este usuário pode acessar (titular e dependentes), por organização
create function public.rpc_portal_context() returns table (
  organization_id uuid, organization_name text, patient_id uuid, patient_name text, relation text)
language sql stable security definer set search_path = '' as $$
  select o.id, o.name, p.id, p.full_name, case when p.id = l.patient_id then 'self' else 'dependent' end
  from public.patient_identity_links l
  join public.organizations o on o.id = l.organization_id and o.status = 'active'
  join public.patients p on p.organization_id = l.organization_id and p.status = 'active'
  where l.user_id = (select auth.uid()) and l.revoked_at is null
    and (p.id = l.patient_id or exists (
      select 1 from public.patient_guardianships g
      where g.organization_id = l.organization_id and g.guardian_patient_id = l.patient_id and g.dependent_patient_id = p.id
        and g.revoked_at is null and g.valid_from <= now() and (g.valid_to is null or g.valid_to > now())))
  order by o.name, p.full_name;
$$;

-- Serviços liberados e profissionais com disponibilidade, por unidade
create function public.rpc_portal_catalog(p_org uuid) returns table (
  unit_id uuid, unit_name text, service_id uuid, service_name text, duration_minutes int,
  professional_id uuid, professional_name text, specialty text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.portal_has_link(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  return query
    select u.id, u.name, s.id, s.name, s.duration_minutes, p.id, p.full_name, p.specialty
    from public.units u
    join public.professional_units pu on pu.unit_id = u.id and pu.organization_id = u.organization_id
    join public.professionals p on p.id = pu.professional_id and p.organization_id = u.organization_id and p.status = 'active'
    join public.services s on s.organization_id = u.organization_id and s.status = 'active' and s.online_booking
    where u.organization_id = p_org and u.status = 'active'
      and exists (select 1 from public.professional_availability a
                  where a.professional_id = p.id and a.unit_id = u.id and a.organization_id = p_org)
    order by u.name, s.name, p.full_name;
end $$;

create function public.rpc_portal_slots(p_org uuid, p_unit uuid, p_service uuid, p_professional uuid, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare u record; s record; d date; a record; cur timestamp; v_start timestamptz; n int := 0;
begin
  if not app.portal_has_link(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 14 then
    raise exception 'invalid range (max 14 days)' using errcode = 'CF422';
  end if;
  select * into u from public.units where id = p_unit and organization_id = p_org and status = 'active';
  select * into s from public.services where id = p_service and organization_id = p_org and status = 'active' and online_booking;
  if u.id is null or s.id is null then return; end if;
  for d in select g::date from generate_series(p_from, p_to, interval '1 day') g loop
    for a in select * from public.professional_availability
             where organization_id = p_org and professional_id = p_professional and unit_id = p_unit
               and weekday = extract(dow from d)::int order by start_time loop
      cur := d + a.start_time;
      while (cur + make_interval(mins => s.duration_minutes))::time <= a.end_time
            and (cur + make_interval(mins => s.duration_minutes))::date = d loop
        v_start := cur at time zone u.timezone;
        if app.portal_resolve(p_org, p_unit, p_service, p_professional, v_start) is not null then
          n := n + 1;
          if n > 300 then return; end if;
          starts_at := v_start; ends_at := v_start + make_interval(mins => s.duration_minutes); return next;
        end if;
        cur := cur + make_interval(mins => greatest(s.duration_minutes, 15));
      end loop;
    end loop;
  end loop;
end $$;

-- Meus agendamentos (somente dados do próprio horário; sem dados clínicos)
create function public.rpc_portal_appointments(p_org uuid, p_patient uuid) returns table (
  event_id uuid, status text, starts_at timestamptz, ends_at timestamptz, unit_id uuid, unit_name text, service_id uuid,
  service_name text, professional_id uuid, professional_name text, can_cancel boolean)
language plpgsql stable security definer set search_path = '' as $$
declare c public.portal_settings;
begin
  if not app.patient_self_access(p_org, p_patient) then raise exception 'not found' using errcode = 'CF404'; end if;
  c := app.portal_cfg(p_org);
  return query
    select e.id, e.status, e.starts_at, e.ends_at, u.id, u.name, s.id, s.name,
           (select ra.resource_id from public.resource_allocations ra
             where ra.event_id = e.id and ra.resource_type = 'professional' order by ra.created_at limit 1),
           (select p.full_name from public.resource_allocations ra join public.professionals p on p.id = ra.resource_id
             where ra.event_id = e.id and ra.resource_type = 'professional' order by ra.created_at limit 1),
           e.status = 'scheduled' and e.starts_at >= now() + make_interval(hours => c.cancel_min_hours)
    from public.scheduling_events e
    join public.units u on u.id = e.unit_id and u.organization_id = e.organization_id
    left join public.services s on s.id = e.service_id and s.organization_id = e.organization_id
    where e.organization_id = p_org and e.patient_id = p_patient and e.kind = 'appointment'
      and e.starts_at >= now() - interval '90 days'
    order by e.starts_at desc
    limit 100;
end $$;

create function public.rpc_portal_book(p_org uuid, p_patient uuid, p_unit uuid, p_service uuid, p_professional uuid, p_starts timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.portal_settings; res jsonb; n int; v_same uuid;
begin
  if not app.patient_self_access(p_org, p_patient) then raise exception 'not found' using errcode = 'CF404'; end if;
  if not exists (select 1 from public.patients where id = p_patient and organization_id = p_org and status = 'active') then
    raise exception 'not found' using errcode = 'CF404';
  end if;
  c := app.portal_cfg(p_org);
  perform pg_advisory_xact_lock(hashtextextended('cf:portal:' || p_patient::text, 0));
  -- idempotência natural: repetir a mesma requisição devolve o agendamento já criado
  select e.id into v_same from public.scheduling_events e
    where e.organization_id = p_org and e.patient_id = p_patient and e.kind = 'appointment' and e.status = 'scheduled'
      and e.unit_id = p_unit and e.service_id = p_service and e.starts_at = p_starts
      and exists (select 1 from public.resource_allocations ra where ra.event_id = e.id and ra.resource_type = 'professional'
                  and ra.resource_id = p_professional and ra.status = 'active')
    limit 1;
  if v_same is not null then return v_same; end if;
  select count(*) into n from public.scheduling_events
    where organization_id = p_org and patient_id = p_patient and kind = 'appointment' and status = 'scheduled' and ends_at > now();
  if n >= c.max_active_per_patient then raise exception 'too many active appointments' using errcode = 'CF409'; end if;
  res := app.portal_resolve(p_org, p_unit, p_service, p_professional, p_starts);
  if res is null then raise exception 'slot unavailable' using errcode = 'CF409'; end if;
  return app.portal_insert_event(p_org, p_unit, p_service, p_patient, p_starts, res, null);
end $$;

create function public.rpc_portal_cancel(p_org uuid, p_event uuid, p_reason text default 'cancelado pelo paciente') returns void
language plpgsql security definer set search_path = '' as $$
declare e record; c public.portal_settings;
begin
  select * into e from public.scheduling_events where id = p_event and organization_id = p_org for update;
  if not found or e.patient_id is null or not app.patient_self_access(p_org, e.patient_id) then
    raise exception 'not found' using errcode = 'CF404';
  end if;
  if e.kind <> 'appointment' or e.status <> 'scheduled' then raise exception 'event is not scheduled' using errcode = 'CF409'; end if;
  c := app.portal_cfg(p_org);
  if e.starts_at < now() + make_interval(hours => c.cancel_min_hours) then
    raise exception 'too late to cancel online' using errcode = 'CF409';
  end if;
  perform app.portal_cancel_core(p_org, p_event, left(coalesce(nullif(trim(p_reason), ''), 'cancelado pelo paciente'), 300), 'portal.cancel');
end $$;

create function public.rpc_portal_reschedule(p_org uuid, p_event uuid, p_starts timestamptz) returns uuid
language plpgsql security definer set search_path = '' as $$
declare e record; c public.portal_settings; v_prof uuid; res jsonb; depth int; v_same uuid;
begin
  select * into e from public.scheduling_events where id = p_event and organization_id = p_org for update;
  if not found or e.patient_id is null or not app.patient_self_access(p_org, e.patient_id) then
    raise exception 'not found' using errcode = 'CF404';
  end if;
  if e.kind = 'appointment' and e.status = 'cancelled' then
    -- repetição da mesma remarcação: devolve o evento novo já criado a partir deste
    select x.id into v_same from public.scheduling_events x
      where x.organization_id = p_org and x.rescheduled_from = p_event and x.status = 'scheduled' and x.starts_at = p_starts limit 1;
    if v_same is not null then return v_same; end if;
  end if;
  if e.kind <> 'appointment' or e.status <> 'scheduled' then raise exception 'event is not scheduled' using errcode = 'CF409'; end if;
  c := app.portal_cfg(p_org);
  if e.starts_at < now() + make_interval(hours => c.cancel_min_hours) then
    raise exception 'too late to reschedule online' using errcode = 'CF409';
  end if;
  with recursive chain as (
    select id, rescheduled_from, 0 as d from public.scheduling_events where id = p_event and organization_id = p_org
    union all
    select x.id, x.rescheduled_from, chain.d + 1 from public.scheduling_events x
      join chain on x.id = chain.rescheduled_from and x.organization_id = p_org)
  select max(d) into depth from chain;
  if depth >= c.max_reschedules then raise exception 'reschedule limit reached' using errcode = 'CF409'; end if;
  select resource_id into v_prof from public.resource_allocations
    where organization_id = p_org and event_id = p_event and resource_type = 'professional' order by created_at limit 1;
  if v_prof is null then raise exception 'cannot reschedule online' using errcode = 'CF422'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cf:portal:' || e.patient_id::text, 0));
  -- libera o horário antigo dentro da mesma transação: se o novo não estiver livre, tudo é desfeito
  perform app.portal_cancel_core(p_org, p_event, 'rescheduled', 'portal.reschedule_release');
  res := app.portal_resolve(p_org, e.unit_id, e.service_id, v_prof, p_starts);
  if res is null then raise exception 'slot unavailable' using errcode = 'CF409'; end if;
  return app.portal_insert_event(p_org, e.unit_id, e.service_id, e.patient_id, p_starts, res, p_event);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Administração (equipe): disponibilidade e parâmetros do portal
-- ---------------------------------------------------------------------------------------------------------
create function public.rpc_set_availability(p_org uuid, p_unit uuid, p_professional uuid, p_windows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare w jsonb; n int := 0;
begin
  if not app.has_perm(p_org, 'agenda.write', p_unit) then raise exception 'permission denied' using errcode = '42501'; end if;
  if jsonb_typeof(p_windows) is distinct from 'array' or jsonb_array_length(p_windows) > 50 then
    raise exception 'invalid windows' using errcode = 'CF422';
  end if;
  if not exists (select 1 from public.professional_units where organization_id = p_org and professional_id = p_professional and unit_id = p_unit) then
    raise exception 'professional not in unit' using errcode = 'CF404';
  end if;
  delete from public.professional_availability where organization_id = p_org and professional_id = p_professional and unit_id = p_unit;
  begin
    for w in select * from jsonb_array_elements(p_windows) loop
      insert into public.professional_availability (organization_id, professional_id, unit_id, weekday, start_time, end_time)
        values (p_org, p_professional, p_unit, (w->>'weekday')::smallint, (w->>'start')::time, (w->>'end')::time);
      n := n + 1;
    end loop;
  exception when invalid_text_representation or check_violation or not_null_violation or datetime_field_overflow or unique_violation then
    raise exception 'invalid windows' using errcode = 'CF422';
  end;
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, p_unit, (select auth.uid()), 'availability.set', 'professional', p_professional::text, 'success');
  return n;
end $$;

create function public.rpc_set_portal_settings(p_org uuid, p_min_lead int, p_cancel_min int, p_horizon int, p_max_active int, p_max_resched int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_perm_any(p_org, 'org.manage') then raise exception 'permission denied' using errcode = '42501'; end if;
  begin
    insert into public.portal_settings (organization_id, min_lead_hours, cancel_min_hours, horizon_days, max_active_per_patient, max_reschedules)
      values (p_org, p_min_lead, p_cancel_min, p_horizon, p_max_active, p_max_resched)
    on conflict (organization_id) do update set min_lead_hours = excluded.min_lead_hours, cancel_min_hours = excluded.cancel_min_hours,
      horizon_days = excluded.horizon_days, max_active_per_patient = excluded.max_active_per_patient,
      max_reschedules = excluded.max_reschedules, updated_at = now();
  exception when check_violation or not_null_violation then raise exception 'invalid settings' using errcode = 'CF422'; end;
  insert into public.audit_logs (organization_id, actor_id, action, resource_type, resource_id, result)
    values (p_org, (select auth.uid()), 'portal.settings', 'organization', p_org::text, 'success');
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------------------------------------------
revoke all on function app.portal_cfg(uuid) from public, anon, authenticated;
revoke all on function app.portal_has_link(uuid) from public, anon, authenticated;
revoke all on function app.portal_resolve(uuid, uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.portal_insert_event(uuid, uuid, uuid, uuid, timestamptz, jsonb, uuid) from public, anon, authenticated;
revoke all on function app.portal_cancel_core(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.rpc_portal_context() from public, anon;
revoke all on function public.rpc_portal_catalog(uuid) from public, anon;
revoke all on function public.rpc_portal_slots(uuid, uuid, uuid, uuid, date, date) from public, anon;
revoke all on function public.rpc_portal_appointments(uuid, uuid) from public, anon;
revoke all on function public.rpc_portal_book(uuid, uuid, uuid, uuid, uuid, timestamptz) from public, anon;
revoke all on function public.rpc_portal_cancel(uuid, uuid, text) from public, anon;
revoke all on function public.rpc_portal_reschedule(uuid, uuid, timestamptz) from public, anon;
revoke all on function public.rpc_set_availability(uuid, uuid, uuid, jsonb) from public, anon;
revoke all on function public.rpc_set_portal_settings(uuid, int, int, int, int, int) from public, anon;
grant execute on function public.rpc_portal_context() to authenticated, service_role;
grant execute on function public.rpc_portal_catalog(uuid) to authenticated, service_role;
grant execute on function public.rpc_portal_slots(uuid, uuid, uuid, uuid, date, date) to authenticated, service_role;
grant execute on function public.rpc_portal_appointments(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_portal_book(uuid, uuid, uuid, uuid, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.rpc_portal_cancel(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.rpc_portal_reschedule(uuid, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.rpc_set_availability(uuid, uuid, uuid, jsonb) to authenticated, service_role;
grant execute on function public.rpc_set_portal_settings(uuid, int, int, int, int, int) to authenticated, service_role;
-- service_role: somente as tabelas novas (NUNCA 'all tables': reabriria as tabelas clínicas, fechadas na 1D)
grant select, insert, update, delete on public.portal_settings, public.professional_availability to service_role;
