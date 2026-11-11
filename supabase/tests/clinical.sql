-- 1D: vínculo assistencial, prontuário sintético (rascunho/finalizado/adendo), acesso de emergência e log de acesso.
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
  uo uuid := gen_random_uuid(); ud uuid := gen_random_uuid(); ud2 uuid := gen_random_uuid(); ur uuid := gen_random_uuid();
  ua uuid := gen_random_uuid(); un uuid := gen_random_uuid(); uad uuid := gen_random_uuid(); ux uuid := gen_random_uuid();
  org uuid; org2 uuid; role_d uuid; role_a uuid; role_r uuid; role_n uuid;
  m uuid; unit1 uuid; prof_d uuid; prof_d2 uuid; prof_ad uuid; rm uuid; svc uuid; res jsonb;
  p1 uuid; p2 uuid; ev uuid; ev2 uuid; rec uuid; rec2 uuid; drf uuid; g uuid; g2 uuid; link uuid; lk record;
  v jsonb; cnt int; n int := 0; s text; h text; v_seq int;
  t0 timestamptz := date_trunc('hour', now()) + interval '48 hours';
  secret text := 'SEGREDO-CLINICO-XYZ-123';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now()
  from unnest(array[uo, ud, ud2, ur, ua, un, uad, ux]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Clinica');
  org2 := public.rpc_provision_organization(ux, 'Clinica Outra');
  select id into role_d from public.roles where organization_id = org and key = 'doctor';
  select id into role_a from public.roles where organization_id = org and key = 'auditor';
  select id into role_r from public.roles where organization_id = org and key = 'receptionist';
  select id into role_n from public.roles where organization_id = org and key = 'nurse';

  -- membros e papéis
  insert into public.organization_members (organization_id, user_id) select org, u from unnest(array[ud, ud2, ur, ua, un, uad]) u;
  insert into public.user_role_assignments (organization_id, member_id, role_id)
    select org, om.id, case om.user_id when ud then role_d when ud2 then role_d when ur then role_r when ua then role_a when un then role_n
                                         when uad then role_d end
    from public.organization_members om where om.organization_id = org and om.user_id = any (array[ud, ud2, ur, ua, un, uad]);
  insert into public.user_role_assignments (organization_id, member_id, role_id)
    select org, om.id, role_a from public.organization_members om where om.organization_id = org and om.user_id = uad;

  insert into public.units (organization_id, name) values (org, 'Unidade C') returning id into unit1;
  insert into public.professionals (organization_id, full_name, member_id)
    select org, 'Dr. Um', om.id from public.organization_members om where om.organization_id = org and om.user_id = ud;
  select id into prof_d from public.professionals where organization_id = org and full_name = 'Dr. Um';
  insert into public.professionals (organization_id, full_name, member_id)
    select org, 'Dra. Dois', om.id from public.organization_members om where om.organization_id = org and om.user_id = ud2;
  select id into prof_d2 from public.professionals where organization_id = org and full_name = 'Dra. Dois';
  insert into public.professionals (organization_id, full_name, member_id)
    select org, 'Dr. Auditor', om.id from public.organization_members om where om.organization_id = org and om.user_id = uad;
  select id into prof_ad from public.professionals where organization_id = org and full_name = 'Dr. Auditor';
  insert into public.professional_units values (org, prof_d, unit1), (org, prof_d2, unit1), (org, prof_ad, unit1);
  insert into public.rooms (organization_id, unit_id, name) values (org, unit1, 'Sala 1') returning id into rm;
  insert into public.services (organization_id, name, kind, duration_minutes) values (org, 'Consulta', 'consultation', 30) returning id into svc;
  res := jsonb_build_array(jsonb_build_object('type','professional','id',prof_d), jsonb_build_object('type','room','id',rm));

  perform pg_temp.as_user(uo);
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Paciente Um', '1990-01-01') returning id into p1;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Paciente Dois', '1991-02-02') returning id into p2;

  -- K1 matriz de permissões: conteúdo clínico só para médico/enfermeiro; proprietário/administrador/recepção não leem
  execute 'reset role';
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
   where r.organization_id = org and r.key in ('owner','admin','unit_manager','receptionist','exam_tech','finance','auditor')
     and rp.permission_key in ('clinical.read','clinical.write','clinical.emergency');
  if cnt <> 0 then raise exception 'FAIL K1 non-clinical roles with clinical content perms %', cnt; end if;
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
   where r.organization_id = org and r.key in ('doctor','nurse') and rp.permission_key in ('clinical.read','clinical.write','clinical.emergency');
  if cnt <> 6 then raise exception 'FAIL K1 doctor/nurse perms %', cnt; end if;
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
   where r.organization_id = org and r.key in ('owner','auditor') and rp.permission_key = 'clinical.audit';
  if cnt <> 2 then raise exception 'FAIL K1 audit perms %', cnt; end if;
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
   where r.organization_id = org and r.key in ('doctor','nurse','receptionist','exam_tech','finance') and rp.permission_key in ('care.read','care.assign','clinical.audit');
  if cnt <> 0 then raise exception 'FAIL K1 care/audit perms leaked to care roles %', cnt; end if; n := n + 1;

  -- K2 vínculo automático pelo agendamento (somente o profissional alocado)
  perform pg_temp.as_user(ur);
  ev := public.rpc_book_event_for_patient(org, unit1, svc, t0, null, res, p1);
  execute 'reset role';
  select * into lk from public.care_relationships where organization_id = org and patient_id = p1 and professional_id = prof_d;
  if lk.id is null or lk.source <> 'appointment' or lk.event_id <> ev or lk.revoked_at is not null
     or lk.valid_to < t0 + interval '30 minutes' + interval '29 days' then raise exception 'FAIL K2 auto link %', to_jsonb(lk); end if;
  if exists (select 1 from public.care_relationships where organization_id = org and professional_id = prof_d2) then raise exception 'FAIL K2 link for non-allocated'; end if;
  link := lk.id; n := n + 1;

  -- K3 acesso ao cadastro do paciente só com vínculo
  perform pg_temp.as_user(ud);
  select count(*) into cnt from public.patients; if cnt <> 1 then raise exception 'FAIL K3 doctor patients %', cnt; end if;
  if not exists (select 1 from public.patients where id = p1) then raise exception 'FAIL K3 linked patient hidden'; end if;
  perform pg_temp.as_user(ud2);
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL K3 unlinked doctor sees patients'; end if; n := n + 1;

  -- K4 criação de rascunho: só profissional vinculado com clinical.write
  perform pg_temp.as_user(ud);
  rec := public.rpc_create_clinical_record(org, p1, 'evolution', 'Evolucao 1', 'Paciente relata ' || secret, ev);
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'receita','T1','x')$q$, org, p1)) <> 'CF422' then raise exception 'FAIL K4 kind'; end if;
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x',%L)$q$, org, p2, ev)) <> '42501' then raise exception 'FAIL K4 no link p2'; end if;
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','   ')$q$, org, p1)) <> 'CF422' then raise exception 'FAIL K4 empty body'; end if;
  perform pg_temp.as_user(ud2);
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> '42501' then raise exception 'FAIL K4 unlinked'; end if;
  perform pg_temp.as_user(uo);
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> '42501' then raise exception 'FAIL K4 owner'; end if;
  foreach m in array array[ur, un] loop
    perform pg_temp.as_user(m);
    if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> '42501' then raise exception 'FAIL K4 role % ', m; end if;
  end loop;
  perform pg_temp.as_user(ux);
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> 'CF404' then raise exception 'FAIL K4 outsider'; end if; n := n + 1;

  -- K5 rascunho: autor edita; privado ao autor; não acessível por tabela
  perform pg_temp.as_user(ud);
  perform public.rpc_update_clinical_draft(org, rec, 'Evolucao 1', 'Paciente relata ' || secret || ' e melhora');
  v := public.rpc_list_clinical_records(org, p1, 'care');
  if jsonb_array_length(v) <> 1 or v -> 0 ->> 'status' <> 'draft' or v::text like '%' || secret || '%' then raise exception 'FAIL K5 list %', v; end if;
  if pg_temp.st(format($q$select * from public.clinical_records$q$)) <> '42501' then raise exception 'FAIL K5 table select'; end if;
  if pg_temp.st(format($q$update public.clinical_records set body = 'x'$q$)) <> '42501' then raise exception 'FAIL K5 table update'; end if;
  if pg_temp.st(format($q$select * from public.clinical_addenda$q$)) <> '42501' then raise exception 'FAIL K5 addenda select'; end if; n := n + 1;

  -- K6 finalização: hash, imutabilidade, sem segunda finalização
  h := public.rpc_finalize_clinical_record(org, rec);
  if h !~ '^[0-9a-f]{64}$' then raise exception 'FAIL K6 hash'; end if;
  if pg_temp.st(format($q$select public.rpc_finalize_clinical_record(%L,%L)$q$, org, rec)) <> 'CF409' then raise exception 'FAIL K6 refinalize'; end if;
  if pg_temp.st(format($q$select public.rpc_update_clinical_draft(%L,%L,'Novo','Novo corpo')$q$, org, rec)) <> 'CF409' then raise exception 'FAIL K6 edit finalized'; end if;
  execute 'reset role';
  if pg_temp.st(format($q$update public.clinical_records set body = 'adulterado' where id = %L$q$, rec)) <> '42501' then raise exception 'FAIL K6 direct update body'; end if;
  if pg_temp.st(format($q$update public.clinical_records set status = 'draft', content_hash = null, finalized_at = null where id = %L$q$, rec)) <> '42501' then raise exception 'FAIL K6 reopen'; end if;
  if pg_temp.st(format($q$delete from public.clinical_records where id = %L$q$, rec)) <> '42501' then raise exception 'FAIL K6 delete'; end if;
  -- hash errado na transição é recusado mesmo para quem escreve direto
  perform pg_temp.as_user(ud);
  drf := public.rpc_create_clinical_record(org, p1, 'anamnesis', 'Anamnese', 'Historico');
  execute 'reset role';
  if pg_temp.st(format($q$update public.clinical_records set status='finalized', content_hash = repeat('a',64), finalized_at = now() where id = %L$q$, drf)) <> '23514' then
    raise exception 'FAIL K6 forged hash'; end if;
  if pg_temp.st(format($q$update public.clinical_records set patient_id = %L where id = %L$q$, p2, drf)) <> '42501' then raise exception 'FAIL K6 move patient'; end if; n := n + 1;

  -- K7 adendos: só em finalizado, sequenciais, imutáveis, por qualquer profissional com vínculo (autoria preservada)
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_add_clinical_addendum(%L,%L,'correcao','texto')$q$, org, drf)) <> 'CF409' then raise exception 'FAIL K7 addendum on draft'; end if;
  if pg_temp.st(format($q$select public.rpc_add_clinical_addendum(%L,%L,'ab','texto')$q$, org, rec)) <> 'CF422' then raise exception 'FAIL K7 short reason'; end if;
  v_seq := public.rpc_add_clinical_addendum(org, rec, 'correcao de dose', 'Dose corrigida para 5 mg');
  if v_seq <> 1 then raise exception 'FAIL K7 seq1 %', v_seq; end if;
  v_seq := public.rpc_add_clinical_addendum(org, rec, 'complemento', 'Retorno em 7 dias');
  if v_seq <> 2 then raise exception 'FAIL K7 seq2 %', v_seq; end if;
  execute 'reset role';
  if pg_temp.st(format($q$update public.clinical_addenda set body = 'x' where record_id = %L$q$, rec)) <> '42501' then raise exception 'FAIL K7 update addendum'; end if;
  if pg_temp.st(format($q$delete from public.clinical_addenda where record_id = %L$q$, rec)) <> '42501' then raise exception 'FAIL K7 delete addendum'; end if; n := n + 1;

  -- K8 leitura: conteúdo + adendos em ordem + integridade; log sem conteúdo; finalidade registrada
  perform pg_temp.as_user(ud);
  v := public.rpc_get_clinical_record(org, rec, 'care');
  if v -> 'record' ->> 'status' <> 'finalized' or v ->> 'integrity' <> 'ok' or jsonb_array_length(v -> 'addenda') <> 2
     or v -> 'addenda' -> 0 ->> 'seq' <> '1' or (v -> 'record' ->> 'body') not like '%' || secret || '%' then raise exception 'FAIL K8 get %', v; end if;
  execute 'reset role';
  select * into lk from public.data_access_logs where organization_id = org and action = 'view' and resource_id = rec::text;
  if lk.id is null or lk.purpose <> 'care' or lk.basis <> 'relationship' or lk.relationship_id <> link or lk.professional_id <> prof_d or lk.actor_id <> ud then
    raise exception 'FAIL K8 access log %', to_jsonb(lk); end if;
  if exists (select 1 from public.data_access_logs d where d::text like '%' || secret || '%')
     or exists (select 1 from public.audit_logs a where a::text like '%' || secret || '%') then raise exception 'FAIL K8 content leaked to logs'; end if;
  if (select count(*) from public.data_access_logs where organization_id = org and action in ('create_draft','update_draft','finalize','addendum','list')) < 7 then
    raise exception 'FAIL K8 write/list logs missing'; end if;
  if pg_temp.st(format($q$update public.data_access_logs set purpose = 'care' where organization_id = %L$q$, org)) <> '42501'
     or pg_temp.st(format($q$delete from public.data_access_logs where organization_id = %L$q$, org)) <> '42501' then raise exception 'FAIL K8 logs mutable'; end if; n := n + 1;

  -- K9 finalidade obrigatória e válida
  perform pg_temp.as_user(ud);
  foreach s in array array['', 'audit', 'research'] loop
    if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,%L)$q$, org, rec, s)) <> 'CF422' then raise exception 'FAIL K9 purpose %', s; end if;
  end loop;
  if pg_temp.st(format($q$select public.rpc_list_clinical_records(%L,%L,null)$q$, org, p1)) <> 'CF422' then raise exception 'FAIL K9 null purpose'; end if;
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'emergency')$q$, org, rec)) <> '42501' then raise exception 'FAIL K9 emergency without grant'; end if;
  if pg_temp.st(format($q$select public.rpc_list_clinical_records(%L,%L,'care',0)$q$, org, p1)) <> 'CF422' then raise exception 'FAIL K9 paging'; end if; n := n + 1;

  -- K10 acesso de emergência: justificado, temporário, somente leitura, registrado
  perform pg_temp.as_user(ud2);
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'care')$q$, org, rec)) <> '42501' then raise exception 'FAIL K10 unlinked read'; end if;
  if pg_temp.st(format($q$select public.rpc_emergency_access(%L,%L,'curto')$q$, org, p1)) <> 'CF422' then raise exception 'FAIL K10 short justification'; end if;
  g := public.rpc_emergency_access(org, p1, 'Paciente em parada, historico necessario para conduta imediata');
  v := public.rpc_list_clinical_records(org, p1, 'emergency');
  if jsonb_array_length(v) <> 1 then raise exception 'FAIL K10 emergency list %', v; end if;
  v := public.rpc_get_clinical_record(org, rec, 'emergency');
  if v ->> 'integrity' <> 'ok' then raise exception 'FAIL K10 emergency get'; end if;
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> '42501' then raise exception 'FAIL K10 emergency write'; end if;
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'care')$q$, org, rec)) <> '42501' then raise exception 'FAIL K10 care purpose with grant only'; end if;
  execute 'reset role';
  select * into lk from public.data_access_logs where organization_id = org and action = 'view' and purpose = 'emergency';
  if lk.id is null or lk.basis <> 'emergency' or lk.grant_id <> g or lk.professional_id <> prof_d2 then raise exception 'FAIL K10 emergency log %', to_jsonb(lk); end if;
  if not exists (select 1 from public.audit_logs where organization_id = org and action = 'clinical.emergency_access' and resource_id = g::text) then
    raise exception 'FAIL K10 audit of grant'; end if;
  -- expirado => negado
  alter table public.emergency_access_grants disable trigger emergency_grants_guard;
  update public.emergency_access_grants set granted_at = now() - interval '3 hours', expires_at = now() - interval '1 hour' where id = g;
  alter table public.emergency_access_grants enable trigger emergency_grants_guard;
  perform pg_temp.as_user(ud2);
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'emergency')$q$, org, rec)) <> '42501' then raise exception 'FAIL K10 expired'; end if;
  -- quem não tem papel clínico nem profissional não pede emergência
  perform pg_temp.as_user(uo);
  if pg_temp.st(format($q$select public.rpc_emergency_access(%L,%L,'Justificativa longa o suficiente para passar')$q$, org, p1)) <> '42501' then raise exception 'FAIL K10 owner emergency'; end if;
  perform pg_temp.as_user(ur);
  if pg_temp.st(format($q$select public.rpc_emergency_access(%L,%L,'Justificativa longa o suficiente para passar')$q$, org, p1)) <> '42501' then raise exception 'FAIL K10 reception emergency'; end if; n := n + 1;

  -- K11 revisão do acesso de emergência
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_review_emergency_access(%L,%L,'justified')$q$, org, g)) <> '42501' then raise exception 'FAIL K11 doctor review'; end if;
  perform pg_temp.as_user(ua);
  if pg_temp.st(format($q$select public.rpc_review_emergency_access(%L,%L,'talvez')$q$, org, g)) <> 'CF422' then raise exception 'FAIL K11 outcome'; end if;
  perform public.rpc_review_emergency_access(org, g, 'justified', 'Parada documentada');
  if pg_temp.st(format($q$select public.rpc_review_emergency_access(%L,%L,'not_justified')$q$, org, g)) <> 'CF409' then raise exception 'FAIL K11 double review'; end if;
  execute 'reset role';
  if pg_temp.st(format($q$update public.emergency_access_grants set justification = 'alterada alterada alterada' where id = %L$q$, g)) <> '42501' then raise exception 'FAIL K11 grant mutable'; end if;
  -- ninguém revisa o próprio acesso (usuário com médico + auditor)
  perform pg_temp.as_user(uad);
  g2 := public.rpc_emergency_access(org, p1, 'Emergencia real, justificativa detalhada e suficiente');
  if pg_temp.st(format($q$select public.rpc_review_emergency_access(%L,%L,'justified')$q$, org, g2)) <> '42501' then raise exception 'FAIL K11 self review'; end if; n := n + 1;

  -- K12 integridade: auditor verifica (sem conteúdo); adulteração direta é detectada
  perform pg_temp.as_user(ua);
  if public.rpc_verify_clinical_record_integrity(org, rec) is not true then raise exception 'FAIL K12 intact'; end if;
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'care')$q$, org, rec)) <> '42501' then raise exception 'FAIL K12 auditor reads content'; end if;
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_verify_clinical_record_integrity(%L,%L)$q$, org, rec)) <> '42501' then raise exception 'FAIL K12 doctor verify'; end if;
  execute 'reset role';
  alter table public.clinical_records disable trigger clinical_records_guard;
  update public.clinical_records set body = body || ' ADULTERADO' where id = rec;
  alter table public.clinical_records enable trigger clinical_records_guard;
  perform pg_temp.as_user(ua);
  if public.rpc_verify_clinical_record_integrity(org, rec) is not false then raise exception 'FAIL K12 tamper not detected'; end if;
  perform pg_temp.as_user(ud);
  v := public.rpc_get_clinical_record(org, rec, 'care');
  if v ->> 'integrity' <> 'mismatch' then raise exception 'FAIL K12 get must flag mismatch'; end if;
  n := n + 1;

  -- K13 remarcação: vínculo do evento antigo revogado, novo vínculo criado; médico mantém acesso
  perform pg_temp.as_user(ur);
  ev2 := public.rpc_reschedule_event(org, ev, t0 + interval '1 day');
  execute 'reset role';
  if not exists (select 1 from public.care_relationships where id = link and revoked_at is not null and revoke_reason = 'appointment_cancelled') then
    raise exception 'FAIL K13 old link not revoked'; end if;
  select * into lk from public.care_relationships where organization_id = org and event_id = ev2 and professional_id = prof_d;
  if lk.id is null or lk.revoked_at is not null then raise exception 'FAIL K13 new link'; end if;
  link := lk.id;
  perform pg_temp.as_user(ud);
  if jsonb_array_length(public.rpc_list_clinical_records(org, p1, 'care')) < 1 then raise exception 'FAIL K13 access lost'; end if; n := n + 1;

  -- K14 vínculo manual: só care.assign; autoria preservada; rascunho privado; revogação
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_assign_care_relationship(%L,%L,%L,null,'Equipe compartilhada do caso')$q$, org, p1, prof_d2)) <> '42501' then raise exception 'FAIL K14 doctor assigns'; end if;
  perform pg_temp.as_user(uo);
  if pg_temp.st(format($q$select public.rpc_assign_care_relationship(%L,%L,%L,null,'abc')$q$, org, p1, prof_d2)) <> 'CF422' then raise exception 'FAIL K14 short reason'; end if;
  if pg_temp.st(format($q$select public.rpc_assign_care_relationship(%L,%L,%L,now() - interval '1 day','Equipe compartilhada do caso')$q$, org, p1, prof_d2)) <> 'CF422' then raise exception 'FAIL K14 past valid_to'; end if;
  link := public.rpc_assign_care_relationship(org, p1, prof_d2, now() + interval '30 days', 'Equipe compartilhada do caso');
  if pg_temp.st(format($q$select public.rpc_assign_care_relationship(%L,%L,%L,null,'Equipe compartilhada do caso')$q$, org, p1, prof_d2)) <> 'CF409' then raise exception 'FAIL K14 duplicate'; end if;
  perform pg_temp.as_user(ud2);
  rec2 := public.rpc_create_clinical_record(org, p1, 'conduct', 'Conduta', 'Rascunho da colega');
  v_seq := public.rpc_add_clinical_addendum(org, rec, 'complemento da equipe', 'Colega confirma o plano');
  if v_seq <> 3 then raise exception 'FAIL K14 addendum seq %', v_seq; end if;
  execute 'reset role';
  if (select professional_id from public.clinical_addenda where record_id = rec and seq = 3) <> prof_d2 then raise exception 'FAIL K14 addendum authorship'; end if;
  perform pg_temp.as_user(ud);
  v := public.rpc_list_clinical_records(org, p1, 'care');
  if exists (select 1 from jsonb_array_elements(v) e where e ->> 'id' = rec2::text) then raise exception 'FAIL K14 foreign draft in list'; end if;
  if pg_temp.st(format($q$select public.rpc_get_clinical_record(%L,%L,'care')$q$, org, rec2)) <> 'CF404' then raise exception 'FAIL K14 foreign draft get'; end if;
  if pg_temp.st(format($q$select public.rpc_update_clinical_draft(%L,%L,'x1','x')$q$, org, rec2)) <> '42501' then raise exception 'FAIL K14 edit foreign draft'; end if;
  if pg_temp.st(format($q$select public.rpc_finalize_clinical_record(%L,%L)$q$, org, rec2)) <> '42501' then raise exception 'FAIL K14 finalize foreign draft'; end if;
  if pg_temp.st(format($q$select public.rpc_revoke_care_relationship(%L,%L,'fim do caso')$q$, org, link)) <> '42501' then raise exception 'FAIL K14 doctor revokes'; end if;
  perform pg_temp.as_user(uo);
  if pg_temp.st(format($q$select public.rpc_revoke_care_relationship(%L,%L,'x')$q$, org, link)) <> 'CF422' then raise exception 'FAIL K14 revoke reason'; end if;
  perform public.rpc_revoke_care_relationship(org, link, 'fim do caso');
  if pg_temp.st(format($q$select public.rpc_revoke_care_relationship(%L,%L,'fim do caso')$q$, org, link)) <> 'CF409' then raise exception 'FAIL K14 revoke twice'; end if;
  perform pg_temp.as_user(ud2);
  if pg_temp.st(format($q$select public.rpc_list_clinical_records(%L,%L,'care')$q$, org, p1)) <> '42501' then raise exception 'FAIL K14 access after revoke'; end if;
  if pg_temp.st(format($q$select public.rpc_create_clinical_record(%L,%L,'evolution','Titulo','x')$q$, org, p1)) <> '42501' then raise exception 'FAIL K14 write after revoke'; end if;
  execute 'reset role';
  if pg_temp.st(format($q$update public.care_relationships set professional_id = %L where id = %L$q$, prof_d, link)) <> '42501' then raise exception 'FAIL K14 link mutable'; end if;
  if pg_temp.st(format($q$update public.care_relationships set revoke_reason = 'outro motivo' where id = %L$q$, link)) <> '42501' then raise exception 'FAIL K14 revoke rewritten'; end if;
  if pg_temp.st(format($q$delete from public.care_relationships where id = %L$q$, link)) <> '42501' then raise exception 'FAIL K14 link delete'; end if; n := n + 1;

  -- K15 validade do vínculo: expirado nega; cancelamento do agendamento revoga e esconde o cadastro
  perform pg_temp.as_user(uo);
  link := public.rpc_assign_care_relationship(org, p1, prof_d2, null, 'Novo periodo de acompanhamento');
  execute 'reset role';
  alter table public.care_relationships disable trigger care_relationships_guard;
  update public.care_relationships set valid_from = now() - interval '2 days', valid_to = now() - interval '1 day' where id = link;
  alter table public.care_relationships enable trigger care_relationships_guard;
  perform pg_temp.as_user(ud2);
  if pg_temp.st(format($q$select public.rpc_list_clinical_records(%L,%L,'care')$q$, org, p1)) <> '42501' then raise exception 'FAIL K15 expired link'; end if;
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL K15 expired link shows patient'; end if;
  perform pg_temp.as_user(ur);
  perform public.rpc_cancel_event(org, ev2, 'Paciente desistiu', 'event.cancel');
  perform pg_temp.as_user(ud);
  if pg_temp.st(format($q$select public.rpc_list_clinical_records(%L,%L,'care')$q$, org, p1)) <> '42501' then raise exception 'FAIL K15 access after cancel'; end if;
  select count(*) into cnt from public.patients; if cnt <> 0 then raise exception 'FAIL K15 cancelled link shows patient'; end if;
  execute 'reset role';
  if (select status from public.clinical_records where id = rec) <> 'finalized' then raise exception 'FAIL K15 record lost'; end if; n := n + 1;

  -- K16 privilégios: sem acesso por tabela (inclusive service_role); anon não executa RPCs; log só para quem audita
  if has_table_privilege('service_role', 'public.clinical_records', 'select') or has_table_privilege('service_role', 'public.clinical_addenda', 'select')
     or has_table_privilege('authenticated', 'public.clinical_records', 'select') or has_table_privilege('anon', 'public.clinical_records', 'select')
     or has_table_privilege('authenticated', 'public.clinical_addenda', 'insert') then raise exception 'FAIL K16 table privileges'; end if;
  if has_function_privilege('anon', 'public.rpc_get_clinical_record(uuid,uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.rpc_emergency_access(uuid,uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'app.clinical_gate(uuid,uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'app.log_access(uuid,uuid,uuid,text,text,text,text,text,uuid,uuid)', 'execute') then
    raise exception 'FAIL K16 function privileges'; end if;
  perform pg_temp.as_user(ua);
  select count(*) into cnt from public.data_access_logs; if cnt < 10 then raise exception 'FAIL K16 auditor log %', cnt; end if;
  perform pg_temp.as_user(ud);
  select count(*) into cnt from public.data_access_logs; if cnt <> 0 then raise exception 'FAIL K16 doctor sees log'; end if;
  select count(*) into cnt from public.care_relationships where professional_id <> prof_d;
  if cnt <> 0 then raise exception 'FAIL K16 doctor sees others links'; end if;
  perform pg_temp.as_user(ur);
  select count(*) into cnt from public.care_relationships; if cnt <> 0 then raise exception 'FAIL K16 receptionist sees links'; end if;
  perform pg_temp.as_user(ux);
  select count(*) into cnt from public.care_relationships; if cnt <> 0 then raise exception 'FAIL K16 outsider sees links'; end if;
  select count(*) into cnt from public.data_access_logs; if cnt <> 0 then raise exception 'FAIL K16 outsider sees log'; end if; n := n + 1;

  -- K17 auditoria transacional dos vínculos, sem conteúdo clínico
  execute 'reset role';
  if not exists (select 1 from public.audit_logs where organization_id = org and action = 'care.link' and resource_type = 'care_relationship')
     or not exists (select 1 from public.audit_logs where organization_id = org and action = 'care.link_change') then raise exception 'FAIL K17 audit of links'; end if;
  if exists (select 1 from public.audit_logs a where a::text like '%' || secret || '%' or a::text like '%Paciente relata%') then raise exception 'FAIL K17 content in audit'; end if; n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
