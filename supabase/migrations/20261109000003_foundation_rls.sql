-- 1A / migration 3: RLS, grants mínimos e catálogo de permissões
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, public;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated, public;
revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;

insert into public.permissions (key, description) values
  ('org.read', 'Ver dados da organização'),
  ('org.manage', 'Editar dados da organização'),
  ('unit.read', 'Ver unidades'),
  ('unit.write', 'Criar e editar unidades'),
  ('member.read', 'Ver membros e atribuições'),
  ('member.manage', 'Gerenciar membros e atribuições'),
  ('role.read', 'Ver papéis e permissões'),
  ('role.manage', 'Gerenciar papéis personalizados'),
  ('audit.read', 'Ler logs de auditoria');

do $$ declare t text; begin
  foreach t in array array['organizations','units','organization_members','permissions','roles','role_permissions',
    'user_role_assignments','audit_logs','feature_flags','idempotency_keys','rate_limits'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- organizations
create policy org_select on public.organizations for select to authenticated using (app.is_member(id));
create policy org_update on public.organizations for update to authenticated
  using (app.has_perm(id, 'org.manage')) with check (app.has_perm(id, 'org.manage'));
grant select on public.organizations to authenticated;
grant update (name, legal_name, cnpj, timezone) on public.organizations to authenticated;

-- units
create policy units_select on public.units for select to authenticated using (app.has_perm(organization_id, 'unit.read', id));
create policy units_insert on public.units for insert to authenticated with check (app.has_perm(organization_id, 'unit.write'));
create policy units_update on public.units for update to authenticated
  using (app.has_perm(organization_id, 'unit.write', id)) with check (app.has_perm(organization_id, 'unit.write', id));
grant select, insert (organization_id, name, timezone) on public.units to authenticated;
grant update (name, timezone, status) on public.units to authenticated;

-- organization_members
create policy members_select on public.organization_members for select to authenticated
  using (user_id = (select auth.uid()) or app.has_perm(organization_id, 'member.read'));
create policy members_insert on public.organization_members for insert to authenticated
  with check (app.has_perm(organization_id, 'member.manage'));
create policy members_update on public.organization_members for update to authenticated
  using (app.has_perm(organization_id, 'member.manage')) with check (app.has_perm(organization_id, 'member.manage'));
grant select, insert (organization_id, user_id) on public.organization_members to authenticated;
grant update (status) on public.organization_members to authenticated;

-- permissions (catálogo global)
create policy permissions_select on public.permissions for select to authenticated using (true);
grant select on public.permissions to authenticated;

-- roles
create policy roles_select on public.roles for select to authenticated using (app.has_perm(organization_id, 'role.read'));
create policy roles_insert on public.roles for insert to authenticated
  with check (app.has_perm(organization_id, 'role.manage') and is_system = false);
create policy roles_update on public.roles for update to authenticated
  using (app.has_perm(organization_id, 'role.manage') and is_system = false)
  with check (app.has_perm(organization_id, 'role.manage') and is_system = false);
grant select, insert (organization_id, key, name) on public.roles to authenticated;
grant update (name) on public.roles to authenticated;

-- role_permissions
create policy rp_select on public.role_permissions for select to authenticated using (app.has_perm(organization_id, 'role.read'));
create policy rp_insert on public.role_permissions for insert to authenticated with check (app.has_perm(organization_id, 'role.manage'));
create policy rp_delete on public.role_permissions for delete to authenticated using (app.has_perm(organization_id, 'role.manage'));
grant select, insert, delete on public.role_permissions to authenticated;

-- user_role_assignments
create policy ura_select on public.user_role_assignments for select to authenticated
  using (app.has_perm(organization_id, 'member.read')
    or exists (select 1 from public.organization_members m
               where m.id = member_id and m.organization_id = user_role_assignments.organization_id and m.user_id = (select auth.uid())));
create policy ura_insert on public.user_role_assignments for insert to authenticated with check (app.has_perm(organization_id, 'member.manage'));
create policy ura_update on public.user_role_assignments for update to authenticated
  using (app.has_perm(organization_id, 'member.manage')) with check (app.has_perm(organization_id, 'member.manage'));
grant select, insert (organization_id, member_id, role_id, unit_id, valid_from, valid_to, created_by) on public.user_role_assignments to authenticated;
grant update (valid_to, revoked_at) on public.user_role_assignments to authenticated;

-- audit_logs: leitura por audit.read; escrita apenas via rpc_write_audit
create policy audit_select on public.audit_logs for select to authenticated using (app.has_perm(organization_id, 'audit.read'));
grant select on public.audit_logs to authenticated;

-- feature_flags: leitura; escrita só service_role
create policy flags_select on public.feature_flags for select to authenticated
  using (organization_id is null or app.is_member(organization_id));
grant select on public.feature_flags to authenticated;

-- idempotency_keys: do próprio usuário na própria organização
create policy idem_select on public.idempotency_keys for select to authenticated
  using (user_id = (select auth.uid()) and app.is_member(organization_id));
create policy idem_insert on public.idempotency_keys for insert to authenticated
  with check (user_id = (select auth.uid()) and app.is_member(organization_id));
create policy idem_update on public.idempotency_keys for update to authenticated
  using (user_id = (select auth.uid()) and app.is_member(organization_id))
  with check (user_id = (select auth.uid()) and app.is_member(organization_id));
grant select, insert (organization_id, user_id, scope, key, request_hash) on public.idempotency_keys to authenticated;
grant update (status, response_status, response_body) on public.idempotency_keys to authenticated;

-- rate_limits: sem políticas e sem grants (somente via rpc_rate_limit_hit)

-- RPCs
grant execute on function public.rpc_provision_organization(uuid, text, text) to service_role;
grant execute on function public.rpc_rate_limit_hit(text, int, int) to service_role;
grant execute on function public.rpc_write_audit(uuid, uuid, text, text, text, text, text, text, text, jsonb) to authenticated, service_role;
grant execute on function public.rpc_my_context() to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
