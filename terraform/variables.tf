# =============================================================================
#  Project Nightshift — Input variables
# =============================================================================
#
#  RULE: nothing secret is ever a default, and every secret is marked
#  `sensitive = true` so it does not land in plan output or CI logs.
#
#  Populate from terraform.tfvars (gitignored) or, better, from the environment:
#
#      export TF_VAR_db_password="…"
#      export TF_VAR_github_mcp_token="…"
#
#  See terraform.tfvars.example for a working starting point.
# =============================================================================


# -----------------------------------------------------------------------------
#  Identity / naming
# -----------------------------------------------------------------------------

variable "project" {
  description = "Short name prefixed onto every resource. Also the teardown tag value."
  type        = string
  default     = "nightshift"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}

variable "owner" {
  description = "Human who owns this environment. Stamped as a tag so nobody else deletes it."
  type        = string
  default     = "lance.haig@delinea.com"
}

variable "sdm_api_host" {
  description = "StrongDM API endpoint used by gateway, relay, and agent service authentication."
  type        = string
  default     = "api.eu.strongdm.com:443"
}


# -----------------------------------------------------------------------------
#  AWS placement
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region. Keep it close to wherever you are demoing — latency is visible on stage."
  type        = string
  default     = "eu-west-1"
}

variable "availability_zones" {
  description = <<-EOT
    Exactly two AZs. Two are required because RDS demands a subnet group
    spanning at least two AZs, even for a single-AZ instance. We are not
    running multi-AZ — this is a demo, and the second AZ exists purely to
    satisfy that constraint.
  EOT
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Provide exactly two availability zones."
  }
}


# -----------------------------------------------------------------------------
#  Network
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR. 10.20.0.0/16 per the architecture doc §4.1."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnets — StrongDM gateway and the agent VM live here."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnets — relay, app servers and RDS. No inbound from the internet, ever."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

# -----------------------------------------------------------------------------
#  Compute
#
#  Static private IPs for the app servers are deliberate — see the long comment
#  in 20-compute.tf. They break a dependency cycle between the EC2 instances and
#  the StrongDM SSH resources.
# -----------------------------------------------------------------------------

variable "gateway_instance_type" {
  description = "StrongDM gateway. t3.small per §4.1."
  type        = string
  default     = "t3.small"
}

variable "relay_instance_type" {
  description = "StrongDM relay. t3.small per §4.1."
  type        = string
  default     = "t3.small"
}

variable "agent_instance_type" {
  description = "PicoClaw host. t3.small — the binary is 10MB but the sdm client and MCP tunnels are not free."
  type        = string
  default     = "t3.small"
}

variable "app_instance_type" {
  description = "orders-api hosts. t3.micro is plenty."
  type        = string
  default     = "t3.micro"
}

variable "app_01_private_ip" {
  description = "Static private IP for app-01. Must fall inside private_subnet_cidrs[0]."
  type        = string
  default     = "10.20.10.11"
}

variable "agent_vm_private_ip" {
  description = "Static private IP for the StrongDM-managed agent-vm SSH resource. Must be in private_subnet_cidrs[0]."
  type        = string
  default     = "10.20.10.22"
}

variable "app_02_private_ip" {
  description = "Static private IP for app-02. Must fall inside private_subnet_cidrs[1]."
  type        = string
  default     = "10.20.11.12"
}

variable "mcp_host_instance_type" {
  description = "mcp-host — Docker + the grafana/mcp-grafana container. t3.micro per §4.1."
  type        = string
  default     = "t3.micro"
}

variable "mcp_host_private_ip" {
  description = <<-EOT
    Static private IP for mcp-host. Must fall inside private_subnet_cidrs[0].

    Pinned for the SAME REASON the app servers are (see 20-compute.tf): the
    StrongDM `grafana-mcp` resource in 90-strongdm-mcp.tf needs a URL, and that
    URL is this address. Reading it back off `aws_instance.mcp_host.private_ip`
    would work today — there is no genuine cycle, because the instance does not
    consume anything from the sdm_resource — but it makes the StrongDM object
    unknown at plan time and it changes on every rebuild, which means the
    resource URL churns and `picoclaw mcp test grafana` starts failing for a
    reason nobody looks for.

    One pinned address, one plan-time constant, one stable resource. See §4.4.
  EOT
  type        = string
  default     = "10.20.10.21"
}


