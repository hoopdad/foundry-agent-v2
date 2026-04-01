# install-agent.py
# Publishes a PARI/GP code-generation agent to Azure AI Foundry.
#
# Steps:
#   1. Load configuration from .env (project endpoint, model deployment name)
#   2. Authenticate to Foundry using DefaultAzureCredential (az login / managed identity)
#   3. Render agent instructions from a Jinja2 template (instructions.jinja2)
#   4. Build a PromptAgentDefinition — a simple prompt-based agent (no hosting/workflow)
#   5. Publish a new version via the Foundry agents API (create_version)
#
# Uses azure-ai-projects SDK (>= 2.0) which is the current Foundry SDK,
# replacing the legacy azure-ai-agents package.

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool, ModelDeployment, ModelDeploymentSku
from azure.identity import DefaultAzureCredential
from azure.mgmt.cognitiveservices import CognitiveServicesManagementClient
from azure.mgmt.cognitiveservices.models import Project
from dotenv import load_dotenv
from jinja2 import Environment, FileSystemLoader
import os

def get_env(name:str, env_var:str) -> str:
    value = os.environ.get(env_var)
    print (f"  {name}: {value}")
    return value

def get_proj(name:str)->Project:
    try:
        project = client.projects.get(
            resource_group_name=resource_group_name,
            account_name=foundry_resource_name,
            project_name=foundry_project_name
        )
        print(project)
        return project
    except Exception as e:
        print(f"Error getting project '{name}': {e}")
        return None
    


# Step 1: Load .env so PROJECT_ENDPOINT and MODEL_DEPLOYMENT_NAME are available
print("[1/8] Loading configuration from .env ...")
load_dotenv()
subscription_id = get_env("SUBSCRIPTION_ID", "SUBSCRIPTION_ID")
resource_group_name = get_env("RESOURCE_GROUP_NAME", "RESOURCE_GROUP_NAME")
foundry_resource_name = get_env("FOUNDRY_RESOURCE_NAME", "FOUNDRY_RESOURCE_NAME")
foundry_project_name = get_env("FOUNDRY_PROJECT_NAME", "FOUNDRY_PROJECT_NAME")
location = get_env("LOCATION", "LOCATION")
mcp_server_label = get_env("MCP_SERVER_LABEL", "MCP_SERVER_LABEL")
mcp_server_url = get_env("MCP_SERVER_URL", "MCP_SERVER_URL")
mcp_server_description = get_env("MCP_SERVER_DESCRIPTION", "MCP_SERVER_DESCRIPTION")
AGENT_NAME = get_env("AGENT_NAME", "AGENT_NAME")
AGENT_DESCRIPTION = get_env("AGENT_DESCRIPTION", "AGENT_DESCRIPTION")
model=get_env("MODEL_DEPLOYMENT_NAME", "MODEL_DEPLOYMENT_NAME")

print (f"[2/8] Authenticating to Azure and Foundry ...")
client = CognitiveServicesManagementClient(
    credential=DefaultAzureCredential(), 
    subscription_id=subscription_id,
    api_version="2025-04-01-preview"
)

# # Create resource
# resource = client.accounts.begin_create(
#     resource_group_name=resource_group_name,
#     account_name=foundry_resource_name,
#     account={
#         "location": location,
#         "kind": "AIServices",
#         "sku": {"name": "S0",},
#         "identity": {"type": "SystemAssigned"},
#         "properties": {
#             "allowProjectManagement": True,
#             "customSubDomainName": foundry_resource_name
#         }
#     }
# )

# print(f"[3/8] Creating Foundry resource '{foundry_resource_name}' in resource group '{resource_group_name}' ...")
# Wait for the resource creation to complete
# resource_result = resource.result()
# print(f"Resource '{foundry_resource_name}' created successfully.")

