# =============================================================================
#  Project Nightshift — Compute
# =============================================================================
#
#  Six instances, each with exactly one job:
#
#    sdm-gateway   public   t3.small   StrongDM gateway, EIP, listens :5555
#    sdm-relay     private  t3.small   reverse tunnel; reaches RDS, app, mcp
#    agent-vm      public   t3.small   PicoClaw + the sdm client. Zero prod creds.
#    app-01        private  t3.micro   orders-api. SSH target. Static IP.
#    app-02        private  t3.micro   orders-api. SSH target. Static IP.
#    mcp-host      private  t3.micro   Docker + grafana/mcp-grafana. Static IP.
#
#  ---------------------------------------------------------------------------
#  WHY THE APP SERVERS HAVE HARD-CODED PRIVATE IPs
#  ---------------------------------------------------------------------------
#  This is the one non-obvious decision in this file, and it exists to break a
#  genuine dependency cycle:
#
#      sdm_resource.app_01 (ssh)  needs  the instance's IP as `hostname`
#      aws_instance.app_01        needs  sdm_resource.app_01.ssh[0].public_key
#                                        in its user-data, to write into
#                                        authorized_keys
#
#  Terraform cannot resolve that. Pinning the private IP with `private_ip =`
#  turns one side of the cycle into a known-at-plan-time constant, so the
#  StrongDM SSH resource can be created from a variable and the instance can
#  consume the resulting public key.
#
#  The alternative — provisioning keys with a null_resource after the fact —
#  adds a moving part to something you run in front of a customer. Don't.
#
#  ---------------------------------------------------------------------------
#  WHY user-data FETCHES TOKENS FROM SSM RATHER THAN RECEIVING THEM
#  ---------------------------------------------------------------------------
#  The provider exposes bootstrap tokens as sensitive computed attributes, so
#  they exist in Terraform state. Terraform writes them to SSM and user-data
#  contains only parameter paths. Protect the remote state as credential data.
# =============================================================================


# -----------------------------------------------------------------------------
#  Base image — Ubuntu 24.04 LTS, arm-free (x86_64) to match t3.*
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}


# -----------------------------------------------------------------------------
#  orders-api deployment inputs
#
#  The real application is app/orders-api/main.py. App hosts clone the same
#  pinned public repository ref as the agent; embedding it exceeds EC2's 16 KiB
#  user-data limit.
#
#  `app_listen_port` is the single source of truth for the port. It is consumed
#  by templates/app-server.sh.tftpl (which rewrites the unit's `--port` and
#  writes ORDERS_API_PORT) and by aws_vpc_security_group_ingress_rule
#  .app_http_from_relay in 10-network.tf. Everything that curls these hosts —
#  agent/workspace/AGENT.md, HEARTBEAT.md, scripts/verify.sh, scripts/break-it.sh
#  — expects 8080. Change it in one place or not at all.
# -----------------------------------------------------------------------------
locals {
  app_listen_port = 8080

  # ---------------------------------------------------------------------------
  #  ONE map per app server, built once, so the two aws_instance blocks below
  #  cannot drift apart.
  #
  #  They were previously two hand-written templatefile() maps of eleven keys
  #  each. Adding the Prometheus remote_write settings would have meant editing
  #  both, and a key added to one and not the other is a `templatefile` error on
  #  app-02 only — which you discover after app-01 has already applied.
  #
  #  THE KEYS HERE MUST EXACTLY MATCH THE ${...} PLACEHOLDERS IN
  #  templates/app-server.sh.tftpl. templatefile() errors on a missing key and,
  #  helpfully, also errors on an unused one, so this pairing is checked at plan
  #  time rather than at boot.
  # ---------------------------------------------------------------------------
  app_server_common_template_vars = {
    aws_region      = var.aws_region
    db_secret_arn   = aws_secretsmanager_secret.db.arn
    db_host         = aws_db_instance.shopfront.address
    db_name         = var.db_name
    app_listen_port = local.app_listen_port

    nightshift_repo_url = var.nightshift_repo_url
    nightshift_repo_ref = var.nightshift_repo_ref

    # --- Prometheus agent -> Grafana Cloud (replaced the CloudWatch publisher)
    prometheus_version         = var.prometheus_agent_version
    prometheus_scrape_interval = var.prometheus_scrape_interval

    # Resolved from data.grafana_cloud_stack in 96-grafana.tf, NOT hardcoded.
    # The host is prometheus-prod-NN-<region-slug>, different per stack; the
    # path is always /api/prom/push; there is no push gateway (§4.5).
    remote_write_url = local.prom_remote_write_url

    # Basic auth USERNAME. A NUMBER, not an email address. Not a secret, so it
    # travels in user-data. The password does not — see below.
    remote_write_username = local.prom_instance_id

    # Basic auth PASSWORD, by reference only. The host fetches it at boot from
    # SSM with its instance role, so the token never enters user-data and never
    # reaches the instance metadata service.
    metrics_write_token_ssm_path = aws_ssm_parameter.grafana_metrics_write_token.name
  }

  app_server_template_vars = {
    "app-01" = merge(local.app_server_common_template_vars, {
      hostname       = "app-01"
      sdm_public_key = sdm_resource.app_01.ssh[0].public_key
    })
    "app-02" = merge(local.app_server_common_template_vars, {
      hostname       = "app-02"
      sdm_public_key = sdm_resource.app_02.ssh[0].public_key
    })
  }
}


