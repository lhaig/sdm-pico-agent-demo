# =============================================================================
#  Project Nightshift — The audit trail
# =============================================================================
#
#  S3 + Athena + Glue over StrongDM's Log Stream output.
#
#  Moment 7: "replay every SQL statement, every shell command, and every policy
#  decision the AI made", queried in SQL.
#
#  ---------------------------------------------------------------------------
#  THIS FILE USED TO DO A SECOND, UNRELATED JOB
#  ---------------------------------------------------------------------------
#  It also carried the incident trigger chain: a CloudWatch alarm on a custom
#  `Http5xxCount` metric, feeding an SNS topic, feeding a Lambda that posted to
#  the PagerDuty Events API. All of it is gone.
#
#  Grafana Alerting replaced all three AWS services (§4.1). orders-api's metrics
#  now remote_write to Grafana Cloud and a Grafana-managed rule fires directly —
#  see 96-grafana.tf. Three fewer services in the live path, and the fault
#  detection now lives in the same tool the agent reads its incident from over
#  MCP, which is a materially better story than "AWS noticed and told a
#  different SaaS product".
#
#  What stayed is everything below: the bucket, the cross-account bucket policy,
#  the Glue table and the Athena workgroup. None of it was ever part of the
#  PagerDuty path — it is Act 5, and it is unchanged.
#
#  ---------------------------------------------------------------------------
#  MANUAL STEP YOU CANNOT SKIP
#  ---------------------------------------------------------------------------
#  THERE IS NO TERRAFORM RESOURCE FOR STRONGDM LOG STREAM. None. No CLI, no
#  public API. It is configured in the Admin UI, by hand, once:
#
#      Settings -> Log Streaming -> Add -> Amazon S3
#      Bucket:  (the value of output.audit_bucket_name)
#      Region:  (var.aws_region)
#
#  Terraform creates the bucket and the bucket policy that lets StrongDM write
#  into it. It cannot create the thing that does the writing. Do this once,
#  screenshot the config, and put the screenshot in the runbook — this is the
#  step that silently makes Moment 7 empty if you forget it after a tenant
#  rebuild.
#
#  Full manual checklist: terraform/README.md, step M2.
# =============================================================================

locals {
  audit_bucket_name = "${local.name}-audit-${random_id.suffix.hex}"

  # StrongDM's Log Stream service writes from this fixed AWS principal. It is
  # StrongDM's account, not yours, and it is the same for every tenant.
  strongdm_log_stream_role_arn = "arn:aws:iam::910226215634:role/StrongDMLogStream"
}

resource "random_id" "suffix" {
  byte_length = 4
}


# -----------------------------------------------------------------------------
#  The bucket.
#
#  Everything the agent did lands here: each SQL statement with the account that
#  issued it, each SSH command, and each policy decision including the denials.
#  The denials are the interesting half — "what did the AI TRY to do" is a
#  better forensic question than "what did it do", and almost nothing else in
#  the customer's estate can answer it.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  bucket = local.audit_bucket_name

  # TRUE for a demo rebuilt weekly, so a teardown is not blocked by log objects.
  # Indefensible anywhere near a real audit trail — see the variable's docs.
  force_destroy = var.audit_bucket_force_destroy

  tags = {
    Name    = local.audit_bucket_name
    Purpose = "strongdm-log-stream"
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = false # the StrongDM cross-account policy below is not "public"
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, deliberately, NOT SSE-KMS. A customer-managed KMS key would
      # require granting the StrongDM Log Stream role kms:GenerateDataKey as
      # well, and a missing KMS grant fails silently — you get an empty bucket
      # and discover it during Moment 7. Keep the demo path simple; recommend
      # SSE-KMS with the corresponding key policy for production.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
#  Lifecycle — keep the bucket cheap, and keep Athena from scanning junk.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "expire-demo-logs"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    expiration {
      days = 30
    }
  }
}


# -----------------------------------------------------------------------------
#  THE LOG STREAM BUCKET POLICY.
#
#  This is the piece that makes the manual Admin-UI step work. StrongDM's Log
#  Stream service assumes a role in StrongDM's own AWS account and writes
#  objects into your bucket cross-account. Without this statement the UI accepts
#  the configuration and then quietly delivers nothing.
#
#  Least privilege, genuinely: s3:PutObject on this bucket's contents. Not
#  ListBucket, not GetObject, not DeleteObject. StrongDM writes your audit log;
#  it does not read it back, and it cannot remove what it wrote. Worth pointing
#  out to a paranoid architect — the vendor holding your audit trail should not
#  be able to edit it.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid    = "AllowStrongDMLogStreamPutObject"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [local.strongdm_log_stream_role_arn]
    }

    actions = ["s3:PutObject"]

    resources = ["${aws_s3_bucket.audit.arn}/*"]
  }

  # Standard hardening: refuse anything that arrives without TLS.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.audit.arn,
      "${aws_s3_bucket.audit.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  # The public access block must settle before a cross-account policy is
  # accepted, or the put races and fails.
  depends_on = [aws_s3_bucket_public_access_block.audit]
}


# -----------------------------------------------------------------------------
#  Glue catalog — schema over the raw log objects.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "audit" {
  name        = replace("${local.name}_audit", "-", "_")
  description = "StrongDM Log Stream audit data for Project Nightshift"
}

