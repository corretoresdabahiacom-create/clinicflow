# MIGRATION — migrations e rollback (Fase 1A)

Aplicadas ao projeto de homologação `tbnzrwgwbmkdjinisrhl` (Supabase free) e versionadas em `supabase/migrations/`. Produção: **nenhuma migration aplicada**.

| Migration | Conteúdo | Rollback |
|---|---|---|
| 20261109000001_foundation_tables | organizations, units, organization_members, roles, role_permissions, user_role_assignments, audit_logs, idempotency_keys, rate_limits, feature_flags | `drop table` na ordem inversa de dependência (somente em hml; dados sintéticos) |
| 20261109000002_foundation_functions | has_perm, rpc_my_context, rpc_provision_organization, rpc_write_audit, rate limit RPC, triggers anti-escalada e imutabilidade | `drop function`/`drop trigger` correspondentes |
| 20261109000003_foundation_rls | ENABLE/FORCE RLS, policies, GRANTs mínimos, REVOKE de anon | `alter table … disable row level security`, `drop policy` (apenas hml) |

Regras: migrations são aditivas e nunca editadas depois de aplicadas; correção = nova migration. Em produção, rollback destrutivo exige backup verificado e aprovação expressa (`docs/BACKUP_RESTORE.md`).
