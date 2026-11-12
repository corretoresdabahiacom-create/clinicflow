# MIGRATION — migrations e rollback (Fase 1A)

Aplicadas ao projeto de homologação `tbnzrwgwbmkdjinisrhl` (Supabase free) e versionadas em `supabase/migrations/`. Produção: **nenhuma migration aplicada**.

| Migration | Conteúdo | Rollback |
|---|---|---|
| 20261109000001_foundation_tables | organizations, units, organization_members, roles, role_permissions, user_role_assignments, audit_logs, idempotency_keys, rate_limits, feature_flags | `drop table` na ordem inversa de dependência (somente em hml; dados sintéticos) |
| 20261109000002_foundation_functions | has_perm, rpc_my_context, rpc_provision_organization, rpc_write_audit, rate limit RPC, triggers anti-escalada e imutabilidade | `drop function`/`drop trigger` correspondentes |
| 20261109000003_foundation_rls | ENABLE/FORCE RLS, policies, GRANTs mínimos, REVOKE de anon | `alter table … disable row level security`, `drop policy` (apenas hml) |

Regras: migrations são aditivas e nunca editadas depois de aplicadas; correção = nova migration. Em produção, rollback destrutivo exige backup verificado e aprovação expressa (`docs/BACKUP_RESTORE.md`).

## Fase 1B
| Migration | Conteúdo | Rollback (apenas hml) |
|---|---|---|
| 20261109000004_scheduling_tables | professionals, professional_units, rooms, equipment, services, service_resource_requirements, scheduling_events, resource_allocations (EXCLUDE), appointment_status_history; extensão btree_gist | `drop table` em ordem inversa; `drop extension btree_gist` |
| 20261109000005_scheduling_functions_rls | 8 permissões novas + backfill nos papéis de sistema, `app.system_role_permissions`, provisionamento atualizado, `has_perm_any`, triggers, RLS, RPCs | `drop function/trigger/policy`; remover permissões e role_permissions novas |
| 20261109000006_scheduling_revoke_anon_execute | Revoga EXECUTE de PUBLIC/anon nas funções novas | `grant execute …` (não recomendado) |

## Fase 1C
| Migration | Conteúdo | Rollback (apenas hml) |
|---|---|---|
| 20261110000007_patients_tables | patients, patient_consents, patient_guardianships, patient_identity_links, patient_checkins; FK composta em scheduling_events.patient_id | `alter table scheduling_events drop constraint scheduling_events_patient_fk`; `drop table` em ordem inversa |
| 20261110000008_patients_functions_rls | permissões patient.read/write e checkin.write + backfill, RLS, guardas, RPCs (agendar com paciente, remarcar preservando paciente, check-in, vincular/revogar conta) | `drop function/policy/trigger`; remover permissões |
Nota: rascunhos anteriores de 1C (nunca aplicados nem commitados) foram descartados do repositório.

## Fase 1H
| Migration | Conteúdo | Rollback (apenas hml) |
|---|---|---|
| 20261111000009_hardening | Guarda do último proprietário (triggers + advisory lock), auditoria transacional por trigger (`app.audit_row`) em 14 tabelas, `idempotency_keys.locked_at` + `rpc_purge_idempotency` (service_role), `patients.cpf_key_version`; revoga EXECUTE das funções novas | `drop trigger *_audit/*_last_owner`; `drop function app.audit_row, app.guard_last_owner_*, app.other_owner_exists, app.lock_owners, public.rpc_purge_idempotency`; `alter table … drop column locked_at / cpf_key_version` |

## Fase 1D
| Migration | Conteúdo | Rollback (apenas hml) |
|---|---|---|
| 20261111000010_clinical_tables | permissões care.*/clinical.* + papéis, care_relationships, clinical_records (hash SHA-256 ao finalizar), clinical_addenda, emergency_access_grants, data_access_logs; guardas de imutabilidade; triggers de vínculo por agendamento; auditoria transacional; RLS forçada e sem GRANT | `drop table` em ordem inversa; `drop function app.*` correspondentes; remover permissões/role_permissions |
| 20261111000011_clinical_functions_rls | helpers (`clinical_gate`, `log_access`, `has_care_link`), 11 RPCs, políticas de leitura de vínculos/emergências/log, política de leitura de pacientes com vínculo, privilégios | `drop function/policy`; restaurar `patients_select` da 1C |
