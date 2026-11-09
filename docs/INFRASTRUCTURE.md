# INFRASTRUCTURE

| Item | Modo A (hml/demo) | Modo B (produção, futuro) |
|---|---|---|
| Supabase | Projeto `clinicflow-hml` (a criar, **após aprovação**) | Projeto distinto, plano pago com backup/PITR |
| Banco/Storage | Do projeto hml | Independentes |
| Cloudflare | Worker `clinicflow-hml` + domínio de homologação | Worker/conta/domínio próprios |
| Segredos | Secrets do Worker + GitHub Environments `hml` | Environments `prod` com aprovação manual |
| CI/CD | GitHub Actions: lint, typecheck, testes, scan de segredos, migrations em Postgres efêmero | + deploy com gate manual |
| Dados | Somente sintéticos (seed gerado) | Reais, só após Gate |

Salvaguardas: checagem de `project_ref`/`APP_ENV` no boot; CI proíbe segredos de prod em jobs de hml; sem credenciais compartilhadas.
Estado atual: **nada provisionado**. O projeto Supabase existente "Mercado" não pertence ao ClinicFlow e não será reutilizado.
