# Relatório da Fase 1D — Prontuário mínimo sintético (seção 29)

## 1. Objetivo
Prontuário mínimo (registros, adendos, autoria, histórico, auditoria clínica) com acesso por vínculo assistencial e finalidade, **apenas com dados sintéticos** até o Production Gate.

## 2. Implementado
- **Vínculo assistencial**: por agendamento (trigger quando há paciente no evento e profissional alocado; vale até 30 dias após o fim; cancelar o evento revoga) e **manual** (`care.assign`, motivo obrigatório, prazo opcional, revogável). Decisão do usuário: os dois.
- **Prontuário**: registros `anamnesis | evolution | conduct` em rascunho (só o autor edita) → finalizado (imutável, com hash SHA-256 do conteúdo, verificado a cada leitura). Correção só por **adendo** (sequência única, só em registro finalizado).
- **Acesso**: conteúdo só por RPC (`clinical_gate`: membro + permissão + profissional ativo + vínculo + finalidade). Sem acesso por tabela, nem para service_role.
- **Emergência (break-glass)**: justificativa ≥ 20 caracteres, 2 h, somente leitura, revisão posterior por `clinical.audit` (não pelo próprio beneficiário).
- **Auditoria clínica**: `data_access_logs` append-only, gravado na mesma transação (ator, profissional, ação, finalidade, base, vínculo/emergência, correlação, IP, UA), sem conteúdo clínico; mais `audit_logs` por trigger.
- **API**: rotas clínicas no Worker, repositório e testes; E2E no CI.
- Proprietário/administrador não leem conteúdo (apenas auditam acessos).

## 3. Não implementado / lacunas
- **Histórico de rascunho**: edições de rascunho não guardam versões anteriores do texto (só `update_draft` no log); após finalizar, o histórico é o próprio registro + adendos.
- Vínculo por agendamento começa **na criação do agendamento** (o médico passa a poder abrir o prontuário desde a reserva). Se preferir só na véspera da consulta, é ajuste simples.
- Eventos criados antes da 1D não geram vínculo retroativo (não há dados reais; hml é sintético).
- Sem UI; sem acesso do próprio paciente ao prontuário (1E); sem exportação/impressão (logs previstos); retenção legal e legal hold não implementados (prazos a confirmar com assessoria).
- Alerta ao proprietário em emergência: hoje só há o registro e a fila de revisão, sem notificação.
- Leitura de `cpf_hash` por profissionais com vínculo via política de `patients` (já era possível para a recepção; o hash é HMAC, inútil sem a chave).

## 4. Migrations
`20261111000010_clinical_tables`, `20261111000011_clinical_functions_rls`. **hml**: 010 aplicada; 011 **não aplicada** (a chamada ficou sem resposta do servidor; as tabelas em hml estão com RLS forçada e sem políticas nem GRANT, ou seja, negação total).

## 5. Testes
Ver `docs/TEST_PLAN.md` (Fase 1D). Testes novos validados por mutação.

## 6. Riscos
Conteúdo clínico em texto simples no banco (criptografia por coluna não implementada; só dados sintéticos). Sem retenção/legal hold. Production Gate 20/20 "Não iniciado".
Custos: nenhum. Deploy: nenhum.

## 7. Recomendação
Aplicar a migration 011 em hml, confirmar o CI verde e decidir as duas pontas acima (início do vínculo; histórico de rascunho) antes de qualquer fase seguinte.
