# ERD (proposta para validação; **nenhuma tabela foi criada**)

Convenções: PK `id uuid`; tabelas privadas com `organization_id uuid NOT NULL`; FKs compostas `(organization_id, x_id)`; `created_at/updated_at timestamptz`; `deleted_at` apenas onde exclusão lógica for permitida; horários sempre `timestamptz` (UTC) + fuso da unidade.

## Domínio Organização e Acesso
```mermaid
erDiagram
  organizations ||--o{ units : possui
  organizations ||--o{ organization_members : tem
  organizations ||--o{ roles : define
  roles }o--o{ permissions : role_permissions
  organization_members ||--o{ user_role_assignments : recebe
  roles ||--o{ user_role_assignments : aplica
  units ||--o{ user_role_assignments : escopo_opcional
```
## Domínio Agenda (núcleo único)
```mermaid
erDiagram
  scheduling_events ||--|{ resource_allocations : reserva
  scheduling_events ||--o{ appointment_status_history : historico
  scheduling_events }o--|| patients : paciente_opcional
  scheduling_events }o--o| recurrence_rules : recorrencia
  resource_allocations }o--|| professionals : tipo_profissional
  resource_allocations }o--|| rooms : tipo_sala
  resource_allocations }o--|| equipment : tipo_equipamento
  services ||--o{ service_resource_requirements : exige
```
`resource_allocations`: `(resource_type, resource_id, period tstzrange, status)`; `EXCLUDE USING gist (organization_id WITH =, resource_type WITH =, resource_id WITH =, period WITH &&) WHERE (status='active')`.

## Domínio Pacientes e Clínico
```mermaid
erDiagram
  patients ||--o{ patient_contacts : tem
  patients ||--o{ patient_consents : concede
  patients ||--o{ patient_guardianships : responsavel_dependente
  patients ||--o{ patient_identity_links : vincula_conta
  patients ||--o{ clinical_encounters : atendido_em
  clinical_encounters ||--o{ clinical_notes : contem
  clinical_notes ||--o{ clinical_note_addenda : corrige_por
  patients ||--o{ legal_holds : retencao
```
## Financeiro
```mermaid
erDiagram
  financial_accounts ||--o{ financial_transactions : livro
  financial_transactions ||--o{ reversals : estornada_por
  accounts_receivable ||--o{ payment_allocations : recebe
  accounts_payable ||--o{ payment_allocations : paga
  scheduling_events ||--o| accounts_receivable : origina
```
Demais domínios (exames, atendimento/conversas, comunicação, estoque, SaaS, auditoria, infraestrutura) seguem a lista de referência da seção 20 do prompt mestre e serão modelados **na subfase correspondente**, com justificativa tabela a tabela antes de cada migration. Ajuste proposto: `patient_dependents` substituída por `patient_guardianships` (relação responsável→dependente com validade e revogação); tabelas globais (sem `organization_id`): `permissions`, `saas_plans`, `feature_flags` globais.
