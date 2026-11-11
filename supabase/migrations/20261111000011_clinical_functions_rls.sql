-- 1D / migration 11: funções de acesso clínico, RPCs, políticas de leitura e privilégios.
-- Toda leitura/escrita de conteúdo clínico passa por RPC security definer: valida papel + vínculo (ou emergência) + finalidade,
-- grava data_access_logs na mesma transação e nunca devolve conteúdo sem registrar.
-- Códigos: CF404 (não encontrado, também para quem não é membro), CF409 (estado), CF422 (inválido), 42501 (negado).

-- Contexto da requisição (correlação/IP/UA repassados pelo Worker)
create function app.req_ctx(out corr text, out ip inet, out ua text) language plpgsql stable set search_path = '' as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  corr := left(nullif(h ->> 'x-correlation-id', ''), 100);
  begin ip := nullif(h ->> 'x-client-ip', '')::inet; exception when others then ip := null; end;
  ua := left(nullif(h ->> 'x-client-ua', ''), 300);
end $$;

-- Profissional (ativo) ligado ao usuário logado na organização
create function app.my_professional(p_org uuid) returns uuid language sql stable security definer set search_path = '' as $$
  select p.id
  from public.professionals p
  join public.organization_members m on m.organization_id = p.organization_id and m.id = p.member_id
  join public.organizations o on o.id = p.organization_id and o.status = 'active'
  where p.organization_id = p_org and p.status = 'active' and m.status = 'active' and m.user_id = (select auth.uid());
$$;

