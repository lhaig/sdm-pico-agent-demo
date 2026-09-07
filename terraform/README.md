# Terraform

This directory creates the disposable AWS, StrongDM, Grafana, workflow, and
audit infrastructure for the fully live Nightshift demo.

For the complete first-time build sequence, start with
[`../docs/03-runbook.md`](../docs/03-runbook.md).

## Resource Topology

- `pg-prod-shopfront-read`: standing agent grant, port 5432
- `pg-prod-shopfront-remediation`: no standing grant, workflow-only, port 5434
- `grafana-mcp`: explicit MCP tool allowlist, port 10001
- `github-mcp`: explicit MCP tool allowlist, port 10002
- `agent-vm`: StrongDM-managed operator SSH with port forwarding enabled
- `app-01` and `app-02`: application hosts; not granted to the agent

No EC2 instance has a customer-managed SSH key attached. The agent VM accepts
SSH only from the StrongDM relay; SSM Session Manager is the break-glass path.

The `ai-agents` role includes only the read database and MCP resources. The
`nightshift-write` workflow grants only the remediation database for at most 15
minutes after manual approval by `sre-oncall`.

## Apply

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform apply
```

StrongDM API credentials are read from `SDM_API_ACCESS_KEY` and
`SDM_API_SECRET_KEY`. Other required values are documented in
`terraform.tfvars.example`.

Terraform cannot complete Log Stream, Slack integration, or tenant-specific MCP
tool-name reconciliation. Follow `manual_steps_reminder` and run preflight.

## Policy Contract

Policy is default-deny. The Terraform templates inject exact account, role, and
resource IDs into the Cedar files. A successful apply establishes only parser
acceptance, not runtime effectiveness. Verify real SQL classifications,
redaction, MCP action names, approval delivery, and expiry in the target tenant.

## Destroy

```bash
terraform destroy
```

The default audit bucket is disposable. Do not carry `force_destroy` into a
production design.
