#!/usr/bin/env bash
# Teste de concorrência REAL do núcleo de agenda: várias conexões simultâneas confirmadas (commit) contra um
# Postgres de teste LOCAL (nunca contra hml/produção). Uso: PGHOST=/tmp PGPORT=54329 PGUSER=postgres bash concurrency.sh
set -u
cd "$(dirname "$0")/.."
DB="cf_conc_$$"; N="${N:-30}"
P="psql -v ON_ERROR_STOP=1 -q -X"
$P -d postgres -c "create database $DB" >/dev/null || exit 2
trap '$P -d postgres -c "drop database if exists $DB" >/dev/null 2>&1' EXIT
Q="$P -d $DB"
$Q -f tests/local_pg_setup.sql && for f in migrations/*.sql; do $Q -f "$f" || exit 2; done
fail=0
chk() { if [ "$2" = "$3" ]; then echo "OK   $1 (=$3)"; else echo "FAIL $1: esperado $3, obtido $2"; fail=1; fi; }

# Dados confirmados
read -r ORG UNIT PROF ROOM SVC USR <<<"$($Q -At -F' ' <<'SQL'
do $$ begin perform set_config('cf.u', gen_random_uuid()::text, false); end $$;
with u as (insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000','authenticated','authenticated','c@test.invalid','',now(),now()) returning id),
o as (select public.rpc_provision_organization((select id from u), 'Clinica Concorrencia') as id),
un as (insert into public.units (organization_id, name) select id, 'Unidade' from o returning id, organization_id),
pr as (insert into public.professionals (organization_id, full_name) select id, 'Profissional Teste' from o returning id),
pu as (insert into public.professional_units (organization_id, professional_id, unit_id) select o.id, pr.id, un.id from o, pr, un returning 1),
rm as (insert into public.rooms (organization_id, unit_id, name) select organization_id, id, 'S1' from un returning id),
sv as (insert into public.services (organization_id, name, kind, duration_minutes) select id, 'Consulta', 'consultation', 30 from o returning id)
select o.id, un.id, pr.id, rm.id, sv.id, u.id from o, un, pr, rm, sv, u, pu;
SQL
)"
RES="[{\"type\":\"professional\",\"id\":\"$PROF\"},{\"type\":\"room\",\"id\":\"$ROOM\"}]"
book() { # $1=início  -> imprime OK ou sqlstate
  $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$USR","role":"authenticated"}', false);
set role authenticated;
do \$\$ begin perform public.rpc_book_event('$ORG','$UNIT','appointment','$SVC','$1'::timestamptz,null,'$RES'::jsonb);
  raise notice 'OK'; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
}
run_parallel() { # $@ = lista de inícios; cada um em um processo; imprime resultados
  local out; out=$(mktemp)
  for s in "$@"; do ( book "$s" >> "$out" ) & done; wait
  cat "$out"; rm -f "$out"
}
at() { date -u -d "@$(( $(date -u -d "$1 UTC" +%s) + $2 ))" '+%FT%TZ'; }
count() { grep -c "^$1$" <<<"$2"; }

echo "== C1: $N conexões disputando o MESMO horário"
R=$(run_parallel $(for i in $(seq $N); do echo 2027-04-01T13:00:00Z; done))
chk "reservas confirmadas" "$(count OK "$R")" 1
chk "conflitos 409" "$(count CF409 "$R")" $((N-1))
chk "alocações ativas do profissional" "$($Q -At -c "select count(*) from public.resource_allocations where resource_id='$PROF' and status='active' and lower(period)>='2027-04-01'")" 1

echo "== C2: $N horários distintos e disjuntos (sem falso conflito)"
R=$(run_parallel $(for i in $(seq $N); do at "2027-05-01 08:00:00" $((i*7200)); done))
chk "reservas confirmadas" "$(count OK "$R")" $N

echo "== C3: horários sobrepostos aleatórios em janela de 6h ($((N*2)) tentativas)"
R=$(run_parallel $(for i in $(seq $((N*2))); do at "2027-06-01 08:00:00" $(( (RANDOM % 36) * 10 * 60 )); done))
OKS=$(count OK "$R")
chk "nenhuma sobreposição ativa" "$($Q -At -c "select count(*) from public.resource_allocations a join public.resource_allocations b on a.resource_id=b.resource_id and a.id<b.id and a.status='active' and b.status='active' and a.period && b.period")" 0
chk "reservas == eventos agendados" "$($Q -At -c "select count(*) from public.scheduling_events where status='scheduled' and starts_at>='2027-06-01' and starts_at<'2027-07-01'")" "$OKS"
chk "só OK ou CF409" "$(( $(count OK "$R") + $(count CF409 "$R") ))" $((N*2))

echo "== C4: $N cancelamentos simultâneos do mesmo evento"
EV=$($Q -At -c "select id from public.scheduling_events where starts_at='2027-04-01 13:00+00'")
cancel() { $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$USR","role":"authenticated"}', false);
set role authenticated;
do \$\$ begin perform public.rpc_cancel_event('$ORG','$EV','cancelamento concorrente');
  raise notice 'OK'; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
}
out=$(mktemp); for i in $(seq $N); do ( cancel >> "$out" ) & done; wait; R=$(cat "$out"); rm -f "$out"
chk "cancelamentos efetivos" "$(count OK "$R")" 1
chk "linhas de histórico 'cancelled'" "$($Q -At -c "select count(*) from public.appointment_status_history where event_id='$EV' and to_status='cancelled'")" 1

echo "== C5: remarcações concorrentes do mesmo evento para horários diferentes"
EV2=$($Q -At -c "select id from public.scheduling_events where starts_at='2027-05-01 10:00+00'")
resch() { $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$USR","role":"authenticated"}', false);
set role authenticated;
do \$\$ begin perform public.rpc_reschedule_event('$ORG','$EV2','$1'::timestamptz);
  raise notice 'OK'; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
}
out=$(mktemp); for i in $(seq 10); do ( resch "$(at "2027-07-01 08:00:00" $((i*3*3600)))" >> "$out" ) & done; wait; R=$(cat "$out"); rm -f "$out"
chk "remarcações efetivas (a original só pode ser movida uma vez)" "$(count OK "$R")" 1
chk "eventos 'rescheduled' ativos a partir do original" "$($Q -At -c "select count(*) from public.scheduling_events where rescheduled_from='$EV2' and status='scheduled'")" 1

par() { # $1 = bloco plpgsql (como usuário autenticado); imprime OK ou sqlstate
  $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$USR","role":"authenticated"}', false);
set role authenticated;
do \$\$ begin $1 raise notice 'OK'; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
}
par_n() { local out; out=$(mktemp); for i in $(seq "$1"); do ( par "$2" >> "$out" ) & done; wait; cat "$out"; rm -f "$out"; }

echo "== C6: $N check-ins simultâneos do mesmo agendamento"
read -r PAT EVC <<<"$($Q -At -F' ' <<SQL
do \$\$ begin perform set_config('request.jwt.claims', '{"sub":"$USR","role":"authenticated"}', false); end \$\$;
set role authenticated;
with p as (insert into public.patients (organization_id, full_name, birth_date) values ('$ORG','Paciente Concorrente','1990-01-01') returning id),
e as (select public.rpc_book_event_for_patient('$ORG','$UNIT','$SVC', date_trunc('hour', now()) + interval '1 hour', null, '$RES'::jsonb, (select id from p)) as id)
select (select id from p), e.id from e;
SQL
)"
R=$(par_n "$N" "perform public.rpc_check_in('$ORG','$EVC');")
chk "check-ins efetivos" "$(count OK "$R")" 1
chk "duplicados 409" "$(count CF409 "$R")" $((N-1))
chk "linhas de check-in" "$($Q -At -c "select count(*) from public.patient_checkins where event_id='$EVC'")" 1

echo "== C7: $N cadastros simultâneos com o mesmo CPF (hash)"
HASH=$(printf 'a%.0s' $(seq 64))
R=$(par_n "$N" "insert into public.patients (organization_id, full_name, birth_date, cpf_hash, cpf_masked) values ('$ORG','Mesmo CPF','1980-02-02','$HASH','***.***.***-00');")
chk "cadastros efetivos" "$(count OK "$R")" 1
chk "duplicados 23505" "$(count 23505 "$R")" $((N-1))

echo "== C8: dois proprietários se revogando ao mesmo tempo (20 rodadas, org nova a cada rodada)"
survive_bad=0; both_ok=0
for r in $(seq 20); do
  read -r UA UB AA AB OG <<<"$($Q -At <<'SQL' 2>&1 | sed -n 's/.*NOTICE:  IDS //p' | head -1
do $$
declare ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); og uuid; mb uuid; aa uuid; ab uuid; ro uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
    select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now() from unnest(array[ua, ub]) u;
  og := public.rpc_provision_organization(ua, 'Org Owners');
  select id into ro from public.roles where organization_id = og and key = 'owner';
  select a.id into aa from public.user_role_assignments a join public.organization_members m on m.id = a.member_id where m.organization_id = og and m.user_id = ua;
  insert into public.organization_members (organization_id, user_id) values (og, ub) returning id into mb;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (og, mb, ro) returning id into ab;
  raise notice 'IDS % % % % %', ua, ub, aa, ab, og;
end $$;
SQL
)"
  rv() { $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$1","role":"authenticated"}', false);
set role authenticated;
do \$\$ declare c int; begin update public.user_role_assignments set revoked_at = now() where id = '$2';
  get diagnostics c = row_count; raise notice '%', case when c = 1 then 'OK' else 'ZERO' end; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
  }
  out=$(mktemp); ( rv "$UA" "$AB" >> "$out" ) & ( rv "$UB" "$AA" >> "$out" ) & wait; R=$(cat "$out"); rm -f "$out"
  [ "$(count OK "$R")" = 1 ] || both_ok=$((both_ok+1))
  [ "$($Q -At -c "select count(*) from public.user_role_assignments a join public.roles r on r.id=a.role_id where a.organization_id='$OG' and r.key='owner' and a.revoked_at is null")" -ge 1 ] || survive_bad=$((survive_bad+1))
done
chk "rodadas sem exatamente 1 revogação efetiva (a outra: 409, 403 ou 0 linhas)" "$both_ok" 0
chk "rodadas que ficaram sem nenhum proprietário" "$survive_bad" 0

echo "== C9: 12 adendos simultâneos no mesmo prontuário (sequência única, sem perda)"
read -r UD OG REC <<<"$($Q -At <<'SQL' 2>&1 | sed -n 's/.*NOTICE:  IDS //p' | head -1
do $$
declare uo uuid := gen_random_uuid(); ud uuid := gen_random_uuid(); og uuid; rd uuid; md uuid; pr uuid; pt uuid; rec uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
    select u, '00000000-0000-0000-0000-000000000000','authenticated','authenticated', u::text||'@test.invalid','',now(),now() from unnest(array[uo, ud]) u;
  og := public.rpc_provision_organization(uo, 'Org Adendos');
  select id into rd from public.roles where organization_id = og and key = 'doctor';
  insert into public.organization_members (organization_id, user_id) values (og, ud) returning id into md;
  insert into public.user_role_assignments (organization_id, member_id, role_id) values (og, md, rd);
  insert into public.professionals (organization_id, full_name, member_id) values (og, 'Dr. Concorrente', md) returning id into pr;
  insert into public.patients (organization_id, full_name, birth_date) values (og, 'Paciente C9', '1990-01-01') returning id into pt;
  insert into public.care_relationships (organization_id, patient_id, professional_id, source, reason) values (og, pt, pr, 'manual', 'Vinculo de teste');
  perform set_config('request.jwt.claims', json_build_object('sub', ud, 'role', 'authenticated')::text, true);
  set local role authenticated;
  rec := public.rpc_create_clinical_record(og, pt, 'evolution', 'Evolucao C9', 'Texto base');
  perform public.rpc_finalize_clinical_record(og, rec);
  reset role;
  raise notice 'IDS % % %', ud, og, rec;
end $$;
SQL
)"
add_one() { $Q -At <<SQL 2>&1 | sed -n "s/.*NOTICE:  //p" | head -1
select set_config('request.jwt.claims', '{"sub":"$UD","role":"authenticated"}', false);
set role authenticated;
do \$\$ begin perform public.rpc_add_clinical_addendum('$OG', '$REC', 'complemento', 'Adendo concorrente $1');
  raise notice 'OK'; exception when others then raise notice '%', sqlstate; end \$\$;
SQL
}
out=$(mktemp); for i in $(seq 12); do ( add_one "$i" >> "$out" ) & done; wait; R=$(cat "$out"); rm -f "$out"
chk "adendos concluídos com sucesso (de 12)" "$(count OK "$R")" 12
chk "sequências distintas 1..12 sem buracos" "$($Q -At -c "select count(distinct seq) || '/' || max(seq) || '/' || min(seq) from public.clinical_addenda where record_id = '$REC'")" "12/12/1"

[ "$fail" -eq 0 ] && echo "CONCURRENCY_OK" || echo "CONCURRENCY_FAIL"
exit "$fail"
