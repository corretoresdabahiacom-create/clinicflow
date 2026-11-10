# Relatório da Fase 1C — Pacientes e recepção (seção 29)

Data: 2026-11-10 · Modo A (somente dados sintéticos)

## 1. Objetivo
Pacientes, dependentes (responsáveis), identidade (CPF, unicidade, vínculo de conta) e check-in; testes de identidade e isolamento.

## 2. Implementado
- Cadastro administrativo mínimo de pacientes. **CPF não é armazenado em claro**: HMAC-SHA256 (chave só no Worker, separada por organização) + máscara; dígitos validados na API; único por organização.
- Detecção de possível duplicado (nome + nascimento) com confirmação explícita; CPF duplicado → 409.
- Consentimentos por finalidade (append-only, autoria forçada pelo banco).
- Responsáveis → dependentes com validade e revogação (imutável exceto validade/revogação).
- Vínculo conta ↔ paciente confirmado pela recepção (1:1 ativo, revogável, auditado). Titular e responsável ativo enxergam só o próprio cadastro/dependentes (RLS); expiração e revogação cortam o acesso.
- Agendar já com paciente (atômico), remarcar preservando o paciente, `patient_id` do evento só nulo→paciente.
- Check-in: janela de 3h antes do início até o fim, uma vez por agendamento, só por RPC, auditado.
- API: pacientes (listar com filtro obrigatório, criar, ler com auditoria, editar), consentimentos, responsáveis, vínculo de conta, check-in; hash do CPF nunca sai da API (defesa em profundidade); sem a chave `CPF_HMAC_KEY` o cadastro com CPF falha fechado (503).
- Papéis: recepção, gerente, admin e proprietário recebem as permissões; **médico/enfermeiro/técnico/financeiro/auditor NÃO leem pacientes** (a matriz exige vínculo assistencial, que só existe na 1D).

## 3. Não implementado
Interface (UI) de pacientes/recepção; contatos múltiplos e endereço; fusão de duplicados; exportação/eliminação/retenção LGPD; fila de espera/status de atendimento após check-in; check-in pelo paciente; portal (1E); regra de “mesmo paciente em dois horários sobrepostos”; acesso por vínculo assistencial (1D).

## 4. Migrations
007 tabelas, 008 permissões/RLS/RPCs. Aplicadas no hml; rollback em `docs/MIGRATION.md`.

## 5. Testes (reais)
| Suite | Ambiente | Resultado |
|---|---|---|
| patients_identity.sql | Postgres 16 local | TESTS_OK 10 grupos |
| concurrency.sh (+C6 check-in, +C7 CPF) | Postgres 16 local | CONCURRENCY_OK (30 check-ins = 1; 30 cadastros mesmo CPF = 1) |
| smoke 1C | hml Supabase | TESTS_OK 10 |
| regressão 1A/1B (43/14/21) | local | OK |
| API vitest | local | 49 passando (14 novos) |
| typecheck, build, secrets, audit | local | OK; 0 vulnerabilidades |
Advisor Supabase: sem exposição anônima; restam avisos esperados (RPCs executáveis por autenticados, com autorização interna) e INFO de `rate_limits`.

## 6. Riscos e lacunas honestas
- Acesso de leitura a pacientes é por papel, não por vínculo assistencial (só a 1D traz isso). Por isso clínicos ficaram sem acesso.
- A suíte SQL completa e a carga concorrente rodaram no Postgres local, não no hml; o hml recebeu só o smoke. `SupabaseRepo` segue sem teste HTTP ponta a ponta (sandbox sem acesso à rede do Supabase).
- A chave `CPF_HMAC_KEY` ainda não existe em lugar nenhum (nenhum deploy); rotação de chave exigiria rehash e não está desenhada.
- O vínculo de conta depende de confirmação humana da recepção; não há verificação de e-mail/telefone do usuário.
- Log de acesso (`patient.read`) é best-effort e sem finalidade (finalidade/`data_access_logs` virão com o clínico).
- CI (job de banco) nunca rodou no GitHub.

## 7. Custos / Gate
R$ 0. Sem Cloudflare. Gate de Produção: 20/20 “Não iniciado”.

## 8. Recomendação
Aprovar a 1C. A 1D (prontuário sintético) exige decisões clínicas e de acesso por vínculo; sugiro revisarmos antes o modelo de vínculo assistencial. **Aguardando autorização expressa para a Fase 1D.**
