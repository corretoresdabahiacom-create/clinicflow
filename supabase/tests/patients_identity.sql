-- 1C: pacientes, identidade, responsáveis, vínculo de conta, consentimentos e check-in. Sintético; rollback proposital.
create function pg_temp.st(q text) returns text language plpgsql as $$
begin execute q; return 'OK'; exception when others then return sqlstate; end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.h(i int) returns text language sql as $$ select lpad(to_hex(i), 64, '0') $$;

do $$
declare
  uo uuid := gen_random_uuid(); ur uuid := gen_random_uuid(); ud uuid := gen_random_uuid(); ux uuid := gen_random_uuid();
  up uuid := gen_random_uuid(); uq uuid := gen_random_uuid(); urA uuid := gen_random_uuid(); ufn uuid := gen_random_uuid();
  org uuid; org2 uuid; mr uuid; md uuid; mrA uuid; mf uuid; rr uuid; rd uuid; rf uuid; uA uuid; uB uuid;
  p1 uuid; p2 uuid; p3 uuid; px uuid; dep uuid; prof uuid; rm uuid; svc uuid; res jsonb;
  ev uuid; ev_early uuid; ev_nopat uuid; ev_cancel uuid; ev_r uuid; link1 uuid; g1 uuid; cnt int; n int := 0; s text;
  now0 timestamptz := date_trunc('hour', now()) + interval '1 hour';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now()
  from unnest(array[uo, ur, ud, ux, up, uq, urA, ufn]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Pacientes');
  org2 := public.rpc_provision_organization(ux, 'Clinica Outra');
  select id into rr from public.roles where organization_id = org and key = 'receptionist';
  select id into rd from public.roles where organization_id = org and key = 'doctor';
  select id into rf from public.roles where organization_id = org and key = 'finance';
  insert into public.organization_members (organization_id, user_id) values (org, ur) returning id into mr;
  insert into public.organization_members (organization_id, user_id) values (org, ud) returning id into md;
  insert into public.organization_members (organization_id, user_id) values (org, urA) returning id into mrA;
  insert into public.organization_members (organization_id, user_id) values (org, ufn) returning id into mf;
  insert into public.units (organization_id, name) values (org, 'Unidade A') returning id into uA;
  insert into public.units (organization_id, name) values (org, 'Unidade B') returning id into uB;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org, mr, rr), (org, md, rd), (org, mf, rf);
  insert into public.user_role_assignments (organization_id, member_id, role_id, unit_id) values (org, mrA, rr, uA);  -- recepção só da unidade A

  -- cadastros de apoio da agenda
  perform pg_temp.as_user(uo);
  insert into public.professionals (organization_id, full_name) values (org, 'Dra. Teste') returning id into prof;
  insert into public.professional_units values (org, prof, uA);
  insert into public.rooms (organization_id, unit_id, name) values (org, uA, 'Sala 1') returning id into rm;
  insert into public.services (organization_id, name, kind, duration_minutes) values (org, 'Consulta', 'consultation', 30) returning id into svc;
  res := jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',rm));

  -- P1 permissões do catálogo
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
    where r.organization_id = org and r.key = 'receptionist' and rp.permission_key in ('patient.read','patient.write','checkin.write');
  if cnt <> 3 then raise exception 'FAIL P1 receptionist perms %', cnt; end if;
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
    where r.organization_id = org and r.key in ('doctor','nurse','exam_tech','finance','auditor') and rp.permission_key like 'patient.%';
  if cnt <> 0 then raise exception 'FAIL P1 clinical roles must not read patients yet'; end if; n := n + 1;

  -- P2 recepção (inclusive restrita à unidade A) cadastra; demais papéis não leem nem escrevem
  perform pg_temp.as_user(urA);
  insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked, phone, email)
    values (org, 'Paciente Um', '1990-05-10', pg_temp.h(1), '***.***.***-01', '71999990001', 'um@test.invalid') returning id into p1;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Paciente Dois', '1985-01-01') returning id into p2;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Menor Dependente', '2018-03-03') returning id into dep;
  perform id from public.patients where id = p1;
  select count(*) into cnt from public.patients; if cnt <> 3 then raise exception 'FAIL P2 reads %', cnt; end if;
  select created_by into px from public.patients where id = p1;
  if px <> urA then raise exception 'FAIL P2 created_by'; end if; n := n + 1;
  foreach px in array array[ud, ufn, uq] loop
    perform pg_temp.as_user(px);
    select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL P2 role sees patients (%)', px; end if;
    if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date) values (%L,'Invasor','2000-01-01')$q$, org)) <> '42501' then
      raise exception 'FAIL P2 insert by non-staff'; end if;
  end loop;
  perform pg_temp.as_user(ux);
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL P2 outsider sees patients'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date) values (%L,'Invasor','2000-01-01')$q$, org)) <> '42501' then
    raise exception 'FAIL P2 cross-org insert'; end if; n := n + 1;

  -- P3 integridade: CPF único por organização (hash), data/telefone/e-mail, colunas protegidas
  perform pg_temp.as_user(ur);
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked) values (%L,'Duplicado','1990-05-10',%L,'***.***.***-01')$q$, org, pg_temp.h(1))) <> '23505' then
    raise exception 'FAIL P3 duplicate cpf'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date, cpf_hash) values (%L,'Sem mascara','1990-05-10',%L)$q$, org, pg_temp.h(9))) <> '23514' then
    raise exception 'FAIL P3 hash without mask'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked) values (%L,'Mascara ruim','1990-05-10',%L,'123.456.789-01')$q$, org, pg_temp.h(8))) <> '23514' then
    raise exception 'FAIL P3 clear cpf in masked column'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date) values (%L,'Futuro',current_date + 1)$q$, org)) <> '23514' then raise exception 'FAIL P3 future birth'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date, phone) values (%L,'Fone','2000-01-01','abc')$q$, org)) <> '23514' then raise exception 'FAIL P3 phone'; end if;
  if pg_temp.st(format($q$insert into public.patients (organization_id, full_name, birth_date, email) values (%L,'Mail','2000-01-01','sem-arroba')$q$, org)) <> '23514' then raise exception 'FAIL P3 email'; end if;
  if pg_temp.st(format($q$update public.patients set created_by = %L where id = %L$q$, ur, p1)) <> '42501' then raise exception 'FAIL P3 created_by tamper'; end if;
  if pg_temp.st(format($q$update public.patients set organization_id = %L where id = %L$q$, org2, p1)) <> '42501' then raise exception 'FAIL P3 org tamper'; end if;
  if pg_temp.st(format($q$delete from public.patients where id = %L$q$, p1)) <> '42501' then raise exception 'FAIL P3 delete'; end if;
  update public.patients set phone = '71988880000', status = 'inactive' where id = p2; get diagnostics cnt = row_count;
  if cnt <> 1 then raise exception 'FAIL P3 update'; end if;
  update public.patients set status = 'active' where id = p2;
  execute 'reset role';
  -- mesmo CPF em outra organização é permitido
  insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked) values (org2, 'Outro Tenant', '1990-05-10', pg_temp.h(1), '***.***.***-01') returning id into px;
  n := n + 1;

  -- P4 consentimentos: append-only, autoria forçada
  perform pg_temp.as_user(ur);
  insert into public.patient_consents (organization_id, patient_id, purpose, granted, source) values (org, p1, 'care_data', true, 'in_person');
  insert into public.patient_consents (organization_id, patient_id, purpose, granted, source) values (org, p1, 'communication', false, 'phone');
  if pg_temp.st(format($q$insert into public.patient_consents (organization_id, patient_id, purpose, granted, source, recorded_by) values (%L,%L,'research',true,'in_person',%L)$q$, org, p1, uo)) <> '42501' then
    raise exception 'FAIL P4 forged recorded_by'; end if;
  if pg_temp.st($q$update public.patient_consents set granted = true$q$) <> '42501' then raise exception 'FAIL P4 update'; end if;
  if pg_temp.st($q$delete from public.patient_consents$q$) <> '42501' then raise exception 'FAIL P4 delete'; end if;
  execute 'reset role';
  if pg_temp.st($q$update public.patient_consents set granted = true$q$) <> '42501' then raise exception 'FAIL P4 update (owner)'; end if;
  if pg_temp.st(format($q$insert into public.patient_consents (organization_id, patient_id, purpose, granted, source) values (%L,%L,'care_data',true,'in_person')$q$, org2, p1)) <> '23503' then
    raise exception 'FAIL P4 cross-org consent fk'; end if; n := n + 1;

  -- P5 responsáveis: regras e imutabilidade
  perform pg_temp.as_user(ur);
  insert into public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id, relationship) values (org, p1, dep, 'parent') returning id into g1;
  if pg_temp.st(format($q$insert into public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id, relationship) values (%L,%L,%L,'parent')$q$, org, p1, p1)) <> '23514' then raise exception 'FAIL P5 self guardian'; end if;
  if pg_temp.st(format($q$insert into public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id, relationship) values (%L,%L,%L,'parent')$q$, org, p1, dep)) <> '23505' then raise exception 'FAIL P5 duplicate active'; end if;
  if pg_temp.st(format($q$update public.patient_guardianships set relationship = 'other' where id = %L$q$, g1)) <> '42501' then raise exception 'FAIL P5 change relationship'; end if;
  if pg_temp.st(format($q$update public.patient_guardianships set guardian_patient_id = %L where id = %L$q$, p2, g1)) <> '42501' then raise exception 'FAIL P5 change guardian'; end if;
  if pg_temp.st(format($q$insert into public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id, relationship) values (%L,%L,%L,'parent')$q$, org, p1, px)) <> '23503' then raise exception 'FAIL P5 cross-org dependent'; end if;
  n := n + 1;

  -- P6 vínculo de conta: só por RPC; unicidade; acesso do titular/responsável; revogação e expiração
  if pg_temp.st(format($q$insert into public.patient_identity_links (organization_id, patient_id, user_id, verified_by) values (%L,%L,%L,%L)$q$, org, p1, up, ur)) <> '42501' then
    raise exception 'FAIL P6 direct link insert'; end if;
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, p1, up)) <> '42501' then raise exception 'FAIL P6 doctor links'; end if;
  perform pg_temp.as_user(ux);
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, p1, up)) <> '42501' then raise exception 'FAIL P6 outsider links'; end if;
  perform pg_temp.as_user(ur);
  link1 := public.rpc_link_patient_account(org, p1, up);
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, p1, uq)) <> 'CF409' then raise exception 'FAIL P6 patient linked twice'; end if;
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, p2, up)) <> 'CF409' then raise exception 'FAIL P6 user linked twice'; end if;
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, p2, gen_random_uuid())) <> 'CF422' then raise exception 'FAIL P6 unknown user'; end if;
  if pg_temp.st(format($q$select public.rpc_link_patient_account(%L,%L,%L)$q$, org, px, uq)) <> 'CF404' then raise exception 'FAIL P6 cross-org patient'; end if;
  execute 'reset role';
  select count(*) into cnt from public.audit_logs where organization_id = org and action = 'patient.link_account' and resource_id = p1::text;
  if cnt <> 1 then raise exception 'FAIL P6 audit'; end if; n := n + 1;

  perform pg_temp.as_user(up);   -- titular vinculado ao paciente 1 (responsável do dependente)
  select count(*) into cnt from public.patients; if cnt <> 2 then raise exception 'FAIL P6 holder sees % patients', cnt; end if;
  select count(*) into cnt from public.patients where id in (p1, dep); if cnt <> 2 then raise exception 'FAIL P6 holder/dependent'; end if;
  select count(*) into cnt from public.patients where id = p2; if cnt <> 0 then raise exception 'FAIL P6 sees other patient'; end if;
  select count(*) into cnt from public.patient_consents; if cnt <> 2 then raise exception 'FAIL P6 own consents %', cnt; end if;
  update public.patients set full_name = 'Hack Hack' where id = p1; get diagnostics cnt = row_count;
  if cnt <> 0 then raise exception 'FAIL P6 holder updates (% rows)', cnt; end if;
  if pg_temp.st(format($q$insert into public.patient_consents (organization_id, patient_id, purpose, granted, source) values (%L,%L,'research',true,'portal')$q$, org, p1)) <> '42501' then raise exception 'FAIL P6 holder consents'; end if;
  select count(*) into cnt from public.scheduling_events; if cnt <> 0 then raise exception 'FAIL P6 holder sees agenda'; end if;
  perform pg_temp.as_user(uq);   -- conta sem vínculo
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL P6 unlinked sees patients'; end if;

  perform pg_temp.as_user(ur);
  update public.patient_guardianships set valid_to = now() + interval '1 second' where id = g1;  -- expira logo
  execute 'reset role';
  update public.patient_guardianships set valid_to = now() - interval '1 second', valid_from = valid_from - interval '1 day' where false;
  -- simula expiração sem violar o guard (valid_from imutável): move valid_to para o passado via service/owner
  execute 'alter table public.patient_guardianships disable trigger patient_guardianships_guard';
  update public.patient_guardianships set valid_from = now() - interval '2 days', valid_to = now() - interval '1 day' where id = g1;
  execute 'alter table public.patient_guardianships enable trigger patient_guardianships_guard';
  perform pg_temp.as_user(up);
  select count(*) into cnt from public.patients where id = dep; if cnt <> 0 then raise exception 'FAIL P6 expired guardian sees dependent'; end if;
  select count(*) into cnt from public.patients where id = p1; if cnt <> 1 then raise exception 'FAIL P6 holder lost own'; end if;
  perform pg_temp.as_user(ur);
  perform public.rpc_revoke_patient_link(org, link1);
  if pg_temp.st(format($q$select public.rpc_revoke_patient_link(%L,%L)$q$, org, link1)) <> 'CF404' then raise exception 'FAIL P6 double revoke'; end if;
  perform pg_temp.as_user(up);
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL P6 revoked link still sees'; end if;
  perform pg_temp.as_user(ur);
  link1 := public.rpc_link_patient_account(org, p1, up);   -- pode revincular após revogação
  n := n + 1;

  -- P7 agendar com paciente, remarcar preservando, imutabilidade do paciente no evento
  perform pg_temp.as_user(ur);
  ev := public.rpc_book_event_for_patient(org, uA, svc, now0, null, res, p1);
  if (select patient_id from public.scheduling_events where id = ev) <> p1 then raise exception 'FAIL P7 patient not set'; end if;
  if pg_temp.st(format($q$select public.rpc_book_event_for_patient(%L,%L,%L,%L,null,%L::jsonb,%L)$q$, org, uA, svc, now0 + interval '5 hours', res, px)) <> 'CF404' then raise exception 'FAIL P7 cross-org patient'; end if;
  update public.patients set status = 'inactive' where id = p2;
  if pg_temp.st(format($q$select public.rpc_book_event_for_patient(%L,%L,%L,%L,null,%L::jsonb,%L)$q$, org, uA, svc, now0 + interval '5 hours', res, p2)) <> 'CF404' then raise exception 'FAIL P7 inactive patient'; end if;
  update public.patients set status = 'active' where id = p2;
  select count(*) into cnt from public.scheduling_events where starts_at = now0 + interval '5 hours'; if cnt <> 0 then raise exception 'FAIL P7 leaked event'; end if;
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_book_event_for_patient(%L,%L,%L,%L,null,%L::jsonb,%L)$q$, org, uA, svc, now0 + interval '7 hours', res, p1)) <> '42501' then raise exception 'FAIL P7 doctor books'; end if;
  perform pg_temp.as_user(ur);
  ev_r := public.rpc_reschedule_event(org, ev, now0 + interval '10 minutes');
  if (select patient_id from public.scheduling_events where id = ev_r) <> p1 then raise exception 'FAIL P7 reschedule lost patient'; end if;
  ev := ev_r;
  execute 'reset role';
  if pg_temp.st(format($q$update public.scheduling_events set patient_id = %L where id = %L$q$, p2, ev)) <> '42501' then raise exception 'FAIL P7 patient swap'; end if;
  if pg_temp.st(format($q$update public.scheduling_events set patient_id = null where id = %L$q$, ev)) <> '42501' then raise exception 'FAIL P7 patient removal'; end if;
  n := n + 1;

  -- P8 check-in
  perform pg_temp.as_user(ur);
  ev_early := public.rpc_book_event_for_patient(org, uA, svc, now() + interval '2 days', null, res, p2);
  ev_nopat := public.rpc_book_event(org, uA, 'appointment', svc, now0 + interval '3 hours', null, res);
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev_early)) <> 'CF422' then raise exception 'FAIL P8 too early'; end if;
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev_nopat)) <> 'CF422' then raise exception 'FAIL P8 no patient'; end if;
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev)) <> '42501' then raise exception 'FAIL P8 doctor check-in'; end if;
  perform pg_temp.as_user(ux);
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev)) <> 'CF404' then raise exception 'FAIL P8 cross-org check-in'; end if;
  perform pg_temp.as_user(ur);
  perform public.rpc_check_in(org, ev);
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev)) <> 'CF409' then raise exception 'FAIL P8 double check-in'; end if;
  select count(*) into cnt from public.patient_checkins where event_id = ev and patient_id = p1; if cnt <> 1 then raise exception 'FAIL P8 row'; end if;
  execute 'reset role';
  select count(*) into cnt from public.audit_logs where organization_id = org and action = 'checkin.create' and resource_id = ev::text; if cnt <> 1 then raise exception 'FAIL P8 audit'; end if;
  perform pg_temp.as_user(ur);
  if pg_temp.st($q$update public.patient_checkins set checked_in_by = gen_random_uuid()$q$) <> '42501' then raise exception 'FAIL P8 update'; end if;
  if pg_temp.st($q$insert into public.patient_checkins (organization_id, unit_id, event_id, patient_id, checked_in_by) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid())$q$) <> '42501' then
    raise exception 'FAIL P8 direct insert'; end if;
  -- cancelado não faz check-in
  ev_cancel := public.rpc_book_event_for_patient(org, uA, svc, now0 + interval '8 hours', null, jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',rm)), p2);
  perform public.rpc_cancel_event(org, ev_cancel, 'cancelado teste');
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev_cancel)) <> 'CF409' then raise exception 'FAIL P8 cancelled check-in'; end if;
  -- recepção só da unidade B não faz check-in na unidade A
  perform pg_temp.as_user(uo);
  insert into public.units (organization_id, name) values (org, 'Unidade C') returning id into uB;
  insert into public.professionals (organization_id, full_name) values (org, 'Dr. Unidade C') returning id into px;
  insert into public.professional_units values (org, px, uB);
  insert into public.rooms (organization_id, unit_id, name) values (org, uB, 'Sala C') returning id into rm;
  ev_cancel := public.rpc_book_event_for_patient(org, uB, svc, now0 + interval '30 minutes', null,
    jsonb_build_array(jsonb_build_object('type','professional','id',px), jsonb_build_object('type','room','id',rm)), p2);
  perform pg_temp.as_user(urA);   -- recepção restrita à unidade A
  if pg_temp.st(format($q$select public.rpc_check_in(%L,%L)$q$, org, ev_cancel)) <> '42501' then raise exception 'FAIL P8 unit-scoped check-in in other unit'; end if;
  perform pg_temp.as_user(uo);
  perform public.rpc_check_in(org, ev_cancel);   -- proprietário (escopo organizacional) consegue
  n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
