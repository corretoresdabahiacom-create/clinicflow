# ARCHITECTURE

## 1. Visão geral
```
Navegador (React PWA)
   │ HTTPS, JWT do Supabase Auth (Bearer)
   ▼
Cloudflare Worker (API REST, Hono + Zod) ── Cron Triggers (outbox)
   │  (1) valida JWT  (2) resolve vínculo org/unidade/papel  (3) valida domínio
   │  (4) chama Supabase repassando o JWT do usuário (RLS aplicada)
   ▼
Supabase: Auth · PostgreSQL (RLS, constraints, EXCLUDE) · Storage (privado)
   ▲
Serviços externos (via adaptadores, desabilitados até aprovação): IA, WhatsApp, e-mail/SMS, pagamentos
```
Frontend e API ficam no mesmo domínio (Workers Static Assets + rotas `/api/*`), reduzindo CORS e superfície CSRF (ADR-002).

## 2. Fronteira de confiança
| Zona | Confiança | Regra |
|---|---|---|
| Navegador / frontend | Nenhuma | Nunca decide escopo, permissão ou preço. Só exibe. |
| Worker | Parcial | Única porta de entrada de escrita. Valida JWT, vínculo, permissão, unidade, plano e regra de domínio. |
| Supabase Auth | Alta | Emite/valida identidade. MFA para perfis administrativos. |
| PostgreSQL | Alta | Última barreira: RLS, FKs compostas, CHECK, EXCLUDE, triggers de imutabilidade. |
| Storage | Alta | Buckets privados, URLs assinadas curtas, emitidas só após autorização no Worker. |
| Externos | Nenhuma | Entrada tratada como não confiável (assinatura de webhook, idempotência, minimização de dados). |

Regras obrigatórias:
1. `service_role` **nunca** no frontend, repositório ou logs; no Worker só como segredo, escopo mínimo, uso excepcional e auditado (ex.: outbox, webhooks, provisionamento).
2. Fluxo padrão: Worker repassa o JWT do usuário ao Supabase, de modo que a RLS valide cada consulta.
3. `organization_id` nunca é confiado se vier do cliente: derivado de `organization_members` a partir do `sub` do JWT; o cabeçalho de organização ativa é apenas seleção entre vínculos existentes.
4. RLS não substitui validação de domínio; validação de domínio não substitui RLS (defesa em profundidade).
5. Isolamento entre organizações é provado por testes automatizados (ver `TEST_PLAN.md`).

## 3. Camadas do Worker
rotas (públicas, autenticadas, admin, paciente, clínicas, financeiras, integração, webhooks, internas) → middleware (correlation-id, auth, tenant, permissão, rate limit, idempotência) → serviços de domínio → repositórios (Supabase client com JWT) → auditoria. Erros em formato padronizado (RFC 7807). Contratos em OpenAPI gerado a partir dos schemas Zod.

## 4. Ambientes (Modo A e B)
Separação estrutural: projetos Supabase distintos, contas/segredos distintos, domínios distintos, variável `APP_ENV` verificada no boot **e** o Worker de produção só aceita o `project_ref` Supabase de produção (validação no startup). Feature flag isolada não é considerada separação. Detalhes em `INFRASTRUCTURE.md`.

## 5. Assíncrono
`outbox_events` gravado na mesma transação da mudança de estado; Cron Trigger do Worker consome com backoff, idempotência, DLQ (tabela `outbox_dead_letters`) e reprocessamento manual. Nada depende de máquina pessoal.

## 6. Atendimento inteligente
Um único motor (`ConversationService`) usado por chat do site, PWA, WhatsApp e painel humano. Fase 3A determinística (máquina de estados + base de conhecimento), sem IA paga. Fase 3B adiciona `AIProviderAdapter` com allowlist de ferramentas; a IA nunca executa SQL, nunca confirma operação sem sucesso do backend.

## 7. Observabilidade
Logs JSON estruturados com correlation-id, sem PII/clínico/tokens. Métricas de consumo vs. limites do plano. Alertas a 80% dos limites.
