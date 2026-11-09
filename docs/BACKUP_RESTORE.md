# BACKUP_RESTORE

Modo A: backups opcionais (dados sintéticos recriáveis por seed + migrations versionadas).
Modo B (requisitos do Gate): backup automático com retenção definida (referência 30 dias), PITR ou equivalente, backup separado de Storage, teste de restauração documentado e repetido, RPO/RTO aprovados, plano de continuidade.
Procedimento de restauração, responsáveis e evidências: **a elaborar e testar antes do Gate** (nada testado até agora).
Armazenamento de arquivos clínicos: cópia independente do projeto Supabase (destino a definir).
