# The workflow grants a separate remediation resource. It does not change the
# Cedar boundary and does not approve or resume an individual SQL statement.

resource "sdm_approval_workflow" "nightshift_write" {
  name          = "nightshift-write-approval"
  description   = "Human approval for a 15-minute Nightshift remediation resource grant."
  approval_mode = "manual"

  approval_step {
    quantifier = "any"

    approvers {
      role_id = sdm_role.sre_oncall.id
    }
  }
}

resource "sdm_workflow" "nightshift_write" {
  name        = "nightshift-write"
  description = "Time-bound access to the Shopfront remediation resource."

  enabled          = true
  approval_flow_id = sdm_approval_workflow.nightshift_write.id

  access_rules = jsonencode([
    {
      ids = [sdm_resource.pg_prod_shopfront_remediation.id]
    },
  ])

  access_request_max_duration = var.write_access_max_duration
  weight                      = 100
}

resource "sdm_workflow_role" "ai_agents_may_request" {
  workflow_id = sdm_workflow.nightshift_write.id
  role_id     = sdm_role.ai_agents.id
}