# =============================================================================
#  IAM
#
#  FIVE instance profiles rather than one shared role. Each host can read only
#  the SSM parameters it actually needs, and the separation is not cosmetic:
#
#    agent-vm   its own StrongDM token + the model key. NOTHING ELSE. It must
#               not be able to read the node tokens, the Grafana tokens or the
#               MCP caller bearer — it is the host we assume is compromised.
#    mcp-host   the Grafana service account token + the MCP caller bearer.
#               Cannot read the agent's token, cannot read the database secret.
#    app        the RDS secret + the Grafana metrics-write token.
#    gateway    its node token.
#    relay      its node token.
#
#  If the room asks "what does an attacker get from owning the agent box?", the
#  answer is aws_iam_role_policy.agent_vm and it fits on one screen.
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  ssm_param_arn_prefix = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter"
}

# --- gateway ------------------------------------------------------------------

resource "aws_iam_role" "sdm_gateway" {
  name               = "${local.name}-sdm-gateway"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "sdm_gateway" {
  statement {
    sid       = "ReadGatewayNodeToken"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_param_arn_prefix}${var.gateway_token_ssm_path}"]
  }

  statement {
    sid       = "DecryptSecureStringWithAwsManagedKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "sdm_gateway" {
  name   = "${local.name}-sdm-gateway"
  role   = aws_iam_role.sdm_gateway.id
  policy = data.aws_iam_policy_document.sdm_gateway.json
}

# SSM Session Manager on every host: a break-glass path that needs no open
# port and no key pair. Cheaper insurance than leaving 22/tcp exposed.
resource "aws_iam_role_policy_attachment" "sdm_gateway_ssm_core" {
  role       = aws_iam_role.sdm_gateway.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sdm_gateway" {
  name = "${local.name}-sdm-gateway"
  role = aws_iam_role.sdm_gateway.name
}

# --- relay --------------------------------------------------------------------

resource "aws_iam_role" "sdm_relay" {
  name               = "${local.name}-sdm-relay"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "sdm_relay" {
  statement {
    sid       = "ReadRelayNodeToken"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_param_arn_prefix}${var.relay_token_ssm_path}"]
  }

  statement {
    sid       = "DecryptSecureStringWithAwsManagedKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "sdm_relay" {
  name   = "${local.name}-sdm-relay"
  role   = aws_iam_role.sdm_relay.id
  policy = data.aws_iam_policy_document.sdm_relay.json
}

resource "aws_iam_role_policy_attachment" "sdm_relay_ssm_core" {
  role       = aws_iam_role.sdm_relay.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sdm_relay" {
  name = "${local.name}-sdm-relay"
  role = aws_iam_role.sdm_relay.name
}

# --- agent --------------------------------------------------------------------
#
#  DELIBERATELY MINIMAL. The agent host can read exactly two parameters: its own
#  StrongDM service-account token, and the OpenAI key. It has no RDS access, no
#  S3 access, no ability to read the node tokens, and no ability to describe
#  anything in the account.
#
#  If the room asks "what does an attacker get from owning the agent box?" —
#  this policy document is the answer, and it fits on one screen.

resource "aws_iam_role" "agent_vm" {
  name               = "${local.name}-agent-vm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "agent_vm" {
  statement {
    sid     = "ReadAgentServiceAccountTokenAndModelKey"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "${local.ssm_param_arn_prefix}${var.agent_sdm_token_ssm_path}",
      "${local.ssm_param_arn_prefix}${aws_ssm_parameter.openai_api_key.name}",
    ]
  }

  statement {
    sid       = "DecryptSecureStringWithAwsManagedKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "agent_vm" {
  name   = "${local.name}-agent-vm"
  role   = aws_iam_role.agent_vm.id
  policy = data.aws_iam_policy_document.agent_vm.json
}

resource "aws_iam_role_policy_attachment" "agent_vm_ssm_core" {
  role       = aws_iam_role.agent_vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "agent_vm" {
  name = "${local.name}-agent-vm"
  role = aws_iam_role.agent_vm.name
}

# --- app servers --------------------------------------------------------------

resource "aws_iam_role" "app" {
  name               = "${local.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "app" {
  # ---------------------------------------------------------------------------
  #  THIS STATEMENT REPLACED cloudwatch:PutMetricData.
  #
  #  The app servers used to hold an IAM grant to publish a custom metric into
  #  the `Nightshift/orders-api` namespace, which a CloudWatch alarm watched.
  #  There is no alarm any more (§4.1) — orders-api's metrics are scraped
  #  locally by `prometheus --agent` and remote_written to Grafana Cloud.
  #
  #  remote_write authenticates with basic auth: the numeric Prometheus instance
  #  ID as the username, and a Cloud Access Policy token scoped `metrics:write`
  #  as the password. The username is not a secret and travels in user-data. The
  #  PASSWORD DOES NOT — it goes into SSM as a SecureString and the host fetches
  #  it at boot with this grant.
  #
  #  Same reasoning as the StrongDM node tokens in §7.2: an attacker who reads
  #  user-data off the instance metadata service should learn a parameter path,
  #  not a token. It is a smaller win here than on the agent VM — these hosts
  #  legitimately hold a production database password — but the pattern is free
  #  and being inconsistent about it is how the exception becomes the rule.
  # ---------------------------------------------------------------------------
  statement {
    sid       = "ReadGrafanaMetricsWriteToken"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_param_arn_prefix}${aws_ssm_parameter.grafana_metrics_write_token.name}"]
  }

  statement {
    sid       = "DecryptSecureStringWithAwsManagedKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${local.name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_role_policy_attachment" "app_ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app"
  role = aws_iam_role.app.name
}

# --- mcp-host -----------------------------------------------------------------
#
#  The host that runs grafana/mcp-grafana. It reads exactly two parameters, and
#  the pairing is the point of §4.4's credential table:
#
#    the Grafana SERVICE ACCOUNT token (glsa_…)  -> mcp-grafana -> Grafana Cloud
#    the MCP CALLER BEARER                        -> MCP Gateway -> mcp-grafana
#
#  Nothing else in this build can read either. In particular the AGENT VM
#  cannot: it holds neither token, and this policy is why that is structural
#  rather than a convention.
#
#  It also cannot read the database secret, the node tokens or the model key.
#  One container, two parameters.

resource "aws_iam_role" "mcp_host" {
  name               = "${local.name}-mcp-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "mcp_host" {
  statement {
    sid     = "ReadGrafanaAndCallerTokens"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "${local.ssm_param_arn_prefix}${aws_ssm_parameter.grafana_service_account_token.name}",
      "${local.ssm_param_arn_prefix}${aws_ssm_parameter.mcp_caller_bearer_token.name}",
    ]
  }

  statement {
    sid       = "DecryptSecureStringWithAwsManagedKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "mcp_host" {
  name   = "${local.name}-mcp-host"
  role   = aws_iam_role.mcp_host.id
  policy = data.aws_iam_policy_document.mcp_host.json
}

# The ONLY administrative path onto this host. There is no SSH ingress rule on
# aws_security_group.mcp_host, deliberately — Session Manager needs no open
# port and no key pair.
resource "aws_iam_role_policy_attachment" "mcp_host_ssm_core" {
  role       = aws_iam_role.mcp_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "mcp_host" {
  name = "${local.name}-mcp-host"
  role = aws_iam_role.mcp_host.name
}


# =============================================================================
#  SSM PARAMETERS
#
#  Every long-lived secret a host needs at boot lives here as a SecureString,
#  and every host fetches its own with its instance role. Nothing secret is ever
#  interpolated into user-data.
#
#  WHY THAT RULE EXISTS, IN ONE SENTENCE: user-data is readable from the
#  instance metadata service by anything running on the host, including a
#  pre-1.0 Go binary taking instructions from a language model.
#
#  These parameters ARE in Terraform state, in plaintext, like every other
#  sensitive value in this build. That is the tradeoff the commented-out remote
#  backend in 00-providers.tf exists to address if this ever outlives a week.
# =============================================================================

# -----------------------------------------------------------------------------
#  The model key — the ONE credential that legitimately lives on the agent host.
#
#  Everything the customer cares about (database, SSH, Grafana, GitHub) does
#  not. Worth pointing out on stage: yes, there is a secret on the agent VM, and
#  it buys an attacker some inference. It does not buy them production.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "openai_api_key" {
  name        = "/${var.project}/agent/openai-api-key"
  description = "Model API key for PicoClaw. The only credential on the agent host."
  type        = "SecureString"
  value       = var.openai_api_key

  tags = {
    Name = "${local.name}-openai-key"
  }
}

# -----------------------------------------------------------------------------
#  Grafana service account token (glsa_…) — for mcp-host ONLY.
#
#  This is the credential that can read incidents, query metrics and — if
#  policy 40 were not in the way — resolve the incident. It lives on exactly one
#  host, and that host is not the agent's.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "grafana_service_account_token" {
  name        = "/${var.project}/grafana/service-account-token"
  description = "Grafana stack service account token (glsa_). Read by mcp-host only."
  type        = "SecureString"
  value       = var.grafana_service_account_token

  tags = {
    Name = "${local.name}-grafana-sa-token"
  }
}

# -----------------------------------------------------------------------------
#  MCP caller bearer — for mcp-host ONLY.
#
#  The other half of the handshake StrongDM performs. The MCP Gateway holds the
#  same value in sdm_resource.grafana_mcp's config; the container compares
#  against it and 401s before any tool runs. Rotating it means changing
#  var.mcp_caller_bearer_token and re-applying — both ends move together.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "mcp_caller_bearer_token" {
  name        = "/${var.project}/mcp/caller-bearer-token"
  description = "MCP Gateway -> mcp-grafana bearer (MCP_GRAFANA_SERVER_TOKEN). Read by mcp-host only."
  type        = "SecureString"
  value       = var.mcp_caller_bearer_token

  tags = {
    Name = "${local.name}-mcp-caller-bearer"
  }
}

# -----------------------------------------------------------------------------
#  Grafana Cloud Access Policy token — for the app servers' remote_write.
#
#  Used as the basic-auth PASSWORD by `prometheus --agent` on app-01/app-02.
#  The matching username is the numeric instance ID, which is not a secret and
#  travels in user-data (§4.5).
#
#  Note this is the SAME token as the one the aliased `grafana.cloud` provider
#  uses for data.grafana_cloud_stack, which is why it needs BOTH `stacks:read`
#  and `metrics:write`. If you would rather have two tokens with narrower
#  scopes — and for anything beyond a demo you would — split
#  var.grafana_cloud_access_policy_token into two variables and point this
#  parameter at the metrics:write one.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "grafana_metrics_write_token" {
  name        = "/${var.project}/grafana/metrics-write-token"
  description = "Grafana Cloud Access Policy token used as the Prometheus remote_write password."
  type        = "SecureString"
  value       = var.grafana_cloud_access_policy_token

  tags = {
    Name = "${local.name}-grafana-metrics-write-token"
  }
}

