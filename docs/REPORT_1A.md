# Relatório da Fase 1A — Fundação (seção 29)

Data: 2026-11-09 · Modo operacional: A (somente dados sintéticos)

## 1. Objetivo
Multi-tenancy, autenticação, organizações, unidades, usuários, RBAC com escopo, permissões, auditoria base, config de ambiente, migrations, RLS e APIs fundamentais.

## 2. Implementado
- Esquema multi-tenant com FKs compostas (organization_id, id), RLS ENABLE+FORCE, GRANTs mínimos por coluna, anon sem acesso.
- RBAC com escopo (org-wide ou por unidade), 9 papéis de sistema, anti-escalada de privilégio, papéis de sistema imutáveis.
- Auditoria append-only (triggers bloqueiam UPDATE/DELETE, inclusive para o dono do banco).
- Worker (Hono + Zod): JWT validado, tenant derivado das memberships reais, guards de permissão, erros RFC 7807, headers seguros, logs sem PII, idempotência, rate limit opcional (fail-closed), guarda de ambiente.
- Rotas: GET /api/health, GET /api/me, GET/PATCH /api/org, GET/POST/PATCH units, GET /api/org/audit-logs.
- Frontend: login, seletor de organização, listagem/criação de unidades. Cadastro público desativado.
- CI (`.github/workflows/ci.yml`) e `scripts/check-secrets.sh`.

## 3. Não implementado
Feature flags (tabela criada, sem API/UI), gestão de membros/papéis via API, criação de organização por self-service, PWA, deploy Cloudflare, E2E, acessibilidade, purge de idempotência, proteção contra remoção do último owner.

## 4. Testes executados e resultados (reais)
| Suite | Onde | Resultado |
|---|---|---|
| supabase/tests/rls_isolation.sql | banco hml, rollback | TESTS_OK 43 |
| supabase/tests/repo_contract.sql | banco hml, rollback; mesmas operações/colunas do SupabaseRepo | TESTS_OK 14 |
| apps/api/tests (vitest, repo fake) | local | 22 passando |
| typecheck / build web / check:secrets / npm audit | local | OK / OK / OK / 0 vulnerabilidades |

## 5. Lacunas honestas
- `SupabaseRepo` **não foi executado via HTTP/PostgREST** contra hml (o sandbox não alcança supabase.co). O contrato SQL (14 asserções) reduz o risco, mas **não substitui** um teste ponta a ponta.
- CI nunca rodou no GitHub.
- Auditoria após mutação é best-effort (não transacional).
- Idempotência sem job de limpeza; falha no meio pode deixar chave em "processing".
- Rate limit inativo sem SUPABASE_SERVICE_ROLE_KEY.
- CNPJ validado só por regex.

## 6. Segurança, custos, deploy
Vulnerabilidades de dependências: 0. Nenhum segredo no repositório. Custo: R$ 0 (Supabase free hml). Limites do plano free ainda a confirmar. Deploy: não realizado (aguarda sua decisão). Projeto "Mercado" não tocado.

## 7. Gate de Produção
20/20 requisitos **Não iniciado**. Sistema permanece no Modo A.

## 8. Recomendação
Aprovar a 1A com as lacunas acima; antes da 1B, executar um teste E2E real (Worker local + hml) a partir de uma máquina com acesso à rede. **Aguardando autorização expressa para a Fase 1B.**
