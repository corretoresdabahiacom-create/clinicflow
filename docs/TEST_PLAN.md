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

## Resultados reais (Fase 1H, 2026-11-11)
- `supabase/tests/hardening.sql`: 31 asserções (último proprietário, auditoria por trigger sem PII/valores, atomicidade, imutabilidade, purge, tomada de chave presa, versão de chave). Mutação: removendo o trigger do último owner → `FAIL H1`; removendo o trigger de auditoria → `FAIL H10`.
- `concurrency.sh` C8: dois proprietários se revogando ao mesmo tempo, 20 rodadas, 3 execuções: 0 rodadas sem exatamente 1 revogação efetiva e 0 organizações sem proprietário. Mutação: sem o advisory lock, 18/20 rodadas deixam a organização sem proprietário.
- Suítes anteriores (RLS 43, contrato 14, agenda 21, pacientes 10 grupos, concorrência C1–C7) seguem verdes com a migration 009.
- API: 51 testes (mocks). **E2E** (`apps/api/e2e`, 6 cenários) roda no job `e2e` do CI contra o Supabase local do CLI (Auth+PostgREST reais): autenticação, cadastros, idempotência + auditoria com correlação/IP, paciente/CPF, agenda (reserva, 409, replay, check-in), isolamento entre organizações, último owner via JWT real. Passou no CI (run 43008578341).
- Smoke em hml (rollback): último owner bloqueado (CF409), trigger de auditoria, purge, coluna cpf_key_version.

## Resultados reais (Fase 1D, 2026-11-12)
- `supabase/tests/clinical.sql`: 17 grupos (permissões, vínculo automático e manual, revogação por cancelamento, imutabilidade, adendos, emergência, log de acesso, isolamento). Validação por mutação (cada defeito injetado foi detectado): sem guarda de imutabilidade → `FAIL K6`; sem revogação ao cancelar → `FAIL K13`; adendo mutável → `FAIL K7`; sem log de acesso → `FAIL K8`.
- `concurrency.sh` C9: 12 adendos simultâneos no mesmo registro → sequência 1..12 sem buracos nem perdas.
- Suítes anteriores seguem verdes (RLS 43, contrato 14, agenda 21, pacientes 10, hardening 31, C1–C8).
- API: 65 testes (clinical.test.ts: 10). E2E: cenário de 1D com vínculo, finalidade, emergência, auditoria e bloqueios (no job `e2e` do CI).
- hml: migration 010 aplicada; **011 (RPCs/políticas) ainda não aplicada** (ver REPORT_1D).