# -----------------------------------------------------------------------------
#  Database
# -----------------------------------------------------------------------------

variable "db_name" {
  description = "The production database the agent queries. 'shopfront' per the narrative."
  type        = string
  default     = "shopfront"
}

variable "db_username" {
  description = <<-EOT
    RDS master username.

    This credential is handed to StrongDM ONCE, at apply time, and then lives
    only in the StrongDM secret store. It never reaches the agent VM, and that
    is Moment 1 of the demo: 'compromised agent host != compromised production'.
  EOT
  type        = string
  default     = "shopfront_admin"
}

variable "db_password" {
  description = "RDS master password. Set via TF_VAR_db_password. Never commit this."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "db.t4g.micro per §4.1. Graviton, cheapest thing that runs Postgres 16."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "GB. 20 is the gp3 floor and holds 50k seeded orders comfortably."
  type        = number
  default     = 20
}


# -----------------------------------------------------------------------------
#  StrongDM node bootstrap
#
#  The pinned provider exposes sensitive computed bootstrap tokens. Terraform
#  writes them to these SSM paths, and EC2 user-data fetches them at boot. The
#  tokens therefore exist in Terraform state; protect its backend accordingly.
# -----------------------------------------------------------------------------

variable "gateway_token_ssm_path" {
  description = "SSM SecureString parameter holding the StrongDM GATEWAY node token."
  type        = string
  default     = "/nightshift/sdm/gateway-token"
}

variable "relay_token_ssm_path" {
  description = "SSM SecureString parameter holding the StrongDM RELAY node token."
  type        = string
  default     = "/nightshift/sdm/relay-token"
}

variable "agent_sdm_token_ssm_path" {
  description = <<-EOT
    SSM SecureString parameter holding the API token for the nightshift-agent
    SERVICE ACCOUNT. The agent VM exports this as SDM_ADMIN_TOKEN so the `sdm`
    CLI can log in headlessly.

    The pinned provider exposes the service token as a sensitive computed
    attribute and Terraform writes it to this path automatically.
  EOT
  type        = string
  default     = "/nightshift/sdm/agent-token"
}

variable "gateway_listen_port" {
  description = "Port the StrongDM gateway listens on for client connections."
  type        = number
  default     = 5555
}


# -----------------------------------------------------------------------------
#  StrongDM identity
# -----------------------------------------------------------------------------

variable "human_users" {
  description = <<-EOT
    Human StrongDM accounts to create and attach to the sre-oncall role. These
    are the approvers for the nightshift-write workflow — the people who say yes
    in Slack while the room watches.

    Map key is an arbitrary stable slug used for the Terraform resource address.
  EOT
  type = map(object({
    email      = string
    first_name = string
    last_name  = string
    # "admin" | "database-admin" | "user" | "audit" — see StrongDM docs.
    permission_level = optional(string, "user")
  }))

  default = {
    lance = {
      email            = "lance.haig@delinea.com"
      first_name       = "Lance"
      last_name        = "Haig"
      permission_level = "admin"
    }
  }
}


