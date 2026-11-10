# PROJECT_STATUS

Data: 2026-11-09 · Fase atual: **1C — Pacientes e recepção (concluída, aguardando aprovação)** · Modo operacional: **A (sintético)**

## Estado
Fases 0, 1A e 1B aprovadas. Fase 1C implementada e testada (hml + Postgres local; sintético). Relatórios: `docs/REPORT_1A.md`, `REPORT_1B.md`, `REPORT_1C.md`. Migrations: `docs/MIGRATION.md`.

## Testes
RLS 43 · contrato repo 14 · agenda 21 · pacientes/identidade 10 grupos · concorrência real (30 conexões: reservas, check-in, CPF) OK · smoke hml 1B/1C · API 49. Sem teste HTTP ponta a ponta contra o Supabase.

## Gate de Produção
20/20 **Não iniciado**. Modo A.

## Próximo
Aguardando autorização expressa para a Fase 1D (Prontuário sintético).
