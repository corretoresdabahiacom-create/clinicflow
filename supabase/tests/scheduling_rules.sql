-- 1B: regras da agenda, RLS dos cadastros, imutabilidade e atomicidade. Dados sintéticos; rollback proposital.
-- Sucesso = 'TESTS_OK n'. Concorrência real (várias conexões): ver tests/concurrency.sh.
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
  uo uuid := gen_random_uuid(); ur uuid := gen_random_uuid(); ud uuid := gen_random_uuid(); ux uuid := gen_random_uuid(); uus uuid := gen_random_uuid();
  org uuid; org2 uuid; mr uuid; md uuid; mus uuid; role_rec uuid; role_doc uuid;
  uA uuid; uB uuid; prof uuid; prof2 uuid; roomA uuid; roomB uuid; eq uuid; svc uuid; svc2 uuid; room_org2 uuid; unit2 uuid;
  e1 uuid; e2 uuid; e3 uuid; e4 uuid; cnt int; n int := 0; s text; res jsonb; t0 timestamptz := '2027-03-01 13:00:00+00';
  ev_before int; per tstzrange; st text;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u::text || '@test.invalid', '', now(), now()
  from unnest(array[uo, ur, ud, ux, uus]) u;
  org := public.rpc_provision_organization(uo, 'Clinica Agenda');
  org2 := public.rpc_provision_organization(ux, 'Clinica Outra');
  select id into role_rec from public.roles where organization_id = org and key = 'receptionist';
  select id into role_doc from public.roles where organization_id = org and key = 'doctor';
  insert into public.organization_members (organization_id, user_id) values (org, ur) returning id into mr;
  insert into public.organization_members (organization_id, user_id) values (org, ud) returning id into md;
  insert into public.organization_members (organization_id, user_id) values (org, uus) returning id into mus;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (org, mr, role_rec), (org, md, role_doc);
  insert into public.units (organization_id, name) values (org, 'Unidade A') returning id into uA;
  insert into public.units (organization_id, name) values (org, 'Unidade B') returning id into uB;
  -- recepcionista restrita à unidade A
  insert into public.user_role_assignments (organization_id, member_id, role_id, unit_id) values (org, mus, role_rec, uA);
  insert into public.units (organization_id, name) values (org2, 'Unidade X') returning id into unit2;
  insert into public.rooms (organization_id, unit_id, name) values (org2, unit2, 'Sala X') returning id into room_org2;

  -- S1 cadastros pelo proprietário (RLS ativa)
  perform pg_temp.as_user(uo);
  insert into public.professionals (organization_id, full_name, council, council_number, council_uf, specialty)
    values (org, 'Dra. Teste Um', 'CRM', '12345', 'BA', 'Clínica geral') returning id into prof;
  insert into public.professionals (organization_id, full_name) values (org, 'Dr. Teste Dois') returning id into prof2;
  insert into public.professional_units (organization_id, professional_id, unit_id) values (org, prof, uA), (org, prof2, uA);
  insert into public.rooms (organization_id, unit_id, name, capacity) values (org, uA, 'Sala 1', 1) returning id into roomA;
  insert into public.rooms (organization_id, unit_id, name) values (org, uB, 'Sala B') returning id into roomB;
  insert into public.equipment (organization_id, unit_id, name) values (org, uA, 'Ultrassom') returning id into eq;
  insert into public.services (organization_id, name, kind, duration_minutes, buffer_before_minutes, buffer_after_minutes)
    values (org, 'Consulta', 'consultation', 30, 10, 10) returning id into svc;
  insert into public.service_resource_requirements (organization_id, service_id, resource_type) values (org, svc, 'professional'), (org, svc, 'room');
  insert into public.services (organization_id, name, kind, duration_minutes) values (org, 'Exame US', 'exam', 20) returning id into svc2;
  n := n + 1;

  -- S2 agendar: período inclui buffers, histórico e auditoria na mesma transação
  res := jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',roomA));
  e1 := public.rpc_book_event(org, uA, 'appointment', svc, t0, null, res);
  select period into per from public.resource_allocations where event_id = e1 and resource_type = 'room';
  if per <> tstzrange(t0 - interval '10 min', t0 + interval '40 min', '[)') then raise exception 'FAIL S2 period %', per; end if; n := n + 1;
  select count(*) into cnt from public.appointment_status_history where event_id = e1 and to_status = 'scheduled';
  if cnt <> 1 then raise exception 'FAIL S2 history'; end if; n := n + 1;
  select count(*) into cnt from public.audit_logs where organization_id = org and action = 'agenda.book' and resource_id = e1::text;
  if cnt <> 1 then raise exception 'FAIL S2 audit'; end if; n := n + 1;

  -- S3 conflito mesmo profissional/sala: CF409 e nada vaza (tudo-ou-nada)
  select count(*) into ev_before from public.scheduling_events where organization_id = org;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '15 min', res));
  if s <> 'CF409' then raise exception 'FAIL S3 conflict sqlstate=%', s; end if; n := n + 1;
  select count(*) into cnt from public.scheduling_events where organization_id = org;
  if cnt <> ev_before then raise exception 'FAIL S3 leaked event'; end if; n := n + 1;
  -- conflito parcial: profissional livre mas sala ocupada -> o profissional NÃO fica reservado
  res := jsonb_build_array(jsonb_build_object('type','professional','id',prof2), jsonb_build_object('type','room','id',roomA));
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '15 min', res));
  if s <> 'CF409' then raise exception 'FAIL S3b'; end if;
  select count(*) into cnt from public.resource_allocations where resource_id = prof2;
  if cnt <> 0 then raise exception 'FAIL S3b partial reservation leaked'; end if; n := n + 1;

  -- S4 limites: período é [ , ) incluindo buffers. e1 ocupa [12:50,13:40). Novo com buffer: start-10 >= 13:40 => start >= 13:50
  res := jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',roomA));
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '49 min', res));
  if s <> 'CF409' then raise exception 'FAIL S4 49min should conflict: %', s; end if;
  e2 := public.rpc_book_event(org, uA, 'appointment', svc, t0 + interval '50 min', null, res);
  n := n + 1;
  -- mesmo instante em outro offset também conflita
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L::timestamptz,null,%L::jsonb)$q$, org, uA, svc, '2027-03-01 10:50:00-03', res));
  if s <> 'CF409' then raise exception 'FAIL S4 offset: %', s; end if; n := n + 1;

  -- S5 requisitos do serviço e recursos inválidos
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '3 hours',
        jsonb_build_array(jsonb_build_object('type','professional','id',prof))));
  if s <> 'CF422' then raise exception 'FAIL S5 missing room type: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '3 hours',
        jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',roomB))));
  if s <> 'CF422' then raise exception 'FAIL S5 room from other unit: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '3 hours',
        jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',room_org2))));
  if s <> 'CF422' then raise exception 'FAIL S5 room from other org: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '3 hours',
        jsonb_build_array(jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','professional','id',prof), jsonb_build_object('type','room','id',roomA))));
  if s <> 'CF422' then raise exception 'FAIL S5 duplicate: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '3 hours',
        jsonb_build_array(jsonb_build_object('type','professional','id','not-a-uuid'), jsonb_build_object('type','room','id',roomA))));
  if s <> 'CF422' then raise exception 'FAIL S5 bad uuid: %', s; end if;
  -- profissional sem vínculo com a unidade B
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'Bloqueio')$q$, org, uB, t0, t0 + interval '1 hour',
        jsonb_build_array(jsonb_build_object('type','professional','id',prof))));
  if s <> 'CF422' then raise exception 'FAIL S5 professional not in unit: %', s; end if; n := n + 1;
  -- serviço inativo e profissional inativo
  update public.services set status = 'inactive' where id = svc2;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc2, t0 + interval '5 hours',
        jsonb_build_array(jsonb_build_object('type','room','id',roomA))));
  if s <> 'CF404' then raise exception 'FAIL S5 inactive service: %', s; end if;
  update public.rooms set status = 'inactive' where id = roomA;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'Bloqueio')$q$, org, uA, t0 + interval '6 hours', t0 + interval '7 hours',
        jsonb_build_array(jsonb_build_object('type','room','id',roomA))));
  if s <> 'CF422' then raise exception 'FAIL S5 inactive room: %', s; end if;
  update public.rooms set status = 'active' where id = roomA; n := n + 1;

  -- S6 bloqueio/manutenção ocupam o recurso
  e3 := public.rpc_book_event(org, uA, 'maintenance', null, t0 + interval '8 hours', t0 + interval '10 hours',
          jsonb_build_array(jsonb_build_object('type','equipment','id',eq)), 'Manutenção US');
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'Outro')$q$, org, uA, t0 + interval '9 hours', t0 + interval '11 hours',
        jsonb_build_array(jsonb_build_object('type','equipment','id',eq))));
  if s <> 'CF409' then raise exception 'FAIL S6: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',%L,%L,%L,%L::jsonb,'x')$q$, org, uA, svc, t0 + interval '12 hours', t0 + interval '13 hours',
        jsonb_build_array(jsonb_build_object('type','equipment','id',eq))));
  if s <> 'CF422' then raise exception 'FAIL S6 block with service: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'x')$q$, org, uA, t0 + interval '12 hours', t0 + interval '30 hours',
        jsonb_build_array(jsonb_build_object('type','equipment','id',eq))));
  if s <> 'CF422' then raise exception 'FAIL S6 >12h: %', s; end if; n := n + 1;

  -- S7 cancelar libera; só quem tem agenda.write; duplo cancelamento = 409
  perform pg_temp.as_user(ud);
  s := pg_temp.st(format($q$select public.rpc_cancel_event(%L,%L,'motivo teste')$q$, org, e2));
  if s <> '42501' then raise exception 'FAIL S7 doctor cancel: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'appointment',%L,%L,null,%L::jsonb)$q$, org, uA, svc, t0 + interval '20 hours', res));
  if s <> '42501' then raise exception 'FAIL S7 doctor book: %', s; end if; n := n + 1;
  perform pg_temp.as_user(ur);
  perform public.rpc_cancel_event(org, e2, 'paciente desistiu');
  s := pg_temp.st(format($q$select public.rpc_cancel_event(%L,%L,'de novo')$q$, org, e2));
  if s <> 'CF409' then raise exception 'FAIL S7 double cancel: %', s; end if;
  s := pg_temp.st(format($q$select public.rpc_cancel_event(%L,%L,'ab')$q$, org, e1));
  if s <> 'CF422' then raise exception 'FAIL S7 short reason: %', s; end if;
  e2 := public.rpc_book_event(org, uA, 'appointment', svc, t0 + interval '50 min', null, res);  -- mesmo horário reaproveitado
  select count(*) into cnt from public.appointment_status_history where organization_id = org and to_status = 'cancelled';
  if cnt <> 1 then raise exception 'FAIL S7 history'; end if; n := n + 1;

  -- S8 remarcar: atômico, vínculo, sobreposição consigo mesmo permitida, conflito mantém original
  e4 := public.rpc_reschedule_event(org, e2, t0 + interval '65 min');   -- desloca 15 min (sobrepõe a si mesmo)
  select count(*) into cnt from public.scheduling_events where id = e2 and status = 'cancelled' and cancel_reason = 'rescheduled';
  if cnt <> 1 then raise exception 'FAIL S8 old not cancelled'; end if;
  select count(*) into cnt from public.scheduling_events where id = e4 and rescheduled_from = e2 and status = 'scheduled' and ends_at - starts_at = interval '30 min';
  if cnt <> 1 then raise exception 'FAIL S8 new event'; end if; n := n + 1;
  s := pg_temp.st(format($q$select public.rpc_reschedule_event(%L,%L,%L)$q$, org, e4, t0));  -- cairia sobre e1
  if s <> 'CF409' then raise exception 'FAIL S8 conflict: %', s; end if;
  select count(*) into cnt from public.scheduling_events where id = e4 and status = 'scheduled';
  if cnt <> 1 then raise exception 'FAIL S8 original lost on conflict'; end if;
  select count(*) into cnt from public.resource_allocations where event_id = e4 and status = 'active';
  if cnt <> 2 then raise exception 'FAIL S8 allocations lost on conflict (%)', cnt; end if; n := n + 1;

  -- S9 RLS: leitura por papel, escrita direta negada, outsiders enxergam zero
  perform pg_temp.as_user(ud);
  select count(*) into cnt from public.scheduling_events;
  if cnt < 3 then raise exception 'FAIL S9 doctor should read events'; end if;
  if pg_temp.st(format($q$insert into public.scheduling_events (organization_id, unit_id, kind, title, starts_at, ends_at) values (%L,%L,'block','x1',now(),now()+interval '1h')$q$, org, uA)) <> '42501' then raise exception 'FAIL S9 direct insert event'; end if;
  if pg_temp.st(format($q$update public.scheduling_events set status='cancelled', cancel_reason='abc' where id=%L$q$, e4)) <> '42501' then raise exception 'FAIL S9 direct update event'; end if;
  if pg_temp.st(format($q$delete from public.scheduling_events where id=%L$q$, e4)) <> '42501' then raise exception 'FAIL S9 delete event'; end if;
  if pg_temp.st(format($q$update public.resource_allocations set status='released' where event_id=%L$q$, e4)) <> '42501' then raise exception 'FAIL S9 direct update alloc'; end if;
  if pg_temp.st(format($q$insert into public.professionals (organization_id, full_name) values (%L,'Invasor')$q$, org)) <> '42501' then raise exception 'FAIL S9 doctor creates professional'; end if;
  perform pg_temp.as_user(ur);
  if pg_temp.st(format($q$insert into public.services (organization_id, name, kind, duration_minutes) values (%L,'Hack','exam',10)$q$, org)) <> '42501' then raise exception 'FAIL S9 receptionist creates service'; end if;
  if pg_temp.st(format($q$insert into public.rooms (organization_id, unit_id, name) values (%L,%L,'Hack')$q$, org, uA)) <> '42501' then raise exception 'FAIL S9 receptionist creates room'; end if;
  perform pg_temp.as_user(ux);
  select count(*) into cnt from public.scheduling_events; if cnt <> 0 then raise exception 'FAIL S9 outsider events %', cnt; end if;
  select count(*) into cnt from public.professionals where organization_id = org; if cnt <> 0 then raise exception 'FAIL S9 outsider professionals'; end if;
  select count(*) into cnt from public.rooms where organization_id = org; if cnt <> 0 then raise exception 'FAIL S9 outsider rooms'; end if;
  select count(*) into cnt from public.resource_allocations; if cnt <> 0 then raise exception 'FAIL S9 outsider allocations'; end if;
  if pg_temp.st(format($q$select public.rpc_cancel_event(%L,%L,'invasor')$q$, org, e4)) <> 'CF404' then raise exception 'FAIL S9 cross-org cancel'; end if;
  if pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'Invasor')$q$, org, uA, t0, t0 + interval '1h',
      jsonb_build_array(jsonb_build_object('type','room','id',roomA)))) <> '42501' then raise exception 'FAIL S9 cross-org book'; end if;
  -- ator da org2 tentando usar recurso da org2 em unidade da org1 também falha por permissão
  n := n + 1;

  -- S10 escopo de unidade: recepcionista só da unidade A
  perform pg_temp.as_user(uus);
  select count(*) into cnt from public.scheduling_events where unit_id = uB; if cnt <> 0 then raise exception 'FAIL S10 reads unit B'; end if;
  select count(*) into cnt from public.scheduling_events where unit_id = uA; if cnt < 3 then raise exception 'FAIL S10 cannot read unit A'; end if;
  if pg_temp.st(format($q$select public.rpc_book_event(%L,%L,'block',null,%L,%L,%L::jsonb,'Sala B')$q$, org, uB, t0, t0 + interval '1h',
      jsonb_build_array(jsonb_build_object('type','room','id',roomB)))) <> '42501' then raise exception 'FAIL S10 books unit B'; end if;
  select count(*) into cnt from public.rooms where unit_id = uB; if cnt <> 0 then raise exception 'FAIL S10 reads rooms B'; end if;
  n := n + 1;

  -- S11 imutabilidade (mesmo para o dono do banco)
  execute 'reset role';
  if pg_temp.st(format($q$update public.scheduling_events set starts_at = starts_at + interval '1h', ends_at = ends_at + interval '1h' where id=%L$q$, e4)) <> '42501' then raise exception 'FAIL S11 move event'; end if;
  if pg_temp.st(format($q$update public.scheduling_events set status='scheduled', cancel_reason=null where id=%L$q$, e2)) <> '42501' then raise exception 'FAIL S11 reopen'; end if;
  if pg_temp.st($q$update public.appointment_status_history set reason='x'$q$) <> '42501' then raise exception 'FAIL S11 history update'; end if;
  if pg_temp.st($q$delete from public.appointment_status_history$q$) <> '42501' then raise exception 'FAIL S11 history delete'; end if;
  if pg_temp.st(format($q$update public.resource_allocations set period = tstzrange(now(), now()+interval '1h') where event_id=%L$q$, e4)) <> '42501' then raise exception 'FAIL S11 alloc period'; end if;
  if pg_temp.st(format($q$update public.resource_allocations set status='active' where event_id=%L and status='released'$q$, e2)) <> '42501' then raise exception 'FAIL S11 alloc reactivate'; end if;
  n := n + 1;

  -- S12 integridade dos cadastros
  if pg_temp.st(format($q$insert into public.professionals (organization_id, full_name, council) values (%L,'Sem numero','CRM')$q$, org)) <> '23514' then raise exception 'FAIL S12 council all-or-none'; end if;
  if pg_temp.st(format($q$insert into public.professionals (organization_id, full_name, council, council_number, council_uf) values (%L,'UF ruim','CRM','1','bahia')$q$, org)) <> '23514' then raise exception 'FAIL S12 uf'; end if;
  if pg_temp.st(format($q$insert into public.services (organization_id, name, kind, duration_minutes) values (%L,'Curta','exam',1)$q$, org)) <> '23514' then raise exception 'FAIL S12 duration'; end if;
  if pg_temp.st(format($q$insert into public.rooms (organization_id, unit_id, name) values (%L,%L,'Sala X')$q$, org2, uA)) <> '23503' then raise exception 'FAIL S12 composite fk room->unit'; end if;
  if pg_temp.st(format($q$insert into public.professional_units (organization_id, professional_id, unit_id) values (%L,%L,%L)$q$, org2, prof, unit2)) <> '23503' then raise exception 'FAIL S12 composite fk pu'; end if;
  n := n + 1;

  -- S13 backfill/provisionamento: papéis de sistema receberam as permissões novas
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
    where r.organization_id = org2 and r.key = 'receptionist' and rp.permission_key in ('agenda.write','agenda.read');
  if cnt <> 2 then raise exception 'FAIL S13 receptionist perms'; end if;
  select count(*) into cnt from public.role_permissions rp join public.roles r on r.id = rp.role_id
    where r.organization_id = org2 and r.key = 'doctor' and rp.permission_key = 'agenda.write';
  if cnt <> 0 then raise exception 'FAIL S13 doctor must not write agenda'; end if; n := n + 1;

  raise exception 'TESTS_OK %', n;
end $$;