# StrongDM's pinned provider exposes these bootstrap tokens as sensitive
# computed attributes. Persist them directly to SSM so a clean apply can boot
# every node without a manual token-copy and instance-replacement cycle.
resource "aws_ssm_parameter" "sdm_gateway_token" {
  name  = var.gateway_token_ssm_path
  type  = "SecureString"
  value = sdm_node.gateway.gateway[0].token

  tags = {
    Name = "${local.name}-sdm-gateway-token"
  }
}

resource "aws_ssm_parameter" "sdm_relay_token" {
  name  = var.relay_token_ssm_path
  type  = "SecureString"
  value = sdm_node.relay.relay[0].token

  tags = {
    Name = "${local.name}-sdm-relay-token"
  }
}

resource "aws_ssm_parameter" "sdm_agent_token" {
  name  = var.agent_sdm_token_ssm_path
  type  = "SecureString"
  value = sdm_account.nightshift_agent.service[0].token

  tags = {
    Name = "${local.name}-sdm-agent-token"
  }
}


# =============================================================================
#  Instances
# =============================================================================

# -----------------------------------------------------------------------------
#  StrongDM gateway
#
#  The EIP is allocated separately and associated explicitly, because
#  40-strongdm-nodes.tf needs a STABLE address to register as the node's
#  listen_address. An instance-assigned public IP would change on every stop/
#  start and silently break the node registration between rehearsals.
# -----------------------------------------------------------------------------

