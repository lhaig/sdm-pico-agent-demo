# MCP resources use the exact block and attributes exposed by the pinned
# StrongDM provider. Upstream credentials remain in StrongDM or on the private
# MCP host and are never written to the agent VM.

locals {
  grafana_mcp_name = "grafana-mcp"
  github_mcp_name  = "github-mcp"
  grafana_mcp_url  = "http://${var.mcp_host_private_ip}:${var.mcp_grafana_port}/mcp"

  mcp_tags = {
    Project = "nightshift"
    kind    = "mcp"
  }
}

resource "sdm_resource" "grafana_mcp" {
  mcp_gateway_pat {
    name     = local.grafana_mcp_name
    url      = local.grafana_mcp_url
    password = var.mcp_caller_bearer_token

    # Organisation-wide default. The agent explicitly connects this resource
    # on local port 10001; keeping the resource default separate avoids clashes
    # with automatically allocated SSH resource ports.
    bind_interface = "127.0.0.1"
    port_override  = 12001
    tags           = local.mcp_tags
  }

  depends_on = [aws_instance.mcp_host]
}

resource "sdm_resource" "github_mcp" {
  mcp_gateway_pat {
    name     = local.github_mcp_name
    url      = var.github_mcp_url
    password = var.github_mcp_token

    bind_interface = "127.0.0.1"
    port_override  = 12002
    tags           = local.mcp_tags
  }
}
