# THREAT_MODEL (STRIDE resumido)

| # | Ameaça | Vetor | Mitigação planejada | Teste | Sev. |
|---|---|---|---|---|---|
| T1 | Vazamento entre organizações | IDOR, RLS ausente, `organization_id` do cliente | RLS FORCE, escopo derivado do JWT, FKs compostas | Isolamento/IDOR | P0 |
| T2 | Acesso indevido a prontuário | Papel excessivo, ausência de vínculo | Permissão + vínculo + finalidade + log | Matriz de acesso clínico | P0 |
| T3 | Vazamento de `service_role` | Frontend/repo/log | Só secret do Worker, varredura de segredos | Scan CI | P0 |
| T4 | Takeover de conta de paciente | Vínculo só por telefone/WhatsApp | Verificação de identidade multi-fator, vínculo explícito | Testes de identidade | P0 |
| T5 | Double booking | Concorrência | EXCLUDE constraint + transação + idempotência | Concorrência | P1 |
| T6 | Adulteração financeira/clínica | UPDATE/DELETE | Triggers de imutabilidade, estorno/adendo | Integridade | P0 |
| T7 | Upload malicioso | Arquivo com malware | Quarentena + varredura | Uploads | P1 |
| T8 | Webhook forjado | Sem assinatura | Validação HMAC + idempotência | Webhooks | P1 |
| T9 | Prompt injection / IA fora de escopo | Mensagem do usuário | Allowlist de ferramentas, sem SQL, limites clínicos | Jailbreak | P1 |
| T10 | Abuso/força bruta/scraping público | Endpoints públicos | Login obrigatório, rate limit 10/min nas escritas, Turnstile server-side (fail-closed; chaves no deploy), mínimo de dados | Rate limit + testes API | P1 |
| T11 | Dados sensíveis em cache/notificação | PWA, push | Cache só do casco estático, nunca API/autenticado; push genérico sem payload; CSP | Testes do service worker (mutação) | P1 |
| T12 | Perda de dados | Falha/erro humano | Backup, PITR, restauração testada (Gate) | Restore test | P0 |
| T13 | Mistura homologação/produção | Credenciais compartilhadas | Separação estrutural + checagem de `project_ref` | Config test | P0 |
| T14 | Dependência comprometida | Supply chain | Lockfile, auditoria, revisão | CI audit | P2 |