resource "aws_eip" "sdm_gateway" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-sdm-gateway-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_instance" "sdm_gateway" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.sdm_gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.sdm_gateway.name

  # IMDSv2 required. On a host that runs no untrusted code this is belt and
  # braces; on the agent VM below it is genuinely load-bearing, and consistency
  # is worth more than a saved line.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/sdm-gateway.sh.tftpl", {
    token_ssm_path = aws_ssm_parameter.sdm_gateway_token.name
    aws_region     = var.aws_region
    listen_port    = var.gateway_listen_port
    sdm_api_host   = var.sdm_api_host
    sdm_app_domain = var.sdm_app_domain
  })

  # Re-run user-data if the bootstrap script changes, rather than silently
  # keeping a stale host around across rehearsals.
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-sdm-gateway"
    Role = "sdm-gateway"
  }
}

resource "aws_eip_association" "sdm_gateway" {
  instance_id   = aws_instance.sdm_gateway.id
  allocation_id = aws_eip.sdm_gateway.id
}


# -----------------------------------------------------------------------------
#  StrongDM relay — private subnet, no public IP, no inbound rules.
# -----------------------------------------------------------------------------

resource "aws_instance" "sdm_relay" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.relay_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.sdm_relay.id]
  iam_instance_profile   = aws_iam_instance_profile.sdm_relay.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/sdm-relay.sh.tftpl", {
    token_ssm_path = aws_ssm_parameter.sdm_relay_token.name
    aws_region     = var.aws_region
    sdm_api_host   = var.sdm_api_host
    sdm_app_domain = var.sdm_app_domain
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-sdm-relay"
    Role = "sdm-relay"
  }

  # The relay dials the gateway. Bringing it up first just means it spends its
  # first minute retrying.
  depends_on = [aws_eip_association.sdm_gateway, aws_nat_gateway.main]
}


