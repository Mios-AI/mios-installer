#!/usr/bin/env bash
# MIOS On-Premise Installer
#
# Usage:
#   ./install.sh                         # interactive setup (prompts for domain + connectors)
#   ./install.sh --env-file /path/.env   # non-interactive with existing env file
#   ./install.sh --with-connectors       # start all connectors without interactive prompt
#   ./install.sh --skip-pull             # skip docker image pull (air-gapped)
#   ./install.sh --help

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.onprem.yml"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly RELEASE_FILE="${SCRIPT_DIR}/release.json"
readonly INSTALLER_URL="https://raw.githubusercontent.com/Mios-AI/mios-installer/main"
readonly MIN_DOCKER_VERSION="24.0.0"
readonly MIN_COMPOSE_VERSION="2.20.0"
readonly HEALTH_TIMEOUT=120

# ─── CLI flags ────────────────────────────────────────────────────────────────
OPT_ENV_FILE=""
OPT_WITH_CONNECTORS=false
OPT_SKIP_PULL=false

# ─── Connector state ──────────────────────────────────────────────────────────
SELECTED_CONNECTORS=()
CONNECTORS_TO_START=()
readonly AVAILABLE_CONNECTORS=("slack" "github" "microsoft" "google")

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

# ─── Cleanup on failure ───────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  if [ "${exit_code}" -ne 0 ]; then
    echo
    error "Installation failed (exit ${exit_code}). Run with MIOS_DEBUG=1 for verbose output."
  fi
}
trap cleanup EXIT

[ "${MIOS_DEBUG:-0}" = "1" ] && set -x

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --env-file PATH      Use an existing .env file instead of the interactive setup
  --with-connectors    Start all connectors without interactive selection prompt
  --skip-pull          Skip docker image pull (for air-gapped environments)
  --help               Show this help message

Connector setup guide: https://docs.mios-ai.com/docs/on-premise/connectors
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)        OPT_ENV_FILE="$2"; shift 2 ;;
    --with-connectors) OPT_WITH_CONNECTORS=true; shift ;;
    --skip-pull)       OPT_SKIP_PULL=true; shift ;;
    --help|-h)         usage ;;
    *) error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ─── Version helpers ──────────────────────────────────────────────────────────
version_gte() {
  # Returns true if $1 >= $2 (semver comparison)
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ─── Prerequisite checks ──────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"

  # Docker
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Install Docker >= ${MIN_DOCKER_VERSION}: https://docs.docker.com/get-docker/"
  fi
  local docker_version
  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
  if ! version_gte "${docker_version}" "${MIN_DOCKER_VERSION}"; then
    error "Docker ${docker_version} is too old. Minimum required: ${MIN_DOCKER_VERSION}"
  fi
  success "Docker ${docker_version}"

  # Docker Compose
  if ! docker compose version &> /dev/null; then
    error "Docker Compose v2 plugin is not installed."
  fi
  local compose_version
  compose_version=$(docker compose version --short 2>/dev/null || echo "0.0.0")
  if ! version_gte "${compose_version}" "${MIN_COMPOSE_VERSION}"; then
    error "Docker Compose ${compose_version} is too old. Minimum required: ${MIN_COMPOSE_VERSION}"
  fi
  success "Docker Compose ${compose_version}"

  # openssl (for secret generation)
  if ! command -v openssl &> /dev/null; then
    warn "openssl not found — secrets will not be auto-generated. Set them manually in .env."
  fi

  # curl (used by health checks)
  if ! command -v curl &> /dev/null; then
    error "curl is required but not installed."
  fi

  success "All prerequisites met"
}

# ─── Port availability ────────────────────────────────────────────────────────
check_ports() {
  local http_port="${HTTP_PORT:-80}"
  local https_port="${HTTPS_PORT:-443}"

  step "Checking port availability"
  for port in "${http_port}" "${https_port}"; do
    if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
      warn "Port ${port} appears to be in use. Update HTTP_PORT / HTTPS_PORT in .env if needed."
    else
      success "Port ${port} is available"
    fi
  done
}

