-- Teste de isolamento/permissões 1A. Dados sintéticos, tudo dentro de uma transação que termina em erro
-- proposital (rollback). Sucesso = exceção 'TESTS_OK n'. Falha = exceção 'FAIL Tx'.
do $$
declare
  ua1 uuid := gen_random_uuid(); ua2 uuid := gen_random_uuid(); ua3 uuid := gen_random_uuid();
  ua4 uuid := gen_random_uuid(); ub1 uuid := gen_random_uuid(); ux uuid := gen_random_uuid();
  org_a uuid; org_b uuid; unit_a1 uuid; unit_a2 uuid; unit_b uuid;
  m1 uuid; m2 uuid; m3 uuid; m4 uuid;
  role_recep uuid; role_owner uuid; role_unitmgr uuid; role_custom uuid; role_b_recep uuid;
  cnt int; ok boolean; n int := 0; r1 boolean; r2 boolean; r3 boolean; ctx jsonb;
begin
  -- ===== setup como postgres =====
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u::text || '@test.invalid', '', now(), now()
  from unnest(array[ua1, ua2, ua3, ua4, ub1, ux]) u;
  org_a := public.rpc_provision_organization(ua1, 'Clinica A');
  org_b := public.rpc_provision_organization(ub1, 'Clinica B');
  select id into m1 from public.organization_members where organization_id = org_a and user_id = ua1;
  select id into role_recep from public.roles where organization_id = org_a and key = 'receptionist';
  select id into role_owner from public.roles where organization_id = org_a and key = 'owner';
  select id into role_unitmgr from public.roles where organization_id = org_a and key = 'unit_manager';
  select id into role_b_recep from public.roles where organization_id = org_b and key = 'receptionist';
  insert into public.organization_members (organization_id, user_id) values (org_a, ua2) returning id into m2;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org_a, m2, role_recep);
  insert into public.roles (organization_id, key, name) values (org_a, 'custom_mgr', 'Custom') returning id into role_custom;
  insert into public.role_permissions (organization_id, role_id, permission_key)
    values (org_a, role_custom, 'member.manage'), (org_a, role_custom, 'member.read'), (org_a, role_custom, 'org.read');
  insert into public.organization_members (organization_id, user_id) values (org_a, ua3) returning id into m3;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org_a, m3, role_custom);
  insert into public.organization_members (organization_id, user_id) values (org_a, ua4) returning id into m4;

  -- ===== criação de unidades pelos próprios donos (via RLS) =====
  perform set_config('request.jwt.claims', json_build_object('sub', ua1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into public.units (organization_id, name) values (org_a, 'Unidade A1') returning id into unit_a1;
  insert into public.units (organization_id, name) values (org_a, 'Unidade A2') returning id into unit_a2;
  insert into public.user_role_assignments (organization_id, member_id, role_id, unit_id) values (org_a, m4, role_unitmgr, unit_a1);
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', ub1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into public.units (organization_id, name) values (org_b, 'Unidade B') returning id into unit_b;
  execute 'reset role';

  -- T1: owner A enxerga só A
  perform set_config('request.jwt.claims', json_build_object('sub', ua1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into cnt from public.organizations;
  if cnt <> 1 then raise exception 'FAIL T1a orgs=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.units;
  if cnt <> 2 then raise exception 'FAIL T1b units=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.organization_members;
  if cnt <> 4 then raise exception 'FAIL T1c members=%', cnt; end if; n := n + 1;
  -- T3: inserir unidade em outra org
  ok := false;
  begin insert into public.units (organization_id, name) values (org_b, 'Invasora');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T3 insert cross-org'; end if; n := n + 1;
  -- T4: update cross-org
  update public.units set name = 'hack' where id = unit_b;
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL T4 update cross-org rows=%', cnt; end if; n := n + 1;
  -- T12: status da organização não editável
  ok := false;
  begin update public.organizations set status = 'suspended' where id = org_a;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T12 status update'; end if; n := n + 1;
  -- T11: papéis de sistema imutáveis
  update public.roles set name = 'x' where id = role_owner;
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL T11a system role update rows=%', cnt; end if; n := n + 1;
  ok := false;
  begin insert into public.role_permissions (organization_id, role_id, permission_key) values (org_a, role_recep, 'audit.read');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T11b system role perm insert'; end if; n := n + 1;
  -- delete de unidade não permitido
  ok := false;
  begin delete from public.units where id = unit_a2;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T11c unit delete'; end if; n := n + 1;
  -- T7: owner lê auditoria (>=1 do provisionamento)
  select count(*) into cnt from public.audit_logs;
  if cnt < 1 then raise exception 'FAIL T7a owner audit=%', cnt; end if; n := n + 1;
  -- T16: auditoria em org alheia bloqueada; na própria permitida
  ok := false;
  begin perform public.rpc_write_audit(org_b, null, 'x', 'unit', 'y', 'success', null, null, 'c1', '{}'::jsonb);
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T16a audit cross-org'; end if; n := n + 1;
  perform public.rpc_write_audit(org_a, unit_a1, 'unit.update', 'unit', unit_a1::text, 'success', '203.0.113.5', 'ua', 'c2', '{}'::jsonb);
  n := n + 1;
  -- T8a: sem grant de update/delete em auditoria
  ok := false;
  begin update public.audit_logs set action = 'forged';
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T8a audit update by user'; end if; n := n + 1;
  ok := false;
  begin delete from public.audit_logs;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T8b audit delete by user'; end if; n := n + 1;
  -- T15: idempotência
  insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash) values (org_a, ua1, 'booking', 'k1', 'h');
  ok := false;
  begin insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash) values (org_a, ua1, 'booking', 'k1', 'h2');
  exception when unique_violation then ok := true; end;
  if not ok then raise exception 'FAIL T15a duplicate idempotency key'; end if; n := n + 1;
  ok := false;
  begin insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash) values (org_a, ua2, 'booking', 'k2', 'h');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T15b idempotency as other user'; end if; n := n + 1;
  -- T20: usuário não provisiona organização
  ok := false;
  begin perform public.rpc_provision_organization(ua1, 'Hack Org');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T20 provision by user'; end if; n := n + 1;
  -- T14b: usuário não chama rate limit
  ok := false;
  begin perform public.rpc_rate_limit_hit('x', 60, 1);
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T14b rate limit by user'; end if; n := n + 1;
  -- T18a: contexto do owner
  ctx := public.rpc_my_context();
  if not ((ctx -> 0 -> 'permissions') ? 'org.manage') then raise exception 'FAIL T18a ctx=%', ctx; end if; n := n + 1;
  execute 'reset role';

  -- T2: owner B não enxerga A (IDOR)
  perform set_config('request.jwt.claims', json_build_object('sub', ub1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into cnt from public.units where organization_id = org_a;
  if cnt <> 0 then raise exception 'FAIL T2a units A visible to B=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.organization_members where organization_id = org_a;
  if cnt <> 0 then raise exception 'FAIL T2b members A visible to B=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.audit_logs where organization_id = org_a;
  if cnt <> 0 then raise exception 'FAIL T2c audit A visible to B=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.roles where organization_id = org_a;
  if cnt <> 0 then raise exception 'FAIL T2d roles A visible to B=%', cnt; end if; n := n + 1;
  ok := false;
  begin insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash) values (org_a, ub1, 'booking', 'kb', 'h');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T2e idempotency cross-org'; end if; n := n + 1;
  execute 'reset role';

  -- T5: usuário sem vínculo não vê nada
  perform set_config('request.jwt.claims', json_build_object('sub', ux, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select (select count(*) from public.organizations) + (select count(*) from public.units)
       + (select count(*) from public.organization_members) + (select count(*) from public.audit_logs)
       + (select count(*) from public.roles) + (select count(*) from public.user_role_assignments) into cnt;
  if cnt <> 0 then raise exception 'FAIL T5 outsider sees %', cnt; end if; n := n + 1;
  execute 'reset role';

  -- T6/T7b: recepcionista
  perform set_config('request.jwt.claims', json_build_object('sub', ua2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  ok := false;
  begin insert into public.units (organization_id, name) values (org_a, 'Nao pode');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T6a receptionist unit insert'; end if; n := n + 1;
  select count(*) into cnt from public.units;
  if cnt <> 2 then raise exception 'FAIL T6b receptionist units=%', cnt; end if; n := n + 1;
  select count(*) into cnt from public.audit_logs;
  if cnt <> 0 then raise exception 'FAIL T7b receptionist audit=%', cnt; end if; n := n + 1;
  ok := false;
  begin insert into public.user_role_assignments (organization_id, member_id, role_id) values (org_a, m2, role_owner);
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T9a receptionist self-promote'; end if; n := n + 1;
  execute 'reset role';

  -- T9: escalada de privilégio por quem tem member.manage mas não tem todas as permissões do papel
  perform set_config('request.jwt.claims', json_build_object('sub', ua3, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  ok := false;
  begin insert into public.user_role_assignments (organization_id, member_id, role_id) values (org_a, m3, role_owner);
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T9b escalation to owner'; end if; n := n + 1;
  ok := false;
  begin update public.organization_members set status = 'suspended' where id = m1;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T9c suspend owner'; end if; n := n + 1;
  ok := false;
  begin update public.user_role_assignments set revoked_at = now() where member_id = m1;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T9d revoke owner assignment'; end if; n := n + 1;
  execute 'reset role';

  -- T13/T18b: escopo por unidade
  perform set_config('request.jwt.claims', json_build_object('sub', ua4, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into cnt from public.units;
  if cnt <> 1 then raise exception 'FAIL T13a unit-scoped sees %', cnt; end if; n := n + 1;
  update public.units set name = 'A1 renomeada' where id = unit_a1;
  get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL T13b update own unit rows=%', cnt; end if; n := n + 1;
  update public.units set name = 'hack' where id = unit_a2;
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL T13c update other unit rows=%', cnt; end if; n := n + 1;
  ok := false;
  begin insert into public.units (organization_id, name) values (org_a, 'Nova');
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T13d unit-scoped create unit'; end if; n := n + 1;
  ctx := public.rpc_my_context();
  if jsonb_array_length(ctx -> 0 -> 'unit_scopes') <> 1 or jsonb_array_length(ctx -> 0 -> 'permissions') <> 0 then
    raise exception 'FAIL T18b ctx=%', ctx; end if; n := n + 1;
  execute 'reset role';

  -- T10: anon sem acesso
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  ok := false;
  begin perform count(*) from public.organizations;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T10 anon read'; end if; n := n + 1;
  execute 'reset role';

  -- T8c: auditoria imutável até para o dono do banco (trigger)
  ok := false;
  begin update public.audit_logs set action = 'forged';
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T8c audit update by owner'; end if; n := n + 1;
  ok := false;
  begin delete from public.audit_logs;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL T8d audit delete by owner'; end if; n := n + 1;

  -- T14a: rate limit via service_role
  execute 'set local role service_role';
  r1 := public.rpc_rate_limit_hit('t-bucket', 3600, 2);
  r2 := public.rpc_rate_limit_hit('t-bucket', 3600, 2);
  r3 := public.rpc_rate_limit_hit('t-bucket', 3600, 2);
  execute 'reset role';
  if not (r1 and r2 and not r3) then raise exception 'FAIL T14a rate limit % % %', r1, r2, r3; end if; n := n + 1;

  -- T17: FKs compostas impedem mistura entre organizações
  ok := false;
  begin insert into public.user_role_assignments (organization_id, member_id, role_id) values (org_a, m2, role_b_recep);
  exception when foreign_key_violation then ok := true; end;
  if not ok then raise exception 'FAIL T17 composite FK'; end if; n := n + 1;

  -- T19: organização suspensa perde acesso
  update public.organizations set status = 'suspended' where id = org_b;
  perform set_config('request.jwt.claims', json_build_object('sub', ub1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select (select count(*) from public.organizations) + (select count(*) from public.units) into cnt;
  execute 'reset role';
  if cnt <> 0 then raise exception 'FAIL T19 suspended org visible=%', cnt; end if; n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