# -----------------------------------------------------------------------------
#  MCP servers
#
#  ONE INTERNAL, ONE SAAS, AND THAT ASYMMETRY IS DELIBERATE (§4.4).
#
#  `grafana-mcp` is a container WE run, in the private subnet, behind the relay.
#  `github-mcp` is somebody else's hosted endpoint on the public internet.
#  The same Cedar policy engine governs both, and neither credential ever
#  touches the agent host.
#
#  Note there are TWO tokens in the Grafana MCP path and they belong to
#  different hops:
#
#    caller bearer (var.mcp_caller_bearer_token)
#        MCP Gateway -> mcp-grafana. Held by StrongDM's resource config and by
#        the container (as MCP_GRAFANA_SERVER_TOKEN). 401 before any tool runs
#        if it does not match.
#
#    Grafana service account token (var.grafana_service_account_token)
#        mcp-grafana -> Grafana Cloud. Held ONLY by the container.
#
#  The agent holds neither.
# -----------------------------------------------------------------------------

variable "mcp_grafana_image" {
  description = <<-EOT
    Container image for the self-hosted Grafana MCP server, INCLUDING A TAG.

    PIN IT. Grafana's MCP tool names have churned materially — the alerting
    tools were consolidated and older names like `list_alert_rules` no longer
    exist. policies/40-mcp-tool-limits.cedar matches on the tool name EXACTLY
    and a mismatch does not error: the forbid silently never fires and the agent
    resolves the incident in front of the customer.

    `:latest` here is a policy that stops working on a Thursday. §7.3.

    After ANY bump: `picoclaw mcp show grafana` and reconcile policy 40.
  EOT
  type        = string
  default     = "grafana/mcp-grafana:1.3.0"

  validation {
    condition     = can(regex(":[^:/]+$", var.mcp_grafana_image)) && !endswith(var.mcp_grafana_image, ":latest")
    error_message = "mcp_grafana_image must carry an explicit tag, and must not be ':latest'."
  }
}

variable "mcp_grafana_port" {
  description = "Port mcp-grafana listens on inside the private subnet. Reachable from the relay SG only."
  type        = number
  default     = 8000
}

variable "mcp_grafana_allowed_origins" {
  description = <<-EOT
    Value for mcp-grafana's `--allowed-origins`.

    ############################################################################
    #  THIS FLAG IS EMPTY BY DEFAULT AND THAT DEFAULT REJECTS ANY REQUEST THAT
    #  CARRIES AN `Origin` HEADER AT ALL.
    ############################################################################

    The failure mode is a silent 403 that looks exactly like a network fault,
    which is why it is called out as a known sharp edge in §7.3 and why it is a
    variable rather than a hardcoded flag.

    The default below is permissive because the only thing that can reach :8000
    is the StrongDM relay's security group — there is no browser, no third-party
    origin and no path from the internet. Tighten it to the exact origin MCP
    Gateway sends if you ever run this anywhere less enclosed.
  EOT
  type        = string
  default     = "*"
}

variable "mcp_caller_bearer_token" {
  description = <<-EOT
    The caller bearer for the mcp-grafana hop.

    Held in exactly two places: StrongDM's `grafana-mcp` resource config (so the
    MCP Gateway can present it) and the container's MCP_GRAFANA_SERVER_TOKEN.
    Callers send `Authorization: Bearer <token>` and mcp-grafana 401s before any
    tool runs if it does not match.

    NOT on the agent host. That is the whole point of §4.4's credential table.

    Any high-entropy string — `openssl rand -hex 32`.
    Set via TF_VAR_mcp_caller_bearer_token.
  EOT
  type        = string
  sensitive   = true
}

variable "github_mcp_url" {
  description = <<-EOT
    GitHub hosted MCP endpoint. Use the FULL toolset URL, not the /readonly
    variant — Cedar must be the thing that stops the merge, or the demo proves
    nothing about StrongDM. See policies/40-mcp-tool-limits.cedar.
  EOT
  type        = string
  default     = "https://api.githubcopilot.com/mcp/"
}

variable "github_mcp_token" {
  description = "Fine-grained GitHub token used by MCP Gateway. Restrict it to var.github_repo. Set via TF_VAR_github_mcp_token."
  type        = string
  sensitive   = true
}

