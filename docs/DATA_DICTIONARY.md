# DATA_DICTIONARY (Fase 0: núcleo da Fase 1A e agenda; demais domínios detalhados por subfase)

Legenda sensibilidade: N = normal · P = pessoal · S = sensível (saúde) · F = financeiro · SEC = segredo/segurança.

| Tabela | Escopo | Finalidade | Campos principais | Sens. | Retenção / exclusão |
|---|---|---|---|---|---|
| organizations | global (é o tenant) | Clínica/grupo | id, name, legal_name, cnpj, status, timezone | P | Suspensão, nunca exclusão automática |
| units | org | Unidade | id, organization_id, name, address, timezone, status | N | Lógica |
| organization_members | org | Vínculo usuário (auth.users) ↔ org | user_id, organization_id, status | P | Revogação, histórico mantido |
| permissions | global | Catálogo de permissões | key (ex.: `agenda.write`), description | N | Imutável |
| roles / role_permissions | org | Papéis e permissões | id, organization_id, key, is_system | N | Lógica |
| user_role_assignments | org | Papel do membro, com unidade opcional | member_id, role_id, unit_id null, valid_from/to | N | Histórico mantido |
| audit_logs | org | Auditoria append-only | actor_id, org, unit, action, resource, result, ip, ua, correlation_id, at | P | Mínimo a definir (Gate); sem UPDATE/DELETE |
| data_access_logs | org | Acesso a dados clínicos | actor, patient_id, resource, purpose, at | S | Igual ao prontuário |
| feature_flags | global/org | Habilitação gradual | key, scope, enabled | N | n/a |
| idempotency_keys | org | Idempotência | scope, key, request_hash, status, response, expires_at | N | TTL (24h–7d) |
| rate_limits | global | Contadores | bucket, window_start, count | N | TTL curto |
| outbox_events | org | Eventos assíncronos | type, payload (sem PII clínica), status, attempts, next_run_at | N/P | Purga após sucesso |
| professionals | org | Profissionais | name, registry_type/number/uf (CRM), status | P | Lógica |
| rooms / equipment | org+unit | Recursos | name, unit_id, type, capacity | N | Lógica |
| services | org | Consultas/procedimentos/exames | name, kind, duration, prep_minutes, cleanup_minutes | N | Lógica |
| pricing_tables | org | Preços com vigência | service_id, unit_id, valid_from/to, amount, payer_type | F | Mantido (histórico) |
| scheduling_events | org+unit | Evento de agenda | kind, status, period, patient_id null, created_by | P | Mantido |
| resource_allocations | org | Alocação de recurso | event_id, resource_type, resource_id, period, status | N | Mantido |
| appointment_status_history | org | Histórico de status | event_id, from, to, by, reason, at | P | Append-only |
| patients | org | Cadastro do paciente | name, birth_date, cpf (cifrado/hash para busca), contacts | P | Eliminação/anonimização apenas se sem guarda legal |
| patient_guardianships | org | Responsável→dependente | guardian_id, dependent_id, valid_from/to, revoked_at | P | Histórico mantido |
| patient_identity_links | org | auth user ↔ patient (verificado) | user_id, patient_id, verified_by/at, method | SEC | Revogável |
| patient_consents | org | Consentimentos | patient_id, purpose, granted_at, revoked_at, version | P | Mantido |
| clinical_encounters / clinical_notes / addenda | org+unit | Prontuário | status draft/finalized, author, content, signed_at | S | Guarda legal; legal hold; sem DELETE |
| financial_transactions / reversals | org+unit | Livro financeiro | account_id, amount, kind, status, ref | F | Imutável após confirmada |

Campos de CPF e contatos: avaliar cifragem em nível de coluna (pgcrypto/Vault) na 1C; busca por hash determinístico com sal por organização.
