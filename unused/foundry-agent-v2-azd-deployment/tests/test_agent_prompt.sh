#!/usr/bin/env bash
# test_agent_prompt.sh — Send a test prompt to the deployed agent and check for errors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE"
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

PROJECT_ENDPOINT="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}"
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)

PROMPT="Discover the first 6 prime numbers and share the algorithm and output"

echo "=== Agent: ${AGENT_NAME} ==="
echo "=== Prompt: ${PROMPT} ==="
echo ""

# Get the agent's current tool definition to inspect
echo "--- Current tool definitions ---"
TOOLS=$(curl -sS "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" 2>&1 | python3 -c "
import json, sys
data = json.load(sys.stdin)
versions = data.get('value', data.get('versions', []))
if isinstance(versions, dict):
    latest = versions.get('latest', {})
    tools = latest.get('definition', {}).get('tools', [])
else:
    tools = versions[-1].get('definition', {}).get('tools', []) if versions else []
print(json.dumps(tools, indent=2))
" 2>/dev/null || echo "Could not parse tools")
echo "$TOOLS"
echo ""

# Send the prompt via the Responses API (direct agent endpoint, not published app)
echo "--- Sending prompt via Responses API ---"
RESPONSE_FILE="/tmp/agent-test-response.json"

HTTP_CODE=$(curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" -X POST \
  "${PROJECT_ENDPOINT}/openai/responses?api-version=2025-03-01-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${AGENT_NAME}\",
    \"input\": \"${PROMPT}\"
  }")

echo "HTTP: $HTTP_CODE"
echo ""

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "--- SUCCESS ---"
  python3 -c "
import json
with open('$RESPONSE_FILE') as f:
    data = json.load(f)
for item in data.get('output', []):
    if item.get('type') == 'message':
        for c in item.get('content', []):
            if c.get('type') == 'output_text':
                print(c.get('text', '')[:500])
" 2>/dev/null || cat "$RESPONSE_FILE" | head -c 500
else
  echo "--- ERROR ---"
  cat "$RESPONSE_FILE" | python3 -m json.tool 2>/dev/null || cat "$RESPONSE_FILE"
fi

echo ""
echo "=== Done ==="