variable "github_repo" {
  description = <<-EOT
    `owner/name` of the repository the agent works on. Act 3 of the demo is the
    agent filing a postmortem issue and then being REFUSED when it tries to
    merge — and `merge_pull_request` can only be refused if there is an open
    pull request to merge.

    Terraform does not create the repository or the PR. Pre-stage both by hand
    (terraform/README.md, manual step M7) and put the same value here and in
    agent/workspace/AGENT.md section 2. scripts/verify.sh fails pre-flight if
    the repository has no open PR.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.github_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form, e.g. your-org/shopfront-platform."
  }
}


# -----------------------------------------------------------------------------
#  Access workflow
# -----------------------------------------------------------------------------

variable "write_access_max_duration" {
  description = <<-EOT
    Maximum duration of an approved write grant, as a Go duration string.

    15 minutes is chosen for the stage: long enough for the agent to do the
    remediation, short enough that the audience sees it expire during the demo.
    Mutually exclusive with a fixed duration on sdm_workflow.
  EOT
  type        = string
  default     = "15m0s"
}

# =============================================================================
#  GRAFANA CLOUD
#
#  This block replaced CloudWatch + SNS + Lambda + PagerDuty entirely (§4.1).
#  Three fewer AWS services in the live path, and — the part that matters for
#  the demo — fault detection now lives in the same tool the agent reads its
#  incident from over MCP.
#
#  FREE TIER, AND IT COVERS EVERYTHING HERE (§4.5):
#    500 alert rules, 1000 instances each        we use 1
#    3 active IRM users per month, HARD LIMIT    you + the agent = 2
#    10k active metric series                    orders-api emits ~8
#    14 day retention, 1 stack, 3 Grafana users
#
#  Watch the IRM number. "Active" means being in an on-call schedule or
#  creating/editing an incident, and it is enforced. A colleague clicking around
#  in your stack mid-rehearsal costs you the ability to open an incident.
# =============================================================================

variable "grafana_stack_slug" {
  description = <<-EOT
    Grafana Cloud stack slug — the first label of the stack hostname. For
    https://nightshift.grafana.net this is `nightshift`.

    Used by `data.grafana_cloud_stack` to look up the Prometheus remote_write
    endpoint and the numeric instance ID, so it must be the slug the Cloud
    Portal shows, not the display name.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,48}$", var.grafana_stack_slug))
    error_message = "grafana_stack_slug is the hostname label only, e.g. 'nightshift' — no scheme, no domain."
  }
}

variable "grafana_url" {
  description = <<-EOT
    Full stack URL, WITH scheme and trailing slash:  https://<slug>.grafana.net/

    This is what the `grafana` provider authenticates against with the service
    account token, and it is what mcp-grafana is given as GRAFANA_URL.

    It is NOT grafana.com (that is the Cloud Portal, and it takes the other
    token type — see 00-providers.tf) and it is NOT the Prometheus endpoint.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.grafana\\.net/?$", var.grafana_url))
    error_message = "grafana_url must look like https://<slug>.grafana.net/ — scheme included, no path."
  }
}

variable "grafana_service_account_token" {
  description = <<-EOT
    Grafana SERVICE ACCOUNT token (`glsa_…`), created inside the stack under
    Administration -> Users and access -> Service accounts.

    Two consumers, and it is worth knowing both:
      * the `grafana` Terraform provider (folder and rule group);
      * the mcp-grafana container, which is the ONLY thing in the data path that
        holds it. Not the agent, not the agent VM, not StrongDM.

    Needs Admin on the stack for the alerting provisioning API, plus whatever
    IRM scopes the demo's tool calls require.

    Set via TF_VAR_grafana_service_account_token. Never commit it.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = startswith(var.grafana_service_account_token, "glsa_")
    error_message = "Expected a Grafana service account token starting with 'glsa_'. A Cloud Access Policy token is a DIFFERENT credential — see 00-providers.tf."
  }
}

