# =============================================================================
#  Project Nightshift — Grafana Cloud
#
#  Supporting observability and the incident system the agent reads over MCP.
# =============================================================================
#
#  The live driver opens a real IRM incident through the Grafana API after the
#  deterministic database fault is injected. It does not expose the task shim
#  as a public webhook and does not claim the optional 5xx alert fired.
#
#  FREE TIER (§4.5) — all of this fits, with one number to watch:
#      500 alert rules, 1000 instances each     we use 1
#      3 ACTIVE IRM USERS PER MONTH, ENFORCED   you + the agent = 2
#      10k active series, 14 day retention, 1 stack, 3 Grafana users
#
#  Keep colleagues out of this stack. An "active IRM user" is anyone in an
#  on-call schedule or anyone who creates or edits an incident, and hitting the
#  limit mid-rehearsal costs you incident creation — which is Act 3.
# =============================================================================


# =============================================================================
#  READING THE STACK
#
#  Note DATA SOURCE, not resource. The free tier gives you exactly one stack and
#  a `grafana_cloud_stack` RESOURCE would put it under Terraform's control,
#  which means `terraform destroy` on a disposable demo environment would take
#  the stack, the alert history, the IRM incidents and the dashboards with it.
#
#  We read it. We create objects inside it. We never own it.
#
#  This runs against the ALIASED provider, because grafana_cloud_* needs the
#  Cloud Access Policy token and not the stack's glsa_ service account token.
#  See the long comment in 00-providers.tf; mixing the two is the single most
#  common way to lose an hour here.
# =============================================================================
data "grafana_cloud_stack" "nightshift" {
  provider = grafana.cloud

  slug = var.grafana_stack_slug
}


# -----------------------------------------------------------------------------
#  The hosted Prometheus datasource UID.
#
#  ###########################################################################
#  DO NOT HARDCODE THIS AND DO NOT ASSUME THE DATASOURCE NAME.
#  ###########################################################################
#
#  Grafana Cloud provisions the hosted Prometheus datasource as EITHER
#  `grafanacloud-prom` OR `grafanacloud-<slug>-prom`, depending on when and how
#  the stack was created. Both are real, both are common, and a build that
#  hardcodes one of them fails on somebody else's stack with an error that says
#  nothing useful.
#
#  So it is resolved by name at plan time, with an escape hatch: set
#  var.grafana_prom_datasource_uid and the lookup is skipped entirely.
#
#  If the apply fails with "data source not found": open Connections -> Data
#  sources in the stack, read the actual name, and set
#  var.grafana_prom_datasource_name. Thirty seconds, once per stack.
# -----------------------------------------------------------------------------
data "grafana_data_source" "hosted_prometheus" {
  count = var.grafana_prom_datasource_uid == "" ? 1 : 0

  name = var.grafana_prom_datasource_name
}

locals {
  prom_datasource_uid = (
    var.grafana_prom_datasource_uid != ""
    ? var.grafana_prom_datasource_uid
    : data.grafana_data_source.hosted_prometheus[0].uid
  )

  # -------------------------------------------------------------------------
  #  Prometheus remote_write, resolved from the stack rather than guessed.
  #
  #  THE PATH IS ALWAYS /api/prom/push. THE HOST IS NOT `prometheus-<region>`.
  #  It looks like https://prometheus-prod-NN-<region-slug>.grafana.net, where
  #  NN is a cluster ordinal you cannot derive from anything you know. There is
  #  no push gateway. Read it out of the stack (§4.5).
  #
  #  Basic auth for remote_write:
  #      username = the NUMERIC instance ID          (not your email)
  #      password = a Cloud Access Policy token      (scoped metrics:write)
  #
  #  Consumed by templates/app-server.sh.tftpl. The password does NOT travel in
  #  user-data — it goes via SSM SecureString, see 20-compute.tf.
  # -------------------------------------------------------------------------
  prom_remote_write_url = (
    var.grafana_prometheus_remote_write_url != ""
    ? var.grafana_prometheus_remote_write_url
    : data.grafana_cloud_stack.nightshift.prometheus_remote_write_endpoint
  )

  prom_instance_id = (
    var.grafana_prometheus_instance_id != ""
    ? var.grafana_prometheus_instance_id
    : tostring(data.grafana_cloud_stack.nightshift.prometheus_user_id)
  )

  # The alert rule's name. Referenced by scripts/break-it.sh (which polls for it
  # to go firing), scripts/verify.sh (which checks it exists at all) and
  # scripts/trigger-agent.sh (which quotes it in the canned payload the agent
  # reads back out loud). Change it here and change it in scripts/.env.example.
  alert_rule_name = "${local.name}-orders-api-5xx"

  # The PromQL behind the alert.
  #
  # `job="orders-api"` is set by the scrape config in
  # templates/app-server.sh.tftpl. `http_requests_5xx_total` is a counter
  # orders-api has always exposed on /metrics — the old CloudWatch publisher
  # scraped exactly this number and republished it as `Http5xxCount`. That
  # republishing step is what disappeared; the metric did not change.
  #
  # sum() across both app servers, because the incident is "orders-api is
  # failing", not "app-01 is failing". rate() over 2m so a single scrape gap
  # does not produce a false recovery mid-demo.
  alert_expr = "sum(rate(http_requests_5xx_total{job=\"orders-api\"}[2m]))"

}


