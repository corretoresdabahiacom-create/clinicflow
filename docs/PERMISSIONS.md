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
