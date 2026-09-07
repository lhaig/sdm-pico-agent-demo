# =============================================================================
#  Project Nightshift — Outputs
#
#  Organised as the things you actually need, in the order you need them:
#
#    1. Where to connect                (demo day)
#    2. IDs to paste into manual steps  (setup)
#    3. Verification / forensics        (rehearsal and Moment 7)
#
#  Everything secret is marked sensitive. `terraform output -raw <name>` if you
#  genuinely need the value.
# =============================================================================


# -----------------------------------------------------------------------------
#  1. WHERE TO CONNECT
# -----------------------------------------------------------------------------

output "agent_vm_private_ip" {
  description = "Private address registered as the StrongDM agent-vm SSH resource."
  value       = aws_instance.agent_vm.private_ip
}

output "agent_vm_instance_id" {
  description = "EC2 instance ID for SSM break-glass access when StrongDM is unavailable."
  value       = aws_instance.agent_vm.id
}

output "sdm_gateway_address" {
  description = "StrongDM gateway listen address. This is the only inbound path in the whole build."
  value       = "${aws_eip.sdm_gateway.public_ip}:${var.gateway_listen_port}"
}

output "sdm_relay_private_ip" {
  description = "Relay private IP. No inbound rules — shown for the network walkthrough only."
  value       = aws_instance.sdm_relay.private_ip
}

output "app_server_private_ips" {
  description = "Pinned private IPs of the SSH targets. Match sdm_resource.app_0x.ssh.hostname."
  value = {
    app-01 = aws_instance.app_01.private_ip
    app-02 = aws_instance.app_02.private_ip
  }
}

output "app_server_instance_ids" {
  description = "EC2 instance IDs for operator diagnostics through SSM Session Manager."
  value = {
    app-01 = aws_instance.app_01.id
    app-02 = aws_instance.app_02.id
  }
}

output "mcp_host_instance_id" {
  description = "EC2 instance ID for mcp-grafana diagnostics through SSM Session Manager."
  value       = aws_instance.mcp_host.id
}

output "mcp_host_private_ip" {
  description = <<-EOT
    Private IP of mcp-host, the box running grafana/mcp-grafana.

    NOTHING CAN REACH IT EXCEPT THE STRONGDM RELAY. No public IP, no SSH ingress
    rule, one port open to one security group. That
    is §4.4's argument expressed as a network fact, and it is the reason the
    policy layer in front of these tools is a control rather than a convention:
    the agent is not choosing to go through StrongDM, there is no other path.

    Administer it with SSM Session Manager:
        aws ssm start-session --target <instance id>
        sudo docker logs mcp-grafana
  EOT
  value       = aws_instance.mcp_host.private_ip
}

output "mcp_grafana_url" {
  description = <<-EOT
    The URL StrongDM's MCP Gateway dials. `/mcp` is mcp-grafana's default
    --endpoint-path.

    THE AGENT NEVER SEES THIS ADDRESS. It runs `sdm connect grafana-mcp` and
    talks to a loopback port.
  EOT
  value       = local.grafana_mcp_url
}


# -----------------------------------------------------------------------------
#  2. IDs FOR THE MANUAL STEPS AND FOR POLICY DEBUGGING
#
#  These are the values you paste into the Admin UI, and the values you check
#  when a Cedar policy does not fire the way you expected.
# -----------------------------------------------------------------------------

output "sdm_agent_account_id" {
  description = "a-... The agent's own service account. Referenced by policy 30."
  value       = sdm_account.nightshift_agent.id
}

output "sdm_ai_agents_role_id" {
  description = "r-... Injected into policies 00 and 20 by templatefile()."
  value       = sdm_role.ai_agents.id
}

output "sdm_sre_oncall_role_id" {
  description = "r-... The approver role on the nightshift-write approval flow."
  value       = sdm_role.sre_oncall.id
}

output "sdm_resource_ids" {
  description = "rs-... for every registered resource. The MCP IDs are injected into policy 40."
  value = {
    pg_prod_shopfront_read        = sdm_resource.pg_prod_shopfront_read.id
    pg_prod_shopfront_remediation = sdm_resource.pg_prod_shopfront_remediation.id
    agent_vm                      = sdm_resource.agent_vm.id
    app_01                        = sdm_resource.app_01.id
    app_02                        = sdm_resource.app_02.id
    grafana_mcp                   = sdm_resource.grafana_mcp.id
    github_mcp                    = sdm_resource.github_mcp.id
  }
}

output "sdm_mcp_resource_names" {
  description = <<-EOT
    The names the agent's `sdm connect` calls use, and the names
    scripts/verify.sh and agent/bootstrap.sh expect. If these ever disagree with
    scripts/.env or agent/bootstrap.sh, the MCP tunnels come up on ports nothing
    is listening for and Act 3 is dead with no error message.

        sdm connect grafana-mcp   -> 127.0.0.1:10001
        sdm connect github-mcp    -> 127.0.0.1:10002
  EOT
  value = {
    grafana = local.grafana_mcp_name
    github  = local.github_mcp_name
  }
}

output "sdm_approval_flow_id" {
  description = "af-... The approval flow used by the remediation access workflow."
  value       = sdm_approval_workflow.nightshift_write.id
}

