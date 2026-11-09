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

[ "$fail" -eq 0 ] && echo "CONCURRENCY_OK" || echo "CONCURRENCY_FAIL"
exit "$fail"