# =============================================================================
#  FOLDER
#
#  Everything this build creates in Grafana lives in one folder, so that a
#  rebuild is a blast radius you can see. Alert rules belong to a folder in
#  Grafana's model — the rule group below needs its UID — and keeping ours
#  separate means nothing here can quietly reorganise a stack you also use for
#  something real.
# =============================================================================
resource "grafana_folder" "nightshift" {
  title = var.grafana_folder_title
}


# =============================================================================
#  THE ALERT RULE
#
#  ###########################################################################
#  THERE IS NO `grafana_alert_rule` RESOURCE. RULES ARE `rule {}` BLOCKS
#  INSIDE A `grafana_rule_group`. Do not go looking for the singular form; it
#  does not exist and never has.
#  ###########################################################################
#
#  Three stages, which is how every Grafana-managed alert is shaped:
#
#      A   the query        against the hosted Prometheus datasource
#      B   reduce           collapse the series to one number
#      C   threshold        compare it, and this is the alert condition
#
#  B and C are SERVER-SIDE EXPRESSIONS, and they are addressed by the magic
#  datasource UID "-100". That is not a placeholder to fill in and it is not a
#  typo — it is how Grafana names its own expression engine in the provisioning
#  API. Point B or C at the real datasource UID and the rule saves fine and then
#  never evaluates correctly.
# =============================================================================
resource "grafana_rule_group" "orders_api" {
  name       = "${local.name}-orders-api"
  folder_uid = grafana_folder.nightshift.uid

  # How often the whole group evaluates. Combined with `for` below this is the
  # first half of the 60-180s in §6.
  interval_seconds = var.alert_evaluation_interval_seconds

  rule {
    name = local.alert_rule_name

    # The ref_id of the stage whose output decides the alert. C, the threshold.
    condition = "C"

    # ------------------------------------------------------------------------
    #  `for` — how long the condition must hold before the rule goes from
    #  Pending to Firing.
    #
    #  1m, deliberately. Zero would page on a single unlucky scrape; five would
    #  add four minutes to a chain you are already telling people not to wait
    #  for. One evaluation of grace, no more.
    # ------------------------------------------------------------------------
    for = "1m"

    # ------------------------------------------------------------------------
    #  no_data_state = "OK", and this one is load-bearing.
    #
    #  This is the Grafana equivalent of the old alarm's
    #  `treat_missing_data = "notBreaching"`, and it exists for the same reason:
    #  a healthy orders-api produces a 5xx rate of zero, and a torn-down demo
    #  environment produces no series at all. The CloudWatch default left the
    #  alarm in INSUFFICIENT_DATA forever and it never fired; the Grafana
    #  default ("NoData") would page you every time the environment is down
    #  between rehearsals.
    #
    #  exec_err_state = "Error" so that a genuinely broken query is visible as
    #  an error rather than silently reading as healthy. A rule that cannot
    #  evaluate is not the same thing as a service that is fine.
    # ------------------------------------------------------------------------
    no_data_state  = "OK"
    exec_err_state = "Error"

    # --- A: the query ------------------------------------------------------
    data {
      ref_id         = "A"
      datasource_uid = local.prom_datasource_uid

      # Required even for an instant query. 600s of lookback comfortably covers
      # the 2m rate() window plus remote_write ingestion lag.
      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        editorMode    = "code"
        expr          = local.alert_expr
        instant       = true
        range         = false
        legendFormat  = "__auto"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    # --- B: reduce ---------------------------------------------------------
    #  Collapse the (single) series to its last value. `dropNN` drops
    #  non-numeric points rather than turning them into an evaluation error,
    #  which matters because remote_write ingestion is not instantaneous and the
    #  newest point can briefly be absent.
    data {
      ref_id = "B"

      # The expression engine. Not a datasource. See the header.
      datasource_uid = "-100"

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "A"
        reducer    = "last"
        settings   = { mode = "dropNN" }
      })
    }

    # --- C: threshold — THE ALERT CONDITION --------------------------------
    data {
      ref_id         = "C"
      datasource_uid = "-100"

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "B"
        conditions = [
          {
            evaluator = {
              type   = "gt"
              params = [var.alert_5xx_rate_threshold]
            }
          }
        ]
      })
    }

    # ------------------------------------------------------------------------
    # Labels retained for operator filtering in the Grafana UI.
    # ------------------------------------------------------------------------
    labels = {
      team     = "nightshift"
      service  = "orders-api"
      severity = "critical"
    }

    # ------------------------------------------------------------------------
    #  Annotations — the text the agent actually reads.
    #
    #  Write these for the LLM, not for a dashboard. The agent's first move is to
    #  quote the incident back into Slack, so anything vague here becomes vague
    #  narration on stage. Name the service, the symptom, the port, and the fact
    #  that /health is deliberately still green — that last one is what stops the
    #  agent concluding the process is down and going looking for a restart.
    # ------------------------------------------------------------------------
    annotations = {
      summary = "orders-api 5xx rate above threshold"

      description = join(" ", [
        "orders-api is returning HTTP 500 on business requests.",
        "5xx rate over 2m exceeded ${var.alert_5xx_rate_threshold} errors/sec.",
        "Hosts: app-01, app-02, both serving on :8080.",
        "/health is still returning 200 — it is a liveness check and does not",
        "read order payloads, so the process is up and every business request",
        "is failing. Start at GET /debug/last-errors on either host.",
      ])

      runbook_url = "https://github.com/${var.github_repo == "" ? "your-org/shopfront-platform" : var.github_repo}/blob/main/RUNBOOK.md"
    }
  }
}
