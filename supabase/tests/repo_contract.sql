-- Contrato banco x SupabaseRepo: executa, como usuário autenticado (RLS ativa), as mesmas operações/colunas
-- que apps/api/src/supabaseRepo.ts usa. Dados sintéticos, rollback proposital. Sucesso = 'TESTS_OK n'.
do $$
declare
  uo uuid := gen_random_uuid(); ur uuid := gen_random_uuid();
  org uuid; m_r uuid; role_recep uuid; u1 uuid; idem uuid; ctx jsonb;
  cnt int; n int := 0; v_status text; ok boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u::text || '@test.invalid', '', now(), now()
  from unnest(array[uo, ur]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Contrato');
  select id into role_recep from public.roles where organization_id = org and key = 'receptionist';
  insert into public.organization_members (organization_id, user_id) values (org, ur) returning id into m_r;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org, m_r, role_recep);

  perform set_config('request.jwt.claims', json_build_object('sub', uo, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- createUnit: insert (organization_id,name,timezone) + select das colunas devolvidas
  insert into public.units (organization_id, name, timezone) values (org, 'U Contrato', 'America/Bahia')
    returning id into u1;
  perform id, name, timezone, status, created_at, updated_at from public.units where id = u1;
  n := n + 1;
  -- updateUnit: name/timezone/status
  update public.units set name = 'U Renomeada', status = 'inactive' where organization_id = org and id = u1;
  get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL C1 updateUnit rows=%', cnt; end if; n := n + 1;
  -- updateOrganization: colunas permitidas
  update public.organizations set name = 'Clinica Nova', legal_name = 'Razao SA', cnpj = '12345678000199', timezone = 'America/Bahia' where id = org;
  get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL C2 updateOrganization rows=%', cnt; end if; n := n + 1;
  ok := false;
  begin update public.organizations set cnpj = '123' where id = org;
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'FAIL C3 cnpj check'; end if; n := n + 1;
  -- writeAudit: ip vazio e ip válido
  perform public.rpc_write_audit(org, u1, 'unit.update', 'unit', u1::text, 'success', '', null, 'corr-00000001', '{}'::jsonb);
  perform public.rpc_write_audit(org, null, 'organization.update', 'organization', org::text, 'success', '203.0.113.9', 'agent', 'corr-00000002', '{}'::jsonb);
  select count(*) into cnt from public.audit_logs where organization_id = org and correlation_id like 'corr-%';
  if cnt <> 2 then raise exception 'FAIL C4 audit rows=%', cnt; end if; n := n + 1;
  -- listAudit: colunas + ordenação + paginação por id
  perform id, at, organization_id, unit_id, actor_id, action, resource_type, resource_id, result, correlation_id
    from public.audit_logs where organization_id = org order by id desc limit 50;
  n := n + 1;
  -- rpc_my_context: forma esperada pelo Worker
  ctx := public.rpc_my_context();
  if jsonb_typeof(ctx) <> 'array' or (ctx -> 0 ->> 'organization_id')::uuid <> org
     or jsonb_typeof(ctx -> 0 -> 'unit_scopes') <> 'array' or (ctx -> 0 ->> 'member_id') is null then
    raise exception 'FAIL C5 ctx shape %', ctx; end if; n := n + 1;

  -- idempotência: begin (insert + select id), duplicado 23505, complete, fail, restart condicional
  insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash)
    values (org, uo, 'units.create', 'key-contract-1', 'hash1') returning id into idem;
  ok := false;
  begin insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash) values (org, uo, 'units.create', 'key-contract-1', 'hash1');
  exception when unique_violation then ok := true; end;
  if not ok then raise exception 'FAIL C6 duplicate key'; end if; n := n + 1;
  perform id, request_hash, status, response_status, response_body from public.idempotency_keys
    where organization_id = org and scope = 'units.create' and key = 'key-contract-1';
  update public.idempotency_keys set status = 'completed', response_status = 201, response_body = '{"id":"x"}'::jsonb where id = idem;
  select status into v_status from public.idempotency_keys where id = idem;
  if v_status <> 'completed' then raise exception 'FAIL C7 complete'; end if; n := n + 1;
  update public.idempotency_keys set status = 'processing' where id = idem and status = 'failed';
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL C8 restart must not reopen completed rows=%', cnt; end if; n := n + 1;
  update public.idempotency_keys set status = 'failed' where id = idem;
  update public.idempotency_keys set status = 'processing' where id = idem and status = 'failed';
  get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL C9 restart failed->processing rows=%', cnt; end if; n := n + 1;
  -- usuário não pode forjar a identidade da chave nem alterar campos fora da concessão
  ok := false;
  begin update public.idempotency_keys set request_hash = 'forged' where id = idem;
  exception when insufficient_privilege then ok := true; end;
  if not ok then raise exception 'FAIL C10 hash tamper'; end if; n := n + 1;
  execute 'reset role';

  -- recepcionista: updateOrganization/updateUnit retornam 0 linhas (Worker responde 404/403), nunca altera
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  update public.organizations set name = 'Hack' where id = org;
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL C11 receptionist org update rows=%', cnt; end if; n := n + 1;
  update public.units set name = 'Hack' where id = u1;
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL C12 receptionist unit update rows=%', cnt; end if; n := n + 1;
  execute 'reset role';

  raise exception 'TESTS_OK %', n;
end $$;
