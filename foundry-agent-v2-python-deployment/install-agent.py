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
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from jinja2 import Environment, FileSystemLoader
import os

# Step 1: Load .env so PROJECT_ENDPOINT and MODEL_DEPLOYMENT_NAME are available
print("[1/5] Loading configuration from .env ...")
load_dotenv()

AGENT_NAME = "PariGpCodeGenAgent"
AGENT_DESCRIPTION = "A Foundry Agent to translate natural language to PARI/GP code"

# Step 2: Connect to the Foundry project using Azure AD credentials
print(f"[2/5] Connecting to Foundry project at {os.environ['PROJECT_ENDPOINT']} ...")
project_client = AIProjectClient(
    endpoint=os.environ["PROJECT_ENDPOINT"],
    credential=DefaultAzureCredential()
)

# Step 3: Render the agent's system prompt from a Jinja2 template
# This keeps instructions version-controlled and templatable separately from code
print("[3/5] Rendering agent instructions from instructions.jinja2 ...")
env = Environment(loader=FileSystemLoader(os.path.dirname(__file__) or "."))
instructions = env.get_template("instructions.jinja2").render()

# Step 4: Build the agent definition — a "prompt" agent backed by a model deployment
print(f"[4/5] Building PromptAgentDefinition with model '{os.environ['MODEL_DEPLOYMENT_NAME']}' ...")
definition = PromptAgentDefinition(
    model=os.environ["MODEL_DEPLOYMENT_NAME"],
    instructions=instructions
)

# Step 5: Publish a new version of the agent to Foundry
# create_version creates the agent if it doesn't exist, or adds a new version if it does
print(f"[5/5] Publishing agent '{AGENT_NAME}' to Foundry ...")
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
print(f"  Definition:  {dict(agent_version.definition)}")
print(f"  Metadata:    {agent_version.metadata or 'None'}")
print(f"  Endpoint:    {os.environ['PROJECT_ENDPOINT']}")