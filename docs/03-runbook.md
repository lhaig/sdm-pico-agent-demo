# Setup, Deployment, And Rehearsal

This is the complete path from an empty AWS account and StrongDM demo
organisation to a rehearsed Nightshift demonstration.

Allow half a day for the first deployment. Do not build this for the first time
on the morning of a presentation.

## 1. What You Need

### Local tools

Install and authenticate:

- Terraform 1.6 or newer
- AWS CLI v2
- StrongDM CLI
- PostgreSQL `psql`
- `jq`, `curl`, `nc`, `ssh`, `openssl`, and Python 3
- Node.js only if you want to rebuild the PowerPoint deck

Check them:

```bash
terraform version
aws --version
sdm version
psql --version
jq --version
node --version
```

### Accounts and licences

You need:

- A dedicated StrongDM demo organisation with Policy Editor, access workflows,
  MCP Gateway, audit, and Slack integration available.
- A Slack workspace where you may install and authorise the StrongDM app.
- An AWS account where you can create VPC, EC2, RDS, IAM, SSM, Secrets Manager,
  S3, Glue, and Athena resources.
- A Grafana Cloud stack with IRM access.
- A disposable GitHub repository.
- An OpenAI API key.

Use a dedicated StrongDM organisation. The strict preflight rejects Global
Access and unconditional broad permits because they invalidate the MCP
allowlist demonstration.

## 2. Prepare StrongDM

1. Sign in as an organisation administrator.
   For this demo the Admin UI is `https://app.eu.strongdm.com` and the runtime
   API endpoint is `api.eu.strongdm.com:443`.
2. Enable policy enforcement in the Policy Editor.
3. Disable or remove Global Access in this dedicated demo organisation.
4. Enable SSH port forwarding in the StrongDM organisation settings. Terraform
   also enables it specifically on the `agent-vm` resource.
5. Create an admin API key for Terraform with account, role, resource, node,
   policy, workflow, and approval-workflow management permissions.
6. Export it locally:

```bash
export SDM_API_ACCESS_KEY='...'
export SDM_API_SECRET_KEY='...'
```

Do not put these values in `terraform.tfvars`.

The human named in `human_users` must be able to sign in to StrongDM. Terraform
creates the account and attaches it to `sre-oncall`. If that account already
exists, keep it in the map and import it into the matching Terraform address.
After apply, accept any StrongDM invitation and verify the presenter can sign in.

## 3. Prepare Grafana Cloud

Create or select a disposable Grafana Cloud stack.

### Stack service-account token

Inside the stack, create a service account with the stack **Admin** role and a
token beginning with `glsa_`. Admin is required by the Terraform provisioning
APIs; Grafana Incident writes require at least Editor. Verify the account can
open IRM before continuing.

### Cloud Access Policy token

In the Grafana Cloud Portal, create a separate Cloud Access Policy token with:

- `stacks:read`
- `metrics:write`

The tokens are not interchangeable.

Record:

```bash
export TF_VAR_grafana_service_account_token='glsa_...'
export TF_VAR_grafana_cloud_access_policy_token='...'
```

Also record the stack URL and slug, for example:

```text
URL:  https://nightshift.grafana.net/
slug: nightshift
```

In Grafana, open **Connections > Data sources** and note the hosted Prometheus
data-source name or UID. Stack naming varies; the Terraform default may not
match your stack.

## 4. Prepare GitHub

Two repository roles are involved:

- The Nightshift project repository contains this code and must be publicly
  readable by the agent VM at `nightshift_repo_url`.
- The disposable target repository is where the agent creates an issue and
  attempts the policy-denied merge.

Prepare the target repository:

1. Create a disposable repository, for example `your-org/shopfront-platform`.
2. Create a branch and leave one harmless pull request open.
3. Create a fine-grained token for the MCP Gateway, restricted to this one
   repository. Grant **Contents: Read and write**, **Issues: Read and write**,
   and **Pull requests: Read and write**, so upstream scope permits the actions.
   StrongDM, not GitHub token scope, must be what denies the merge.
4. Create a second read-only token for local preflight. It only needs to list
   pull requests in that repository.

Export only the MCP token for Terraform:

```bash
export TF_VAR_github_mcp_token='github_pat_...'
```

Keep the read-only token for `scripts/.env` later.

## 5. Prepare AWS

Authenticate the AWS CLI and select the deployment region:

