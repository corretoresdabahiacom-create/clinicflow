# FINANCIAL_RULES

- Livro de movimentações (`financial_transactions`) append-only; confirmadas nunca apagadas/sobrescritas; correção por estorno (`reversals`) ou lançamento compensatório com justificativa e auditoria.
- Valores em `numeric` ou centavos inteiros; nunca float; moeda BRL.
- Ciclo: agendamento ≠ receita; atendimento realizado → cobrança (a receber) → pagamento parcial/integral (`payment_allocations`) → saldo → estorno → repasses/comissões.
- Pagamento do paciente não confirma atendimento (e vice-versa).
- Distinções: receita prevista/faturada/recebida; convênios a receber; despesas previstas/pagas.
- DRE gerencial por caixa e por competência, com critério explícito; não é lucro contábil/fiscal.
- Pagamentos inicialmente manuais; sem simulação de PIX/cartão/conciliação automática.
- Idempotência em pagamentos/estornos; isolamento por unidade; fechamento de caixa imutável.
- Assinatura da clínica ao ClinicFlow é separada dos pagamentos de pacientes à clínica.
Pontos fiscais/contábeis dependem de validação por contador.
