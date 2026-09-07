# Cedar is an additional gate after StrongDM resource grants. These templates
# use exact object IDs created by this deployment.

resource "sdm_policy" "baseline" {
  name        = "00-baseline"
  description = "Permit agent connections and standing reads; permit the human operator within existing grants."

  policy = templatefile("${path.module}/../policies/00-baseline.cedar", {
    ai_agents_role_id       = sdm_role.ai_agents.id
    agent_account_id        = sdm_account.nightshift_agent.id
    grafana_mcp_resource_id = sdm_resource.grafana_mcp.id
    github_mcp_resource_id  = sdm_resource.github_mcp.id
    remediation_resource_id = sdm_resource.pg_prod_shopfront_remediation.id
    sre_oncall_role_id      = sdm_role.sre_oncall.id
    read_resource_id        = sdm_resource.pg_prod_shopfront_read.id
  })
}

resource "sdm_policy" "agents_are_readonly" {
  name        = "10-agents-are-readonly"
  description = "Deny service-account writes on production except the exact remediation path."

  policy = templatefile("${path.module}/../policies/10-agents-are-readonly.cedar", {
    agent_account_id        = sdm_account.nightshift_agent.id
    remediation_resource_id = sdm_resource.pg_prod_shopfront_remediation.id
  })
}

resource "sdm_policy" "redact_pii" {
  name        = "20-redact-pii"
  description = "Redact customer email and phone for Nightshift and cap results at 100 rows."

  policy = templatefile("${path.module}/../policies/20-redact-pii.cedar", {
    ai_agents_role_id = sdm_role.ai_agents.id
    read_resource_id  = sdm_resource.pg_prod_shopfront_read.id
  })
}

resource "sdm_policy" "approve_remediation_write" {
  name        = "30-remediation-write"
  description = "Permit only the approved Nightshift update of public.orders through the remediation resource."

  policy = templatefile("${path.module}/../policies/30-approve-remediation-write.cedar", {
    agent_account_id        = sdm_account.nightshift_agent.id
    remediation_resource_id = sdm_resource.pg_prod_shopfront_remediation.id
  })
}

resource "sdm_policy" "mcp_tool_limits" {
  name        = "40-mcp-tool-limits"
  description = "Explicitly allow required agent tools and forbid incident-state and code-merge actions."

  policy = templatefile("${path.module}/../policies/40-mcp-tool-limits.cedar", {
    agent_account_id        = sdm_account.nightshift_agent.id
    grafana_mcp_resource_id = sdm_resource.grafana_mcp.id
    github_mcp_resource_id  = sdm_resource.github_mcp.id
  })
}
