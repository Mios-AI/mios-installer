#!/usr/bin/env bash
# MIOS On-Premise Upgrade Script
#
# Usage:
#   ./upgrade.sh                        # pull latest images and restart
#   ./upgrade.sh --tag v1.2.3           # upgrade to a specific version
#   ./upgrade.sh --skip-backup          # skip database backup (not recommended)
#   ./upgrade.sh --with-connectors      # include connector services
#   ./upgrade.sh --help

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.onprem.yml"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly BACKUP_DIR="${SCRIPT_DIR}/backups"

# ─── CLI flags ────────────────────────────────────────────────────────────────
OPT_TAG=""
OPT_SKIP_BACKUP=false
OPT_WITH_CONNECTORS=false

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
step()    { echo -e "${BOLD}${BLUE}==>${RESET}${BOLD} $*${RESET}"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*" >&2; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; exit 1; }
info()    { echo -e "   $*"; }

# ─── State tracking for rollback ──────────────────────────────────────────────
PREVIOUS_TAG=""
ROLLBACK_TRIGGERED=false

rollback() {
  if [ "${ROLLBACK_TRIGGERED}" = true ] || [ -z "${PREVIOUS_TAG}" ]; then
    return
  fi
  ROLLBACK_TRIGGERED=true
  warn "Rolling back to ${PREVIOUS_TAG}..."

  sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${PREVIOUS_TAG}|" "${ENV_FILE}"

  local compose_args=(-f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
  [ "${OPT_WITH_CONNECTORS}" = true ] && compose_args+=(--profile connectors)

  docker compose "${compose_args[@]}" pull --quiet 2>/dev/null || true
  docker compose "${compose_args[@]}" up -d --remove-orphans 2>/dev/null || true

  warn "Rolled back to ${PREVIOUS_TAG}. Investigate before retrying the upgrade."
}

cleanup() {
  local exit_code=$?
  if [ "${exit_code}" -ne 0 ] && [ "${ROLLBACK_TRIGGERED}" = false ]; then
    echo
    warn "Upgrade encountered an error (exit ${exit_code})."
    rollback
  fi
}
trap cleanup EXIT

[ "${MIOS_DEBUG:-0}" = "1" ] && set -x

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --tag VERSION        Target image tag to upgrade to (e.g. v1.2.3)
  --skip-backup        Skip database backup before upgrading
  --with-connectors    Include connector services in the upgrade
  --help               Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              OPT_TAG="$2"; shift 2 ;;
    --skip-backup)      OPT_SKIP_BACKUP=true; shift ;;
    --with-connectors)  OPT_WITH_CONNECTORS=true; shift ;;
    --help|-h)          usage ;;
    *) error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ─── Guards ───────────────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ]    || error ".env not found. Run ./install.sh first."
[ -f "${COMPOSE_FILE}" ] || error "docker-compose.onprem.yml not found."

# shellcheck source=/dev/null
source "${ENV_FILE}" 2>/dev/null || true

PREVIOUS_TAG="${IMAGE_TAG:-latest}"

# ─── Database backup ──────────────────────────────────────────────────────────
backup_database() {
  if [ "${OPT_SKIP_BACKUP}" = true ]; then
    warn "--skip-backup: skipping database backup."
    return
  fi

  step "Backing up databases"
  mkdir -p "${BACKUP_DIR}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  local backup_back="${BACKUP_DIR}/db-back_${timestamp}.sql.gz"
  local backup_ai="${BACKUP_DIR}/db-ai_${timestamp}.sql.gz"

  info "Backing up business database..."
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    exec -T db-back \
    pg_dump -U "${DB_BACK_USER}" "${DB_BACK_NAME}" \
    | gzip > "${backup_back}"
  success "Business DB → ${backup_back}"

  info "Backing up AI database..."
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    exec -T db-ai \
    pg_dump -U "${DB_AI_USER}" "${DB_AI_NAME}" \
    | gzip > "${backup_ai}"
  success "AI DB → ${backup_ai}"

  # Prune backups older than 30 days
  find "${BACKUP_DIR}" -name "*.sql.gz" -mtime +30 -delete 2>/dev/null || true
}

# ─── Pull new images ──────────────────────────────────────────────────────────
pull_images() {
  step "Pulling new images (tag: ${IMAGE_TAG})"
  local compose_args=(-f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
  [ "${OPT_WITH_CONNECTORS}" = true ] && compose_args+=(--profile connectors)

  docker compose "${compose_args[@]}" pull --quiet
  success "Images pulled"
}

# ─── Apply migrations ─────────────────────────────────────────────────────────
run_migrations() {
  step "Applying database migrations"
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    run --rm --no-deps \
    -e "DATABASE_URL=$(grep "^DATABASE_URL=" "${ENV_FILE}" | cut -d= -f2-)" \
    app-back \
    sh -c "bun x prisma migrate deploy" \
    2>&1 | sed 's/^/   /'
  success "Migrations applied"
}

# ─── Restart services ─────────────────────────────────────────────────────────
restart_services() {
  step "Restarting services"
  local compose_args=(-f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
  [ "${OPT_WITH_CONNECTORS}" = true ] && compose_args+=(--profile connectors)

  docker compose "${compose_args[@]}" up -d --remove-orphans
  success "Services restarted"
}

# ─── Health check ─────────────────────────────────────────────────────────────
run_health_checks() {
  step "Post-upgrade health checks"
  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  local failed=0
  check_service() {
    local name="$1" url="$2"
    local elapsed=0
    printf "   Waiting for %-25s" "${name}..."
    until curl -sf --max-time 3 "${url}" > /dev/null 2>&1; do
      if [ "${elapsed}" -ge 90 ]; then
        echo -e " ${RED}FAILED${RESET}"
        failed=$((failed + 1))
        return
      fi
      sleep 3; elapsed=$((elapsed + 3)); printf "."
    done
    echo -e " ${GREEN}OK${RESET}"
  }

  check_service "API backend"  "https://api.${domain}/health"
  check_service "Frontend app" "https://app.${domain}"
  check_service "AI service"   "https://ai.${domain}/health"

  if [ "${failed}" -gt 0 ]; then
    error "${failed} service(s) failed health checks — triggering rollback."
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  echo
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║   MIOS upgraded successfully! 🚀      ║${RESET}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════╝${RESET}"
  echo
  echo -e "  ${BOLD}Previous version${RESET}  ${PREVIOUS_TAG}"
  echo -e "  ${BOLD}Current version${RESET}   ${IMAGE_TAG}"
  echo -e "  ${BOLD}Application${RESET}       https://app.${domain}"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo
  echo -e "${BOLD}MIOS Upgrade${RESET}  (${PREVIOUS_TAG} → ${OPT_TAG:-latest})"
  echo

  if [ -n "${OPT_TAG}" ]; then
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${OPT_TAG}|" "${ENV_FILE}"
    # Reload
    source "${ENV_FILE}" 2>/dev/null || true
  fi

  backup_database
  pull_images
  run_migrations
  restart_services
  run_health_checks
  print_summary
}

main "$@"
