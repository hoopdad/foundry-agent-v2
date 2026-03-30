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
for var in SUBSCRIPTION_ID RESOURCE_GROUP ACCOUNT_NAME PROJECT_NAME AGENT_NAME AGENT_MANIFEST; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

PROJECT_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}"
PROJECT_ENDPOINT="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}"
MANIFEST_PATH="$SCRIPT_DIR/$AGENT_MANIFEST"
AZD_ENV_NAME="${AZD_ENV_NAME:-$(basename "$SCRIPT_DIR")-dev}"
APP_DEPLOYMENT_NAME="${APP_DEPLOYMENT_NAME:-primary}"
APP_MGMT_API_VERSION="${APP_MGMT_API_VERSION:-2026-01-15-preview}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "ERROR: Agent manifest not found at $MANIFEST_PATH"
  exit 1
fi

# ── Check prerequisites ─────────────────────────────────────────────────────
echo "[2/9] Checking prerequisites ..."

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
echo "[3/9] Authenticating ..."
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

# ── Prepare/select azd environment ──────────────────────────────────────────
echo "[4/9] Preparing azd environment ..."
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

# ── Deploy infrastructure ────────────────────────────────────────────────────
echo "[5/9] Running azd up (provision + deploy) ..."
azd up --no-prompt

# ── Deploy agent version from YAML ───────────────────────────────────────────
echo "[6/9] Deploying agent from ${AGENT_MANIFEST} ..."

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
echo "[7/9] Publishing Agent Application ..."

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
echo "[8/9] Validating deployment ..."
az cognitiveservices agent show \
  --account-name "$ACCOUNT_NAME" \
  --project-name "$PROJECT_NAME" \
  --name "$AGENT_NAME"

echo ""
echo "Deployment complete."

# ── Optional: verify published endpoint ──────────────────────────────────────
if [[ -n "${APP_NAME:-}" ]]; then
  echo "[9/9] Verifying published endpoint ..."
  echo ""
  echo "Verifying published endpoint for application '$APP_NAME' ..."
  TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
  ENDPOINT="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}/applications/${APP_NAME}/protocols/openai/responses?api-version=2025-11-15-preview"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"input": "Write a GP function to compute the nth Fibonacci number."}')

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Endpoint responded 200 OK."
  else
    echo "  WARNING: Endpoint responded HTTP $HTTP_CODE."
    if [[ "$HTTP_CODE" == "404" ]]; then
      echo "  Agent Application '$APP_NAME' was not found. Publish/create the application first."
    fi
    echo "  If 403, assign Azure AI User on the Agent Application resource."
  fi
fi