# -----------------------------------------------------------------------------
#  The `queries` table — the one you actually query on stage.
#
#  #########################################################################
#  #  VALIDATE THIS SCHEMA AGAINST YOUR OWN LOG OUTPUT BEFORE THE DEMO.    #
#  #                                                                       #
#  #  Log Stream emits newline-delimited JSON, and the exact field set     #
#  #  varies by StrongDM version and by which log types you enabled in the #
#  #  Admin UI. The columns below are the commonly-present ones and are    #
#  #  enough to tell the story, but treat them as a starting point:        #
#  #                                                                       #
#  #      aws s3 cp s3://<bucket>/<prefix>/<an-object> - | head -1 | jq .  #
#  #                                                                       #
#  #  and add or rename columns to match. A JSON SerDe silently returns    #
#  #  NULL for a column that is not in the data — it does not error — so a #
#  #  wrong schema looks exactly like an empty audit trail.                #
#  #########################################################################
#
#  Not partitioned. Over a demo's worth of data, partitioning costs more in
#  setup and MSCK REPAIR ceremony than it saves in scan. Add date partitions if
#  you leave this running for a customer POV.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "queries" {
  name          = "queries"
  database_name = aws_glue_catalog_database.audit.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "json"
    EXTERNAL       = "TRUE"
  }

  storage_descriptor {
    # Set this to whatever prefix you configure in the Log Stream UI.
    location      = "s3://${aws_s3_bucket.audit.id}/logs/queries/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        # Tolerate fields present in the JSON but absent from this schema,
        # rather than failing the whole row.
        "ignore.malformed.json" = "true"
        "dots.in.keys"          = "true"
      }
    }

    # --- identity: WHO ran it -------------------------------------------------
    columns {
      name    = "id"
      type    = "string"
      comment = "Unique query record ID"
    }
    columns {
      name    = "timestamp"
      type    = "string"
      comment = "ISO 8601 UTC"
    }
    columns {
      name    = "account_id"
      type    = "string"
      comment = "a-... The agent's own service account. This column is the whole argument."
    }
    columns {
      name    = "account_email"
      type    = "string"
      comment = "Human-readable identity"
    }
    columns {
      name = "account_first_name"
      type = "string"
    }
    columns {
      name = "account_last_name"
      type = "string"
    }

    # --- target: WHAT they ran it against -------------------------------------
    columns {
      name    = "resource_id"
      type    = "string"
      comment = "rs-..."
    }
    columns {
      name    = "resource_name"
      type    = "string"
      comment = "e.g. pg-prod-shopfront-read"
    }
    columns {
      name    = "resource_type"
      type    = "string"
      comment = "e.g. postgres, ssh, mcp"
    }
    columns {
      name = "remote_identity_username"
      type = "string"
    }

    # --- the statement itself -------------------------------------------------
    columns {
      name    = "query_body"
      type    = "string"
      comment = "The literal SQL or shell command. The answer to 'what did the AI do?'"
    }
    columns {
      name = "query_hash"
      type = "string"
    }
    columns {
      name = "duration"
      type = "string"
    }
    columns {
      name    = "record_count"
      type    = "string"
      comment = "Rows returned. Cross-check against @maxrows enforcement."
    }

    # --- the decision ---------------------------------------------------------
    columns {
      name    = "authorization"
      type    = "string"
      comment = "Policy outcome. The DENIALS are the interesting half of this table."
    }
    columns {
      name    = "error"
      type    = "string"
      comment = "The @error string the agent was shown, verbatim"
    }

    # --- provenance -----------------------------------------------------------
    columns {
      name = "source_ip"
      type = "string"
    }
    columns {
      name = "client_ip"
      type = "string"
    }
    columns {
      name = "user_agent"
      type = "string"
    }
    columns {
      name = "egress_node_id"
      type = "string"
    }
    columns {
      name = "encrypted"
      type = "boolean"
    }
    columns {
      name    = "capture"
      type    = "string"
      comment = "Reference to the full session capture, where one exists"
    }
  }
}


# -----------------------------------------------------------------------------
#  Athena workgroup.
#
#  THE DETAIL THAT MAKES THIS A DEMO MOMENT RATHER THAN A SCREENSHOT: you query
#  this through StrongDM too. Register Athena as a StrongDM resource and the
#  forensic investigation into what the AI did is itself brokered, authorized
#  and recorded. The auditor's access is audited. Nobody expects that, and it
#  answers the "who watches the watchers" question without a slide.
#
#  (Registering Athena is left out of this build to keep the apply lean — one
#  more sdm_resource block if you want it live.)
# -----------------------------------------------------------------------------
resource "aws_athena_workgroup" "audit" {
  name        = "${local.name}-audit"
  description = "Forensic queries over the StrongDM audit trail"

  # Lets `terraform destroy` remove the workgroup along with its query history.
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.audit.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Hard cap so a `SELECT *` typed under stage lighting cannot produce a
    # surprising bill.
    bytes_scanned_cutoff_per_query = 1073741824 # 1 GiB
  }

  tags = {
    Name = "${local.name}-athena-audit"
  }
}
