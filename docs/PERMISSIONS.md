# PERMISSIONS (matriz proposta)

Legenda: ● total · ◐ restrito (escopo/vínculo/atribuição) · ○ nenhum por padrão · ⚠ excepcional com justificativa, prazo e auditoria.

| Domínio | Superadmin SaaS | Proprietário | Admin geral | Gerente unidade | Recepção | Médico | Enfermeiro | Téc. exames | Financeiro | Paciente | Auditor |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Plataforma (planos, orgs) | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Config. da organização | ○ | ● | ● | ◐ unidade | ○ | ○ | ○ | ○ | ○ | ○ | ◐ leitura |
| Usuários e papéis | ⚠ suporte | ● | ● | ◐ unidade | ○ | ○ | ○ | ○ | ○ | ○ | ◐ leitura |
| Profissionais/recursos/serviços | ○ | ● | ● | ◐ | ◐ leitura | ◐ leitura | ◐ leitura | ◐ leitura | ◐ leitura | ○ | ◐ leitura |
| Agenda | ○ | ● | ● | ◐ | ● unidade | ◐ própria | ◐ | ◐ atribuída | ○ | ◐ própria | ◐ leitura |
| Pacientes (cadastro) | ○ | ● | ● | ◐ | ● | ◐ vinculados | ◐ vinculados | ◐ atribuídos | ◐ mínimo | ◐ próprio/dependentes | ◐ |
| Prontuário/notas clínicas | ⚠ | ○ | ○ | ○ | ○ | ◐ vínculo + finalidade | ◐ conforme perfil | ◐ só necessário | ○ | ◐ liberado | ◐ escopo de auditoria |
| Documentos médicos | ⚠ | ○ | ○ | ○ | ◐ administrativos | ◐ autoria/vínculo | ◐ | ◐ | ○ | ◐ liberados | ◐ |
| Exames/resultados | ⚠ | ○ | ○ | ○ | ◐ status | ◐ vinculados | ◐ | ◐ atribuídos | ○ | ◐ liberados | ◐ |
| Financeiro | ○ | ● | ● | ◐ unidade | ◐ caixa | ○ | ○ | ○ | ● | ◐ próprios | ◐ leitura |
| Auditoria/logs | ◐ plataforma | ◐ org | ◐ org | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● escopo |
| Conversas/atendimento humano | ○ | ● | ● | ◐ | ● | ○ | ○ | ○ | ○ | ◐ próprias | ◐ |

Regras: (1) permissão = papel + escopo (org/unidade) + estado do recurso + plano/assinatura ativa; (2) acesso clínico exige vínculo e registra finalidade em `data_access_logs`; (3) acesso emergencial (⚠): justificativa obrigatória, expiração automática, alerta ao proprietário e registro em `security_events`; (4) o frontend só espelha o que o backend retorna.
Chaves de permissão seguem `domínio.ação` (ex.: `agenda.read`, `clinical.note.write`, `finance.ledger.reverse`).

## Implementado na 1B (chaves)
professional.read/write, resource.read/write, service.read/write, agenda.read/write. Leitura de profissionais/serviços vale em qualquer escopo; escrita exige escopo organizacional (salas/equipamentos/agenda: por unidade). **Não implementado:** agenda "própria" do médico (só leitura da unidade inteira).

## Implementado na 1C
patient.read, patient.write, checkin.write → proprietário, admin, gerente de unidade e recepção. **Médico, enfermeiro, técnico, financeiro e auditor NÃO leem pacientes ainda** (a matriz pede acesso por vínculo assistencial e finalidade, que só existe a partir da 1D). Pacientes são entidades da organização: permissão em qualquer escopo vale (recepção de uma unidade cadastra pacientes da organização).

## Implementado na 1D
Chaves: `care.read`, `care.assign` (proprietário, admin, gerente de unidade; auditor lê), `clinical.read`, `clinical.write`, `clinical.emergency` (médico e enfermeiro), `clinical.audit` (proprietário e auditor: log de acesso, revisão de emergência e verificação de integridade, **sem ler conteúdo**). Proprietário e administrador **não leem conteúdo clínico** (minimização). Recepção, técnico e financeiro não têm permissão clínica.
Acesso ao conteúdo = permissão clínica + profissional ativo ligado ao usuário + **vínculo assistencial ativo** (ou acesso de emergência, somente leitura) + finalidade declarada (`care` ou `emergency`). Conteúdo clínico só por RPC; sem acesso por tabela, nem para service_role.
Vínculo: (a) **por agendamento**: criado por trigger quando há paciente no evento e o profissional está alocado, válido a partir da criação até 30 dias após o fim; cancelar o evento o revoga; (b) **manual** (`care.assign`): motivo obrigatório, prazo opcional, revogável. Emergência: justificativa ≥ 20 caracteres, 2 h, revisão posterior por `clinical.audit` (nunca pelo próprio beneficiário).
