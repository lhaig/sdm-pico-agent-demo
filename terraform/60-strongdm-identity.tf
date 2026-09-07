# =============================================================================
#  Project Nightshift — Identity
# =============================================================================
#
#  THE AGENT GETS ITS OWN SERVICE ACCOUNT. SAY THIS OUT LOUD IN THE ROOM.
#  ---------------------------------------------------------------------
#  This file is short and it is the foundation everything else stands on.
#
#  What customers do today, almost without exception: the engineer who built the
#  agent gives it their own credentials, or points it at a shared `automation`
#  login that six other things also use. Both choices destroy attribution at the
#  source, and once attribution is gone, nothing downstream can be recovered:
#
#    * You cannot write policy 10. `principal.accountType == "service"` is
#      meaningless if the agent authenticates as a human.
#    * You cannot answer "what did the AI do?" — its queries are interleaved
#      with the engineer's in the same audit stream, indistinguishable.
#    * You cannot revoke it. Pulling the role pulls the engineer's access too,
#      at 3am, during an incident.
#    * You cannot approve anything meaningfully. The approver sees a request
#      from a person who is asleep.
#
#  Giving the agent a first-class identity is the cheap, boring, unglamorous
#  decision that makes every sophisticated control in this build possible. It
#  costs one Terraform resource.
# =============================================================================


# -----------------------------------------------------------------------------
#  The AI's own identity.
#
#  Note `service {}`, not `user {}`. StrongDM stamps accountType accordingly,
#  and policy 10 keys off exactly that:
#
#      principal.accountType == "service"
#
#  which is how "no autonomous agent writes to production" becomes an
#  expressible sentence rather than an aspiration.
#
#  TOKEN HANDLING: the provider exposes the service token as a sensitive
#  computed attribute. Terraform writes it directly to SSM for the agent VM.
#  It therefore exists in state, which must use an encrypted restricted backend.
# -----------------------------------------------------------------------------
resource "sdm_account" "nightshift_agent" {
  service {
    name      = "nightshift-agent"
    suspended = false

    tags = {
      Project  = "nightshift"
      identity = "non-human"
      owner    = var.owner
    }
  }
}


# -----------------------------------------------------------------------------
#  Human accounts — the approvers.
#
#  These are the people who say yes in Slack while the room watches. They are
#  attached to sre-oncall below, and sre-oncall is the approver role on the
#  nightshift-write approval flow in 80-strongdm-workflows.tf.
#
#  IN A REAL DEPLOYMENT you would not manage humans here at all — you would sync
#  them from the customer's IdP (Okta, Entra, Google) via SCIM, and an on-call
#  integration would drive group membership from the live schedule. StrongDM
#  supports PagerDuty and incident.io for that; it does not support Grafana, so
#  in this build the membership below is static (§4.2). Terraform-managed users
#  are a demo convenience. If an architect asks, give them that answer straight;
#  provisioning humans from code is not the pattern to advocate.
# -----------------------------------------------------------------------------
resource "sdm_account" "human" {
  for_each = var.human_users

  user {
    email      = each.value.email
    first_name = each.value.first_name
    last_name  = each.value.last_name

    permission_level = each.value.permission_level

    tags = {
      Project = "nightshift"
      team    = "sre"
    }
  }
}


# =============================================================================
#  ROLES
#
#  `sdm_role_grant` DOES NOT EXIST in this provider. Access is expressed with
#  `access_rules`, a JSON string built with jsonencode(). Individual rules OR
#  together: a resource matching ANY rule is in scope.
#
#  Two rule styles, and the choice between them is architectural:
#
#    ids  = [...]        explicit, brittle, auditable at a glance
#    tags = { k = v }    dynamic, scales, new resources inherit automatically
#
#  Used deliberately below: the agent gets an explicit ID list, humans get a tag
#  match. Reasoning under each role.
# =============================================================================