variable "grafana_cloud_access_policy_token" {
  description = <<-EOT
    Cloud ACCESS POLICY token, created in the Cloud Portal at grafana.com under
    Security -> Access Policies. A different thing entirely from the `glsa_`
    service account token above (§4.5) — do not mix them up.

    Two consumers:
      * `data.grafana_cloud_stack` via the aliased `grafana.cloud` provider,
        which is how we read the remote_write endpoint instead of hardcoding a
        `prometheus-prod-NN-<region>` hostname that is different in every stack;
      * Prometheus remote_write on app-01/app-02, as the basic-auth PASSWORD.

    SCOPES REQUIRED:  stacks:read  AND  metrics:write

    Terraform never puts this in user-data. It goes into SSM as a SecureString
    and the app servers fetch it at boot with their instance role — same reason
    the StrongDM node tokens do (§7.2): an attacker who reads user-data off the
    IMDS should learn a parameter path, not a token.

    Set via TF_VAR_grafana_cloud_access_policy_token.
  EOT
  type        = string
  sensitive   = true
}

variable "grafana_prometheus_instance_id" {
  description = <<-EOT
    OPTIONAL OVERRIDE. The numeric Prometheus instance ID used as the
    remote_write basic-auth USERNAME.

    It is a NUMBER, not your email address, and getting that wrong produces a
    401 from a hostname you have never seen before. Leave this empty and it is
    read from `data.grafana_cloud_stack.nightshift.prometheus_user_id`, which is
    the correct source and the one that survives a stack rebuild.

    Set it only if you are deliberately not using the cloud data source.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.grafana_prometheus_instance_id == "" || can(regex("^[0-9]+$", var.grafana_prometheus_instance_id))
    error_message = "The Prometheus instance ID is numeric. If you typed an email address, that is the mistake this validation exists to catch."
  }
}

variable "grafana_prometheus_remote_write_url" {
  description = <<-EOT
    OPTIONAL OVERRIDE for the remote_write endpoint.

    Empty (correct) means it comes from
    `data.grafana_cloud_stack.nightshift.prometheus_remote_write_endpoint`.

    IF YOU DO SET IT: the path is always `/api/prom/push`, and the host looks
    like https://prometheus-prod-NN-<region-slug>.grafana.net — NOT
    `prometheus-<region>`. There is no push gateway. Read it out of the stack
    rather than guessing (§4.5).
  EOT
  type        = string
  default     = ""
}

variable "grafana_prom_datasource_name" {
  description = <<-EOT
    Name of the hosted Prometheus datasource inside the stack, used to resolve
    its UID for the alert rule's query.

    DO NOT HARDCODE THE UID AND DO NOT ASSUME THIS NAME. Stacks provision this
    datasource as either `grafanacloud-prom` or `grafanacloud-<slug>-prom`
    depending on when and how they were created. If the apply fails with "data
    source not found", open Connections -> Data sources in the stack, read the
    real name, and put it here — or set grafana_prom_datasource_uid below and
    skip the lookup entirely.
  EOT
  type        = string
  default     = "grafanacloud-prom"
}

variable "grafana_prom_datasource_uid" {
  description = <<-EOT
    OPTIONAL OVERRIDE. Set this to the datasource UID and the name lookup above
    is skipped completely. Useful if your stack names the datasource something
    the default does not match and you would rather not care why.
  EOT
  type        = string
  default     = ""
}

variable "grafana_folder_title" {
  description = "Grafana folder that owns the rule group. Kept separate so a rebuild never touches anything else in the stack."
  type        = string
  default     = "Nightshift"
}

variable "alert_5xx_rate_threshold" {
  description = <<-EOT
    5xx RATE, in errors per second, that constitutes an incident.

    0.05/s is roughly three failed requests a minute — comfortably above the
    zero a healthy orders-api produces, and comfortably below what 400 poisoned
    rows produce the moment anything lists orders.

    This replaced `alarm_threshold_5xx` (a raw count over a 60s CloudWatch
    period). scripts/.env carries the same number as ALERT_5XX_RATE_THRESHOLD
    because trigger-agent.sh quotes it in the canned payload and the agent reads
    it back out loud — a mismatch between the two is audible.
  EOT
  type        = number
  default     = 0.05
}

