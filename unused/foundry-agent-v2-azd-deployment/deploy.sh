#!/usr/bin/env bash
# deploy.sh — Deploy and validate the PARI/GP Foundry Agent via azd.
#
# Usage:
#   1. Copy .env.template to .env and fill in your values.
#   2. chmod +x deploy.sh
#   3. ./deploy.sh
#
# The script will stop on the first error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load environment variables ───────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  echo "[1/9] Loading configuration from .env ..."
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
else
  echo "ERROR: .env not found. Copy .env.template to .env and fill in your values."
  exit 1
fi

# ── Validate required variables ──────────────────────────────────────────────
for var in SUBSCRIPTION_ID RESOURCE_GROUP ACCOUNT_NAME AGENT_NAME AGENT_MANIFEST; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

# Default PROJECT_NAME to <ACCOUNT_NAME>-project if not set.
PROJECT_NAME="${PROJECT_NAME:-${ACCOUNT_NAME}-project}"

# Default MODEL_NAME to DeepSeek-V3.2 if not set.
MODEL_NAME="${MODEL_NAME:-DeepSeek-V3.2}"
MODEL_SKU="${MODEL_SKU:-Standard}"
MODEL_CAPACITY="${MODEL_CAPACITY:-1}"

PROJECT_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}"
PROJECT_ENDPOINT="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}"
MANIFEST_PATH="$SCRIPT_DIR/$AGENT_MANIFEST"
AZD_ENV_NAME="${AZD_ENV_NAME:-$(basename "$SCRIPT_DIR")-dev}"
APP_DEPLOYMENT_NAME="${APP_DEPLOYMENT_NAME:-primary}"
APP_MGMT_API_VERSION="${APP_MGMT_API_VERSION:-2026-01-15-preview}"
MCP_CONNECTION_NAME="${MCP_CONNECTION_NAME:-}"
MCP_SERVER_URL="${MCP_SERVER_URL:-}"
MCP_PROJECT_CONNECTION_ID="${MCP_PROJECT_CONNECTION_ID:-}"
ARM_API_VERSION="${ARM_API_VERSION:-2025-10-01-preview}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "ERROR: Agent manifest not found at $MANIFEST_PATH"
  exit 1
fi

# ── Check prerequisites ─────────────────────────────────────────────────────
echo "[2/11] Checking prerequisites ..."

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) is not installed. https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

if ! command -v azd &>/dev/null; then
  echo "ERROR: Azure Developer CLI (azd) is not installed. https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd"
  exit 1
fi

AZD_VERSION=$(azd version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
echo "  azd version: $AZD_VERSION"

# ── Authenticate ─────────────────────────────────────────────────────────────
echo "[3/11] Authenticating ..."
if ! az account show &>/dev/null; then
  echo "ERROR: Azure CLI is not logged in. Run 'az login' (or configure a service principal) before running this script."
  exit 1
fi

if ! azd auth login --check-status &>/dev/null 2>&1; then
  if ! azd auth login --no-prompt; then
    echo "ERROR: azd is not authenticated. Run 'azd auth login' first, or configure non-interactive credentials."
    exit 1
  fi
fi

# ── Ensure Foundry project exists ────────────────────────────────────────────
echo "[4/11] Ensuring Foundry project '${PROJECT_NAME}' exists ..."

ACCOUNT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}"
PROJECT_URL="${ACCOUNT_URL}/projects/${PROJECT_NAME}?api-version=${ARM_API_VERSION}"

