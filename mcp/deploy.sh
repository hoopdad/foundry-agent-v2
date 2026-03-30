#!/usr/bin/env bash
set -euo pipefail

echo "🚀 MCP end-to-end deploy (Terraform + App Service)"

# -------------------------------------------------
# Load environment variables
# -------------------------------------------------
if [ ! -f ".env" ]; then
  echo "❌ .env file not found"
  echo "👉 Copy .env.template to .env and set required values"
  exit 1
fi

set -a
source .env
set +a

# -------------------------------------------------
# Validate required env vars
# -------------------------------------------------
REQUIRED_VARS=(
  APP_NAME
  RESOURCE_GROUP
  LOCATION
  USE_PRIVATE_ENDPOINT
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ]; then
    echo "❌ Environment variable '$VAR' is not set"
    exit 1
  fi
done

# Default to Standard S1 unless overridden in .env
SERVICE_PLAN_SKU="${SERVICE_PLAN_SKU:-S1}"

# -------------------------------------------------
# Preflight checks
# -------------------------------------------------
command -v az >/dev/null || {
  echo "❌ Azure CLI not installed"
  exit 1
}

command -v terraform >/dev/null || {
  echo "❌ Terraform not installed"
  exit 1
}

az account show >/dev/null || {
  echo "❌ Not logged into Azure. Run 'az login'."
  exit 1
}

# -------------------------------------------------
# Terraform: init / apply
# -------------------------------------------------
echo "📐 Running Terraform"
cd infra

terraform init

export TF_VAR_alert_email_receivers="${ALERT_EMAIL_RECEIVERS:-[]}"

terraform apply \
  -auto-approve \
  -var "app_name=${APP_NAME}" \
  -var "resource_group_name=${RESOURCE_GROUP}" \
  -var "location=${LOCATION}" \
  -var "service_plan_sku=${SERVICE_PLAN_SKU}"

cd ..

echo "✅ Infrastructure provisioning complete"
echo ""
echo "👉 Next: run deploy-app.ps1 from your Windows host to deploy the application code"
echo "   (requires private network connectivity to the App Service)"