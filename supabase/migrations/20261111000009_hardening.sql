-- 1H / migration 9: endurecimento
--  (a) último proprietário não pode ser removido/suspenso/revogado
--  (b) auditoria transacional por trigger para mutações fora das RPCs de agenda
--  (c) idempotência: tomada de chave presa em 'processing' e rotina de limpeza
--  (d) versão da chave de HMAC do CPF
-- Sem dado novo sensível: a auditoria registra somente NOMES de colunas alteradas, nunca valores.

-- ---------------------------------------------------------------------------------------------------------
-- (a) Último proprietário
-- ---------------------------------------------------------------------------------------------------------
create function app.other_owner_exists(p_org uuid, p_exclude_member uuid, p_exclude_assignment uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.user_role_assignments a
    join public.roles r on r.id = a.role_id and r.organization_id = a.organization_id and r.key = 'owner'
    join public.organization_members m on m.id = a.member_id and m.organization_id = a.organization_id and m.status = 'active'
    where a.organization_id = p_org
      and a.unit_id is null
      and a.revoked_at is null
      and a.valid_from <= now()
      and (a.valid_to is null or a.valid_to > now())
      and (p_exclude_member is null or a.member_id <> p_exclude_member)
      and (p_exclude_assignment is null or a.id <> p_exclude_assignment)
  );
$$;

-- Serializa alterações de proprietários da mesma organização: duas revogações simultâneas não passam juntas.
create function app.lock_owners(p_org uuid) returns void language sql security definer set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('cf:owners:' || p_org::text, 0));
$$;

create function app.guard_last_owner_assignment() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_is_owner boolean; v_ends boolean;
begin
  if old.unit_id is not null or old.revoked_at is not null or old.valid_from > now()
     or (old.valid_to is not null and old.valid_to <= now()) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  select exists (select 1 from public.roles r where r.id = old.role_id and r.organization_id = old.organization_id and r.key = 'owner')
    into v_is_owner;
  if not v_is_owner then return case when tg_op = 'DELETE' then old else new end; end if;
  v_ends := tg_op = 'DELETE' or new.revoked_at is not null or (new.valid_to is not null and new.valid_to <= now())
            or new.unit_id is not null or new.role_id is distinct from old.role_id;
  if v_ends then
    perform app.lock_owners(old.organization_id);
    if not app.other_owner_exists(old.organization_id, null, old.id) then
      raise exception 'cannot remove the last owner of the organization' using errcode = 'CF409';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create function app.guard_last_owner_member() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status <> 'active' or (tg_op = 'UPDATE' and new.status = 'active') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if exists (
    select 1 from public.user_role_assignments a
    join public.roles r on r.id = a.role_id and r.organization_id = a.organization_id and r.key = 'owner'
    where a.organization_id = old.organization_id and a.member_id = old.id and a.unit_id is null
      and a.revoked_at is null and a.valid_from <= now() and (a.valid_to is null or a.valid_to > now())
  ) then
    perform app.lock_owners(old.organization_id);
    if not app.other_owner_exists(old.organization_id, old.id, null) then
      raise exception 'cannot remove the last owner of the organization' using errcode = 'CF409';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger assignments_last_owner before update or delete on public.user_role_assignments
  for each row execute function app.guard_last_owner_assignment();
create trigger members_last_owner before update or delete on public.organization_members
  for each row execute function app.guard_last_owner_member();

-- ---------------------------------------------------------------------------------------------------------
-- (b) Auditoria transacional por trigger
-- Argumentos: 0 ação no INSERT, 1 ação no UPDATE, 2 tipo do recurso, 3 coluna do id do recurso,
--             4 coluna da unidade ('' = nenhuma), 5 ação no DELETE ('' = não audita)
-- Contexto da requisição (correlação, IP, user-agent) vem de cabeçalhos repassados pelo Worker ao PostgREST.
-- Se a gravação da auditoria falhar, a mutação inteira falha (mesma transação).
-- ---------------------------------------------------------------------------------------------------------
create function app.audit_row() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_row jsonb; v_old jsonb; v_action text; v_org uuid; v_unit uuid; v_changed text[];
  h json; v_ip inet; v_corr text; v_ua text;
