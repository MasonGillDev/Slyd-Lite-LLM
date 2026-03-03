#!/usr/bin/env bash
# =============================================================================
# LiteLLM Gateway + Admin UI — Non-Interactive Setup Script
# Target: Fresh Ubuntu LXD instance (22.04 / 24.04)
#
# All configuration is driven by environment variables.
# See VARIABLES.md for the full reference.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Root check & logging helpers
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root. Use: sudo bash setup-litellm.sh" >&2
    exit 1
fi
log()  { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate required variables
# ---------------------------------------------------------------------------
log "Validating environment variables"

# Auto-generate master key if not provided
if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)"
    warn "LITELLM_MASTER_KEY not set — generated: ${LITELLM_MASTER_KEY}"
fi

# Providers are optional — models can be added later via the Admin UI
if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && \
   [ -z "${AZURE_API_KEY:-}" ] && [ -z "${LOCAL_LLM_ENDPOINT:-}" ]; then
    warn "No LLM provider configured. You can add models later via the Admin UI."
fi

# Defaults
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_DB_NAME="${LITELLM_DB_NAME:-litellm}"
LITELLM_DB_USER="${LITELLM_DB_USER:-litellm}"
LITELLM_DB_PASSWORD="${LITELLM_DB_PASSWORD:-$(openssl rand -hex 16)}"
LOCAL_LLM_MODEL_NAME="${LOCAL_LLM_MODEL_NAME:-local-model}"

# Azure validation — all three are required if any is set
if [ -n "${AZURE_API_KEY:-}" ] || [ -n "${AZURE_API_BASE:-}" ] || [ -n "${AZURE_API_VERSION:-}" ]; then
    : "${AZURE_API_KEY:?AZURE_API_KEY is required when using Azure}"
    : "${AZURE_API_BASE:?AZURE_API_BASE is required when using Azure (e.g. https://<resource>.openai.azure.com)}"
    : "${AZURE_API_VERSION:?AZURE_API_VERSION is required when using Azure (e.g. 2024-06-01)}"
    : "${AZURE_DEPLOYMENT_NAME:?AZURE_DEPLOYMENT_NAME is required when using Azure}"
fi

log "Environment OK"

# ---------------------------------------------------------------------------
# 2. System packages
# ---------------------------------------------------------------------------
log "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    postgresql postgresql-contrib \
    curl jq

# ---------------------------------------------------------------------------
# 3. PostgreSQL setup
# ---------------------------------------------------------------------------
log "Configuring PostgreSQL"
systemctl enable --now postgresql

if sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${LITELLM_DB_USER}'" | grep -q 1; then
    # User exists — reset password to match current config (handles re-runs)
    sudo -u postgres psql -c "ALTER USER ${LITELLM_DB_USER} WITH PASSWORD '${LITELLM_DB_PASSWORD}';"
else
    sudo -u postgres psql -c "CREATE USER ${LITELLM_DB_USER} WITH PASSWORD '${LITELLM_DB_PASSWORD}';"
