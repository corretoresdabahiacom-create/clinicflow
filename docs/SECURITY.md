# SECURITY

Controles planejados (todos **não implementados** nesta fase; status real em PROJECT_STATUS):
- Identidade: Supabase Auth; MFA obrigatório para perfis administrativos; política de senha; expiração/revogação de sessões; recuperação segura.
- Autorização: RBAC + escopo + vínculo clínico no Worker **e** RLS no banco.
- Segredos: apenas em secrets do Worker/GitHub Actions; `.gitignore` e varredura de segredos em CI (ex.: gitleaks); rotação documentada.
- Web: CSP estrita, HSTS, CORS restrito (mesmo domínio), proteção CSRF (SameSite + checagem de origem/cabeçalho customizado), escape de saída contra XSS, validação Zod em toda entrada.
- Rate limiting: login, recuperação, OTP, cadastro/agendamento público, chat, webhooks, uploads, consultas sensíveis (ADR-006).
- Uploads: quarentena + validação de tamanho/extensão/MIME real + antimalware (ADR-008; desabilitado até aprovado).
- Auditoria append-only; logs sem PII/clínico/tokens.
- Dependências: lockfile, `npm audit`/Dependabot, justificativa por biblioteca.
- IA: allowlist de ferramentas, minimização de dados, defesa contra prompt injection, testes de jailbreak.
- Incidentes: plano em `PRODUCTION_GATE.md` (item 13); P0/P1 conforme severidades do prompt mestre.

Nenhuma afirmação de conformidade (LGPD, CFM etc.) é feita; depende de validação jurídica e profissional.