begin
  if tg_op = 'INSERT' then v_action := nullif(tg_argv[0], ''); v_row := to_jsonb(new);
  elsif tg_op = 'UPDATE' then v_action := nullif(tg_argv[1], ''); v_row := to_jsonb(new); v_old := to_jsonb(old);
  else v_action := nullif(tg_argv[5], ''); v_row := to_jsonb(old); end if;
  if v_action is null then return null; end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(n.key order by n.key), '{}') into v_changed
    from jsonb_each(v_row) n
    where n.key <> 'updated_at' and n.value is distinct from (v_old -> n.key);
    if cardinality(v_changed) = 0 then return null; end if;
  end if;

  v_org := coalesce(v_row ->> 'organization_id', case when tg_table_name = 'organizations' then v_row ->> 'id' end)::uuid;
  v_unit := case when tg_argv[4] <> '' then nullif(v_row ->> tg_argv[4], '')::uuid end;

  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  begin v_ip := nullif(h ->> 'x-client-ip', '')::inet; exception when others then v_ip := null; end;
  v_corr := left(nullif(h ->> 'x-correlation-id', ''), 100);
  v_ua := left(nullif(h ->> 'x-client-ua', ''), 300);

  insert into public.audit_logs (organization_id, unit_id, actor_id, action, resource_type, resource_id, result, ip, user_agent, correlation_id, metadata)
  values (v_org, v_unit, (select auth.uid()), v_action, tg_argv[2], v_row ->> tg_argv[3], 'success', v_ip, v_ua, v_corr,
          case when v_changed is null then '{}'::jsonb else jsonb_build_object('changed', to_jsonb(v_changed)) end);
  return null;
end $$;

create trigger organizations_audit after update on public.organizations
  for each row execute function app.audit_row('', 'organization.update', 'organization', 'id', '', '');
create trigger units_audit after insert or update on public.units
  for each row execute function app.audit_row('unit.create', 'unit.update', 'unit', 'id', 'id', '');
create trigger professionals_audit after insert or update on public.professionals
  for each row execute function app.audit_row('professional.create', 'professional.update', 'professional', 'id', '', '');
create trigger professional_units_audit after insert or delete on public.professional_units
  for each row execute function app.audit_row('professional.link_unit', '', 'professional', 'professional_id', 'unit_id', 'professional.unlink_unit');
create trigger rooms_audit after insert or update on public.rooms
  for each row execute function app.audit_row('room.create', 'room.update', 'room', 'id', 'unit_id', '');
create trigger equipment_audit after insert or update on public.equipment
  for each row execute function app.audit_row('equipment.create', 'equipment.update', 'equipment', 'id', 'unit_id', '');
create trigger services_audit after insert or update on public.services
  for each row execute function app.audit_row('service.create', 'service.update', 'service', 'id', '', '');
create trigger service_requirements_audit after insert or delete on public.service_resource_requirements
  for each row execute function app.audit_row('service.add_requirement', '', 'service', 'service_id', '', 'service.remove_requirement');
create trigger patients_audit after insert or update on public.patients
  for each row execute function app.audit_row('patient.create', 'patient.update', 'patient', 'id', '', '');
create trigger patient_consents_audit after insert on public.patient_consents
  for each row execute function app.audit_row('patient.consent', '', 'patient', 'patient_id', '', '');
create trigger patient_guardianships_audit after insert or update on public.patient_guardianships
  for each row execute function app.audit_row('patient.add_guardian', 'patient.revoke_guardian', 'guardianship', 'id', '', '');
create trigger role_assignments_audit after insert or update on public.user_role_assignments
  for each row execute function app.audit_row('role.assign', 'role.assignment_change', 'role_assignment', 'id', 'unit_id', '');
create trigger members_audit after update on public.organization_members
  for each row execute function app.audit_row('', 'member.update', 'member', 'id', '', '');

-- ---------------------------------------------------------------------------------------------------------
-- (c) Idempotência: tomada de chave presa e limpeza
-- ---------------------------------------------------------------------------------------------------------
alter table public.idempotency_keys add column locked_at timestamptz not null default now();
grant update (locked_at) on public.idempotency_keys to authenticated;

create function public.rpc_purge_idempotency(p_batch int default 5000) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if p_batch is null or p_batch not between 1 and 100000 then
    raise exception 'invalid batch' using errcode = '22023';
  end if;
  with d as (
    select id from public.idempotency_keys where expires_at < now() order by expires_at limit p_batch
  )
  delete from public.idempotency_keys k using d where k.id = d.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- (d) Versão da chave de HMAC do CPF
-- ---------------------------------------------------------------------------------------------------------
alter table public.patients add column cpf_key_version smallint not null default 1 check (cpf_key_version > 0);
grant insert (cpf_key_version) on public.patients to authenticated;
grant update (cpf_key_version) on public.patients to authenticated;

-- ---------------------------------------------------------------------------------------------------------
-- Privilégios: nada novo é executável por anon/authenticated (funções de trigger não precisam de EXECUTE)
-- ---------------------------------------------------------------------------------------------------------
revoke all on function app.other_owner_exists(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.lock_owners(uuid) from public, anon, authenticated;
revoke all on function app.guard_last_owner_assignment() from public, anon, authenticated;
revoke all on function app.guard_last_owner_member() from public, anon, authenticated;
revoke all on function app.audit_row() from public, anon, authenticated;
revoke all on function public.rpc_purge_idempotency(int) from public, anon, authenticated;
grant execute on function public.rpc_purge_idempotency(int) to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