```bash
export AWS_PROFILE='nightshift'
export AWS_REGION='eu-west-1'
aws sts get-caller-identity
```

No EC2 key pair is required. The agent VM and application hosts are StrongDM
SSH resources using StrongDM-generated keys. Gateway, relay, MCP host, and agent
VM retain SSM Session Manager as the break-glass path.

## 6. Configure Terraform

Create the local configuration:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and set at least:

| Variable | Value |
|---|---|
| `owner` | Your email |
| `sdm_api_host` | `api.eu.strongdm.com:443` for the EU control plane |
| `aws_region` | Your AWS region |
| `availability_zones` | Two AZs in that region |
| `agent_vm_private_ip` | Free address in `private_subnet_cidrs[0]` |
| `human_users` | The presenter/approver account |
| `github_repo` | The disposable `owner/repository` |
| `grafana_stack_slug` | Grafana stack slug |
| `grafana_url` | Full stack URL with scheme |
| `grafana_prom_datasource_name` | Actual hosted Prometheus data-source name |
| `mcp_grafana_image` | Existing tested tag, currently `grafana/mcp-grafana:1.3.0` |
| `nightshift_repo_url` | Public HTTPS clone URL of this repository |
| `nightshift_repo_ref` | Tested branch or tag |

The repository must be readable by the agent VM without a deploy key. Publish a
dedicated branch or tag before applying; user-data clones that exact ref.

Set the remaining secrets in the shell:

```bash
export TF_VAR_db_password="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-28)"
export TF_VAR_openai_api_key='sk-...'
export TF_VAR_mcp_caller_bearer_token="$(openssl rand -hex 32)"
```

Terraform state contains the RDS password, MCP credentials, and StrongDM node
and service tokens. Use an encrypted restricted remote backend for a shared or
long-lived environment. Local state is acceptable only for this short-lived
single-operator demo and must not be committed.

## 7. Validate And Deploy

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=plan.out
terraform -chdir=terraform apply plan.out
```

The initial apply creates and connects the StrongDM gateway, relay, resources,
identity, policies, workflow, MCP resources, AWS infrastructure, and Grafana
supporting resources. StrongDM bootstrap tokens are written to SSM
automatically.

Print the important outputs:

```bash
terraform -chdir=terraform output agent_vm_private_ip
terraform -chdir=terraform output agent_vm_instance_id
terraform -chdir=terraform output sdm_resource_ids
terraform -chdir=terraform output manual_steps_reminder
```

## 8. Verify Instance Bootstrap

Wait for the agent VM through the SSM break-glass path first:

```bash
AGENT_INSTANCE_ID="$(terraform -chdir=terraform output -raw agent_vm_instance_id)"
aws ssm start-session --target "$AGENT_INSTANCE_ID" --region "$AWS_REGION"
# In the SSM session:
sudo cloud-init status --wait
exit
```

Then log the local StrongDM CLI in as the human presenter and establish the
StrongDM-managed operator tunnel:

```bash
sdm login
cp scripts/.env.example scripts/.env
./scripts/live-demo.sh operator-tunnel
```

The command runs `sdm ssh config`, then opens standard SSH through the
StrongDM `agent-vm` resource. It does not use an EC2 key or public port 22.

Wait for cloud-init and inspect the services through the generated config:

```bash
ssh -F scripts/.sdm-ssh-config agent-vm 'sudo cloud-init status --wait'
ssh -F scripts/.sdm-ssh-config agent-vm \
  'systemctl --no-pager --full status nightshift-sdm picoclaw-gateway nightshift-shim'
ssh -F scripts/.sdm-ssh-config agent-vm 'sdm status'
```

`sdm status` must show:

- `pg-prod-shopfront-read` on 5432
- `grafana-mcp` on 10001
- `github-mcp` on 10002

It must not show `pg-prod-shopfront-remediation` before approval.

Confirm the configured OpenAI account has billing enabled and access to
`gpt-4.1`, then test one model call:

```bash
ssh -F scripts/.sdm-ssh-config agent-vm \
  "cd /opt/nightshift/workspace && picoclaw agent -m 'Reply SETUP_OK only' -s setup-smoke"
