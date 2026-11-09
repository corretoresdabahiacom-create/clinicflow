# ClinicFlow

SaaS multi-tenant para gestão administrativa e operacional de clínicas, consultórios e centros de diagnóstico (Brasil, pt-BR, BRL).

**Estado atual: Fase 0 (diagnóstico e planejamento). Nenhum código de produto foi escrito.** Veja `PROJECT_STATUS.md`.

## Stack de referência (Modo A, custo zero/mínimo)
React + TypeScript + Vite + Tailwind (PWA) · Cloudflare Workers (API REST) · Supabase (PostgreSQL, Auth, Storage, RLS) · GitHub Actions.

## Regras-chave
- Desenvolvimento por fases/subfases, com aprovação expressa entre elas.
- Apenas dados sintéticos até o Gate de Produção (`docs/PRODUCTION_GATE.md`) ser aprovado.
- A IA é somente administrativa: nunca diagnostica, prescreve ou interpreta exames.

## Índice da documentação
Arquitetura: `docs/ARCHITECTURE.md`, `docs/ADR/`, `docs/INFRASTRUCTURE.md`
Dados: `docs/DATABASE.md`, `docs/ERD.md`, `docs/DATA_DICTIONARY.md`, `docs/RLS.md`, `docs/PERMISSIONS.md`
Segurança e governança: `docs/SECURITY.md`, `docs/THREAT_MODEL.md`, `docs/LGPD_DATA_MAP.md`, `docs/CLINICAL_DATA_GOVERNANCE.md`, `docs/PRODUCTION_GATE.md`, `docs/BACKUP_RESTORE.md`
Negócio: `docs/SCHEDULING_RULES.md`, `docs/FINANCIAL_RULES.md`, `docs/INTEGRATIONS.md`, `docs/COSTS.md`, `docs/PWA.md`
Execução: `docs/ROADMAP.md`, `docs/TEST_PLAN.md`
