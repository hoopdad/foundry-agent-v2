#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy MCP application code to an existing App Service.

.DESCRIPTION
    Runs from a Windows host with private network connectivity to the App Service
    (VPN or ExpressRoute into the hub VNet). Handles zip deployment, startup
    command, and health check configuration.

    Infrastructure (VNet, private endpoint, peering) must already be provisioned
    by deploy.sh before running this script.

.NOTES
    Prerequisites:
      - Azure CLI installed and logged in  (az login)
      - Private network connectivity to the App Service VNet
      - .env file in the same directory as this script
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "🚀 MCP application deployment (Windows / Azure CLI)"

# -------------------------------------------------
# UNC-path workaround
# az spawns CMD which doesn't support UNC paths; stage source to local temp
# -------------------------------------------------
$sourceDir = $PSScriptRoot
$tmpDir    = $null
if ($sourceDir -match '^\\\\') {
    $tmpDir = Join-Path $env:TEMP "mcp-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "📁 UNC path detected — staging source to $tmpDir ..."
    $null = New-Item -ItemType Directory -Path $tmpDir -Force
    $deployFiles = @('main.py', 'requirements.txt')
    foreach ($f in $deployFiles) {
        Copy-Item -Path (Join-Path $sourceDir $f) -Destination $tmpDir
    }
    $deployDir = $tmpDir
} else {
    $deployDir = $sourceDir
}

# -------------------------------------------------
# Load .env
# -------------------------------------------------
$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Error "❌ .env file not found at $envFile`n   Copy .env.template to .env and fill in required values."
}

Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^\s*#') {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $key   = $parts[0].Trim()
            $value = $parts[1].Trim()
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}

# -------------------------------------------------
# Validate required env vars
# -------------------------------------------------
$required = @('APP_NAME', 'RESOURCE_GROUP', 'LOCATION', 'USE_PRIVATE_ENDPOINT')
foreach ($var in $required) {
    $val = [System.Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrWhiteSpace($val)) {
        Write-Error "❌ Environment variable '$var' is not set in .env"
    }
}

$appName       = $env:APP_NAME
$resourceGroup = $env:RESOURCE_GROUP
$location      = $env:LOCATION
$sku           = if ($env:SERVICE_PLAN_SKU) { $env:SERVICE_PLAN_SKU } else { 'S1' }

# -------------------------------------------------
# Preflight checks
# -------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "❌ Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
}

az account show | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "❌ Not logged into Azure. Run 'az login' first."
}

# -------------------------------------------------
# Private endpoint connectivity check
# -------------------------------------------------
if ($env:USE_PRIVATE_ENDPOINT -eq 'true') {
    Write-Host "🔒 Private endpoint mode — verifying Kudu reachability over private network..."
    $scmHost = "$appName.scm.azurewebsites.net"
    try {
        $null = [System.Net.Dns]::GetHostAddresses($scmHost)
        Write-Host "   ✅ DNS resolved $scmHost"
    }
    catch {
        Write-Warning "   ⚠️  Cannot resolve $scmHost"
        Write-Warning "      Ensure your VPN/private network is connected before deploying."
        Write-Warning "      Continuing anyway — deployment will fail if not connected."
    }
}

# -------------------------------------------------
# Deploy application code
# -------------------------------------------------
Write-Host "📦 Deploying MCP server code to App Service..."

Push-Location $deployDir
try {
    $deployArgs = @(
        'webapp', 'up',
        '--name',           $appName,
        '--resource-group', $resourceGroup,
        '--location',       $location,
        '--runtime',        'PYTHON:3.11',
        '--sku',            $sku,
        '--track-status',   'false',
        '--logs'
    )
    az @deployArgs
    if ($LASTEXITCODE -ne 0) { throw "az webapp up failed" }
} finally {
    Pop-Location
    if ($tmpDir -and (Test-Path $tmpDir)) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------
# Configure startup command
# -------------------------------------------------
Write-Host "⚙️  Setting App Service startup command..."

az webapp config set `
    --name           $appName `
    --resource-group $resourceGroup `
    --startup-file   "gunicorn -k uvicorn.workers.UvicornWorker main:app"
if ($LASTEXITCODE -ne 0) { Write-Error "❌ Failed to set startup command" }

# -------------------------------------------------
# Configure health check
# -------------------------------------------------
Write-Host "❤️  Configuring health check endpoint..."

az webapp config set `
    --name               $appName `
    --resource-group     $resourceGroup `
    --generic-configurations '{"healthCheckPath": "/health"}'
if ($LASTEXITCODE -ne 0) { Write-Error "❌ Failed to configure health check" }

# -------------------------------------------------
# Done
# -------------------------------------------------
Write-Host ""
Write-Host "✅ MCP application deployment complete"
Write-Host "🌐 App DNS name (private): $appName.azurewebsites.net"
Write-Host "🔐 Public access: disabled"
