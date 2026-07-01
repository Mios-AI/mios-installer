#!/usr/bin/env bash
# MIOS — install or renew the license file issued by Mios.
#
# Usage:
#   ./setup-license.sh /path/to/your.license
#
# Copies the license next to the stack (./license/mios.license), then makes
# app-back pick it up immediately. Without this it is auto-reloaded within ~60s.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.onprem.yml"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly LICENSE_DIR="${SCRIPT_DIR}/license"
readonly LICENSE_FILE="${LICENSE_DIR}/mios.license"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*" >&2; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; exit 1; }
info()    { echo -e "   $*"; }

[ $# -eq 1 ] || error "Usage: $(basename "$0") <license-file>"
SRC="$1"
[ -f "${SRC}" ] || error "License file not found: ${SRC}"

# Sanity-check the file looks like a Mios license (JSON with payload + signature).
if command -v python3 >/dev/null 2>&1; then
  python3 - "${SRC}" <<'PY' || error "Not a valid Mios license (expected JSON with payload + signature)."
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d, dict) and d.get("payload") and d.get("signature")
PY
fi

mkdir -p "${LICENSE_DIR}"
cp "${SRC}" "${LICENSE_FILE}"
# The license is signed public data (no secret) — keep it readable by the
# container user, whose uid may differ from the host installer's.
chmod 644 "${LICENSE_FILE}"
success "License installed at ${LICENSE_FILE}"

# Trigger an immediate reload (best-effort; otherwise picked up within ~60s).
if [ -f "${COMPOSE_FILE}" ] && docker compose -f "${COMPOSE_FILE}" ps app-back >/dev/null 2>&1; then
  if docker compose -f "${COMPOSE_FILE}" restart app-back >/dev/null 2>&1; then
    success "app-back restarted — license active immediately"
  else
    info "The license will be picked up automatically within ~60s."
  fi
fi

# Report the resulting license state.
domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
if [ -n "${domain:-}" ] && command -v curl >/dev/null 2>&1; then
  state=""
  for _ in $(seq 1 20); do
    state=$(curl -sfk --max-time 3 "https://api.${domain}/license/status" 2>/dev/null \
      | grep -o '"state":"[A-Z_]*"' | head -1 | cut -d'"' -f4 || true)
    [ -n "${state}" ] && break
    sleep 2
  done
  case "${state}" in
    VALID) success "License is ${BOLD}VALID${RESET}." ;;
    GRACE) warn "License is in its GRACE period (expired but still usable) — renew soon." ;;
    "")    info "Could not confirm status. Check: curl -sk https://api.${domain}/license/status" ;;
    *)     warn "License state: ${state}. Verify the file matches this instance (MIOS_INSTANCE_ID)." ;;
  esac
fi
