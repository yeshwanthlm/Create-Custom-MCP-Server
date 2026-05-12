# Create a Custom MCP Server with Strands Agents

This project demonstrates how to build a custom **Model Context Protocol (MCP)** server and connect it to a [Strands Agents](https://strandsagents.com/) AI agent. It uses a simple calculator as the example tool (not limitted to), but the same pattern applies to any custom functionality you want to expose to an AI agent.

---

## What is MCP?

The **Model Context Protocol (MCP)** is an open standard that lets AI agents discover and call tools hosted on external servers. Instead of hardcoding tools into your agent, you run a separate MCP server that exposes tools over HTTP. The agent connects to it, lists available tools, and calls them as needed — keeping your agent logic and tool implementations cleanly separated.

---

## Project Structure

```
Create-Custom-MCP-Server/
├── mcp_server.py                  # The custom MCP server (calculator tool)
├── connect_to_mcp_server.ipynb    # Jupyter notebook showing how to connect a Strands agent
└── requirements.txt               # Python dependencies
```

---

## Prerequisites

- Python 3.10+
- An AWS account with [Amazon Bedrock](https://aws.amazon.com/bedrock/) access (used by Strands Agents as the default model provider)
- AWS credentials configured locally (`aws configure` or environment variables)

---

## Installation

```bash
# Clone the repository
git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git
cd Create-Custom-MCP-Server

# Create and activate a virtual environment (recommended)
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

---

## Usage

### Step 1 — Start the MCP Server

The server exposes an `add` tool over HTTP using the `streamable-http` transport on `http://localhost:8000/mcp/`.

```bash
python mcp_server.py
```

You should see the FastMCP server start and begin listening for connections.

### Step 2 — Connect a Strands Agent

Open and run `connect_to_mcp_server.ipynb` in Jupyter, or use the code snippets below directly.

**Agent-driven invocation** — let the agent decide when to call the tool:

```python
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.tools.mcp.mcp_client import MCPClient

def create_transport():
    return streamablehttp_client("http://localhost:8000/mcp/")

mcp_client = MCPClient(create_transport)

with mcp_client:
    tools = mcp_client.list_tools_sync()
    agent = Agent(tools=tools)
    response = agent("What is 125 plus 375?")
```

**Direct tool call** — invoke a tool programmatically without going through the agent:

```python
with mcp_client:
    result = mcp_client.call_tool_sync(
        tool_use_id="tool-123",
        name="add",
        arguments={"x": 125, "y": 375}
    )
    print(f"Result: {result['content'][0]['text']}")
```

**Explicit tool call through the agent**:

```python
with mcp_client:
    tools = mcp_client.list_tools_sync()
    agent = Agent(tools=tools)
    result = agent.tool.add(x=125, y=375)
    print(f"Result: {result['content'][0]['text']}")
```

> **Note:** All agent and tool calls must happen inside the `with mcp_client:` context manager. The MCP session is only active within that block.

---

## How It Works

```
┌─────────────────────┐        HTTP (streamable-http)       ┌──────────────────────┐
│   Strands Agent     │  ──────────────────────────────────▶ │   FastMCP Server     │
│  (connect notebook) │  ◀──────────────────────────────────  │  (mcp_server.py)     │
│                     │        Tool results (JSON)            │                      │
│  - list_tools()     │                                       │  Tools exposed:      │
│  - call_tool()      │                                       │  - add(x, y) → int   │
└─────────────────────┘                                       └──────────────────────┘
```

1. `mcp_server.py` starts a FastMCP server and registers the `add` tool.
2. The notebook creates an `MCPClient` pointing at `http://localhost:8000/mcp/`.
3. The Strands agent discovers available tools via `list_tools_sync()`.
4. When the agent needs to add numbers, it calls the `add` tool on the MCP server and gets the result back.

---

## Extending the Server

To add more tools, just decorate additional functions in `mcp_server.py`:

```python
@mcp.tool(description="Multiply two numbers")
def multiply(x: int, y: int) -> int:
    """Multiply two numbers and return the result."""
    return x * y
```

Restart the server and the new tool will automatically be available to any connected agent.

---

## Dependencies

| Package         | Purpose                                      |
|-----------------|----------------------------------------------|
| `strands-agents`| Strands Agents SDK for building AI agents    |
| `FastMCP`       | Framework for building MCP servers in Python |
| `boto3`         | AWS SDK (used by Strands for Bedrock access) |

---

## Resources

- [Strands Agents Documentation](https://strandsagents.com/docs/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [FastMCP GitHub](https://github.com/jlowin/fastmcp)
- [Amazon Bedrock](https://aws.amazon.com/bedrock/)