# ─── Secret generation ────────────────────────────────────────────────────────
generate_secret() {
  openssl rand -base64 32 | tr -d '=+/' | cut -c1-32
}

# ─── Environment setup ────────────────────────────────────────────────────────
setup_env() {
  if [ -n "${OPT_ENV_FILE}" ]; then
    if [ ! -f "${OPT_ENV_FILE}" ]; then
      error "Provided env file not found: ${OPT_ENV_FILE}"
    fi
    cp "${OPT_ENV_FILE}" "${ENV_FILE}"
    success "Using env file: ${OPT_ENV_FILE}"
    return
  fi

  if [ -f "${ENV_FILE}" ]; then
    warn ".env already exists — skipping interactive setup. Delete it to reconfigure."
    return
  fi

  step "Environment setup"
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"

  # ── Interactive prompts ──
  read_input() {
    local prompt="$1" default="$2" value
    read -rp "   ${prompt} [${default}]: " value </dev/tty
    echo "${value:-$default}"
  }

  echo
  info "Press Enter to accept the default value shown in brackets."
  echo

  local domain
  domain=$(read_input "Domain name (e.g. mios.mycompany.com)" "mios.local")
  sed -i "s/^DOMAIN_NAME=.*/DOMAIN_NAME=${domain}/" "${ENV_FILE}"
  sed -i "s|mios.example.com|${domain}|g" "${ENV_FILE}"

  # Registry from release.json
  if [ -f "${RELEASE_FILE}" ] && command -v python3 &>/dev/null; then
    local registry version
    registry=$(python3 -c "import json,sys; d=json.load(open('${RELEASE_FILE}')); print(d.get('registry',''))" 2>/dev/null || true)
    version=$(python3 -c "import json,sys; d=json.load(open('${RELEASE_FILE}')); print(d.get('version','latest'))" 2>/dev/null || true)
    if [ -n "${registry}" ]; then
      sed -i "s|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${registry}|" "${ENV_FILE}"
      sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${version}|" "${ENV_FILE}"
    fi
  fi

  # Generate secrets
  if command -v openssl &>/dev/null; then
    info "Generating secure secrets..."
    sed -i "s|^DB_BACK_PASSWORD=.*|DB_BACK_PASSWORD=$(generate_secret)|" "${ENV_FILE}"
    sed -i "s|^DB_AI_PASSWORD=.*|DB_AI_PASSWORD=$(generate_secret)|" "${ENV_FILE}"
    sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$(generate_secret)|" "${ENV_FILE}"
    sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=$(generate_secret)|" "${ENV_FILE}"
    sed -i "s|^INTERNAL_API_KEY=.*|INTERNAL_API_KEY=$(generate_secret)|" "${ENV_FILE}"
    success "Secrets generated"
  fi

  # Fix URL references that depend on DOMAIN_NAME
  sed -i "s|\${DOMAIN_NAME}|${domain}|g" "${ENV_FILE}"

  success ".env created at ${ENV_FILE}"
}