```

If bootstrap failed:

```bash
aws ssm start-session --target "$AGENT_INSTANCE_ID" --region "$AWS_REGION"
# In the SSM session:
sudo journalctl -u nightshift-sdm -u picoclaw-gateway -u nightshift-shim -n 200 --no-pager
sudo tail -200 /var/log/cloud-init-output.log
```

Verify both application hosts through SSM. Obtain their IDs:

```bash
terraform -chdir=terraform output app_server_instance_ids
```

For each ID, start a session and run:

```bash
aws ssm start-session --target i-REPLACE_ME --region "$AWS_REGION"
sudo systemctl is-active orders-api prometheus-agent
curl -fsS http://127.0.0.1:8080/health
exit
```

Both services and the health endpoint must be healthy. These are operator
deployment checks; the agent has no application-host grant.

## 9. Complete Manual StrongDM Setup

### Slack workflow approvals

In the StrongDM Admin UI, connect the Slack integration. Confirm that the
`nightshift-write-approval` workflow exists and that `sre-oncall` is its manual
approver.

The Slack integration belongs to StrongDM. PicoClaw's own Slack channel is
disabled; the agent is driven through the loopback task shim.

### Log Stream

For S3/Athena audit demonstration, configure StrongDM Log Stream:

1. Open **Settings > Log Streaming > Add > Amazon S3**.
2. Use `terraform -chdir=terraform output -raw audit_bucket_name`.
3. Use the Terraform AWS region.
4. Set the object prefix to `logs` so query records land under
   `logs/queries/`, matching the Glue table.
5. Run a test query and confirm an object appears in the bucket.

The core `live-demo.sh audit` command uses the StrongDM audit CLI and does not
depend on Athena. Treat Athena as optional until the Glue schema has been
validated against your tenant's actual Log Stream records.

### MCP tool names

Inspect the effective tools from the agent host:

```bash
ssh -F scripts/.sdm-ssh-config agent-vm 'picoclaw mcp show grafana'
ssh -F scripts/.sdm-ssh-config agent-vm 'picoclaw mcp show github'
```

Confirm these exact names exist:

```text
Grafana: get_incident, add_activity_to_incident, create_incident
GitHub:  list_pull_requests, create_issue, merge_pull_request
```

If a server uses different names, update all three locations together:

- `policies/40-mcp-tool-limits.cedar`
- `agent/workspace/AGENT.md`
- `scripts/verify.sh`
- `scripts/live-demo.sh`

Publish the updated repository ref, reapply Terraform, then refresh the agent:

```bash
ssh -F scripts/.sdm-ssh-config agent-vm \
  "sudo git -C /opt/SDMChallenge pull --ff-only && sudo GITHUB_REPO='your-org/shopfront-platform' /opt/SDMChallenge/agent/bootstrap.sh"
```

If Terraform replaced the agent VM because `nightshift_repo_ref` changed, wait
for cloud-init through SSM and rerun `operator-tunnel`. The StrongDM resource
continues to target the configured fixed private IP.

## 10. Configure The Operator

Open the separate human database connection:

```bash
sdm connect pg-prod-shopfront-read 5433
```

Read the shim bearer from the agent host:

```bash
NIGHTSHIFT_SHIM_TOKEN="$(ssh -F scripts/.sdm-ssh-config agent-vm \
  "sudo awk -F= '/^NIGHTSHIFT_SHIM_TOKEN=/{print \$2}' /etc/nightshift.env")"
```

Set these values in `scripts/.env`:

```dotenv
SHOPFRONT_ADMIN_URL="postgresql://127.0.0.1:5433/shopfront"
NIGHTSHIFT_SHIM_TOKEN="value-from-the-command-above"
AGENT_SSH_RESOURCE="agent-vm"
GRAFANA_URL="https://your-stack.grafana.net"
GRAFANA_SA_TOKEN="glsa_..."
GITHUB_REPO="your-org/shopfront-platform"
GITHUB_TOKEN="read-only-local-token"
```

Do not put the GitHub MCP token in `scripts/.env`; StrongDM holds that token.

Open the managed SSH forwards:

```bash
./scripts/live-demo.sh operator-tunnel
```

This is an operator control tunnel only. It forwards the task shim and MCP ports
used by preflight; it does not carry the agent's database or MCP resource
traffic. The agent VM already opened its own StrongDM listeners during boot. If
this SSH tunnel closes after dispatch, the running agent continues; reopen it to
submit the next phase. The shim is never exposed publicly.

Verify the current Grafana IRM RPC path:

```bash
source scripts/common.sh
irm_rpc IncidentsService.QueryIncidentPreviews \
  '{"query":{"queryString":"status:active","limit":5}}' | jq .
