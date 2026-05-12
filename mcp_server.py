"""
The following code demonstrates how to create a simple MCP server that provides limited calculator functionality.
"""

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

# Disable DNS rebinding protection so the server accepts requests forwarded
# by Nginx. This is safe because port 8000 is closed externally — only Nginx
# running on localhost can reach FastMCP directly.
security = TransportSecuritySettings(enable_dns_rebinding_protection=False)

mcp = FastMCP("Calculator Server", transport_security=security)

@mcp.tool(description="Add two numbers together")
def add(x: int, y: int) -> int:
    """Add two numbers and return the result."""
    return x + y

mcp.run(transport="streamable-http")