# ─── Connector selection ──────────────────────────────────────────────────────
select_connectors_interactive() {
  # --with-connectors flag: select all without showing UI
  if [ "${OPT_WITH_CONNECTORS}" = true ]; then
    for c in "${AVAILABLE_CONNECTORS[@]}"; do
      SELECTED_CONNECTORS+=("app-conn-${c}")
    done
    success "All connectors selected"
    return
  fi

  # --env-file mode: no interactive prompt
  if [ -n "${OPT_ENV_FILE}" ]; then
    return
  fi

  local selected=()
  for i in "${!AVAILABLE_CONNECTORS[@]}"; do selected[i]=0; done
  local cursor=0

  trap "tput cnorm 2>/dev/null >&2; echo >&2; exit 130" SIGINT

  tput civis 2>/dev/null >&2 || true

  _draw_connector_menu() {
    clear >&2
    echo -e "${BOLD}Select connectors to install:${RESET}" >&2
    echo -e "   ${BLUE}Space${RESET} to toggle · ${BLUE}↑ ↓${RESET} to move · ${BLUE}Enter${RESET} to confirm\n" >&2
    for i in "${!AVAILABLE_CONNECTORS[@]}"; do
      local prefix="  " ul=""
      [ "$i" -eq "$cursor" ] && prefix="${BOLD}>${RESET} " && ul="\033[4m"
      if [ "${selected[i]}" -eq 1 ]; then
        echo -e "${prefix}${GREEN}${ul}[x] ${AVAILABLE_CONNECTORS[i]}${RESET}" >&2
      else
        echo -e "${prefix}${ul}[ ] ${AVAILABLE_CONNECTORS[i]}${RESET}" >&2
      fi
    done
    echo >&2
    echo -e "   ${YELLOW}Note:${RESET} Connectors require OAuth credentials in .env before connecting." >&2
    echo -e "   Setup guide: https://docs.mios-ai.com/docs/on-premise/connectors" >&2
  }

  while true; do
    _draw_connector_menu
    IFS= read -rsn1 key </dev/tty
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 1 seq </dev/tty 2>/dev/null || true
      case "$seq" in
        "[A"|"OA") cursor=$(( cursor - 1 )); [ "$cursor" -lt 0 ] && cursor=$(( ${#AVAILABLE_CONNECTORS[@]} - 1 )) ;;
        "[B"|"OB") cursor=$(( cursor + 1 )); [ "$cursor" -ge "${#AVAILABLE_CONNECTORS[@]}" ] && cursor=0 ;;
      esac
    elif [[ "$key" == " " ]]; then
      selected[cursor]=$(( 1 - selected[cursor] ))
    elif [[ "$key" == "" ]]; then
      break
    fi
  done

  tput cnorm 2>/dev/null >&2 || true
  clear >&2
  trap cleanup EXIT

  for i in "${!AVAILABLE_CONNECTORS[@]}"; do
    [ "${selected[i]}" -eq 1 ] && SELECTED_CONNECTORS+=("app-conn-${AVAILABLE_CONNECTORS[i]}")
  done

  if [ "${#SELECTED_CONNECTORS[@]}" -gt 0 ]; then
    success "Selected connectors: $(IFS=', '; echo "${SELECTED_CONNECTORS[*]/#app-conn-/}")"
  else
    info "No connectors selected — rerun install.sh to add them later"
  fi
}

# ─── Connector credential check ───────────────────────────────────────────────
_connector_env_valid() {
  local var
  for var in "$@"; do
    local val
    val=$(grep "^${var}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ -z "$val" ] || [[ "$val" == *"<CHANGE_ME>"* ]]; then
      return 1
    fi
  done
  return 0
}

_connector_doc_url() {
  case "$1" in
    slack)     echo "https://docs.mios-ai.com/docs/on-premise/connectors#slack" ;;
    github)    echo "https://docs.mios-ai.com/docs/on-premise/connectors#github" ;;
    microsoft) echo "https://docs.mios-ai.com/docs/on-premise/connectors#microsoft-365" ;;
    google)    echo "https://docs.mios-ai.com/docs/on-premise/connectors#google-workspace" ;;
  esac
}

check_connector_credentials() {
  [ "${#SELECTED_CONNECTORS[@]}" -eq 0 ] && return

  step "Checking connector credentials"
  for c in "${SELECTED_CONNECTORS[@]}"; do
    local name="${c#app-conn-}"
    local ready=true
    case "$name" in
      slack)     _connector_env_valid SLACK_BOT_TOKEN SLACK_CLIENT_ID SLACK_CLIENT_SECRET SLACK_SIGNING_SECRET || ready=false ;;
      github)    _connector_env_valid GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET || ready=false ;;
      microsoft) _connector_env_valid MICROSOFT_CLIENT_ID MICROSOFT_CLIENT_SECRET || ready=false ;;
      google)    _connector_env_valid GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET || ready=false ;;
    esac

    if [ "$ready" = true ]; then
      success "${name}: credentials found — will start"
      CONNECTORS_TO_START+=("$c")
    else
      warn "${name}: credentials missing in .env — skipping"
      info "  Setup guide: $(_connector_doc_url "$name")"
    fi
  done
}

