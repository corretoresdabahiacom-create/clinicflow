-- 1A / migration 2: funções auxiliares, guardas anti-escalada, imutabilidade, RPCs
create function app.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create function app.forbid_mutation() returns trigger language plpgsql set search_path = '' as $$
begin raise exception '% is append-only', tg_table_name using errcode = '42501'; end $$;

create function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    join public.organizations o on o.id = m.organization_id and o.status = 'active'
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active'
  );
$$;

-- p_unit nulo exige atribuição de escopo organizacional; atribuição por unidade só vale para aquela unidade
create function app.has_perm(p_org uuid, p_perm text, p_unit uuid default null) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id and o.status = 'active'
    join public.user_role_assignments a on a.organization_id = m.organization_id and a.member_id = m.id
    join public.role_permissions rp on rp.organization_id = a.organization_id and rp.role_id = a.role_id
    where m.organization_id = p_org
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and a.revoked_at is null
      and a.valid_from <= now()
      and (a.valid_to is null or a.valid_to > now())
      and rp.permission_key = p_perm
      and (a.unit_id is null or (p_unit is not null and a.unit_id = p_unit))
  );
$$;

-- Guardas (usuário final autenticado; sem JWT de usuário = provisionamento/service_role)
create function app.guard_system_role() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and old.is_system then
    raise exception 'system role is immutable' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create function app.guard_role_permission() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_role uuid; v_sys boolean;
begin
  if (select auth.uid()) is null then
    if tg_op = 'DELETE' then return old; end if; return new;
  end if;
  v_org := case when tg_op = 'DELETE' then old.organization_id else new.organization_id end;
  v_role := case when tg_op = 'DELETE' then old.role_id else new.role_id end;
  select is_system into v_sys from public.roles where id = v_role and organization_id = v_org;
  if coalesce(v_sys, false) then
    raise exception 'system role permissions are immutable' using errcode = '42501';
  end if;
  if tg_op <> 'DELETE' and not app.has_perm(v_org, new.permission_key, null) then
    raise exception 'cannot grant a permission you do not hold' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create function app.guard_role_assignment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then return new; end if;
  if exists (
    select 1 from public.role_permissions rp
    where rp.organization_id = new.organization_id and rp.role_id = new.role_id
      and not app.has_perm(new.organization_id, rp.permission_key, null)
  ) then
    raise exception 'privilege escalation blocked' using errcode = '42501';
  end if;
  return new;
end $$;

create function app.guard_member_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then return new; end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status and exists (
    select 1 from public.user_role_assignments a
    join public.role_permissions rp on rp.organization_id = a.organization_id and rp.role_id = a.role_id
    where a.member_id = old.id and a.revoked_at is null
      and not app.has_perm(old.organization_id, rp.permission_key, null)
  ) then
    raise exception 'cannot change status of a member with higher privileges' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger organizations_touch before update on public.organizations for each row execute function app.touch_updated_at();
create trigger units_touch before update on public.units for each row execute function app.touch_updated_at();
create trigger audit_no_mutation before update or delete on public.audit_logs for each row execute function app.forbid_mutation();
create trigger audit_no_truncate before truncate on public.audit_logs for each statement execute function app.forbid_mutation();
create trigger roles_guard before update or delete on public.roles for each row execute function app.guard_system_role();
create trigger role_permissions_guard before insert or update or delete on public.role_permissions for each row execute function app.guard_role_permission();
create trigger assignments_guard before insert or update on public.user_role_assignments for each row execute function app.guard_role_assignment();
create trigger members_guard before update on public.organization_members for each row execute function app.guard_member_change();

