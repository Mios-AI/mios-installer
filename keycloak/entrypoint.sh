#!/usr/bin/env bash
set -euo pipefail

# Keycloak entrypoint that templates ${KEYCLOAK_CLIENT_SECRET} and ${DOMAIN_NAME}
# into the realm export before importing it. The templated file is mounted at
# realm-export.tpl.json; the rendered file goes alongside it as realm-export.json
# which Keycloak's --import-realm picks up.

TPL="/opt/keycloak/data/import/realm-export.tpl.json"
OUT="/opt/keycloak/data/import/realm-export.json"

if [ -f "$TPL" ]; then
  envsubst '${KEYCLOAK_CLIENT_SECRET} ${DOMAIN_NAME}' < "$TPL" > "$OUT"
  echo "[keycloak/entrypoint] rendered realm export -> $OUT"
fi

exec /opt/keycloak/bin/kc.sh "$@"
