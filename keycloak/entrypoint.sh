#!/usr/bin/env bash
set -euo pipefail

TPL="/opt/keycloak/realm-export.tpl.json"
OUT="/opt/keycloak/data/import/realm-export.json"

if [ -f "$TPL" ]; then
  mkdir -p "$(dirname "$OUT")"
  content="$(<"$TPL")"
  content="${content//\$\{KEYCLOAK_CLIENT_SECRET\}/${KEYCLOAK_CLIENT_SECRET}}"
  content="${content//\$\{DOMAIN_NAME\}/${DOMAIN_NAME}}"
  printf '%s\n' "$content" > "$OUT"
  echo "[keycloak/entrypoint] rendered realm export -> $OUT"
fi

exec /opt/keycloak/bin/kc.sh "$@"
