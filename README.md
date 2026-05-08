# MIOS On-Premise Installer

Deploy MIOS on your own infrastructure in minutes.

## Prerequisites

- Docker >= 24.0
- Docker Compose v2 >= 2.20
- `openssl` and `curl`

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Mios-AI/mios-installer/main/install.sh | bash
```

The installer will:

1. Check prerequisites
2. Ask for your domain name and generate all secrets
3. Generate a self-signed TLS certificate
4. Ask which connectors to install (Slack, GitHub, Microsoft, Google)
5. Pull images, run migrations, and start all services

## Connectors

Connectors (Slack, GitHub, Microsoft 365, Google Workspace) are optional and require OAuth credentials configured before use.

**Full connector setup guide:** https://docs.mios-ai.com/docs/on-premise/connectors

## Flags

| Flag | Description |
|------|-------------|
| `--env-file PATH` | Skip interactive setup, use an existing `.env` file |
| `--with-connectors` | Start all connectors without the interactive selection prompt |
| `--skip-pull` | Skip image pull (air-gapped environments) |

```bash
# Example: non-interactive install with all connectors
./install.sh --env-file /path/to/.env --with-connectors
```

## After install

```bash
# View logs
docker compose -f docker-compose.onprem.yml logs -f

# Upgrade
./upgrade.sh
```
