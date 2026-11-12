# ROADMAP (aprovação expressa entre subfases)

| Fase | Escopo | Entrega principal | Gate de saída |
|---|---|---|---|
| 0 | Diagnóstico e planejamento | Estes documentos | Aprovação do responsável |
| 1A | Fundação | Monorepo, CI, projeto Supabase hml, auth, orgs/unidades, RBAC, RLS, auditoria base, flags, idempotência, rate limit | Testes de isolamento e permissões verdes |
| 1B | Profissionais e recursos | Cadastros + núcleo de agenda com EXCLUDE | Testes de concorrência verdes |
| 1C | Pacientes e recepção | Pacientes, dependentes, identidade, check-in | Testes de identidade/isolamento |
| 1D | Prontuário (sintético) | Notas, adendos, auditoria clínica | Testes de integridade |
| 1E | Portal, PWA, agendamento (paciente logado) | Portal do paciente, PWA, Turnstile configurável | Testes E2E/PWA/segurança — implementada (ver REPORT_1E) |
| 2A–2D | Exames, documentos, financeiro, convênios/estoque | Conforme prompt mestre | Integridade financeira, acesso a documentos |
| 3A–3C | Motor determinístico, IA, WhatsApp | Só com aprovação de custos/fornecedores | Testes de privacidade e limites clínicos |
| 4A–4G | Admin SaaS, planos, redes, BI, integrações, marketplace, escala | Conforme prompt mestre | Gate de Produção |

Dependências críticas: ADRs aprovados → criação do projeto hml → 1A. Cada subfase termina com o relatório da seção 29 do prompt mestre e para.