```

## 11. Initialise And Seed The Database

The schema is not created by Terraform. Apply it through the human StrongDM
connection, then seed it:

```bash
source scripts/.env

psql "$SHOPFRONT_ADMIN_URL" \
  --no-psqlrc \
  --set=ON_ERROR_STOP=1 \
  --file app/schema.sql

python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r app/orders-api/requirements.txt
python3 app/seed.py
```

The seed creates approximately 5,000 customers, 50,000 orders, payments, and a
`pristine` schema used by reset.

Verify it:

```bash
psql "$SHOPFRONT_ADMIN_URL" --tuples-only --command \
  "SELECT count(*) FROM public.orders"
psql "$SHOPFRONT_ADMIN_URL" --tuples-only --command \
  "SELECT count(*) FROM pristine.orders"
```

Both counts should match.

## 12. Run Strict Preflight

```bash
./scripts/live-demo.sh prepare
```

Do not continue unless every check passes. Preflight proves:

- Agent and operator connectivity
- Standing read resource present and remediation resource absent
- Root-owned wrappers and no general SSH wrapper
- Direct and aliased email/phone redaction
- The 100-row customer result cap
- A safe zero-row write denied by StrongDM
- Grafana and GitHub MCP tool inventories
- PicoClaw's actual `/mcp` connections
- Valid shim authentication
- No stale incident or active remediation request
- No Global Access or unconditional broad permit
- The configured GitHub repository has an open pull request

## 13. Rehearse The Complete Demo

```bash
./scripts/live-demo.sh start
```

Wait for the command to stop at `awaiting_approval`. In Slack, inspect the
request justification and approve it as a member of `sre-oncall`.

Continue:

```bash
./scripts/live-demo.sh resume
./scripts/live-demo.sh deny
./scripts/live-demo.sh audit
```

The scripts fail unless they can correlate the expected Nightshift principal,
resource, action, and policy decision in StrongDM audit records.

Reset after the rehearsal:

```bash
./scripts/live-demo.sh reset
```

Rehearse again after changing any policy, MCP image, MCP endpoint, StrongDM CLI,
Terraform provider, PicoClaw version, prompt, or wrapper.

## 14. Presentation-Day Checklist

1. Confirm the local StrongDM CLI can reach the `agent-vm` SSH resource.
2. Confirm the disposable GitHub pull request is still open.
3. Confirm the StrongDM Slack integration is connected.
4. Run `./scripts/live-demo.sh operator-tunnel`.
5. Run `./scripts/live-demo.sh prepare`.
6. Open the terminal, Slack approval channel, StrongDM Policy Monitor, and
   Grafana incident list.
7. Use an 18 point or larger terminal font.

## 15. Teardown

Reset first so incidents and grants are cleaned up:

```bash
./scripts/live-demo.sh reset
terraform -chdir=terraform destroy
```

Then remove local secret-bearing files if the environment is finished:

```bash
rm -f terraform/terraform.tfvars scripts/.env terraform/plan.out
```

Also revoke or delete the StrongDM Terraform API key, GitHub MCP token, GitHub
preflight token, Grafana service-account token, Grafana Cloud Access Policy
token and OpenAI key when the environment is no longer needed. Delete the
disposable target repository if it exists only for Nightshift.

The audit bucket is disposable by default. Change
`audit_bucket_force_destroy` before adapting this environment for retained
customer evidence.

## Troubleshooting

### Terraform cannot find the Grafana data source

Set `grafana_prom_datasource_name` to the name shown under Grafana
**Connections > Data sources**, or set `grafana_prom_datasource_uid`.

### Agent services did not start

Check cloud-init and the three systemd units. Confirm the SSM parameters exist:

```bash
aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names \
    /nightshift/sdm/gateway-token \
    /nightshift/sdm/relay-token \
    /nightshift/sdm/agent-token \
  --query 'Parameters[].Name'
```

### Preflight says the remediation resource is already available

Cancel or revoke the old request in StrongDM, then run:

```bash
./scripts/live-demo.sh reset
./scripts/live-demo.sh prepare
```

### MCP tool-name check fails

Do not weaken preflight. Enumerate the current server tools, reconcile policy,
agent instructions, and verification together, then reapply and rehearse.

### Approval does not appear in Slack

Verify the StrongDM Slack integration, the approval workflow, and membership of
`sre-oncall`. The agent should remain stopped; do not bypass the approval phase.