# Create default project
project = get_proj(foundry_project_name)
if project is None:
    print(f"[4/8] Creating Foundry project '{foundry_project_name}' in resource group '{resource_group_name}' ...")
    project = client.projects.begin_create(
        resource_group_name=resource_group_name,
        account_name=foundry_resource_name,
        project_name=foundry_project_name,
        project={
            "location": location,
            "identity": {
                "type": "SystemAssigned"
            },
            "properties": {}
        }
    )

    # Wait for the project creation to complete
    project_result = project.result()
    print(f"Project '{foundry_project_name}' created successfully.")

    # output the created project details
    project = client.projects.get(
        resource_group_name=resource_group_name,
        account_name=foundry_resource_name,
        project_name=foundry_project_name
    )
    print(project)
else:
    print(f"Project '{foundry_project_name}' already exists. Skipping creation.")

print ("Begin printing project properties")
print ("*********")
print(project.properties)
print ("*********")
print ("End printing project properties")

foundry_endpoint = project.properties.endpoints['AI Foundry API']
print(f"Foundry Endpoint: {foundry_endpoint}")

skus = client.deployments.list_skus(resource_group_name, foundry_resource_name, model)
if (skus is not None):
    try:
        while (sku := skus.next()):
            print(f"SKU: {sku.name}, Tier: {sku.tier}, Size: {sku.size}, Family: {sku.family}, Capacity: {sku.capacity}")
    except Exception as e:
        print(f"Error reading SKUs: {e}")
else:
    print("No SKUs found for model deployment.")

# Step 3: Connect to the Foundry project using Azure AD credentials
print(f"[5/8] Connecting to Foundry project at {foundry_endpoint} ...")
project_client = AIProjectClient(
    endpoint=foundry_endpoint,
    credential=DefaultAzureCredential()
)
print("Connected to Foundry project successfully.")
for deployment in project_client.deployments.list():
    print(deployment)
print ("Finished listing deployments.")

try:
    deployment = ModelDeployment(
        name="gpt-4.1-mini",
        type="ModelDeployment", 
        model_name="gpt-4.1-mini", 
        model_version="2025-04-14", 
        model_publisher="azure-openai",
        capabilities={"chat_completion": "true"},
        sku=ModelDeploymentSku(
            name="GlobalStandard",
            tier="Global",
            size="S",
            family="Standard",
            capacity="1"
        ),
        connection_name=None
    )
    deployment_result = project_client.deployments.create_or_update(deployment)
    print(f"Deployment '{deployment.name}' creation initiated, waiting for completion...")
    deployment_result.wait()
    print(f"Deployment '{deployment.name}' created successfully with status: {deployment_result.result().status}")
except Exception as e:
    print(f"Error creating deployment: {e}")

mcp_tool = MCPTool(
    server_label=mcp_server_label,
    server_url=mcp_server_url,
    server_description=mcp_server_description,
    require_approval="never",
)

# project_client.tools.create_mcp_tool(mcp_tool)

# Step 4: Render the agent's system prompt from a Jinja2 template
# This keeps instructions version-controlled and templatable separately from code
print("[6/8] Rendering agent instructions from instructions.jinja2 ...")
env = Environment(loader=FileSystemLoader(os.path.dirname(__file__) or "."))
instructions = env.get_template("instructions.jinja2").render()

# Step 5: Build the agent definition — a "prompt" agent backed by a model deployment
print(f"[7/8] Building PromptAgentDefinition with model '{model}' ...")
definition = PromptAgentDefinition(
    model=model,
    instructions=instructions,
    tools=[mcp_tool]
)

# Step 6: Publish a new version of the agent to Foundry
# create_version creates the agent if it doesn't exist, or adds a new version if it does
print(f"[8/8] Publishing agent '{AGENT_NAME}' to Foundry ...")
agent_version = project_client.agents.create_version(
    agent_name=AGENT_NAME,
    definition=definition,
    description=AGENT_DESCRIPTION
)

print()
print("Agent Published Successfully")
print(f"  Name:        {agent_version.name}")
print(f"  ID:          {agent_version.id}")
print(f"  Version:     {agent_version.version}")
print(f"  Description: {agent_version.description}")
print(f"  Created At:  {agent_version.created_at}")
# print(f"  Definition:  {dict(agent_version.definition)}")
# print(f"  Metadata:    {agent_version.metadata or 'None'}")
print(f"  Endpoint:    {foundry_endpoint}")

print ("Agent installation complete.")
# print (f"{agent_version}")