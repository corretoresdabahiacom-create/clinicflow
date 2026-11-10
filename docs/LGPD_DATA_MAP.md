# LGPD_DATA_MAP (rascunho técnico; **não constitui parecer jurídico**)

| Categoria | Exemplos | Titular | Sensível? | Finalidade | Base legal (a validar por jurídico) | Acesso | Operadores/fornecedores |
|---|---|---|---|---|---|---|---|
| Identificação | nome, CPF, nascimento | Paciente/profissional/usuário | Não | Cadastro, agendamento | A validar | Recepção, médico (vínculo) | Supabase, Cloudflare |
| Contato | telefone, e-mail, endereço | Idem | Não | Comunicação operacional | A validar | Recepção | Supabase; WhatsApp/e-mail se ativados |
| Saúde | anamnese, evolução, alergias, exames | Paciente | **Sim** | Atenção à saúde | A validar | Profissional com vínculo + finalidade | Supabase |
| Financeiro | cobranças, pagamentos | Paciente | Não | Cobrança | A validar | Financeiro | Supabase |
| Menores/dependentes | dados + responsável | Menor | Sim (se saúde) | Atendimento | A validar (cuidado com menores) | Responsável autorizado | — |
| Marketing | consentimentos | Paciente | Não | Comunicação promocional | Consentimento separado | CRM | Canais ativados |
| Segurança | logs, IP, user agent | Usuário | Não | Auditoria | A validar | Auditor | Supabase/Cloudflare |

Pendências: DPA e localização de dados de cada fornecedor (transferência internacional), encarregado (DPO), RIPD, política de privacidade, retenção por categoria (ver `CLINICAL_DATA_GOVERNANCE.md`).

## Dados pessoais na 1C (sintéticos)
nome, nome social, data de nascimento, telefone, e-mail (texto), CPF (somente HMAC + 2 últimos dígitos). Base legal/consentimento por finalidade em `patient_consents`. Acesso de leitura individual registrado em `audit_logs` (`patient.read`), sem PII no log. Exportação, eliminação/anonimização e retenção ainda NÃO implementadas.