variable "alert_evaluation_interval_seconds" {
  description = <<-EOT
    How often the rule group evaluates. 60s.

    Combined with `for = 1m` on the rule this gives roughly 60-180 seconds from
    poison to page (§6) — shorter and more reliable than the old AWS chain, and
    still far too long to stand in silence in front of a customer. On stage you
    use scripts/trigger-agent.sh. This path is for the deep dive.

    Do not drive it below 10s: Grafana rejects it, and a demo does not need it.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.alert_evaluation_interval_seconds >= 10
    error_message = "Grafana requires a rule group interval of at least 10 seconds."
  }
}

variable "prometheus_agent_version" {
  description = <<-EOT
    Prometheus release installed on app-01/app-02 and run in AGENT MODE — scrape
    orders-api on loopback, remote_write to Grafana Cloud, no local TSDB, no
    query API, no rule evaluation.

    PINNED, and the version matters for one specific reason: the flag that turns
    agent mode on CHANGED. Prometheus 3.x takes `--agent`. Prometheus 2.32-2.x
    took `--enable-feature=agent`. templates/app-server.sh.tftpl writes the 3.x
    flag, so do not drop this to a 2.x tag without changing it there too.
  EOT
  type        = string
  default     = "3.5.0"

  validation {
    condition     = can(regex("^3\\.[0-9]+\\.[0-9]+$", var.prometheus_agent_version))
    error_message = "Pin a Prometheus 3.x version — app-server.sh.tftpl uses the 3.x `--agent` flag, not 2.x's `--enable-feature=agent`."
  }
}

variable "prometheus_scrape_interval" {
  description = <<-EOT
    Scrape interval for orders-api's /metrics, as a Prometheus duration.

    15s rather than the usual 60s on purpose: the whole §6 chain is
    scrape + remote_write + rule evaluation + notification, and 45 seconds saved
    at the front of it is 45 seconds you are not standing still for.
  EOT
  type        = string
  default     = "15s"
}

variable "audit_bucket_force_destroy" {
  description = <<-EOT
    Allow `terraform destroy` to delete the audit bucket even when it contains
    Log Stream objects. TRUE is correct for a rebuilt-weekly demo. It would be
    indefensible anywhere near a real audit trail.
  EOT
  type        = bool
  default     = true
}


# -----------------------------------------------------------------------------
#  Agent VM
# -----------------------------------------------------------------------------

variable "picoclaw_version" {
  description = "Pinned PicoClaw release. v0.3.1 is the version this build was tested against (§7.3)."
  type        = string
  default     = "v0.3.1"
}

variable "nightshift_repo_url" {
  description = <<-EOT
    Clone URL for THIS repository. The agent VM's user-data does nothing except
    fetch it and exec `agent/bootstrap.sh`.

    There is exactly ONE agent installation in this build and it lives in
    agent/. user-data used to build a second, subtly different one inline; the
    two disagreed about the workspace path, the wrapper names, the shim port and
    the exec allow-patterns, so half the operator scripts spoke to a machine
    that did not exist. Do not reintroduce that.

    Must be readable without credentials from the agent VM (a public HTTPS clone
    URL, or a pre-baked AMI). Leave empty and the bootstrap fails loudly at boot
    rather than leaving a half-built host.
  EOT
  type        = string
  default     = ""
}

variable "nightshift_repo_ref" {
  description = "Branch or tag of nightshift_repo_url to check out on the agent VM."
  type        = string
  default     = "main"
}

variable "openai_api_key" {
  description = <<-EOT
    OpenAI key for PicoClaw. Set via TF_VAR_openai_api_key.

    Note the irony worth pointing out on stage: this IS a credential sitting on
    the agent host, and it is the only one. Everything that touches the
    customer's production estate — database, SSH, MCP tools — has none.
  EOT
  type        = string
  sensitive   = true
}
