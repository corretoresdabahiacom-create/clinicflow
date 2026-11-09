# COSTS

**Aviso:** limites e preços de planos gratuitos mudam. Os números abaixo **não foram verificados** nesta fase; devem ser confirmados nas páginas oficiais antes de ativar qualquer serviço, e este arquivo atualizado com data da consulta.

| Serviço | O que usar | A confirmar (limites oficiais) | Riscos conhecidos / qualitativos |
|---|---|---|---|
| Supabase Free | Postgres, Auth, Storage (hml) | Tamanho de banco, storage, MAU, egress, nº de projetos | Projetos free podem ser pausados por inatividade; backups/PITR do free são limitados ou inexistentes, então **inadequado para dados reais** |
| Cloudflare Workers (free) | API + estáticos | Requisições/dia, CPU por requisição, Cron Triggers, KV/DO | Limite de CPU curto; estouro causa erro, não cobrança, no free |
| GitHub Free | Repo + Actions | Minutos de Actions | Repo privado tem franquia menor |
| Domínio | Homologação | Custo anual do registro | Pode gerar custo (decisão do responsável) |
| IA, WhatsApp, SMS, e-mail, pagamentos, antimalware | **Não ativar** | Preço por uso | Custo recorrente: exige aprovação |
| Produção (Modo B) | Supabase pago + backup/PITR, Workers pago se necessário, observabilidade | Cotar | **Custo zero em produção com dados médicos não é prometido** |

Monitoramento: painel de consumo e alerta a 80% dos limites (Fase 1A). Custo atual: R$ 0 (nada contratado). Estimativa de produção: a levantar na cotação do Gate.

## Custo atual (Fase 1A)
R$ 0: um projeto Supabase free de homologação. Sem Cloudflare, sem serviços pagos.