# ─── Hosts entries ────────────────────────────────────────────────────────────
setup_hosts() {
  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  local subdomains="app api ai minio chatbot slack github microsoft google"
  local hosts_line="127.0.0.1 ${domain}"
  for sub in ${subdomains}; do
    hosts_line="${hosts_line} ${sub}.${domain}"
  done

  if ! grep -qF "${domain}" /etc/hosts 2>/dev/null; then
    step "Adding hosts entries for ${domain}"
    echo "${hosts_line}" | sudo tee -a /etc/hosts > /dev/null
    success "Hosts entries added"
  fi
}

# ─── TLS certificates ─────────────────────────────────────────────────────────
setup_tls() {
  step "Checking TLS certificates"
  local certs_dir="${SCRIPT_DIR}/certs"
  mkdir -p "${certs_dir}"

  if [ -f "${certs_dir}/cert.pem" ] && [ -f "${certs_dir}/key.pem" ]; then
    success "TLS certificates already present"
    return
  fi

  warn "No TLS certificates found in ./certs/. Generating self-signed certificate..."
  info "Replace ./certs/cert.pem and ./certs/key.pem with your real certificate before going live."

  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  openssl req -x509 -newkey rsa:4096 -keyout "${certs_dir}/key.pem" \
    -out "${certs_dir}/cert.pem" -sha256 -days 365 -nodes \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain},DNS:*.${domain}" \
    2>/dev/null

  success "Self-signed certificate generated (valid 365 days)"
}

