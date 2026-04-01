# PARI/GP Foundry Agent — AZD Deployment

Deploy and publish the PARI/GP code-generation agent to Microsoft Foundry using the Azure Developer CLI (`azd`).

## Permissions

Role-based access control (RBAC) is required before you can deploy or invoke agents.
See [Role-based access control for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry) for full details.

| Scenario | Required roles |
|---|---|
| Create a new Foundry project | **Azure AI Owner** on the Foundry resource |
| Deploy to an existing project with new resources | **Azure AI Owner** on Foundry resource + **Contributor** on subscription |
| Deploy to a fully configured project | **Reader** on the Foundry resource + **Azure AI User** on the project |
| Publish an agent to a stable endpoint | **Azure AI Project Manager** on the Foundry resource scope |
| Invoke a published agent (Responses API) | **Azure AI User** on the Agent Application resource |

> **Note:** When you publish an agent, it receives its own dedicated Entra agent identity.
> Permissions assigned to the project identity do **not** transfer automatically.
> You must reassign RBAC roles to the new agent identity for any downstream Azure
> resources the agent accesses. See [Publish and share agents](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-agent#what-to-watch-for).

## Prerequisites

- **Azure CLI** — [install](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **Azure Developer CLI (`azd`) 1.2.3 or later** — [install](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- A Foundry resource and project already provisioned, or sufficient RBAC to create them (see table above)

Verify your `azd` version:

```bash
azd version
# Must be 1.2.3 or later
```

## Deployment Steps

### 1. Authenticate

```bash
az login
azd auth login
```

### 2. Initialise with an existing Foundry project

Point `azd` at your Foundry project by its Azure resource ID:

```bash
azd ai agent init \
  --project-id /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.CognitiveServices/accounts/<ACCOUNT_NAME>/projects/<PROJECT_NAME>
```

Replace the placeholders with your actual values. You can find them in the Azure portal on the Foundry project's **Overview** page.

### 3. Configure the agent from the manifest

The agent definition lives in [`parigp.yml`](parigp.yml) — a YAML manifest that captures the agent's model, instructions, tools, and metadata.

```bash
azd ai agent init -m parigp.yml
```

### 4. Deploy

Provision infrastructure and deploy the agent in one step:

```bash
azd up
```

`azd up` runs `azd provision` (Bicep/Terraform) followed by `azd deploy`. If you only need to push agent changes without re-provisioning, run `azd deploy` instead.

### 5. Validate the deployment

Confirm the agent was created in the Foundry project:

```bash
az cognitiveservices agent show \
  --account-name <ACCOUNT_NAME> \
  --project-name <PROJECT_NAME> \
  --name <AGENT_NAME>
```

You can also list all agents in the project:

```bash
az cognitiveservices agent list \
  --account-name <ACCOUNT_NAME> \
  --project-name <PROJECT_NAME>
```

### 6. Verify a published endpoint (optional)

If the agent has been published to an Agent Application, test the endpoint directly:

```bash
# Get an access token for the Foundry data plane
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)

# Call the Responses API
curl -X POST \
  "https://<ACCOUNT_NAME>.services.ai.azure.com/api/projects/<PROJECT_NAME>/applications/<APP_NAME>/protocols/openai/responses?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input": "Write a GP function to compute the nth Fibonacci number."}'
```

A `403 Forbidden` means the caller lacks the **Azure AI User** role on the Agent Application resource.

## Scripted Deployment

Fully automated scripts are provided for both platforms:

- **Bash** — [`deploy.sh`](deploy.sh)
- **PowerShell** — [`deploy.ps1`](deploy.ps1)

Both scripts read the same environment variables. Copy `.env.template` to `.env`, fill in your values, then run:

```bash
# Bash
chmod +x deploy.sh
./deploy.sh

# PowerShell
./deploy.ps1
```

### Private MCP Pattern

Use this order:

1. Deploy private MCP endpoint and private networking.
2. Create a Foundry project connection that points to the MCP server.
3. Set either `MCP_PROJECT_CONNECTION_ID` or `MCP_CONNECTION_NAME` in `.env`.
4. Run `./deploy.sh`.

`parigp.yml` references MCP via `project_connection_id` using a placeholder token.
During deployment, `deploy.sh` resolves and injects the actual connection id into the agent payload.

## Reference

| Resource | Link |
|---|---|
| Foundry Agent Service overview | https://learn.microsoft.com/en-us/azure/foundry/agents/overview |
| Agent development lifecycle | https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/development-lifecycle |
| Publish and share agents | https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-agent |
| RBAC for Microsoft Foundry | https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry |
| Azure Developer CLI docs | https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview |
