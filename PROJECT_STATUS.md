# PROJECT_STATUS

Data: 2026-11-11 · Fase atual: **1H — Endurecimento (concluída, aguardando aprovação)** · Modo operacional: **A (sintético)**

## Estado
Fases 0, 1A, 1B e 1C aprovadas; 1H (endurecimento) implementada e testada (hml + Postgres local + CI; sintético). Relatórios: `docs/REPORT_1A.md`, `REPORT_1B.md`, `REPORT_1C.md`, `REPORT_1H.md`. Migrations: `docs/MIGRATION.md`.

## Testes
RLS 43 · contrato repo 14 · agenda 21 · pacientes/identidade 10 grupos · concorrência real (30 conexões: reservas, check-in, CPF) OK · smoke hml 1B/1C · hardening SQL 31 · concorrência C8 (último owner) · API 51 · **E2E HTTP real contra Supabase local no CI: 6/6**.

## Gate de Produção
20/20 **Não iniciado**. Modo A.

## Próximo
## Decisões do usuário (2026-11-11)
1. **Provisionamento de organização: manual por enquanto** (via `rpc_provision_organization` com service_role; sem cadastro aberto nem convite SaaS nesta etapa).
2. **Vínculo assistencial: nasce do agendamento E de atribuição manual** (os dois). Detalhes a desenhar na 1D: duração, revogação, acesso de emergência e registro da finalidade do acesso.

Aguardando autorização expressa para iniciar a Fase 1D (Prontuário sintético).
