# DATABASE

- PostgreSQL via Supabase. Migrations versionadas em `supabase/migrations/` (timestamp + descrição), sempre com script de rollback documentado (`docs/MIGRATION.md`, criado na Fase 1A).
- Extensões previstas: `btree_gist`, `pgcrypto`/`gen_random_uuid()`, `pg_trgm` (busca/deduplicação). Nenhuma habilitada ainda.
- Regras: FKs, CHECKs, índices por `(organization_id, ...)`, enum via tabela de domínio ou CHECK, valores monetários em `numeric(14,2)` (ou inteiros em centavos, a decidir na 2C), nunca `float`.
- Migrations destrutivas só com autorização e plano de recuperação.
- Funções `SECURITY DEFINER` mínimas, com `search_path` fixo, revisadas.
- Tabelas globais: `permissions`, `saas_plans`, catálogos, flags globais. Todas as demais: `organization_id NOT NULL`.
- Dados clínicos: separados em tabelas próprias com RLS mais restritiva (permissão `clinical.read` + vínculo + finalidade).
- Teste local de migrations: Supabase CLI + Postgres local em CI (sem dados reais).
