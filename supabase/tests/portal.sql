-- 1E: portal do paciente. Dados sintéticos; rollback proposital. Sucesso = 'TESTS_OK n'.
create function pg_temp.st(q text) returns text language plpgsql as $$
begin execute q; return 'OK'; exception when others then return sqlstate; end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.sc(q text) returns text language plpgsql security definer as $$
declare v text; begin execute q into v; return v; end $$;

do $$
declare
  uo uuid := gen_random_uuid(); ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); ug uuid := gen_random_uuid(); ux uuid := gen_random_uuid();
  org uuid; org2 uuid; unit uuid; prof uuid; room uuid; svc uuid; svc_off uuid; pa uuid; pb uuid; pg uuid; pd uuid; px uuid;
  slot timestamptz; slot2 timestamptz; slot3 timestamptz; ev uuid; ev2 uuid; ev3 uuid; cnt int; n int := 0; s text; r record; lnk uuid; la uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now()
  from unnest(array[uo, ua, ub, ug, ux]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Portal');
  org2 := public.rpc_provision_organization(ux, 'Outra Clinica');
  insert into public.units (organization_id, name, timezone) values (org, 'Unidade Portal', 'America/Bahia') returning id into unit;
  insert into public.professionals (organization_id, full_name, specialty) values (org, 'Dra. Sintetica', 'Clinica geral') returning id into prof;
  insert into public.professional_units (organization_id, professional_id, unit_id) values (org, prof, unit);
  insert into public.rooms (organization_id, unit_id, name) values (org, unit, 'Sala 1') returning id into room;
  insert into public.services (organization_id, name, kind, duration_minutes, online_booking) values (org, 'Consulta online', 'consultation', 30, true) returning id into svc;
  insert into public.services (organization_id, name, kind, duration_minutes, online_booking) values (org, 'Consulta so recepcao', 'consultation', 30, false) returning id into svc_off;
  insert into public.service_resource_requirements (organization_id, service_id, resource_type) values (org, svc, 'professional'), (org, svc, 'room');
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Paciente A', date '1990-01-01') returning id into pa;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Paciente B', date '1991-01-01') returning id into pb;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Responsavel G', date '1980-01-01') returning id into pg;
  insert into public.patients (organization_id, full_name, birth_date) values (org, 'Dependente D', date '2015-01-01') returning id into pd;
  insert into public.patients (organization_id, full_name, birth_date) values (org2, 'Paciente X', date '1992-01-01') returning id into px;
  insert into public.patient_guardianships (organization_id, guardian_patient_id, dependent_patient_id, relationship) values (org, pg, pd, 'parent');

  perform pg_temp.as_user(uo);
  perform public.rpc_link_patient_account(org, pa, ua);
  perform public.rpc_link_patient_account(org, pb, ub);
  la := public.rpc_link_patient_account(org, pg, ug);
  perform pg_temp.as_user(ux);
  perform public.rpc_link_patient_account(org2, px, ux);
  -- disponibilidade (somente equipe)
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format($q$select public.rpc_set_availability(%L,%L,%L,'[{"weekday":1,"start":"08:00","end":"12:00"}]'::jsonb)$q$, org, unit, prof));
  if s <> '42501' then raise exception 'FAIL E1 paciente define disponibilidade: %', s; end if; n := n + 1;
  perform pg_temp.as_user(uo);
  s := pg_temp.st(format($q$select public.rpc_set_availability(%L,%L,%L,'[{"weekday":9,"start":"08:00","end":"12:00"}]'::jsonb)$q$, org, unit, prof));
  if s <> 'CF422' then raise exception 'FAIL E2 janela invalida: %', s; end if; n := n + 1;
  s := pg_temp.st(format($q$select public.rpc_set_availability(%L,%L,%L,'[{"weekday":1,"start":"12:00","end":"08:00"}]'::jsonb)$q$, org, unit, prof));
  if s <> 'CF422' then raise exception 'FAIL E3 fim antes do inicio: %', s; end if; n := n + 1;
  perform public.rpc_set_availability(org, unit, prof,
    (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '08:00', 'end', '18:00')) from generate_series(0, 6) d));
  if (select count(*) from public.professional_availability where professional_id = prof) <> 7 then raise exception 'FAIL E4 janelas'; end if; n := n + 1;
  s := pg_temp.st(format($q$select public.rpc_set_portal_settings(%L, 2, 24, 60, 5, 2)$q$, org));
  if s <> 'OK' then raise exception 'FAIL E5 settings owner: %', s; end if; n := n + 1;
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format($q$select public.rpc_set_portal_settings(%L, 0, 0, 365, 50, 10)$q$, org));
  if s <> '42501' then raise exception 'FAIL E6 settings paciente: %', s; end if; n := n + 1;

  slot  := ((current_date + 5)::timestamp + time '10:00') at time zone 'America/Bahia';
  slot2 := ((current_date + 5)::timestamp + time '11:00') at time zone 'America/Bahia';
  slot3 := ((current_date + 6)::timestamp + time '10:00') at time zone 'America/Bahia';

  -- ============ contexto e catálogo ============
  select count(*) into cnt from public.rpc_portal_context();
  if cnt <> 1 then raise exception 'FAIL P1 contexto de A: %', cnt; end if; n := n + 1;
  perform pg_temp.as_user(ug);
  select count(*) into cnt from public.rpc_portal_context();
  if cnt <> 2 then raise exception 'FAIL P2 responsavel ve si e dependente: %', cnt; end if; n := n + 1;
  if (select count(*) from public.rpc_portal_context() where relation = 'dependent' and patient_id = pd) <> 1 then raise exception 'FAIL P3 relacao'; end if; n := n + 1;
  perform pg_temp.as_user(ux);
  s := pg_temp.st(format('select * from public.rpc_portal_catalog(%L)', org));
  if s <> 'CF404' then raise exception 'FAIL P4 catalogo de outra org: %', s; end if; n := n + 1;
  perform pg_temp.as_user(ua);
  select count(*) into cnt from public.rpc_portal_catalog(org);
  if cnt <> 1 then raise exception 'FAIL P5 catalogo so servico online: %', cnt; end if; n := n + 1;

  -- ============ horários ============
  select count(*) into cnt from public.rpc_portal_slots(org, unit, svc, prof, (current_date + 5), (current_date + 5));
  if cnt <> 20 then raise exception 'FAIL P6 slots do dia (08-18, 30min => 20) %', cnt; end if; n := n + 1;
  s := pg_temp.st(format('select * from public.rpc_portal_slots(%L,%L,%L,%L,%L,%L)', org, unit, svc, prof, current_date, current_date + 30));
  if s <> 'CF422' then raise exception 'FAIL P7 intervalo grande: %', s; end if; n := n + 1;
  select count(*) into cnt from public.rpc_portal_slots(org, unit, svc_off, prof, (current_date + 5), (current_date + 5));
  if cnt <> 0 then raise exception 'FAIL P8 servico nao liberado'; end if; n := n + 1;

  -- ============ agendar ============
  ev := public.rpc_portal_book(org, pa, unit, svc, prof, slot);
  if pg_temp.sc(format($q$select count(*) from public.scheduling_events where id = %L and patient_id = %L and kind = 'appointment' and starts_at = %L and ends_at = %L::timestamptz + interval '30 minutes'$q$, ev, pa, slot, slot)) <> '1' then
    raise exception 'FAIL B1 evento'; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.resource_allocations where event_id = %L and status = 'active'$q$, ev)) <> '2' then raise exception 'FAIL B2 alocacoes'; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.audit_logs where resource_id = %L and action = 'portal.book' and actor_id = %L$q$, ev, ua)) <> '1' then raise exception 'FAIL B3 auditoria'; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.appointment_status_history where event_id = %L and to_status = 'scheduled' and changed_by = %L$q$, ev, ua)) <> '1' then raise exception 'FAIL B4 historico'; end if; n := n + 1;
  -- horário ocupado some da lista e não pode ser reservado por outro paciente
  if exists (select 1 from public.rpc_portal_slots(org, unit, svc, prof, (current_date + 5), (current_date + 5)) where starts_at = slot) then raise exception 'FAIL B5 slot ocupado listado'; end if; n := n + 1;
  perform pg_temp.as_user(ub);
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pb, unit, svc, prof, slot));
  if s <> 'CF409' then raise exception 'FAIL B6 dupla reserva: %', s; end if; n := n + 1;
  -- repetir a mesma requisição devolve o mesmo agendamento (idempotência natural)
  perform pg_temp.as_user(ua);
  if public.rpc_portal_book(org, pa, unit, svc, prof, slot) <> ev then raise exception 'FAIL B5b book repetido'; end if; n := n + 1;
  perform pg_temp.as_user(ub);
  -- B tenta agendar em nome de A / de paciente de outra org
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, slot2));
  if s <> 'CF404' then raise exception 'FAIL B7 agendar para outro paciente: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, px, unit, svc, prof, slot2));
  if s <> 'CF404' then raise exception 'FAIL B8 paciente de outra org: %', s; end if; n := n + 1;
  -- regras: serviço não liberado, antecedência, fora da disponibilidade, minuto desalinhado, passado
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc_off, prof, slot2));
  if s <> 'CF409' then raise exception 'FAIL B9 servico nao liberado: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, now() + interval '30 minutes'));
  if s <> 'CF409' then raise exception 'FAIL B10 antecedencia minima: %', s; end if; n := n + 1;
  perform pg_temp.as_user(uo);
  perform public.rpc_set_portal_settings(org, 168, 24, 60, 5, 2);
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, slot2 + interval '1 day'));
  if s <> 'CF409' then raise exception 'FAIL B10b antecedencia dentro do expediente: %', s; end if; n := n + 1;
  if exists (select 1 from public.rpc_portal_slots(org, unit, svc, prof, (current_date + 5), (current_date + 5))) then raise exception 'FAIL B10c slots dentro da antecedencia'; end if; n := n + 1;
  perform pg_temp.as_user(uo);
  perform public.rpc_set_portal_settings(org, 2, 24, 60, 5, 2);
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, ((current_date + 5)::timestamp + time '19:00') at time zone 'America/Bahia'));
  if s <> 'CF409' then raise exception 'FAIL B11 fora da disponibilidade: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, slot2 + interval '7 minutes'));
  if s <> 'CF409' then raise exception 'FAIL B12 minuto desalinhado: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, now() + interval '200 days'));
  if s <> 'CF409' then raise exception 'FAIL B13 alem do horizonte: %', s; end if; n := n + 1;
  -- responsável agenda para o dependente
  perform pg_temp.as_user(ug);
  ev3 := public.rpc_portal_book(org, pd, unit, svc, prof, slot2);
  if pg_temp.sc(format('select patient_id from public.scheduling_events where id = %L', ev3)) <> pd::text then raise exception 'FAIL B14 dependente'; end if; n := n + 1;
  -- A não vê o do dependente; responsável vê
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select * from public.rpc_portal_appointments(%L,%L)', org, pd));
  if s <> 'CF404' then raise exception 'FAIL B15 A lista agenda do dependente alheio: %', s; end if; n := n + 1;

  -- ============ meus agendamentos ============
  select * into r from public.rpc_portal_appointments(org, pa) limit 1;
  if r.event_id <> ev or r.status <> 'scheduled' or r.can_cancel is not true or r.professional_name <> 'Dra. Sintetica' or r.service_name <> 'Consulta online' then
    raise exception 'FAIL M1 lista %', to_jsonb(r); end if; n := n + 1;
  if (select count(*) from public.rpc_portal_appointments(org, pa)) <> 1 then raise exception 'FAIL M2 so os meus'; end if; n := n + 1;
  -- acesso direto às tabelas: nada
  if (select count(*) from public.scheduling_events) <> 0 then raise exception 'FAIL M3 paciente le eventos'; end if; n := n + 1;
  if (select count(*) from public.resource_allocations) <> 0 then raise exception 'FAIL M4 paciente le alocacoes'; end if; n := n + 1;
  if (select count(*) from public.audit_logs) <> 0 then raise exception 'FAIL M5 paciente le auditoria'; end if; n := n + 1;
  s := pg_temp.st(format($q$update public.scheduling_events set status = 'cancelled', cancel_reason = 'xxx' where id = %L$q$, ev));
  if s = 'OK' then
    if (select status from public.scheduling_events where id = ev) <> 'scheduled' then raise exception 'FAIL M6 update direto'; end if;
  end if; n := n + 1;
  execute 'reset role';
  if (select status from public.scheduling_events where id = ev) <> 'scheduled' then raise exception 'FAIL M6b update direto'; end if;
  perform pg_temp.as_user(ua);

  -- ============ cancelar ============
  perform pg_temp.as_user(ub);
  s := pg_temp.st(format('select public.rpc_portal_cancel(%L,%L)', org, ev));
  if s <> 'CF404' then raise exception 'FAIL C1 cancelar de outro: %', s; end if; n := n + 1;
  perform pg_temp.as_user(ua);
  perform public.rpc_portal_cancel(org, ev, 'nao poderei ir');
  if pg_temp.sc(format('select status from public.scheduling_events where id = %L', ev)) <> 'cancelled' then raise exception 'FAIL C2'; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.resource_allocations where event_id = %L and status = 'active'$q$, ev)) <> '0' then raise exception 'FAIL C3 recursos presos'; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_cancel(%L,%L)', org, ev));
  if s <> 'CF409' then raise exception 'FAIL C4 cancelar duas vezes: %', s; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.audit_logs where resource_id = %L and action = 'portal.cancel' and actor_id = %L$q$, ev, ua)) <> '1' then raise exception 'FAIL C5 auditoria'; end if; n := n + 1;
  -- horário volta a ficar livre
  ev := public.rpc_portal_book(org, pa, unit, svc, prof, slot);
  n := n + 1;
  -- prazo mínimo para cancelar
  perform pg_temp.as_user(uo);
  perform public.rpc_set_portal_settings(org, 2, 24 * 7, 60, 5, 2);
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select public.rpc_portal_cancel(%L,%L)', org, ev));
  if s <> 'CF409' then raise exception 'FAIL C6 prazo de cancelamento: %', s; end if; n := n + 1;
  if (select can_cancel from public.rpc_portal_appointments(org, pa) where event_id = ev) is not false then raise exception 'FAIL C7 can_cancel'; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_reschedule(%L,%L,%L)', org, ev, slot3));
  if s <> 'CF409' then raise exception 'FAIL C8 prazo de remarcacao: %', s; end if; n := n + 1;
  perform pg_temp.as_user(uo);
  perform public.rpc_set_portal_settings(org, 2, 24, 60, 5, 2);
  perform pg_temp.as_user(ua);

  -- ============ remarcar ============
  s := pg_temp.st(format('select public.rpc_portal_reschedule(%L,%L,%L)', org, ev, slot2));
  if s <> 'CF409' then raise exception 'FAIL R1 remarcar para horario ocupado: %', s; end if; n := n + 1;
  if pg_temp.sc(format('select status from public.scheduling_events where id = %L', ev)) <> 'scheduled'
     or pg_temp.sc(format($q$select count(*) from public.resource_allocations where event_id = %L and status = 'active'$q$, ev)) <> '2' then
    raise exception 'FAIL R2 remarcacao falha nao e atomica'; end if; n := n + 1;
  perform pg_temp.as_user(ub);
  s := pg_temp.st(format('select public.rpc_portal_reschedule(%L,%L,%L)', org, ev, slot3));
  if s <> 'CF404' then raise exception 'FAIL R3 remarcar de outro: %', s; end if; n := n + 1;
  perform pg_temp.as_user(ua);
  ev2 := public.rpc_portal_reschedule(org, ev, slot3);
  if pg_temp.sc(format('select status from public.scheduling_events where id = %L', ev)) <> 'cancelled'
     or pg_temp.sc(format('select rescheduled_from from public.scheduling_events where id = %L', ev2)) <> ev::text
     or pg_temp.sc(format('select (starts_at = %L)::text from public.scheduling_events where id = %L', slot3, ev2)) <> 'true' then raise exception 'FAIL R4 remarcar'; end if; n := n + 1;
  if pg_temp.sc(format($q$select count(*) from public.resource_allocations where event_id = %L and status = 'active'$q$, ev2)) <> '2' then raise exception 'FAIL R5 recursos novos'; end if; n := n + 1;
  if public.rpc_portal_reschedule(org, ev, slot3) <> ev2 then raise exception 'FAIL R5b remarcacao repetida'; end if; n := n + 1;
  ev := public.rpc_portal_reschedule(org, ev2, slot);          -- 2ª remarcação (limite = 2)
  s := pg_temp.st(format('select public.rpc_portal_reschedule(%L,%L,%L)', org, ev, slot3));
  if s <> 'CF409' then raise exception 'FAIL R6 limite de remarcacoes: %', s; end if; n := n + 1;

  -- ============ limite de agendamentos ativos ============
  perform pg_temp.as_user(uo);
  perform public.rpc_set_portal_settings(org, 2, 24, 60, 1, 2);
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, slot2 + interval '1 day'));
  if s <> 'CF409' then raise exception 'FAIL L1 limite ativos: %', s; end if; n := n + 1;

  -- ============ vínculo revogado e anon ============
  perform pg_temp.as_user(uo);
  perform public.rpc_revoke_patient_link(org, (select id from public.patient_identity_links where patient_id = pa and revoked_at is null));
  perform pg_temp.as_user(ua);
  s := pg_temp.st(format('select * from public.rpc_portal_appointments(%L,%L)', org, pa));
  if s <> 'CF404' then raise exception 'FAIL V1 vinculo revogado lista: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_cancel(%L,%L)', org, ev));
  if s <> 'CF404' then raise exception 'FAIL V2 vinculo revogado cancela: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select * from public.rpc_portal_catalog(%L)', org));
  if s <> 'CF404' then raise exception 'FAIL V3 vinculo revogado catalogo: %', s; end if; n := n + 1;
  execute 'reset role'; execute 'set local role anon';
  s := pg_temp.st('select * from public.rpc_portal_context()');
  if s <> '42501' then raise exception 'FAIL V4 anon contexto: %', s; end if; n := n + 1;
  s := pg_temp.st(format('select public.rpc_portal_book(%L,%L,%L,%L,%L,%L)', org, pa, unit, svc, prof, slot2));
  if s <> '42501' then raise exception 'FAIL V5 anon agenda: %', s; end if; n := n + 1;
  -- funções internas não são executáveis por usuário
  perform pg_temp.as_user(ub);
  s := pg_temp.st(format('select app.portal_insert_event(%L,%L,%L,%L,now(),%L::jsonb,null)', org, unit, svc, pb, '[]'));
  if s <> '42501' then raise exception 'FAIL V6 funcao interna: %', s; end if; n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