# -----------------------------------------------------------------------------
#  Agent VM — PicoClaw's home. The assumed-hostile host.
#
#  Note what is NOT passed into this user-data: no database password, no SSH
#  private key, no MCP tokens. The only secrets it receives are its own
#  StrongDM service-account token and the model key, and both are fetched at
#  boot from SSM rather than embedded.
#
#  When you SSH to this box on stage and run `env | grep -i pass`, the empty
#  result is Moment 1.
# -----------------------------------------------------------------------------

resource "aws_instance" "agent_vm" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.agent_instance_type
  subnet_id              = aws_subnet.private[0].id
  private_ip             = var.agent_vm_private_ip
  vpc_security_group_ids = [aws_security_group.agent_vm.id]
  iam_instance_profile   = aws_iam_instance_profile.agent_vm.name

  # hop_limit = 1 matters here: it stops a container or a proxied request on
  # this host from reaching the instance metadata service and assuming the
  # instance role. On the box running the pre-1.0 agent, take the free win.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # user-data fetches this repository and execs agent/bootstrap.sh. It installs
  # nothing itself — there is exactly ONE agent installation in this build and
  # bootstrap.sh is it. See the header of templates/agent-vm.sh.tftpl for what
  # happened when there were two.
  user_data = templatefile("${path.module}/templates/agent-vm.sh.tftpl", {
    aws_region                   = var.aws_region
    sdm_token_ssm_path           = aws_ssm_parameter.sdm_agent_token.name
    openai_key_ssm_path          = aws_ssm_parameter.openai_api_key.name
    picoclaw_version             = var.picoclaw_version
    pg_read_resource_name        = local.pg_read_resource_name
    pg_remediation_resource_name = local.pg_remediation_resource_name
    grafana_mcp_name             = local.grafana_mcp_name
    github_mcp_name              = local.github_mcp_name
    github_repo                  = var.github_repo
    agent_ssh_public_key         = sdm_resource.agent_vm.ssh[0].public_key
    sdm_api_host                 = var.sdm_api_host
    nightshift_repo_url          = var.nightshift_repo_url
    nightshift_repo_ref          = var.nightshift_repo_ref
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-agent-vm"
    Role = "agent"
  }

  # User-data immediately connects resources and starts PicoClaw. Wait for the
  # complete identity, grant, policy, workflow, and MCP graph.
  depends_on = [
    aws_eip_association.sdm_gateway,
    sdm_account_attachment.agent_to_ai_agents,
    sdm_policy.baseline,
    sdm_policy.agents_are_readonly,
    sdm_policy.redact_pii,
    sdm_policy.approve_remediation_write,
    sdm_policy.mcp_tool_limits,
    sdm_workflow_role.ai_agents_may_request,
    sdm_resource.grafana_mcp,
    sdm_resource.github_mcp,
    sdm_resource.agent_vm,
    aws_nat_gateway.main,
  ]
}