# ─── Pull images ──────────────────────────────────────────────────────────────
pull_images() {
  if [ "${OPT_SKIP_PULL}" = true ]; then
    warn "--skip-pull: skipping image pull (air-gapped mode)"
    return
  fi

  step "Pulling Docker images"
  local compose_args=(-f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
  docker compose "${compose_args[@]}" pull --quiet
  if [ "${#SELECTED_CONNECTORS[@]}" -gt 0 ]; then
    docker compose "${compose_args[@]}" pull --quiet "${SELECTED_CONNECTORS[@]}"
  fi
  success "Images pulled"
}

# ─── Database migrations ──────────────────────────────────────────────────────
run_migrations() {
  step "Running database migrations"
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    run --rm --no-deps \
    -e "DATABASE_URL=$(grep "^DATABASE_URL=" "${ENV_FILE}" | cut -d= -f2-)" \
    app-back \
    sh -c "bun x prisma migrate deploy" \
    2>&1 | sed 's/^/   /'
  success "Migrations applied"
}

# ─── Start services ───────────────────────────────────────────────────────────
start_services() {
  step "Starting services"
  local compose_args=(-f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
  docker compose "${compose_args[@]}" up -d --remove-orphans
  if [ "${#CONNECTORS_TO_START[@]}" -gt 0 ]; then
    docker compose "${compose_args[@]}" up -d "${CONNECTORS_TO_START[@]}"
  fi
  success "Services started"
}

# ─── Health checks ────────────────────────────────────────────────────────────
wait_healthy() {
  local service="$1" url="$2"
  local elapsed=0

  printf "   Waiting for %-25s" "${service}..."
  until curl -sfk --max-time 3 "${url}" > /dev/null 2>&1; do
    if [ "${elapsed}" -ge "${HEALTH_TIMEOUT}" ]; then
      echo -e " ${RED}TIMEOUT${RESET}"
      warn "${service} did not become healthy within ${HEALTH_TIMEOUT}s"
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    printf "."
  done
  echo -e " ${GREEN}OK${RESET}"
}

run_health_checks() {
  step "Health checks"
  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  wait_healthy "API backend"  "https://api.${domain}/health" || true
  wait_healthy "Frontend app" "https://app.${domain}"        || true
  wait_healthy "AI service"   "https://ai.${domain}/health"  || true
  wait_healthy "Chatbot"      "https://chatbot.${domain}/health" || true
  for c in "${CONNECTORS_TO_START[@]}"; do
    local name="${c#app-conn-}"
    local container="mios-${c}"
    printf "   Waiting for %-25s" "${name} connector..."
    local elapsed=0
    until docker exec "${container}" curl -sf http://localhost:3000/health > /dev/null 2>&1; do
      if [ "${elapsed}" -ge "${HEALTH_TIMEOUT}" ]; then
        echo -e " ${RED}TIMEOUT${RESET}"
        warn "${name} connector did not become healthy within ${HEALTH_TIMEOUT}s"
        break
      fi
      sleep 3
      elapsed=$((elapsed + 3))
      printf "."
    done
    [ "${elapsed}" -lt "${HEALTH_TIMEOUT}" ] && echo -e " ${GREEN}OK${RESET}" || true
  done
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  local domain
  domain=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "mios.local")

  echo
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║   MIOS installed successfully! 🚀    ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════╝${RESET}"
  echo
  echo -e "  ${BOLD}Application${RESET}  → https://app.${domain}"
  echo -e "  ${BOLD}API${RESET}          → https://api.${domain}"
  echo -e "  ${BOLD}AI service${RESET}   → https://ai.${domain}"
  echo -e "  ${BOLD}Storage${RESET}      → https://minio.${domain}"
  if [ "${#CONNECTORS_TO_START[@]}" -gt 0 ]; then
    echo
    echo -e "  ${BOLD}Connectors${RESET}"
    for c in "${CONNECTORS_TO_START[@]}"; do
      local name="${c#app-conn-}"
      echo -e "    ${name}      → https://${name}.${domain}"
    done
  fi
  local pending=()
  for c in "${SELECTED_CONNECTORS[@]}"; do
    local found=false
    for s in "${CONNECTORS_TO_START[@]}"; do [ "$c" = "$s" ] && found=true && break; done
    [ "$found" = false ] && pending+=("${c#app-conn-}")
  done
  if [ "${#pending[@]}" -gt 0 ]; then
    echo
    echo -e "  ${YELLOW}Connectors pending setup:${RESET}"
    for name in "${pending[@]}"; do
      echo -e "    ${name}  → fill credentials in .env then rerun ./install.sh"
      echo -e "             $(_connector_doc_url "$name")"
    done
  fi
  echo
  echo -e "  ${YELLOW}Note:${RESET} If you used a self-signed certificate, add ./certs/cert.pem"
  echo -e "        to your system's trusted certificate store."
  echo
  echo -e "  Logs:    docker compose -f docker-compose.onprem.yml logs -f"
  echo -e "  Upgrade: ./upgrade.sh"
  echo
}

# ─── Bootstrap — download required files if missing (curl | bash mode) ───────
bootstrap() {
  local files=(
    "docker-compose.onprem.yml"
    "traefik/dynamic/tls.yml"
    "traefik/dynamic/middlewares.yml"
    ".env.example"
  )
  local missing=false
  for f in "${files[@]}"; do
    [[ ! -f "${SCRIPT_DIR}/${f}" ]] && missing=true && break
  done
  [[ "$missing" == "false" ]] && return

  step "Downloading installer files..."
  mkdir -p "${SCRIPT_DIR}/traefik/dynamic"
  for f in "${files[@]}"; do
    curl -fsSL "${INSTALLER_URL}/${f}" -o "${SCRIPT_DIR}/${f}"
  done
  success "Installer files ready"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo
  echo -e "${BOLD}MIOS On-Premise Installer${RESET}"
  echo

  bootstrap
  check_prerequisites
  setup_env
  select_connectors_interactive
  # shellcheck source=/dev/null
  source "${ENV_FILE}" 2>/dev/null || true
  check_ports
  setup_tls
  setup_hosts
  pull_images
  check_connector_credentials
  start_services
  run_health_checks
  print_summary
}

main "$@"
