# PWA

Manifest, ícones 192/512, standalone, theme color, Service Worker com atualização controlada (aviso de nova versão, limpeza de cache antigo, versão mínima de API aceita).
Cache: somente ativos estáticos e shell. **Nunca** cachear respostas de API clínicas, resultados, documentos ou dados pessoais; sem operações clínicas offline.
Push: só com consentimento; conteúdo genérico ("Você tem uma atualização"), sem dados clínicos/pessoais. Depende de provedor/VAPID (sem custo previsto, a confirmar).
iOS: orientação de "Adicionar à Tela de Início". Sessão expirada tratada com redirecionamento ao login sem expor dados em cache.
