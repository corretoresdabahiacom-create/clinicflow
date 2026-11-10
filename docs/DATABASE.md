# DATABASE

- PostgreSQL via Supabase. Migrations versionadas em `supabase/migrations/` (timestamp + descrição), sempre com script de rollback documentado (`docs/MIGRATION.md`, criado na Fase 1A).
- Extensões previstas: `btree_gist`, `pgcrypto`/`gen_random_uuid()`, `pg_trgm` (busca/deduplicação). Nenhuma habilitada ainda.
- Regras: FKs, CHECKs, índices por `(organization_id, ...)`, enum via tabela de domínio ou CHECK, valores monetários em `numeric(14,2)` (ou inteiros em centavos, a decidir na 2C), nunca `float`.
- Migrations destrutivas só com autorização e plano de recuperação.
- Funções `SECURITY DEFINER` mínimas, com `search_path` fixo, revisadas.
- Tabelas globais: `permissions`, `saas_plans`, catálogos, flags globais. Todas as demais: `organization_id NOT NULL`.
- Dados clínicos: separados em tabelas próprias com RLS mais restritiva (permissão `clinical.read` + vínculo + finalidade).
- Teste local de migrations: Supabase CLI + Postgres local em CI (sem dados reais).

## Fase 1B — justificativa tabela a tabela
| Tabela | Por quê | Decisões |
|---|---|---|
| professionals | Cadastro do profissional; vínculo opcional a um membro (login) | Conselho/número/UF juntos ou nenhum; sem CPF/endereço (minimização). Escrita só com escopo organizacional |
| professional_units | Profissional atende em N unidades | FK composta; permissão de escrita por unidade |
| rooms / equipment | Recursos físicos por unidade | Nome único por unidade; unit_id imutável (sem grant de update). `capacity` é informativo: sala é tratada como exclusiva |
| services | Duração e folgas (antes/depois) | Sem preço (financeiro é fase 2C) |
| service_resource_requirements | Tipos de recurso exigidos pelo serviço | Reserva só vale se todos os tipos vierem |
| scheduling_events | Núcleo único: consulta, bloqueio, manutenção | Imutável (só scheduled→cancelled); remarcar cria novo evento ligado ao original; `patient_id` sem FK até a 1C |
| resource_allocations | Uma linha por recurso reservado | `EXCLUDE USING gist` (org, tipo, recurso, período) onde ativo; período inclui folgas; trigger valida recurso/unidade/organização |
| appointment_status_history | Trilha de transições | Append-only por trigger |
Escrita de agenda **somente** por RPC (`rpc_book_event`, `rpc_cancel_event`, `rpc_reschedule_event`), sem grants de INSERT/UPDATE nas tabelas de agenda. Auditoria e histórico são gravados na mesma transação.
Códigos de erro das RPCs: CF409 conflito/estado, CF404 não encontrado (inclui não-membro), CF422 inválido, 42501 sem permissão.

## Fase 1C — justificativa tabela a tabela
| Tabela | Por quê | Decisões |
|---|---|---|
| patients | Cadastro administrativo mínimo | Sem endereço/RG/prontuário. **CPF não é guardado em claro**: `cpf_hash` (HMAC-SHA256 com chave só no Worker, escopo por organização) + `cpf_masked`. Único por organização. Sem DELETE (apenas `status`). `created_by` forçado pelo banco |
| patient_consents | Consentimentos LGPD por finalidade | Append-only; autoria forçada (`recorded_by = auth.uid()`); o estado vigente é o último registro por finalidade |
| patient_guardianships | Responsável → dependente com validade e revogação | Par ativo único; imutável exceto validade/revogação; sem DELETE |
| patient_identity_links | Conta de usuário ↔ paciente | Escrita só por RPC (confirmação pela recepção); 1 conta ativa por paciente e 1 paciente ativo por conta; revogável; sem DELETE |
| patient_checkins | Chegada do paciente | Append-only; 1 por agendamento; só por RPC; janela de 3h antes do início até o fim |
`scheduling_events.patient_id` agora tem FK composta; só pode passar de nulo para um paciente (nunca trocar/remover). Titular (conta vinculada) e responsável ativo enxergam o próprio cadastro/dependentes por RLS (`app.patient_self_access`); não enxergam agenda (portal é 1E).
