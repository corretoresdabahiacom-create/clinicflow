#!/usr/bin/env bash
# Verificação simples de vazamento de segredos (complementar; não substitui uma ferramenta dedicada).
set -u
cd "$(dirname "$0")/.."
fail=0
EXCL=(--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.git --exclude-dir=.wrangler --exclude=package-lock.json --exclude=check-secrets.sh)

# 1) service_role jamais no frontend
if grep -rniE "service_role|SERVICE_ROLE" apps/web/src apps/web/index.html apps/web/.env.example 2>/dev/null; then
  echo "ERRO: referência a service_role no frontend"; fail=1
fi
# 2) padrão de JWT (chaves/tokens) no repositório
if grep -rnE "eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}" "${EXCL[@]}" . 2>/dev/null; then
  echo "ERRO: possível JWT/chave embutido"; fail=1
fi
# 3) chaves de provedores
if grep -rnE "sb_secret_[A-Za-z0-9_-]+|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----" "${EXCL[@]}" . 2>/dev/null; then
  echo "ERRO: possível segredo de provedor"; fail=1
fi
# 4) arquivos .env versionados
if git ls-files --error-unmatch 2>/dev/null | grep -E "(^|/)\.env($|\.)" | grep -v "\.env\.example$"; then
  echo "ERRO: arquivo .env versionado"; fail=1
fi
[ "$fail" -eq 0 ] && echo "check-secrets: OK"
exit "$fail"