# -----------------------------------------------------------------------------
#  App servers — the SSH targets.
#
#  user-data appends the StrongDM-generated public key to ubuntu's
#  authorized_keys. This is step 4 of §7.1, automated: StrongDM holds the
#  private half and never releases it, so there is no SSH private key anywhere
#  in this build for anyone to steal — including on the agent host.
# -----------------------------------------------------------------------------

resource "aws_instance" "app_01" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.app_instance_type
  subnet_id              = aws_subnet.private[0].id
  private_ip             = var.app_01_private_ip # see cycle note at top of file
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/app-server.sh.tftpl", local.app_server_template_vars["app-01"])

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-app-01"
    Role = "orders-api"
  }

  depends_on = [aws_nat_gateway.main, aws_secretsmanager_secret_version.db]
}

resource "aws_instance" "app_02" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.app_instance_type
  subnet_id              = aws_subnet.private[1].id
  private_ip             = var.app_02_private_ip
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/app-server.sh.tftpl", local.app_server_template_vars["app-02"])

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-app-02"
    Role = "orders-api"
  }

  depends_on = [aws_nat_gateway.main, aws_secretsmanager_secret_version.db]
}


# -----------------------------------------------------------------------------
#  mcp-host — the SELF-HOSTED MCP server.
#
#  ###########################################################################
#  THIS INSTANCE IS THE ARGUMENT IN §4.4, AND ITS PLACEMENT IS THE ARGUMENT.
#  ###########################################################################
#
#  Private subnet. No public IP. No SSH ingress rule, not even from
#  any operator CIDR — it is administered through SSM Session Manager. The only
#  thing that can open a connection to it is the StrongDM relay's security
#  group, on one port.
#
#  Compare that to how MCP is usually demonstrated: the server runs as a
#  subprocess on the agent's own machine, holding the upstream credential, with
#  any policy layer in front of it purely advisory because the agent could
#  bypass it by talking to the upstream directly. Here there is no upstream the
#  agent can reach. The container holds the Grafana service account token; the
#  agent holds neither that nor the caller bearer; the only route between them
#  runs through the relay and therefore through Cedar.
#
#  It is also the pattern these customers will actually build. Far more of them
#  are going to run an internal MCP server against their own systems than are
#  going to point an agent at a vendor's hosted MCP endpoint.
#
#  Static private IP for the same class of reason as the app servers: the
#  StrongDM `grafana-mcp` resource URL is http://<this address>:8000/mcp, and a
#  plan-time constant keeps that resource stable across rebuilds. See
#  var.mcp_host_private_ip.
#
#  t3.micro. It runs one container that mostly waits.
# -----------------------------------------------------------------------------

