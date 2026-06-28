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
| `--skip-pull` | Skip image pull (images already loaded locally) |
| `--airgap` | Fully offline: load images + Ollama model from the bundle, no network |
| `--bundle DIR` | Directory holding the air-gap bundle (default: install dir) |

```bash
# Example: non-interactive install with all connectors
./install.sh --env-file /path/to/.env --with-connectors
```

## Air-gapped install (no internet on the target)

The release ships a bundle: `mios-<version>-images.tar.gz.part*` (all container
images, split into <2 GB parts) and `mios-<version>-ollama-<model>.tar.gz.part*`
(the pre-pulled Ollama model).

```bash
# 1. Copy the release files + every *.part* to the target host (same folder).
# 2. Configure your environment:
cp .env.example .env        # then set DOMAIN_NAME and secrets
# 3. Install fully offline:
./install.sh --airgap --env-file .env
```

`--airgap` runs `docker load` on the image parts, restores the Ollama model into
the `mios_ollama_models` volume, and starts the stack without any network access.

## After install

```bash
# View logs
docker compose -f docker-compose.onprem.yml logs -f

# Upgrade
./upgrade.sh
```