-- RPC: provisionamento de organização (somente service_role)
create function public.rpc_provision_organization(p_user uuid, p_name text, p_timezone text default 'America/Sao_Paulo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_member uuid; v_role uuid; r record;
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'invalid name' using errcode = '22023'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'invalid timezone' using errcode = '22023';
  end if;
  insert into public.organizations (name, timezone) values (trim(p_name), p_timezone) returning id into v_org;
  insert into public.organization_members (organization_id, user_id) values (v_org, p_user) returning id into v_member;
  for r in select * from (values
    ('owner', 'Proprietário', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','role.manage','audit.read']),
    ('admin', 'Administrador geral', array['org.read','org.manage','unit.read','unit.write','member.read','member.manage','role.read','audit.read']),
    ('unit_manager', 'Gerente de unidade', array['unit.read','unit.write','member.read']),
    ('receptionist', 'Recepcionista', array['org.read','unit.read']),
    ('doctor', 'Médico', array['org.read','unit.read']),
    ('nurse', 'Enfermeiro', array['org.read','unit.read']),
    ('exam_tech', 'Técnico de exames', array['org.read','unit.read']),
    ('finance', 'Financeiro', array['org.read','unit.read']),
    ('auditor', 'Auditor/compliance', array['org.read','unit.read','member.read','role.read','audit.read'])
  ) as t(k, n, p) loop
    insert into public.roles (organization_id, key, name, is_system) values (v_org, r.k, r.n, true) returning id into v_role;
    insert into public.role_permissions (organization_id, role_id, permission_key)
      select v_org, v_role, unnest(r.p);
    if r.k = 'owner' then
      insert into public.user_role_assignments (organization_id, member_id, role_id, created_by) values (v_org, v_member, v_role, p_user);
    end if;
  end loop;
  insert into public.audit_logs (organization_id, actor_id, action, resource_type, resource_id, result)
    values (v_org, p_user, 'organization.provision', 'organization', v_org::text, 'success');
  return v_org;
end $$;

-- RPC: auditoria com ator = usuário autenticado e verificação de vínculo
create function public.rpc_write_audit(
  p_org uuid, p_unit uuid, p_action text, p_resource_type text, p_resource_id text,
  p_result text, p_ip text, p_user_agent text, p_correlation_id text, p_metadata jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app.is_member(p_org) then raise exception 'not a member' using errcode = '42501'; end if;
  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result, ip, user_agent, correlation_id, metadata)
  values (p_org, p_unit, (select auth.uid()), p_action, p_resource_type, p_resource_id, p_result,
          nullif(p_ip, '')::inet, p_user_agent, p_correlation_id, coalesce(p_metadata, '{}'::jsonb));
end $$;

-- RPC: rate limit por janela fixa (somente service_role; ver ADR-006)
create function public.rpc_rate_limit_hit(p_bucket text, p_window_seconds int, p_max int)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_start timestamptz; v_count int;
begin
  if p_bucket is null or length(p_bucket) > 200 or p_window_seconds not between 1 and 86400 or p_max < 1 then
    raise exception 'invalid rate limit parameters' using errcode = '22023';
  end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits as rl (bucket, window_start, count) values (p_bucket, v_start, 1)
    on conflict (bucket, window_start) do update set count = rl.count + 1
    returning count into v_count;
  if random() < 0.01 then
    delete from public.rate_limits where window_start < now() - interval '1 day';
  end if;
  return v_count <= p_max;
end $$;

-- RPC: contexto do usuário (organizações, permissões organizacionais e por unidade)
create function public.rpc_my_context() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'organization_id', o.id, 'organization_name', o.name, 'organization_status', o.status, 'member_id', m.id,
    'permissions', (
      select coalesce(jsonb_agg(distinct rp.permission_key), '[]'::jsonb)
      from public.user_role_assignments a
      join public.role_permissions rp on rp.organization_id = a.organization_id and rp.role_id = a.role_id
      where a.member_id = m.id and a.unit_id is null and a.revoked_at is null
        and a.valid_from <= now() and (a.valid_to is null or a.valid_to > now())),
    'unit_scopes', (
      select coalesce(jsonb_agg(jsonb_build_object('unit_id', x.unit_id, 'permissions', x.perms)), '[]'::jsonb)
      from (
        select a.unit_id, jsonb_agg(distinct rp.permission_key) as perms
        from public.user_role_assignments a
        join public.role_permissions rp on rp.organization_id = a.organization_id and rp.role_id = a.role_id
        where a.member_id = m.id and a.unit_id is not null and a.revoked_at is null
          and a.valid_from <= now() and (a.valid_to is null or a.valid_to > now())
        group by a.unit_id) x)
  )), '[]'::jsonb)
  from public.organization_members m
  join public.organizations o on o.id = m.organization_id
  where m.user_id = (select auth.uid()) and m.status = 'active';
$$;