create function app.has_care_link(p_org uuid, p_patient uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select app.my_professional(p_org) is not null
    and app.has_perm_any(p_org, 'clinical.read')
    and exists (
      select 1 from public.care_relationships c
      where c.organization_id = p_org and c.patient_id = p_patient and c.professional_id = app.my_professional(p_org)
        and c.revoked_at is null and c.valid_from <= now() and (c.valid_to is null or c.valid_to > now()));
$$;

-- Porta única do acesso clínico. purpose: 'care' (exige vínculo ativo) ou 'emergency' (exige acesso de emergência vigente; só leitura).
create function app.clinical_gate(p_org uuid, p_patient uuid, p_perm text, p_purpose text,
  out o_prof uuid, out o_basis text, out o_rel uuid, out o_grant uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_purpose is null or p_purpose not in ('care','emergency') then
    raise exception 'invalid purpose' using errcode = 'CF422';
  end if;
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  o_prof := app.my_professional(p_org);
  if o_prof is null or not app.has_perm_any(p_org, p_perm) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients where organization_id = p_org and id = p_patient) then
    raise exception 'not found' using errcode = 'CF404';
  end if;
  if p_purpose = 'care' then
    select c.id into o_rel from public.care_relationships c
     where c.organization_id = p_org and c.patient_id = p_patient and c.professional_id = o_prof
       and c.revoked_at is null and c.valid_from <= now() and (c.valid_to is null or c.valid_to > now())
     order by c.id limit 1;
    if o_rel is null then raise exception 'forbidden' using errcode = '42501'; end if;
    o_basis := 'relationship';
  else
    if p_perm <> 'clinical.read' or not app.has_perm_any(p_org, 'clinical.emergency') then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    select g.id into o_grant from public.emergency_access_grants g
     where g.organization_id = p_org and g.patient_id = p_patient and g.professional_id = o_prof and g.expires_at > now()
     order by g.id limit 1;
    if o_grant is null then raise exception 'forbidden' using errcode = '42501'; end if;
    o_basis := 'emergency';
  end if;
end $$;

create function app.log_access(p_org uuid, p_patient uuid, p_prof uuid, p_action text, p_rtype text, p_rid text,
                               p_purpose text, p_basis text, p_rel uuid, p_grant uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from app.req_ctx();
  insert into public.data_access_logs (organization_id, patient_id, actor_id, professional_id, action, resource_type, resource_id,
                                       purpose, basis, relationship_id, grant_id, correlation_id, ip, user_agent)
  values (p_org, p_patient, (select auth.uid()), p_prof, p_action, p_rtype, p_rid, p_purpose, p_basis, p_rel, p_grant, c.corr, c.ip, c.ua);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Escrita clínica (sempre finalidade 'care' + vínculo ativo + profissional vinculado ao usuário)
-- ---------------------------------------------------------------------------------------------------------
create function public.rpc_create_clinical_record(p_org uuid, p_patient uuid, p_kind text, p_title text, p_body text, p_event uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare g record; v_id uuid;
begin
  select * into g from app.clinical_gate(p_org, p_patient, 'clinical.write', 'care');
  if p_kind is null or p_kind not in ('anamnesis','evolution','conduct') then raise exception 'invalid kind' using errcode = 'CF422'; end if;
  if p_event is not null and not exists (
       select 1 from public.scheduling_events e where e.organization_id = p_org and e.id = p_event and e.patient_id = p_patient) then
    raise exception 'event does not belong to this patient' using errcode = 'CF422';
  end if;
  begin
    insert into public.clinical_records (organization_id, patient_id, professional_id, event_id, kind, title, body, created_by)
    values (p_org, p_patient, g.o_prof, p_event, p_kind, p_title, p_body, (select auth.uid())) returning id into v_id;
  exception when check_violation then raise exception 'invalid clinical record' using errcode = 'CF422'; end;
  perform app.log_access(p_org, p_patient, g.o_prof, 'create_draft', 'clinical_record', v_id::text, 'care', g.o_basis, g.o_rel, null);
  return v_id;
end $$;

create function public.rpc_update_clinical_draft(p_org uuid, p_record uuid, p_title text, p_body text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.clinical_records; g record;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into r from public.clinical_records where organization_id = p_org and id = p_record for update;
  if r.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into g from app.clinical_gate(p_org, r.patient_id, 'clinical.write', 'care');
  if r.professional_id <> g.o_prof then raise exception 'only the author can edit a draft' using errcode = '42501'; end if;
  if r.status <> 'draft' then raise exception 'record is finalized; use an addendum' using errcode = 'CF409'; end if;
  begin
    update public.clinical_records set title = p_title, body = p_body where id = r.id;
  exception when check_violation then raise exception 'invalid clinical record' using errcode = 'CF422'; end;
  perform app.log_access(p_org, r.patient_id, g.o_prof, 'update_draft', 'clinical_record', r.id::text, 'care', g.o_basis, g.o_rel, null);
end $$;

create function public.rpc_finalize_clinical_record(p_org uuid, p_record uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare r public.clinical_records; g record; v_hash text;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into r from public.clinical_records where organization_id = p_org and id = p_record for update;
  if r.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into g from app.clinical_gate(p_org, r.patient_id, 'clinical.write', 'care');
  if r.professional_id <> g.o_prof then raise exception 'only the author can finalize' using errcode = '42501'; end if;
  if r.status <> 'draft' then raise exception 'record already finalized' using errcode = 'CF409'; end if;
  v_hash := app.clinical_content_hash(r.title, r.body);
  update public.clinical_records set status = 'finalized', content_hash = v_hash, finalized_at = now() where id = r.id;
  perform app.log_access(p_org, r.patient_id, g.o_prof, 'finalize', 'clinical_record', r.id::text, 'care', g.o_basis, g.o_rel, null);
  return v_hash;
end $$;

create function public.rpc_add_clinical_addendum(p_org uuid, p_record uuid, p_reason text, p_body text)
returns integer language plpgsql security definer set search_path = '' as $$
declare r public.clinical_records; g record; v_seq int;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into r from public.clinical_records where organization_id = p_org and id = p_record for update; -- serializa a sequência de adendos
  if r.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into g from app.clinical_gate(p_org, r.patient_id, 'clinical.write', 'care');
  if r.status <> 'finalized' then raise exception 'addendum requires a finalized record' using errcode = 'CF409'; end if;
  select coalesce(max(seq), 0) + 1 into v_seq from public.clinical_addenda where record_id = r.id;
  begin
    insert into public.clinical_addenda (organization_id, record_id, seq, professional_id, reason, body, created_by)
    values (p_org, r.id, v_seq, g.o_prof, p_reason, p_body, (select auth.uid()));
  exception when check_violation then raise exception 'invalid addendum' using errcode = 'CF422'; end;
  perform app.log_access(p_org, r.patient_id, g.o_prof, 'addendum', 'clinical_record', r.id::text, 'care', g.o_basis, g.o_rel, null);
  return v_seq;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Leitura clínica (finalidade declarada: 'care' ou 'emergency'); rascunhos só aparecem para o próprio autor
-- ---------------------------------------------------------------------------------------------------------
create function public.rpc_list_clinical_records(p_org uuid, p_patient uuid, p_purpose text, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g record; v jsonb;
begin
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then raise exception 'invalid paging' using errcode = 'CF422'; end if;
  select * into g from app.clinical_gate(p_org, p_patient, 'clinical.read', p_purpose);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc, x.id desc), '[]'::jsonb) into v
  from (
    select r.id, r.kind, r.title, r.status, r.professional_id, r.event_id, r.created_at, r.finalized_at,
           (select count(*) from public.clinical_addenda a where a.record_id = r.id) as addenda_count
    from public.clinical_records r
    where r.organization_id = p_org and r.patient_id = p_patient and (r.status = 'finalized' or r.professional_id = g.o_prof)
    order by r.created_at desc, r.id desc limit p_limit offset p_offset
  ) x;
  perform app.log_access(p_org, p_patient, g.o_prof, 'list', 'patient', p_patient::text, p_purpose, g.o_basis, g.o_rel, g.o_grant);
  return v;
end $$;

create function public.rpc_get_clinical_record(p_org uuid, p_record uuid, p_purpose text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.clinical_records; g record; v_add jsonb; v_ok boolean;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into r from public.clinical_records where organization_id = p_org and id = p_record;
  if r.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  select * into g from app.clinical_gate(p_org, r.patient_id, 'clinical.read', p_purpose);
  if r.status = 'draft' and r.professional_id <> g.o_prof then raise exception 'not found' using errcode = 'CF404'; end if;
  v_ok := r.status = 'draft' or r.content_hash = app.clinical_content_hash(r.title, r.body);
  select coalesce(jsonb_agg(jsonb_build_object('seq', a.seq, 'professional_id', a.professional_id, 'reason', a.reason,
                                               'body', a.body, 'created_at', a.created_at) order by a.seq), '[]'::jsonb)
    into v_add from public.clinical_addenda a where a.record_id = r.id;
  perform app.log_access(p_org, r.patient_id, g.o_prof, 'view', 'clinical_record', r.id::text, p_purpose, g.o_basis, g.o_rel, g.o_grant);
  return jsonb_build_object(
    'record', jsonb_build_object('id', r.id, 'patient_id', r.patient_id, 'professional_id', r.professional_id, 'event_id', r.event_id,
                                 'kind', r.kind, 'title', r.title, 'body', r.body, 'status', r.status, 'finalized_at', r.finalized_at,
                                 'content_hash', r.content_hash, 'created_at', r.created_at),
    'addenda', v_add,
    'integrity', case when v_ok then 'ok' else 'mismatch' end);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Acesso de emergência (2 h), com revisão posterior por quem tem clinical.audit (nunca o próprio beneficiário)
-- ---------------------------------------------------------------------------------------------------------
create function public.rpc_emergency_access(p_org uuid, p_patient uuid, p_justification text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_prof uuid; v_id uuid;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  v_prof := app.my_professional(p_org);
  if v_prof is null or not app.has_perm_any(p_org, 'clinical.emergency') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients where organization_id = p_org and id = p_patient) then raise exception 'not found' using errcode = 'CF404'; end if;
  if p_justification is null or length(trim(p_justification)) < 20 then raise exception 'justification too short' using errcode = 'CF422'; end if;
  begin
    insert into public.emergency_access_grants (organization_id, patient_id, professional_id, justification, expires_at, created_by)
    values (p_org, p_patient, v_prof, trim(p_justification), now() + interval '2 hours', (select auth.uid())) returning id into v_id;
  exception when check_violation then raise exception 'invalid justification' using errcode = 'CF422'; end;
  perform app.log_access(p_org, p_patient, v_prof, 'emergency_grant', 'emergency_grant', v_id::text, 'emergency', 'emergency', null, v_id);
  return v_id;
end $$;

create function public.rpc_review_emergency_access(p_org uuid, p_grant uuid, p_outcome text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare g public.emergency_access_grants;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  if not app.has_perm_any(p_org, 'clinical.audit') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_outcome is null or p_outcome not in ('justified','not_justified') then raise exception 'invalid outcome' using errcode = 'CF422'; end if;
  select * into g from public.emergency_access_grants where organization_id = p_org and id = p_grant for update;
  if g.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  if g.created_by = (select auth.uid()) then raise exception 'cannot review own emergency access' using errcode = '42501'; end if;
  if g.reviewed_at is not null then raise exception 'already reviewed' using errcode = 'CF409'; end if;
  update public.emergency_access_grants set reviewed_at = now(), reviewed_by = (select auth.uid()), review_outcome = p_outcome, review_note = p_note
   where id = g.id;
  perform app.log_access(p_org, g.patient_id, null, 'emergency_review', 'emergency_grant', g.id::text, 'audit', 'audit_role', null, g.id);
end $$;

-- Verificação de integridade: só devolve verdadeiro/falso (sem conteúdo)
create function public.rpc_verify_clinical_record_integrity(p_org uuid, p_record uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.clinical_records; v_ok boolean;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  if not app.has_perm_any(p_org, 'clinical.audit') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into r from public.clinical_records where organization_id = p_org and id = p_record;
  if r.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  v_ok := r.status = 'finalized' and r.content_hash = app.clinical_content_hash(r.title, r.body);
  perform app.log_access(p_org, r.patient_id, null, 'integrity_check', 'clinical_record', r.id::text, 'audit', 'audit_role', null, null);
  return v_ok;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Vínculo manual
-- ---------------------------------------------------------------------------------------------------------
create function public.rpc_assign_care_relationship(p_org uuid, p_patient uuid, p_professional uuid, p_valid_to timestamptz, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  if not app.has_perm_any(p_org, 'care.assign') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients where organization_id = p_org and id = p_patient and status = 'active')
     or not exists (select 1 from public.professionals where organization_id = p_org and id = p_professional and status = 'active') then
    raise exception 'not found' using errcode = 'CF404';
  end if;
  if p_valid_to is not null and p_valid_to <= now() then raise exception 'valid_to must be in the future' using errcode = 'CF422'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then raise exception 'reason too short' using errcode = 'CF422'; end if;
  begin
    insert into public.care_relationships (organization_id, patient_id, professional_id, source, reason, valid_to, created_by)
    values (p_org, p_patient, p_professional, 'manual', trim(p_reason), p_valid_to, (select auth.uid())) returning id into v_id;
  exception when unique_violation then raise exception 'an active manual relationship already exists' using errcode = 'CF409'; end;
  perform app.log_access(p_org, p_patient, null, 'care_assign', 'care_relationship', v_id::text, 'administration', 'administrative_role', v_id, null);
  return v_id;
end $$;

create function public.rpc_revoke_care_relationship(p_org uuid, p_link uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.care_relationships;
begin
  if not app.is_member(p_org) then raise exception 'not found' using errcode = 'CF404'; end if;
  if not app.has_perm_any(p_org, 'care.assign') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'reason too short' using errcode = 'CF422'; end if;
  select * into c from public.care_relationships where organization_id = p_org and id = p_link for update;
  if c.id is null then raise exception 'not found' using errcode = 'CF404'; end if;
  if c.revoked_at is not null then raise exception 'already revoked' using errcode = 'CF409'; end if;
  update public.care_relationships set revoked_at = now(), revoked_by = (select auth.uid()), revoke_reason = trim(p_reason) where id = c.id;
  perform app.log_access(p_org, c.patient_id, null, 'care_revoke', 'care_relationship', c.id::text, 'administration', 'administrative_role', c.id, null);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Políticas de leitura (tabelas sem conteúdo clínico) e acesso do profissional ao cadastro do paciente vinculado
-- ---------------------------------------------------------------------------------------------------------
create policy care_select on public.care_relationships for select to authenticated
  using (app.has_perm_any(organization_id, 'care.read') or professional_id = app.my_professional(organization_id));
create policy grants_select on public.emergency_access_grants for select to authenticated
  using (app.has_perm_any(organization_id, 'clinical.audit') or professional_id = app.my_professional(organization_id));
create policy access_logs_select on public.data_access_logs for select to authenticated
  using (app.has_perm_any(organization_id, 'clinical.audit'));
grant select on public.care_relationships, public.emergency_access_grants, public.data_access_logs to authenticated;

-- Profissional com vínculo ativo enxerga o cadastro administrativo do paciente (nome, nascimento, máscara do CPF...)
drop policy patients_select on public.patients;
create policy patients_select on public.patients for select to authenticated
  using (app.has_perm_any(organization_id, 'patient.read') or app.patient_self_access(organization_id, id) or app.has_care_link(organization_id, id));

-- ---------------------------------------------------------------------------------------------------------
-- Privilégios: helpers internos sem EXECUTE para usuários; RPCs só para authenticated (e service_role onde cabe)
-- ---------------------------------------------------------------------------------------------------------
revoke all on function app.req_ctx() from public, anon, authenticated;
revoke all on function app.my_professional(uuid) from public, anon;
revoke all on function app.has_care_link(uuid, uuid) from public, anon;
revoke all on function app.clinical_gate(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function app.log_access(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function app.clinical_content_hash(text, text) from public, anon, authenticated;
revoke all on function app.sync_appointment_links(uuid, uuid) from public, anon, authenticated;
revoke all on function app.trg_alloc_care_link() from public, anon, authenticated;
revoke all on function app.trg_event_patient_care_link() from public, anon, authenticated;
revoke all on function app.trg_event_cancel_care_revoke() from public, anon, authenticated;
revoke all on function app.guard_clinical_record() from public, anon, authenticated;
revoke all on function app.guard_clinical_addendum() from public, anon, authenticated;
revoke all on function app.guard_care_relationship() from public, anon, authenticated;
revoke all on function app.guard_emergency_grant() from public, anon, authenticated;
grant execute on function app.my_professional(uuid), app.has_care_link(uuid, uuid) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'rpc_create_clinical_record(uuid,uuid,text,text,text,uuid)', 'rpc_update_clinical_draft(uuid,uuid,text,text)',
    'rpc_finalize_clinical_record(uuid,uuid)', 'rpc_add_clinical_addendum(uuid,uuid,text,text)',
    'rpc_list_clinical_records(uuid,uuid,text,int,int)', 'rpc_get_clinical_record(uuid,uuid,text)',
    'rpc_emergency_access(uuid,uuid,text)', 'rpc_review_emergency_access(uuid,uuid,text,text)',
    'rpc_verify_clinical_record_integrity(uuid,uuid)', 'rpc_assign_care_relationship(uuid,uuid,uuid,timestamptz,text)',
    'rpc_revoke_care_relationship(uuid,uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- Reforço: conteúdo clínico nunca é acessível por tabela, nem por service_role (a 009 concedeu "all tables" antes destas tabelas existirem)
revoke all on public.clinical_records, public.clinical_addenda from public, anon, authenticated, service_role;
