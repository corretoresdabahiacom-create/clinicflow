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
