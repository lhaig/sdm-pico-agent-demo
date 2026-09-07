# =============================================================================
#  Project Nightshift — Providers
# =============================================================================
#
#  Three providers do all the work:
#
#    hashicorp/aws     the disposable demo environment (VPC, EC2, RDS, S3, …)
#    strongdm/sdm      the control plane objects that are the actual demo
#    grafana/grafana   the optional alert rule used for supporting observability
#
#  VERSION PINNING IS NOT OPTIONAL HERE.
#  The StrongDM MCP resource types are marked *unstable* by the provider, which
#  means their schema can change without a major version bump. This build is
#  demonstrated live in front of customers; a surprise schema change during a
#  rehearsal-free week is not a risk worth carrying. Pin sdm exactly, and
#  re-validate deliberately when you choose to move.
#
#  See also §7.3 "Known sharp edges" in docs/01-architecture-and-build-plan.md.
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }

    # Pinned EXACTLY — see note above about unstable MCP resource types.
    sdm = {
      source  = "strongdm/sdm"
      version = "17.9.0"
    }

    # Suffix generation for globally-unique S3 bucket names.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # Grafana Cloud: folder and rule group.
    #
    # `~> 4.0` rather than an exact pin, deliberately and in contrast to sdm.
    # None of the resources used here are marked unstable, the 4.x line has been
    # schema-stable across the alerting resources, and taking patch releases is
    # worth more than freezing. If a minor bump ever breaks the apply, pin it
    # exactly the same way sdm is pinned and move on — do not debug it the
    # morning of a demo.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }

  # ---------------------------------------------------------------------------
  #  REMOTE STATE — commented out deliberately.
  #
  #  This environment is torn down between rehearsals and rebuilt from scratch,
  #  so local state is genuinely fine and one less thing to fail on stage.
  #
  #  BUT: state contains the RDS password, the MCP PATs and the StrongDM
  #  resource secrets in plaintext. If more than one person ever runs this, or
  #  if it lives longer than a week, uncomment this and use an encrypted bucket
  #  with a DynamoDB lock table.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "nightshift-tfstate-CHANGEME"
  #   key            = "nightshift/terraform.tfstate"
  #   region         = "eu-west-1"
  #   encrypt        = true
  #   dynamodb_table = "nightshift-tfstate-lock"
  # }
}


# -----------------------------------------------------------------------------
#  AWS
#
#  default_tags stamps Project = "nightshift" onto every taggable resource this
#  provider creates. That single tag is the teardown story: if `terraform
#  destroy` ever fails halfway (it will, eventually, on an ENI stuck behind a
#  Lambda), you can find every orphan with one tag filter instead of clicking
#  through eight consoles at 11pm before a customer call.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "nightshift"
      Environment = "demo"
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}


# -----------------------------------------------------------------------------
#  StrongDM
#
#  The provider block takes NO arguments. Credentials come exclusively from the
#  environment:
#
#      export SDM_API_ACCESS_KEY="…"
#      export SDM_API_SECRET_KEY="…"
#
#  That is a feature, not a limitation — it makes it structurally impossible to
#  commit a StrongDM API key to this repository.
#
#  The API key needs, at minimum: Resource, Role, Account, Node, Policy and
#  Workflow write permissions. An admin-scoped key is simplest for a demo
#  tenant.
# -----------------------------------------------------------------------------
provider "sdm" {}


# =============================================================================
#  GRAFANA — TWO PROVIDER INSTANCES, TWO DIFFERENT CREDENTIALS.
#
#  THIS IS THE SINGLE MOST COMMON WAY TO LOSE AN HOUR ON THIS FILE, so it is
#  worth being blunt about it. Grafana Cloud has two token types and they are
#  not interchangeable — §4.5 of the architecture doc says the same thing:
#
#    Grafana SERVICE ACCOUNT token   `glsa_…`
#        Created INSIDE the stack (Administration -> Users and access ->
#        Service accounts). Authenticates against https://<slug>.grafana.net.
#        This is what the default provider below uses, and it is also the token
#        the mcp-grafana container holds.
#
#    Cloud ACCESS POLICY token
#        Created in the Cloud PORTAL (grafana.com -> Security -> Access
#        Policies). Authenticates against the grafana.com management API.
#        This is what the aliased `grafana.cloud` provider below uses, what the
#        `grafana_cloud_*` data sources need, and what Prometheus remote_write
#        uses as its basic-auth PASSWORD.
#
#  Hand a glsa_ token to the cloud provider and you get a 401 from a hostname
#  you were not expecting. Hand a Cloud Access Policy token to the stack
#  provider and you get a 401 from the other one. Neither error names the
#  problem.
# =============================================================================

# -----------------------------------------------------------------------------
#  Default instance — the STACK. Everything in 96-grafana.tf uses this.
#
#  `url` must be the stack URL including the scheme and a trailing slash, e.g.
#  https://nightshift.grafana.net/ — not grafana.com, and not the Prometheus
#  endpoint. var.grafana_url is validated for exactly that shape.
# -----------------------------------------------------------------------------
provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_service_account_token
}

# -----------------------------------------------------------------------------
#  Aliased instance — the CLOUD PORTAL. Used by exactly one thing:
#  `data.grafana_cloud_stack` in 96-grafana.tf, which is where the Prometheus
#  remote_write endpoint and the numeric instance ID come from.
#
#  We READ the stack, we do not create it. The free tier gives you exactly one
#  stack and `terraform destroy` on a `grafana_cloud_stack` RESOURCE would take
#  it — along with the alert history, the IRM incidents and the dashboards —
#  which is not a risk worth carrying on an environment that gets rebuilt
#  weekly. Data source only. See §4.5.
# -----------------------------------------------------------------------------
provider "grafana" {
  alias = "cloud"

  cloud_access_policy_token = var.grafana_cloud_access_policy_token
}
