# RLS (estratégia; nenhuma política criada ainda)

1. `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` e `FORCE` em **todas** as tabelas privadas; sem política = sem acesso.
2. Funções auxiliares (STABLE, `SECURITY DEFINER`, `search_path` fixo): `app.is_member(org)`, `app.has_perm(org, perm, unit)`, `app.has_clinical_link(org, patient)`. O `org` nunca vem de claim editável pelo usuário; vem de `organization_members`.
3. Padrão por tabela: SELECT/INSERT/UPDATE/DELETE separados, cada um com `app.has_perm(...)`.
4. Tabelas de auditoria: INSERT permitido via função; UPDATE/DELETE revogados e bloqueados por trigger.
5. Dados clínicos: política adicional exigindo vínculo (`has_clinical_link`); registro `finalized` sem UPDATE.
6. Paciente: política por `patient_identity_links` e `patient_guardianships` vigentes.
7. Tabelas globais: leitura para autenticados quando apropriado, escrita só por superadmin via Worker.
8. `service_role` ignora RLS: uso restrito conforme ADR-003.
9. Testes (pgTAP ou scripts de integração): para cada tabela, matriz usuário×org×papel comprovando acesso permitido e negado; teste de IDOR trocando IDs entre organizações; consulta sem JWT.
10. Performance: índices em colunas usadas pelas políticas; evitar subconsultas não cacheadas (usar `(select auth.uid())`).