output "sdm_workflow_id" {
  description = "The nightshift-write access workflow the agent requests against."
  value       = sdm_workflow.nightshift_write.id
}

output "sdm_node_ids" {
  description = "Node IDs for troubleshooting. Terraform writes their computed tokens to SSM automatically."
  value = {
    gateway = sdm_node.gateway.id
    relay   = sdm_node.relay.id
  }
}

output "sdm_ssh_public_keys" {
  description = <<-EOT
    The public halves of the StrongDM-generated SSH keypairs, already appended
    to each host's authorized_keys by user-data.

    Surfaced so you can verify by hand — and so you can point at them and say
    "the private halves do not exist outside the control plane."
  EOT
  value = {
    agent_vm = sdm_resource.agent_vm.ssh[0].public_key
    app_01   = sdm_resource.app_01.ssh[0].public_key
    app_02   = sdm_resource.app_02.ssh[0].public_key
  }
}


# -----------------------------------------------------------------------------
#  3. VERIFICATION AND FORENSICS
# -----------------------------------------------------------------------------

output "audit_bucket_name" {
  description = <<-EOT
    PASTE THIS INTO THE ADMIN UI. Log Stream has no Terraform resource, no CLI
    and no API (§4.2) — Settings -> Log Streaming -> Add -> Amazon S3, with this
    bucket name. Skip it and Moment 7 is an empty table.
  EOT
  value       = aws_s3_bucket.audit.id
}

output "athena_workgroup" {
  description = "Athena workgroup for the forensic queries in Moment 7."
  value       = aws_athena_workgroup.audit.name
}

output "athena_database" {
  description = "Glue database holding the `queries` table over the audit log."
  value       = aws_glue_catalog_database.audit.name
}

output "athena_sample_query" {
  # `timestamp` is a reserved word in some Athena engine versions, so it is
  # double-quoted. docs/02-demo-script.md Act 5 prints this query verbatim —
  # keep the two identical.
  description = "Paste-ready. The 'what did the AI do?' query, including what it TRIED to do."
  value       = <<-EOT
    SELECT "timestamp",
           account_email,
           resource_name,
           authorization,
           error,
           query_body
      FROM ${aws_glue_catalog_database.audit.name}.queries
     WHERE account_id = '${sdm_account.nightshift_agent.id}'
     ORDER BY "timestamp" DESC
     LIMIT 100;
  EOT
}

output "database_endpoint" {
  description = "RDS endpoint. Nothing on the agent host can reach it — shown for your own debugging."
  value       = aws_db_instance.shopfront.address
  sensitive   = true
}

output "database_secret_arn" {
  description = "Secrets Manager ARN holding the master credential. Readable by orders-api, not by the agent."
  value       = aws_secretsmanager_secret.db.arn
}

# -----------------------------------------------------------------------------
#  GRAFANA CLOUD
#
#  The incident chain (§6) and the object the agent reads over MCP (Act 3) now
#  live in the same product. These are the values you need to look at either.
# -----------------------------------------------------------------------------

output "grafana_stack_url" {
  description = <<-EOT
    The Grafana stack. Everything Terraform creates in it lives in one folder,
    so a rebuild has a blast radius you can point at.

    On stage, the two tabs worth having open:
      Alerting -> Alert rules  (the rule named by output grafana_alert_rule_name)
      Incidents                (what the agent is reading over MCP in Act 3)
  EOT
  value       = var.grafana_url
}

output "grafana_alert_rule_name" {
  description = <<-EOT
    The rule scripts/break-it.sh polls for and scripts/verify.sh checks exists.

    Must equal GRAFANA_ALERT_RULE in scripts/.env. If they disagree, break-it.sh
    reports "rule not firing yet" until it times out, which looks exactly like a
    broken chain and is not one.
  EOT
  value       = local.alert_rule_name
}

output "grafana_prometheus_remote_write_url" {
  description = <<-EOT
    Where app-01/app-02 send their metrics, read from data.grafana_cloud_stack
    rather than hardcoded.

    Sanity-check the shape if metrics are not arriving: the path is always
    /api/prom/push, and the host looks like
    prometheus-prod-NN-<region-slug>.grafana.net — NOT prometheus-<region>.
  EOT
  value       = local.prom_remote_write_url
}

output "grafana_prometheus_instance_id" {
  description = <<-EOT
    The remote_write basic-auth USERNAME. It is a NUMBER.

    If you are debugging a 401 from remote_write, check this first: putting an
    email address here is the single most common cause, and the error message
    does not say so.
  EOT
  value       = local.prom_instance_id
}

output "manual_steps_reminder" {
  description = "Terraform cannot create these. Read them every time you rebuild the tenant."
  value       = <<-EOT
    MANUAL STEPS
    1. Configure StrongDM Log Stream to s3://${aws_s3_bucket.audit.id} in ${var.aws_region}.
    2. Connect the StrongDM Slack integration for workflow approvals.
    3. Reconcile policy 40 with the observed Grafana and GitHub MCP tool names.
    4. Leave one disposable pull request open in ${var.github_repo == "" ? "<set var.github_repo>" : var.github_repo}.

    Node and agent bootstrap tokens are created by the StrongDM provider and
    written to SSM automatically. They are sensitive values in Terraform state.
  EOT
}