fi

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${LITELLM_DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${LITELLM_DB_NAME} OWNER ${LITELLM_DB_USER};"

DATABASE_URL="postgresql://${LITELLM_DB_USER}:${LITELLM_DB_PASSWORD}@localhost:5432/${LITELLM_DB_NAME}"
log "Database ready: ${LITELLM_DB_NAME}"

# ---------------------------------------------------------------------------
# 4. Install LiteLLM in a virtual environment
# ---------------------------------------------------------------------------
INSTALL_DIR="/opt/litellm"
log "Installing LiteLLM to ${INSTALL_DIR}"

mkdir -p "${INSTALL_DIR}"
python3 -m venv "${INSTALL_DIR}/venv"
source "${INSTALL_DIR}/venv/bin/activate"

pip install --upgrade pip -q
pip install 'litellm[proxy]' prisma psycopg2-binary -q

# Generate the Prisma client and push schema to DB
log "Generating Prisma client"
PRISMA_SCHEMA=$(python3 -c "import litellm, os; print(os.path.join(os.path.dirname(litellm.__file__), 'proxy', 'schema.prisma'))")
python3 -m prisma generate --schema="${PRISMA_SCHEMA}"

log "Pushing database schema (creating tables)"
export DATABASE_URL
python3 -m prisma db push --schema="${PRISMA_SCHEMA}" --accept-data-loss

LITELLM_BIN="${INSTALL_DIR}/venv/bin/litellm"
log "LiteLLM installed: $(${LITELLM_BIN} --version 2>&1 || echo 'version check skipped')"

deactivate

# ---------------------------------------------------------------------------
# 5. Build config.yaml
# ---------------------------------------------------------------------------
CONFIG_FILE="${INSTALL_DIR}/config.yaml"
log "Generating ${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<YAML
general_settings:
  master_key: "${LITELLM_MASTER_KEY}"
  database_url: "${DATABASE_URL}"

litellm_settings:
  drop_params: true
  num_retries: 3
  request_timeout: 120
YAML

# Only add model_list section if at least one provider is configured
HAVE_PROVIDER=false
[ -n "${OPENAI_API_KEY:-}" ]     && HAVE_PROVIDER=true
[ -n "${ANTHROPIC_API_KEY:-}" ]  && HAVE_PROVIDER=true
[ -n "${AZURE_API_KEY:-}" ]      && HAVE_PROVIDER=true
[ -n "${LOCAL_LLM_ENDPOINT:-}" ] && HAVE_PROVIDER=true

if [ "$HAVE_PROVIDER" = true ]; then
    echo "" >> "${CONFIG_FILE}"
    echo "model_list:" >> "${CONFIG_FILE}"
fi

# --- OpenAI models ---
if [ -n "${OPENAI_API_KEY:-}" ]; then
    cat >> "${CONFIG_FILE}" <<YAML
  # OpenAI
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY
  - model_name: gpt-4-turbo
    litellm_params:
      model: openai/gpt-4-turbo
      api_key: os.environ/OPENAI_API_KEY
  - model_name: o1
    litellm_params:
      model: openai/o1
      api_key: os.environ/OPENAI_API_KEY
YAML
fi

# --- Anthropic models ---
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    cat >> "${CONFIG_FILE}" <<YAML
  # Anthropic
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: anthropic/claude-sonnet-4-5-20250929
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: claude-opus-4
    litellm_params:
      model: anthropic/claude-opus-4-20250514
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: claude-haiku-3.5
    litellm_params:
      model: anthropic/claude-3-5-haiku-20241022
      api_key: os.environ/ANTHROPIC_API_KEY
YAML
fi

# --- Azure OpenAI ---
if [ -n "${AZURE_API_KEY:-}" ]; then
    cat >> "${CONFIG_FILE}" <<YAML
  # Azure OpenAI
  - model_name: azure/${AZURE_DEPLOYMENT_NAME}
    litellm_params:
      model: azure/${AZURE_DEPLOYMENT_NAME}
      api_key: os.environ/AZURE_API_KEY
      api_base: os.environ/AZURE_API_BASE
      api_version: "${AZURE_API_VERSION}"
YAML
fi

# --- Local / self-hosted LLM ---
if [ -n "${LOCAL_LLM_ENDPOINT:-}" ]; then
    cat >> "${CONFIG_FILE}" <<YAML
  # Local / self-hosted LLM (OpenAI-compatible endpoint)
  - model_name: ${LOCAL_LLM_MODEL_NAME}
    litellm_params:
      model: openai/${LOCAL_LLM_MODEL_NAME}
      api_base: "${LOCAL_LLM_ENDPOINT}"
      api_key: "${LOCAL_LLM_API_KEY:-no-key-required}"
YAML
fi

log "Config written to ${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 6. Create systemd service
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/litellm.service"
log "Creating systemd service"

# Build the Environment= lines for the service
ENV_LINES="Environment=DATABASE_URL=${DATABASE_URL}\nEnvironment=STORE_MODEL_IN_DB=True\n"
[ -n "${OPENAI_API_KEY:-}" ]    && ENV_LINES+="Environment=OPENAI_API_KEY=${OPENAI_API_KEY}\n"
[ -n "${ANTHROPIC_API_KEY:-}" ] && ENV_LINES+="Environment=ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}\n"
[ -n "${AZURE_API_KEY:-}" ]     && ENV_LINES+="Environment=AZURE_API_KEY=${AZURE_API_KEY}\n"
[ -n "${AZURE_API_BASE:-}" ]    && ENV_LINES+="Environment=AZURE_API_BASE=${AZURE_API_BASE}\n"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=LiteLLM Proxy Gateway
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${LITELLM_BIN} --config ${CONFIG_FILE} --port ${LITELLM_PORT} --host 0.0.0.0
Restart=on-failure
RestartSec=5
$(printf '%b' "${ENV_LINES}")
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable litellm

# ---------------------------------------------------------------------------
# 7. Start LiteLLM
# ---------------------------------------------------------------------------
log "Starting LiteLLM on port ${LITELLM_PORT}"
systemctl start litellm

# Give it a moment to bind
sleep 3

if systemctl is-active --quiet litellm; then
    log "LiteLLM is running"
else
    warn "LiteLLM may not have started cleanly. Check: journalctl -u litellm -n 50"
fi

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
IP_ADDR=$(hostname -I | awk '{print $1}')

log "Setup complete!"
echo ""
echo "  LiteLLM Proxy:   http://${IP_ADDR}:${LITELLM_PORT}"
echo "  Admin UI:        http://${IP_ADDR}:${LITELLM_PORT}/ui"
echo "  Health check:    http://${IP_ADDR}:${LITELLM_PORT}/health"
echo ""
echo "  Master Key:      ${LITELLM_MASTER_KEY}"
echo "  DB Password:     ${LITELLM_DB_PASSWORD}"
echo ""
echo "  Config file:     ${CONFIG_FILE}"
echo "  Service:         systemctl {start|stop|restart|status} litellm"
echo "  Logs:            journalctl -u litellm -f"
echo ""
if [ "$HAVE_PROVIDER" = false ]; then
echo "  NOTE: No models configured. Add them via the Admin UI at:"
echo "        http://${IP_ADDR}:${LITELLM_PORT}/ui"
echo ""
fi
echo "  Test it:"
echo "    curl -s http://${IP_ADDR}:${LITELLM_PORT}/health -H 'Authorization: Bearer ${LITELLM_MASTER_KEY}' | jq ."
echo ""