resource "aws_instance" "mcp_host" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.mcp_host_instance_type
  subnet_id              = aws_subnet.private[0].id
  private_ip             = var.mcp_host_private_ip
  vpc_security_group_ids = [aws_security_group.mcp_host.id]
  iam_instance_profile   = aws_iam_instance_profile.mcp_host.name

  # hop_limit = 1 is genuinely load-bearing on a Docker host: without it a
  # container on the default bridge network can reach 169.254.169.254 through
  # the host's NAT and assume this instance role — which would hand any
  # container on this box the Grafana service account token. The container we
  # run does not try, but the point of the control is that it does not have to
  # be trusted not to.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/mcp-host.sh.tftpl", {
    aws_region = var.aws_region

    # Fetched at boot with the instance role. Paths, not tokens.
    grafana_token_ssm_path = aws_ssm_parameter.grafana_service_account_token.name
    caller_token_ssm_path  = aws_ssm_parameter.mcp_caller_bearer_token.name

    grafana_url = var.grafana_url

    # PINNED. Grafana's MCP tool names have churned and policy 40 matches them
    # exactly; `:latest` is a policy that stops firing silently. var validation
    # rejects a missing tag and rejects ':latest' outright.
    mcp_image = var.mcp_grafana_image
    mcp_port  = var.mcp_grafana_port

    # --allowed-origins. EMPTY IS NOT PERMISSIVE — empty rejects any request
    # carrying an Origin header, with a 403 that looks like a network fault.
    mcp_allowed_origins = var.mcp_grafana_allowed_origins
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-mcp-host"
    Role = "mcp-grafana"
  }

  # Needs the NAT gateway to pull the image from Docker Hub.
  depends_on = [aws_nat_gateway.main]
}