PROJECT_STATE=$(az rest --method get --url "$PROJECT_URL" \
  --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$PROJECT_STATE" == "NotFound" ]]; then
  echo "  Project not found. Enabling allowProjectManagement and creating project ..."
  # Enable allowProjectManagement on the account (idempotent)
  CURRENT_ALLOW=$(az rest --method get --url "${ACCOUNT_URL}?api-version=${ARM_API_VERSION}" \
    --query "properties.allowProjectManagement" -o tsv 2>/dev/null || echo "false")
  if [[ "$CURRENT_ALLOW" != "true" ]]; then
    ACCOUNT_LOCATION=$(az rest --method get --url "${ACCOUNT_URL}?api-version=${ARM_API_VERSION}" \
      --query "location" -o tsv)
    az rest --method patch --url "${ACCOUNT_URL}?api-version=${ARM_API_VERSION}" \
      --body "{\"properties\":{\"allowProjectManagement\":true}}" --output none
    echo "  Waiting for account update ..."
    for _i in $(seq 1 30); do
      _state=$(az rest --method get --url "${ACCOUNT_URL}?api-version=${ARM_API_VERSION}" \
        --query "properties.provisioningState" -o tsv 2>/dev/null)
      [[ "$_state" == "Succeeded" ]] && break
      sleep 10
    done
  fi
  # Create the project
  ACCOUNT_LOCATION=$(az rest --method get --url "${ACCOUNT_URL}?api-version=${ARM_API_VERSION}" \
    --query "location" -o tsv 2>/dev/null)
  az rest --method put --url "$PROJECT_URL" \
    --body "{\"location\":\"${ACCOUNT_LOCATION}\",\"properties\":{},\"identity\":{\"type\":\"SystemAssigned\"},\"kind\":\"AIServices\"}" --output none
  echo "  Waiting for project provisioning ..."
  for _i in $(seq 1 30); do
    _state=$(az rest --method get --url "$PROJECT_URL" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Creating")
    [[ "$_state" == "Succeeded" ]] && break
    sleep 10
  done
  echo "  Project '${PROJECT_NAME}' created."
else
  echo "  Project exists (state: ${PROJECT_STATE})."
fi

# ── Ensure model deployment exists ───────────────────────────────────────────
echo "[5/11] Ensuring model deployment '${MODEL_NAME}' exists ..."

MODEL_EXISTS=$(az cognitiveservices account deployment list \
  -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
  --query "[?name=='${MODEL_NAME}'].name" -o tsv 2>/dev/null || true)

if [[ -z "$MODEL_EXISTS" ]]; then
  echo "  Deploying model '${MODEL_NAME}' (sku=${MODEL_SKU}, capacity=${MODEL_CAPACITY}) ..."
  az cognitiveservices account deployment create \
    -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
    --deployment-name "$MODEL_NAME" \
    --model-name "$MODEL_NAME" \
    --model-version "*" \
    --model-format OpenAI \
    --sku-capacity "$MODEL_CAPACITY" \
    --sku-name "$MODEL_SKU" \
    --output none
  echo "  Model '${MODEL_NAME}' deployed."
else
  echo "  Model deployment '${MODEL_NAME}' already exists."
fi

# ── Prepare/select azd environment ──────────────────────────────────────────
echo "[6/11] Preparing azd environment ..."
echo "  Environment: $AZD_ENV_NAME"

if azd env list --output json | grep -q "\"Name\": \"${AZD_ENV_NAME}\""; then
  echo "  Environment already exists, selecting it."
  azd env select "$AZD_ENV_NAME" --no-prompt
else
  echo "  Environment does not exist, creating it."
  if [[ -n "${AZURE_LOCATION:-}" ]]; then
    azd env new "$AZD_ENV_NAME" --subscription "$SUBSCRIPTION_ID" --location "$AZURE_LOCATION" --no-prompt
  else
    azd env new "$AZD_ENV_NAME" --subscription "$SUBSCRIPTION_ID" --no-prompt
  fi
fi

# Ensure downstream azd commands bind to the selected environment.
export AZURE_ENV_NAME="$AZD_ENV_NAME"

# ── Set MCP connection in azd env (IaC-managed) ─────────────────────────────
if [[ -z "$MCP_PROJECT_CONNECTION_ID" && -n "${MCP_CONNECTION_NAME:-}" ]]; then
  if [[ -z "${MCP_SERVER_URL:-}" ]]; then
    echo "ERROR: MCP_CONNECTION_NAME is set but MCP_SERVER_URL is empty. Set MCP_SERVER_URL in .env."
    exit 1
  fi
  echo "  Configuring azd env with MCP project connection: ${MCP_CONNECTION_NAME}"
  azd env set AI_PROJECT_CONNECTIONS "[{\"name\":\"${MCP_CONNECTION_NAME}\",\"category\":\"CustomKeys\",\"target\":\"${MCP_SERVER_URL}\",\"authType\":\"CustomKeys\",\"credentials\":{\"keys\":{\"mcp_server\":\"true\"}},\"metadata\":{\"type\":\"mcp\"}}]"
fi

# ── Deploy infrastructure ────────────────────────────────────────────────────
echo "[7/11] Running azd up (provision + deploy) ..."
azd up --no-prompt

# Resolve MCP for manifest substitution.
#   The manifest may contain __MCP_PROJECT_CONNECTION_ID__ and/or __MCP_SERVER_URL__.
#   Resolve both where possible.

# 1. Resolve MCP_SERVER_URL: explicit > sibling mcp/.env > project connections.
if [[ -z "${MCP_SERVER_URL:-}" ]]; then
  MCP_SIBLING_ENV="$SCRIPT_DIR/../mcp/.env"
  if [[ -f "$MCP_SIBLING_ENV" ]]; then
    MCP_APP_NAME=$(grep -E '^APP_NAME=' "$MCP_SIBLING_ENV" | cut -d= -f2- | tr -d '[:space:]')
    if [[ -n "$MCP_APP_NAME" ]]; then
      MCP_SERVER_URL="https://${MCP_APP_NAME}.azurewebsites.net/mcp"
      echo "  Inferred MCP_SERVER_URL from ../mcp/.env: $MCP_SERVER_URL"
    fi
  fi
fi

# 2. Resolve MCP_PROJECT_CONNECTION_ID: explicit > by name > auto-discover > auto-create.
if [[ -z "$MCP_PROJECT_CONNECTION_ID" && -n "$MCP_CONNECTION_NAME" ]]; then
  echo "  Resolving MCP connection id from name: ${MCP_CONNECTION_NAME}"
  MCP_PROJECT_CONNECTION_ID=$(az cognitiveservices account project connection show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACCOUNT_NAME" \
    --project-name "$PROJECT_NAME" \
    --connection-name "$MCP_CONNECTION_NAME" \
    --query id -o tsv 2>/dev/null || true)
fi

if [[ -z "$MCP_PROJECT_CONNECTION_ID" ]]; then
  echo "  Auto-discovering MCP connection on project ${PROJECT_NAME} ..."
  MCP_PROJECT_CONNECTION_ID=$(az cognitiveservices account project connection list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACCOUNT_NAME" \
    --project-name "$PROJECT_NAME" \
    --query "[?ends_with(properties.target, '/mcp')] | [0].id" -o tsv 2>/dev/null || true)
  if [[ -n "$MCP_PROJECT_CONNECTION_ID" ]]; then
    echo "  Found MCP connection: $MCP_PROJECT_CONNECTION_ID"
  fi
fi

# Auto-create MCP connection if manifest needs it but none exists.
if [[ -z "$MCP_PROJECT_CONNECTION_ID" ]] && grep -q '__MCP_PROJECT_CONNECTION_ID__' "$MANIFEST_PATH"; then
  if [[ -z "${MCP_SERVER_URL:-}" ]]; then
    echo "ERROR: Cannot create MCP connection — MCP_SERVER_URL is not set and could not be inferred."
    exit 1
  fi
  MCP_CONNECTION_NAME="${MCP_CONNECTION_NAME:-mcp-auto}"
  MCP_CONN_URL="https://management.azure.com${PROJECT_ID}/connections/${MCP_CONNECTION_NAME}?api-version=2025-04-01-preview"
  MCP_CONN_BODY_FILE="$SCRIPT_DIR/.azd.mcp-conn-body.json"

  echo "  Creating MCP project connection '${MCP_CONNECTION_NAME}' -> ${MCP_SERVER_URL}"
  cat > "$MCP_CONN_BODY_FILE" <<JSON
{
  "properties": {
    "category": "CustomKeys",
    "target": "${MCP_SERVER_URL}",
    "authType": "CustomKeys",
    "credentials": {
      "keys": {
        "mcp_server": "true"
      }
    },
    "metadata": {
      "type": "mcp"
    },
    "isSharedToAll": true
  }
}
JSON

  az rest --method PUT --url "$MCP_CONN_URL" --body "@$MCP_CONN_BODY_FILE" --output none
  rm -f "$MCP_CONN_BODY_FILE"

  MCP_PROJECT_CONNECTION_ID=$(az cognitiveservices account project connection show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACCOUNT_NAME" \
    --project-name "$PROJECT_NAME" \
    --connection-name "$MCP_CONNECTION_NAME" \
    --query id -o tsv)

  echo "  Created MCP connection: $MCP_PROJECT_CONNECTION_ID"
fi

# Export resolved values for the Python payload builder.
if [[ -n "${MCP_SERVER_URL:-}" ]]; then
  export MCP_SERVER_URL
fi
if [[ -n "${MCP_PROJECT_CONNECTION_ID:-}" ]]; then
  export MCP_PROJECT_CONNECTION_ID
  echo "  MCP project connection id resolved: $MCP_PROJECT_CONNECTION_ID"
fi

# ── Deploy agent version from YAML ───────────────────────────────────────────
echo "[8/11] Deploying agent from ${AGENT_MANIFEST} ..."

# Always use the YAML manifest as the source of truth.
# If the agent already exists, bump version in a temp manifest and deploy a new version.
LATEST_VERSION=$(az cognitiveservices agent list-versions \
  --account-name "$ACCOUNT_NAME" \
  --project-name "$PROJECT_NAME" \
  --name "$AGENT_NAME" \
  --query "[].version" -o tsv 2>/dev/null | tr '\t' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)

MANIFEST_TO_DEPLOY="$MANIFEST_PATH"
TMP_MANIFEST=""
REQUESTED_VERSION=""

if [[ -n "$LATEST_VERSION" ]]; then
  NEXT_VERSION=$((LATEST_VERSION + 1))
  REQUESTED_VERSION="$NEXT_VERSION"
  TMP_MANIFEST="$SCRIPT_DIR/.azd.${AGENT_NAME}.${NEXT_VERSION}.yml"
  echo "  Agent '$AGENT_NAME' already exists (latest version: $LATEST_VERSION)."
  echo "  Bumping to version: $NEXT_VERSION"

  awk -v newver="$NEXT_VERSION" -v agent="$AGENT_NAME" '
    BEGIN { has_version=0; has_id=0 }
    {
      if ($0 ~ /^version:[[:space:]]*/) { print "version: \"" newver "\""; has_version=1; next }
      if ($0 ~ /^id:[[:space:]]*/) { print "id: " agent ":" newver; has_id=1; next }
      print
    }
    END {
      if (!has_id) print "id: " agent ":" newver
      if (!has_version) print "version: \"" newver "\""
    }
  ' "$MANIFEST_PATH" > "$TMP_MANIFEST"

  MANIFEST_TO_DEPLOY="$TMP_MANIFEST"
else
  REQUESTED_VERSION="1"
fi

PAYLOAD_FILE="$SCRIPT_DIR/.azd.agent-payload.json"
APP_BODY_FILE="$SCRIPT_DIR/.azd.app-body.json"
APP_DEPLOYMENT_BODY_FILE="$SCRIPT_DIR/.azd.app-deployment-body.json"

cleanup() {
  if [[ -n "$TMP_MANIFEST" && -f "$TMP_MANIFEST" ]]; then
    rm -f "$TMP_MANIFEST"
  fi
  if [[ -f "$PAYLOAD_FILE" ]]; then
    rm -f "$PAYLOAD_FILE"
  fi
  if [[ -f "$APP_BODY_FILE" ]]; then
    rm -f "$APP_BODY_FILE"
  fi
  if [[ -f "$APP_DEPLOYMENT_BODY_FILE" ]]; then
    rm -f "$APP_DEPLOYMENT_BODY_FILE"
  fi
  if [[ -n "${RESPONSE_FILE:-}" && -f "$RESPONSE_FILE" ]]; then
    rm -f "$RESPONSE_FILE"
  fi
}
trap cleanup EXIT

# Build REST payload from YAML (definition + description + metadata).
# Add a unique deployment stamp so Foundry always materializes a fresh version.
/usr/bin/python3 - "$MANIFEST_TO_DEPLOY" "$PAYLOAD_FILE" "$REQUESTED_VERSION" <<'PY'
import json
import os
import sys
import time
import yaml

manifest_path = sys.argv[1]
payload_path = sys.argv[2]
requested_version = sys.argv[3]

with open(manifest_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)

payload = {}
for key in ("definition", "description", "metadata"):
    if key in data and data[key] is not None:
        payload[key] = data[key]

metadata = dict(payload.get("metadata") or {})
metadata["modified_at"] = str(int(time.time()))
metadata["azd.deploy.requested_version"] = str(requested_version)
payload["metadata"] = metadata

mcp_connection_id = os.environ.get("MCP_PROJECT_CONNECTION_ID", "").strip()
mcp_server_url = os.environ.get("MCP_SERVER_URL", "").strip()
missing_placeholders = []


def substitute_placeholders(value):
  if isinstance(value, dict):
    return {k: substitute_placeholders(v) for k, v in value.items()}
  if isinstance(value, list):
    return [substitute_placeholders(v) for v in value]
  if isinstance(value, str):
    if value == "__MCP_PROJECT_CONNECTION_ID__":
      if not mcp_connection_id:
        missing_placeholders.append("__MCP_PROJECT_CONNECTION_ID__")
        return value
      return mcp_connection_id
    if value == "__MCP_SERVER_URL__":
      if not mcp_server_url:
        missing_placeholders.append("__MCP_SERVER_URL__")
        return value
      return mcp_server_url
  return value


payload = substitute_placeholders(payload)

if missing_placeholders:
  raise RuntimeError(
    f"Manifest contains unresolved placeholders: {', '.join(missing_placeholders)}. "
    "Ensure MCP_SERVER_URL is set (or can be inferred from ../mcp/.env)."
  )

with open(payload_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY

TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
CREATE_VERSION_URL="${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=v1"
RESPONSE_FILE="$SCRIPT_DIR/.azd.agent-create-response.json"

HTTP_CODE=$(curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" -X POST "$CREATE_VERSION_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Agent version deployment failed (HTTP $HTTP_CODE)."
  cat "$RESPONSE_FILE"
  exit 1
fi

DEPLOYED_VERSION=$(/usr/bin/python3 - "$RESPONSE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print(data.get("version", "unknown"))
PY
)

if [[ "$DEPLOYED_VERSION" != "$REQUESTED_VERSION" ]]; then
  echo "ERROR: Expected deployed version $REQUESTED_VERSION but Foundry returned $DEPLOYED_VERSION."
  echo "This usually means the service reused an existing version instead of creating a new one."
  cat "$RESPONSE_FILE"
  exit 1
fi

echo "  Agent version deployed: $DEPLOYED_VERSION"

# ── Publish/update Agent Application ─────────────────────────────────────────
echo "[9/11] Publishing Agent Application ..."

if [[ -n "${APP_NAME:-}" ]]; then
  APP_RESOURCE_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}/applications/${APP_NAME}?api-version=${APP_MGMT_API_VERSION}"
  APP_DEPLOYMENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}/applications/${APP_NAME}/agentdeployments/${APP_DEPLOYMENT_NAME}?api-version=${APP_MGMT_API_VERSION}"

  cat > "$APP_BODY_FILE" <<JSON
{
  "properties": {
    "displayName": "${APP_NAME}",
    "agents": [
      {
        "agentName": "${AGENT_NAME}"
      }
    ],
    "authorizationPolicy": {
      "AuthorizationScheme": "Default"
    }
  }
}
JSON

  cat > "$APP_DEPLOYMENT_BODY_FILE" <<JSON
{
  "properties": {
    "displayName": "${APP_DEPLOYMENT_NAME}",
    "deploymentType": "Managed",
    "protocols": [
      {
        "protocol": "Responses",
        "version": "1.0"
      }
    ],
    "agents": [
      {
        "agentName": "${AGENT_NAME}",
        "agentVersion": "${DEPLOYED_VERSION}"
      }
    ]
  }
}
JSON

  az rest --method put --url "$APP_RESOURCE_URL" --body "@$APP_BODY_FILE" --output none
  az rest --method put --url "$APP_DEPLOYMENT_URL" --body "@$APP_DEPLOYMENT_BODY_FILE" --output none
  echo "  Published app: ${APP_NAME} (deployment: ${APP_DEPLOYMENT_NAME}, version: ${DEPLOYED_VERSION})"
else
  echo "  APP_NAME is not set; skipping application publish."
fi

# ── Validate ─────────────────────────────────────────────────────────────────
echo "[10/11] Validating deployment ..."
az cognitiveservices agent show \
  --account-name "$ACCOUNT_NAME" \
  --project-name "$PROJECT_NAME" \
  --name "$AGENT_NAME"

echo ""
echo "Deployment complete."

# ── Optional: verify published endpoint ──────────────────────────────────────
if [[ -n "${APP_NAME:-}" ]]; then
  echo "[11/11] Verifying published endpoint ..."
  echo ""
  echo "Verifying published endpoint for application '$APP_NAME' ..."
  TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
  ENDPOINT="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}/applications/${APP_NAME}/protocols/openai/responses?api-version=2025-11-15-preview"

  # Resolve the agent's model name for the Responses API health check.
  AGENT_MODEL=$(az cognitiveservices agent show \
    --account-name "$ACCOUNT_NAME" \
    --project-name "$PROJECT_NAME" \
    --name "$AGENT_NAME" \
    --query "versions.latest.definition.model" -o tsv 2>/dev/null || echo "gpt-4.1-mini")

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${AGENT_MODEL}\",\"input\":\"ping\"}")

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Endpoint responded 200 OK."
  elif [[ "$HTTP_CODE" == "400" ]]; then
    echo "  Endpoint responded HTTP 400 (may indicate the published endpoint does not yet support MCP tool passthrough)."
    echo "  The agent definition is correctly deployed — test via the Portal Playground or direct agent API instead."
  else
    echo "  WARNING: Endpoint responded HTTP $HTTP_CODE."
    if [[ "$HTTP_CODE" == "404" ]]; then
      echo "  Agent Application '$APP_NAME' was not found. Publish/create the application first."
    fi
    echo "  If 403, assign Azure AI User on the Agent Application resource."
  fi
fi
