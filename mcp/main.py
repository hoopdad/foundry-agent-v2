from fastapi import FastAPI
from fastmcp import FastMCP
import subprocess
import tempfile
import os

app = FastAPI(title="PARI/GP MCP Server")
mcp = FastMCP("pari-gp-tools")

@mcp.tool()
def write_gp_file(code: str) -> dict:
    fd, path = tempfile.mkstemp(suffix=".gp")
    with os.fdopen(fd, "w") as f:
        f.write(code)
    return {"file_path": path}

@mcp.tool()
def run_gp_file(file_path: str) -> dict:
    result = subprocess.run(
        ["gp", "-q", file_path],
        capture_output=True,
        text=True
    )
    return {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "returncode": result.returncode
    }

@app.get("/health", tags=["infra"])
def health():
    return {"status": "ok"}

# Mount MCP on root path
app.mount("/", mcp.http_app())