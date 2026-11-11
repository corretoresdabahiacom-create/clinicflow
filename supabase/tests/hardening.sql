-- 1H: endurecimento. Último proprietário, auditoria transacional por trigger, idempotência, versão da chave de CPF.
-- Dados sintéticos; rollback proposital. Sucesso = 'TESTS_OK n'.
create function pg_temp.st(q text) returns text language plpgsql as $$
begin execute q; return 'OK'; exception when others then return sqlstate; end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

do $$
declare
  uo uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); ur uuid := gen_random_uuid();
  org uuid; m1 uuid; m2 uuid; mr uuid; role_owner uuid; role_recep uuid; a1 uuid; a2 uuid; ar uuid;
  unit1 uuid; pat uuid; idem uuid; cnt int; n int := 0; s text; meta jsonb; aud record; purged int;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now()
  from unnest(array[uo, u2, ur]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Endurecimento');
  select id into role_owner from public.roles where organization_id = org and key = 'owner';
  select id into role_recep from public.roles where organization_id = org and key = 'receptionist';
  select id into m1 from public.organization_members where organization_id = org and user_id = uo;
  select id into a1 from public.user_role_assignments where organization_id = org and member_id = m1 and role_id = role_owner;
  insert into public.organization_members (organization_id, user_id) values (org, ur) returning id into mr;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org, mr, role_recep) returning id into ar;

  -- ============ (a) Último proprietário ============
  perform pg_temp.as_user(uo);
  s := pg_temp.st(format('update public.user_role_assignments set revoked_at = now() where id = %L', a1));
  if s <> 'CF409' then raise exception 'FAIL H1 revogar unico owner: %', s; end if; n := n + 1;
  s := pg_temp.st(format('update public.user_role_assignments set valid_to = now() where id = %L', a1));
  if s <> 'CF409' and s <> '23514' then raise exception 'FAIL H2 expirar unico owner: %', s; end if; n := n + 1;
  s := pg_temp.st(format('update public.organization_members set status = %L where id = %L', 'suspended', m1));
  if s <> 'CF409' then raise exception 'FAIL H3 suspender unico owner: %', s; end if; n := n + 1;
  -- revogar uma recepcionista continua permitido
  s := pg_temp.st(format('update public.user_role_assignments set revoked_at = now() where id = %L', ar));
  if s <> 'OK' then raise exception 'FAIL H4 revogar nao-owner: %', s; end if; n := n + 1;
  s := pg_temp.st(format('update public.organization_members set status = %L where id = %L', 'suspended', mr));
  if s <> 'OK' then raise exception 'FAIL H5 suspender nao-owner: %', s; end if; n := n + 1;

  -- com um segundo owner ativo, o primeiro pode ser revogado; o segundo passa a ser o último
  insert into public.organization_members (organization_id, user_id) values (org, u2) returning id into m2;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org, m2, role_owner) returning id into a2;
  s := pg_temp.st(format('update public.user_role_assignments set revoked_at = now() where id = %L', a1));
  if s <> 'OK' then raise exception 'FAIL H6 revogar owner com substituto: %', s; end if; n := n + 1;
  perform pg_temp.as_user(u2);
  s := pg_temp.st(format('update public.user_role_assignments set revoked_at = now() where id = %L', a2));
  if s <> 'CF409' then raise exception 'FAIL H7 novo ultimo owner: %', s; end if; n := n + 1;
  s := pg_temp.st(format('update public.organization_members set status = %L where id = %L', 'revoked', m2));
  if s <> 'CF409' then raise exception 'FAIL H8 revogar membro ultimo owner: %', s; end if; n := n + 1;
  -- vale também para o provisionamento (sem JWT de usuário): service_role não remove o último owner
  execute 'reset role';
  s := pg_temp.st(format('delete from public.user_role_assignments where id = %L', a2));
  if s <> 'CF409' then raise exception 'FAIL H9 delete do ultimo owner: %', s; end if; n := n + 1;

  -- ============ (b) Auditoria transacional ============
  perform pg_temp.as_user(u2);
  perform set_config('request.headers', json_build_object('x-correlation-id', 'corr-hard-001', 'x-client-ip', '203.0.113.7',
                                                          'x-client-ua', 'ua-teste')::text, true);
  insert into public.units (organization_id, name, timezone) values (org, 'Unidade Audit', 'America/Bahia') returning id into unit1;
  select * into aud from public.audit_logs where organization_id = org and action = 'unit.create' and resource_id = unit1::text;
  if aud.id is null or aud.correlation_id <> 'corr-hard-001' or host(aud.ip) <> '203.0.113.7' or aud.user_agent <> 'ua-teste'
     or aud.actor_id <> u2 or aud.unit_id <> unit1 or aud.result <> 'success' then
    raise exception 'FAIL H10 audit unit.create %', to_jsonb(aud); end if; n := n + 1;

  update public.units set name = 'Nome Secreto Novo' where id = unit1;
  select * into aud from public.audit_logs where organization_id = org and action = 'unit.update' and resource_id = unit1::text;
  if aud.id is null or aud.metadata -> 'changed' <> '["name"]'::jsonb then raise exception 'FAIL H11 audit update %', to_jsonb(aud); end if; n := n + 1;
  if aud.metadata::text like '%Secreto%' then raise exception 'FAIL H12 valor vazou na auditoria'; end if; n := n + 1;

  -- update sem mudança real não gera ruído
  select count(*) into cnt from public.audit_logs where organization_id = org and action = 'unit.update';
  update public.units set name = name where id = unit1;
  if (select count(*) from public.audit_logs where organization_id = org and action = 'unit.update') <> cnt then
    raise exception 'FAIL H13 update sem mudanca auditado'; end if; n := n + 1;

  -- paciente: ação auditada, sem PII (hash/máscara/nome) nos metadados
  insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked)
    values (org, 'Paciente Sintetico', date '1990-01-01', lpad('a', 64, 'a'), '***.***.***-00') returning id into pat;
  select * into aud from public.audit_logs where organization_id = org and action = 'patient.create' and resource_id = pat::text;
  if aud.id is null or aud.resource_type <> 'patient' then raise exception 'FAIL H14 audit patient.create'; end if; n := n + 1;
  update public.patients set cpf_hash = lpad('b', 64, 'b'), cpf_masked = '***.***.***-11', full_name = 'Outro Nome' where id = pat;
  select * into aud from public.audit_logs where organization_id = org and action = 'patient.update' and resource_id = pat::text;
  if aud.metadata::text ~ 'aaaa|bbbb|Outro|Sintetico|\*\*\*' then raise exception 'FAIL H15 PII na auditoria %', aud.metadata; end if; n := n + 1;
  if aud.metadata -> 'changed' <> '["cpf_hash","cpf_masked","full_name"]'::jsonb then raise exception 'FAIL H16 changed %', aud.metadata; end if; n := n + 1;

  -- transacional: se a mutação falha, nenhuma auditoria sobra; auditoria não pode ser alterada nem apagada
  select count(*) into cnt from public.audit_logs where organization_id = org;
  s := pg_temp.st(format('update public.organizations set cnpj = %L where id = %L', '123', org));
  if s <> '23514' then raise exception 'FAIL H17 cnpj invalido: %', s; end if; n := n + 1;
  if (select count(*) from public.audit_logs where organization_id = org) <> cnt then raise exception 'FAIL H18 audit de mutacao falha'; end if; n := n + 1;
  execute 'reset role';
  s := pg_temp.st(format('update public.audit_logs set action = %L where organization_id = %L', 'x', org));
  if s <> '42501' then raise exception 'FAIL H19 audit mutavel: %', s; end if; n := n + 1;
  -- atribuições de papel também são auditadas
  if not exists (select 1 from public.audit_logs where organization_id = org and action = 'role.assignment_change' and resource_id = a1::text) then
    raise exception 'FAIL H20 audit de revogacao de papel'; end if; n := n + 1;

  -- usuário comum não consegue executar as funções internas
  perform pg_temp.as_user(u2);
  s := pg_temp.st(format('select app.audit_row()'));
  if s = 'OK' then raise exception 'FAIL H21 audit_row executavel'; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_purge_idempotency(10)'));
  if s <> '42501' then raise exception 'FAIL H22 purge por usuario: %', s; end if; n := n + 1;

  -- ============ (c) Idempotência ============
  insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash)
    values (org, u2, 'units.create', 'key-hard-0001', 'h1') returning id into idem;
  -- chave recém-criada em 'processing' NÃO pode ser tomada
  update public.idempotency_keys set locked_at = now() where id = idem and status = 'processing' and locked_at < now() - interval '2 minutes';
  get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL H23 tomada precoce rows=%', cnt; end if; n := n + 1;
  -- depois do prazo, pode
  update public.idempotency_keys set locked_at = now() - interval '5 minutes' where id = idem;
  update public.idempotency_keys set locked_at = now() where id = idem and status = 'processing' and locked_at < now() - interval '2 minutes';
  get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL H24 tomada apos prazo rows=%', cnt; end if; n := n + 1;

  execute 'reset role';
  insert into public.idempotency_keys (organization_id, user_id, scope, key, request_hash, expires_at)
    select org, u2, 'units.create', 'key-old-' || g, 'h', now() - interval '1 day' from generate_series(1, 7) g;
  select public.rpc_purge_idempotency(5) into purged;
  if purged <> 5 then raise exception 'FAIL H25 purge em lote purged=%', purged; end if; n := n + 1;
  select public.rpc_purge_idempotency(100) into purged;
  if purged <> 2 then raise exception 'FAIL H26 purge restante purged=%', purged; end if; n := n + 1;
  if not exists (select 1 from public.idempotency_keys where id = idem) then raise exception 'FAIL H27 purge apagou chave valida'; end if; n := n + 1;
  s := pg_temp.st('select public.rpc_purge_idempotency(0)');
  if s <> '22023' then raise exception 'FAIL H28 lote invalido: %', s; end if; n := n + 1;

  -- ============ (d) Versão da chave de CPF ============
  if (select cpf_key_version from public.patients where id = pat) <> 1 then raise exception 'FAIL H29 default cpf_key_version'; end if; n := n + 1;
  perform pg_temp.as_user(u2);
  update public.patients set cpf_key_version = 2 where id = pat;
  if (select cpf_key_version from public.patients where id = pat) <> 2 then raise exception 'FAIL H30 set cpf_key_version'; end if; n := n + 1;
  s := pg_temp.st(format('update public.patients set cpf_key_version = 0 where id = %L', pat));
  if s <> '23514' then raise exception 'FAIL H31 cpf_key_version invalida: %', s; end if; n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
