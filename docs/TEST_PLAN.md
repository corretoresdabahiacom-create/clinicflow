# TEST_PLAN

Nenhum teste foi executado (não há código). Estratégia:
- Unitários (Vitest) para serviços de domínio e validação Zod.
- Integração contra Postgres/Supabase local ou efêmero em CI.
- RLS/isolamento: matriz usuário×organização×papel; IDOR; acesso sem JWT; trocas de `organization_id`.
- Concorrência de agenda: N requisições paralelas ao mesmo recurso/intervalo, exatamente 1 sucesso; multi-recurso atômico; fuso horário; cancelamento libera recurso.
- Segurança: SQL injection, XSS, CSRF, escalada de privilégios, tokens, uploads, webhooks, segredos, rate limiting, prompt injection (3B).
- Financeiro: parcial, parcelamento, estorno, compensatório, DRE, isolamento por unidade.
- Clínico: acesso permitido/negado, adendos, imutabilidade, exportação, legal hold, auditoria.
- E2E (Playwright), acessibilidade (axe), desempenho básico.
Regras: dados sintéticos apenas; resultados reais registrados no relatório de cada subfase; teste não executado é reportado como não executado.

## Resultados reais (Fase 1A)
RLS 43/43 (rls_isolation.sql), contrato repo 14/14 (repo_contract.sql), API 22/22. Ver docs/REPORT_1A.md.

## Resultados reais (Fase 1B)
- `scheduling_rules.sql`: 21 asserções (conflito, buffers, atomicidade, RLS, escopo de unidade, imutabilidade, cross-tenant) — Postgres 16 local descartável.
- `concurrency.sh`: 30 conexões simultâneas confirmadas (1 reserva/29 conflitos; 30 disjuntas = 30 reservas; 60 sobrepostas aleatórias sem sobreposição ativa; 30 cancelamentos = 1; remarcações concorrentes = 1). Executado 4 vezes; controle negativo sem a constraint falha como esperado.
- hml (Supabase): smoke de 9 verificações (agendar, conflito, remarcar, cancelar, médico bloqueado, escrita direta negada, anon sem execute).
- API: 13 testes novos (35 no total).

## Resultados reais (Fase 1C)
- `patients_identity.sql`: 10 grupos (permissões, isolamento, CPF-hash único, colunas protegidas, consentimentos append-only, responsáveis, vínculo de conta, expiração/revogação, agendar/remarcar com paciente, check-in) — Postgres 16 local.
- `concurrency.sh` (+C6, C7): 30 check-ins simultâneos = 1; 30 cadastros com o mesmo CPF = 1.
- hml: smoke 10 verificações. API: 49 testes (14 novos de pacientes + cpf).
