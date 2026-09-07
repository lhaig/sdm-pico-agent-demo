# =============================================================================
#  Project Nightshift — StrongDM resources (database + SSH)
# =============================================================================
#
#  ONE RESOURCE TYPE, MANY SUB-TYPES
#  ---------------------------------
#  The provider exposes a single `sdm_resource` with a nested block naming the
#  sub-type. There is no `sdm_postgres` and no `sdm_ssh`. If you have seen those
#  in an example somewhere, that example is wrong.
#
#  TAGS ARE THE POLICY SURFACE — this is the important part of this file
#  --------------------------------------------------------------------
#  `env = "prod"` and `data = "pii"` are not decoration. Policy 10 reads them
#  directly:
#
#      resource.sdm.hasTag("env") && resource.sdm.getTag("env") == "prod"
#
#  Which means the read-only-for-agents guardrail is attached to the TAG, not to
#  this resource. Register a second production database tomorrow, tag it
#  env=prod, and it inherits the control on creation. No policy edit, no
#  redeploy, no ticket.
#
#  That is the answer to "does this scale past the three things in your demo?"
#  and it is much stronger demonstrated than asserted. If you have a spare
#  minute in the deep-dive session, add a resource live and show the policy
#  applying to it immediately.
# =============================================================================

locals {
  pg_read_resource_name        = "pg-prod-shopfront-read"
  pg_remediation_resource_name = "pg-prod-shopfront-remediation"
  agent_vm_resource_name       = "agent-vm"
  app_01_resource_name         = "app-01"
  app_02_resource_name         = "app-02"

  # Applied to every resource the agent can reach. Kept in one place so the tag
  # contract that policy 10 depends on cannot drift between resources.
  prod_tags = {
    Project = "nightshift"
    env     = "prod"
    data    = "pii"
  }
}

# Operator control path. The agent itself is never granted this resource.
# StrongDM owns the private key; user-data installs only the generated public
# key. Port forwarding carries the loopback-only task shim and MCP preflight.
resource "sdm_resource" "agent_vm" {
  ssh {
    name = local.agent_vm_resource_name

    hostname = var.agent_vm_private_ip
    port     = 22
    username = "ubuntu"

    key_type        = "ed25519"
    port_forwarding = true

    tags = {
      Project = "nightshift"
      env     = "prod"
      kind    = "operator-control"
    }
  }
}


# -----------------------------------------------------------------------------
#  pg-prod-shopfront-read and pg-prod-shopfront-remediation
#
#  THE CREDENTIAL HANDOFF, which is Moment 1:
#
#  The master username and password are passed to StrongDM here, once, at apply
#  time. From that point the control plane holds them and injects them on the
#  far side of the relay. The agent's client presents NO password — it connects
#  to 127.0.0.1:5432 on its own host and StrongDM completes the real
#  authentication out of its reach.
#
#  `env | grep -i PGPASSWORD` on the agent VM returns nothing.
#
#  port_override = -1 asks StrongDM to allocate the local listener port
#  automatically. Set an explicit port only if a client hard-codes one.
# -----------------------------------------------------------------------------
resource "sdm_resource" "pg_prod_shopfront_read" {
  postgres {
    name = local.pg_read_resource_name

    hostname = aws_db_instance.shopfront.address
    port     = aws_db_instance.shopfront.port
    database = var.db_name

    username = var.db_username
    password = var.db_password

    port_override = 5432

    tags = merge(local.prod_tags, { access = "read" })
  }
}

# This resource is intentionally absent from the agent's standing role. A
# workflow grants it for at most 15 minutes, after human approval.
resource "sdm_resource" "pg_prod_shopfront_remediation" {
  postgres {
    name = local.pg_remediation_resource_name

    hostname = aws_db_instance.shopfront.address
    port     = aws_db_instance.shopfront.port
    database = var.db_name

    username = var.db_username
    password = var.db_password

    port_override = 5434

    tags = merge(local.prod_tags, { access = "remediation" })
  }
}


# -----------------------------------------------------------------------------
#  app-01 / app-02 — SSH targets
#
#  STRONGDM-GENERATED KEYPAIR. Read this bit carefully, because it is a stronger
#  claim than it first looks:
#
#  StrongDM generates the keypair and NEVER RELEASES THE PRIVATE HALF. The
#  public half is exposed as the computed attribute `public_key`, which
#  20-compute.tf appends to authorized_keys via user-data (step 4 of §7.1,
#  automated).
#
#  The result: there is no SSH private key anywhere in this build. Not on the
#  agent VM, not in Terraform state, not in a secrets manager, not on your
#  laptop. The agent role is not granted these SSH resources.
#
#  key_type = "ed25519" — smallest, fastest, and universally supported on
#  Ubuntu 24.04. rsa-4096 is available if a customer's estate demands it.
#
#  hostname uses the pinned private IP rather than aws_instance.app_01.private_ip
#  to break the dependency cycle documented at the top of 20-compute.tf.
#
#  KNOWN SHARP EDGE (§7.3): SSH command logging is best-effort and degrades on
#  tmux, TUIs and exotic prompts. Keep the agent's shell commands simple and
#  non-interactive, and do not open tmux on stage.
# -----------------------------------------------------------------------------
resource "sdm_resource" "app_01" {
  ssh {
    name = local.app_01_resource_name

    hostname = var.app_01_private_ip
    port     = 22
    username = "ubuntu"

    key_type = "ed25519"

    # No reason for the agent to forward ports through an SSH session. Off.
    port_forwarding = false

    tags = local.prod_tags
  }
}

resource "sdm_resource" "app_02" {
  ssh {
    name = local.app_02_resource_name

    hostname = var.app_02_private_ip
    port     = 22
    username = "ubuntu"

    key_type = "ed25519"

    port_forwarding = false

    tags = local.prod_tags
  }
}
