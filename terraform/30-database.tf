# =============================================================================
#  Project Nightshift — The production database
# =============================================================================
#
#  `shopfront` is "production" for the purposes of the story: it holds
#  public.customers (with email and phone — the PII that policy 20 redacts),
#  public.orders (the table policy 30 scopes the approved write to), and
#  public.payments (the table nobody, approved or not, gets to touch).
#
#  THE POINT OF THIS FILE
#  ----------------------
#  Nothing here is unusual. That is deliberate. This is a stock RDS instance
#  with a stock password, and the entire security story is applied *in front of
#  it* by StrongDM without the database knowing anything about it.
#
#  No database-level row security. No per-agent database role. No audit
#  extension. No application change. The customer does not have to modify the
#  thing they are least willing to modify.
#
#  Say that out loud when someone asks "how much work is this to adopt?"
# =============================================================================


# -----------------------------------------------------------------------------
#  Subnet group — private subnets only.
#  Two AZs because RDS insists, even for a single-AZ instance.
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "shopfront" {
  name        = "${local.name}-shopfront"
  description = "Private subnets for the shopfront production database"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = "${local.name}-db-subnet-group"
  }
}


# -----------------------------------------------------------------------------
#  Parameter group
#
#  log_statement = 'all' is set for a specific reason: it lets you show the
#  contrast in Moment 7. The database's own log records the statements, but with
#  no identity attached beyond the single shared `shopfront_admin` login — every
#  query from every human and every agent looks identical.
#
#  StrongDM's log has the same statements WITH the account that ran them. Put
#  the two logs side by side and the value of a per-agent identity stops being
#  an abstract argument.
#
#  (In a real production estate you would not leave log_statement = 'all' on.
#  Here the whole database is 50k rows of fake orders.)
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "shopfront" {
  name        = "${local.name}-postgres16"
  family      = "postgres16"
  description = "shopfront demo tuning — verbose statement logging for the audit contrast"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "0"
  }

  # Log the connection source so you can point at "everything came from the
  # relay's IP" during the network walkthrough.
  parameter {
    name  = "log_connections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}


# -----------------------------------------------------------------------------
#  The instance
# -----------------------------------------------------------------------------
resource "aws_db_instance" "shopfront" {
  identifier = "${local.name}-shopfront"

  engine = "postgres"

  # Major version only. AWS selects the current minor, so a rebuild three months
  # from now does not fail on a retired patch release.
  engine_version              = "16"
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.shopfront.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.shopfront.name

  # NOT publicly accessible. The only inbound path is the relay's security
  # group. This single line is a large part of the architecture story.
  publicly_accessible = false

  multi_az = false

  # Demo hygiene: no backups to pay for, no final snapshot to block a teardown
  # at 11pm, no deletion protection to fight with.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  # RDS is the long pole in `terraform apply` — roughly 8 of the ~12 minutes.
  # Apply before you need it, not while the customer is joining the call.
  apply_immediately = true

  tags = {
    Name = "${local.name}-shopfront"
    Role = "production-database"
  }
}


# =============================================================================
#  Secrets
#
#  The master credential exists in exactly two places:
#
#    1. AWS Secrets Manager  — so orders-api can read it at boot
#    2. StrongDM             — passed once at apply time in 50-strongdm-*.tf,
#                              stored in the control plane, never released
#
#  It is NOT on the agent VM, NOT in the agent's config file, and NOT in any
#  environment variable the LLM can read. When the agent connects to
#  127.0.0.1:5432 it presents no password at all — StrongDM injects the real
#  credential on the far side of the relay.
#
#  That injection is what makes "revoke the agent" instantaneous in Moment 6:
#  there is nothing cached on the agent host to keep working after you pull the
#  role.
# =============================================================================

resource "aws_secretsmanager_secret" "db" {
  name        = "${local.name}/shopfront/master"
  description = "shopfront master credential — consumed by orders-api. NOT by the agent."

  # Zero recovery window so a rebuild ten minutes after a destroy does not hit
  # "a secret with this name is scheduled for deletion".
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.shopfront.address
    port     = aws_db_instance.shopfront.port
    dbname   = var.db_name
    username = var.db_username
    password = var.db_password
  })
}