# -----------------------------------------------------------------------------
#  ai-agents — the read path, and nothing else.
#
#  EXPLICIT IDs, ON PURPOSE.
#
#  It would be tidier to write `tags = { env = "prod" }` here and let the agent
#  pick up new production resources automatically. Do not. An autonomous
#  identity should never gain access to a system because someone else tagged
#  something; every resource an agent can reach should be a decision a human
#  made, visible in a diff, in this file.
#
#  Humans get the convenience of tag-based access. The AI gets an allow-list.
#  That asymmetry is the point, and it is worth ten seconds if someone notices.
#
#  What this grants: connect-level access to the database, both SSH targets, and
#  both MCP servers. What it does NOT grant is the right to WRITE to any of
#  them — that is policy's job, not the role's, and policies 10/20/30/40 are
#  where it happens.
# -----------------------------------------------------------------------------
resource "sdm_role" "ai_agents" {
  name = "ai-agents"

  access_rules = jsonencode([
    {
      # Standing database access is read-only. The remediation resource is
      # deliberately absent and can only arrive through the access workflow.
      ids = [sdm_resource.pg_prod_shopfront_read.id]
    },
    {
      # MCP tool access — one self-hosted (grafana-mcp, private subnet, behind
      # the relay) and one SaaS (github-mcp). Which specific TOOLS it may call
      # is policy 40's job; this rule only decides that the resources are
      # reachable at all.
      ids = [
        sdm_resource.grafana_mcp.id,
        sdm_resource.github_mcp.id,
      ]
    },
  ])

  tags = {
    Project  = "nightshift"
    identity = "non-human"
  }
}


# -----------------------------------------------------------------------------
#  sre-oncall — the humans.
#
#  TAG-BASED, ON PURPOSE — the mirror image of the decision above. Humans on
#  call need to reach whatever is on fire, including the thing that was
#  registered an hour ago. Making them wait for a Terraform PR at 3am is how you
#  end up with a shared break-glass password in a wiki.
#
#  These accounts are NOT service accounts, so policy 10 never fires for them.
#  A human on this role can write to production. That is correct: the control
#  being demonstrated is about autonomy, not about locking everyone out.
#
#  ---------------------------------------------------------------------------
#  THIS ROLE IS STATIC, AND IF IT COMES UP, SAY SO STRAIGHT (§4.2).
#  ---------------------------------------------------------------------------
#  StrongDM's on-call sync supports PAGERDUTY AND INCIDENT.IO ONLY. There is no
#  Grafana integration. An earlier revision of this build paged from PagerDuty
#  and drove membership of this role from the live rota, so the agent's
#  eligibility to request elevated access existed only during its on-call
#  window. That was a good architect beat and moving to Grafana lost it.
#
#  Do not fake it. The honest answer is strong on its own:
#
#      "StrongDM syncs PagerDuty and incident.io schedules straight into groups,
#       and those groups drive roles, workflows and policy — so eligibility
#       follows the rota. We're on Grafana here, so this role is static. In your
#       environment we'd wire it to whatever you page from."
# -----------------------------------------------------------------------------
resource "sdm_role" "sre_oncall" {
  name = "sre-oncall"

  access_rules = jsonencode([
    {
      # Everything tagged production. Includes resources that do not exist yet.
      tags = {
        env = "prod"
      }
    },
  ])

  tags = {
    Project  = "nightshift"
    identity = "human"
  }
}


# =============================================================================
#  ATTACHMENTS
#
#  `sdm_account_attachment` is the current, non-deprecated way to put an account
#  in a role.
#
#  MOMENT 6 — THE KILL SWITCH — LIVES HERE.
#  Deleting `sdm_account_attachment.agent_to_ai_agents` (or toggling
#  `suspended = true` on the service account above) revokes the agent mid-run.
#  Its next action dies instantly, because there is no cached credential on the
#  agent host to keep working with. On stage, do it from the Admin UI so the
#  audience watches you click it; the Terraform below is how it is expressed in
#  code afterwards.
# =============================================================================

resource "sdm_account_attachment" "agent_to_ai_agents" {
  account_id = sdm_account.nightshift_agent.id
  role_id    = sdm_role.ai_agents.id
}

resource "sdm_account_attachment" "humans_to_sre_oncall" {
  for_each = var.human_users

  account_id = sdm_account.human[each.key].id
  role_id    = sdm_role.sre_oncall.id
}
