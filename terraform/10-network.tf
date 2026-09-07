# =============================================================================
#  Project Nightshift — Network
# =============================================================================
#
#  THE ARCHITECTURAL POINT THIS TOPOLOGY MAKES
#  -------------------------------------------
#  Spend thirty seconds on this in front of the architects. It is the "no
#  inbound firewall change" claim, made visible in a diagram they can audit.
#
#      public subnet    sdm-gateway   <- the ONLY thing with an inbound rule
#                       agent-vm         from the internet (:5555)
#
#      private subnet   sdm-relay     <- reverse-tunnels OUT to the gateway
#                       app-01/02        no inbound from anywhere but the relay
#                       RDS              no inbound from anywhere but the relay
#                       mcp-host         no inbound from anywhere but the relay
#
#  The relay dials outbound to the gateway and holds the tunnel open. Nothing in
#  the private subnet accepts a connection that did not originate inside the
#  VPC. RDS is not publicly accessible and its security group names exactly one
#  source security group.
#
#  Compare that to the alternative a customer usually has: a bastion with 22/tcp
#  open, or an RDS instance with `publicly_accessible = true` and a very long
#  allow-list that nobody has audited since 2021.
# =============================================================================

locals {
  name = var.project
}


# -----------------------------------------------------------------------------
#  VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # SSM Session Manager and RDS both want working DNS inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}


# -----------------------------------------------------------------------------
#  Subnets
#
#  Two public + two private. The second private subnet exists almost entirely to
#  satisfy the RDS subnet-group requirement of two AZs; app-02 lives there so it
#  is not an empty subnet on the diagram.
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Explicitly false. This is the whole point of the tier.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-private-${count.index + 1}"
    Tier = "private"
  }
}


# -----------------------------------------------------------------------------
#  Internet gateway + NAT
#
#  ONE NAT gateway, not one per AZ. A second NAT costs ~$32/month for zero demo
#  value; if AZ-a dies mid-demo you have larger problems. This is the single
#  biggest line item in the ~$3-5/day running cost.
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}


# -----------------------------------------------------------------------------
#  Route tables
#
#  The private route table is what makes the relay's reverse tunnel possible:
#  outbound to the internet via NAT, no inbound path at all.
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name}-rt-private"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# =============================================================================
#  SECURITY GROUPS
#
#  Read these top to bottom as the story of the demo. The permitted inbound
#  paths are: internet -> gateway:5555, and relay -> everything else. There is
#  no third path.
# =============================================================================

# -----------------------------------------------------------------------------
#  StrongDM gateway — the only internet-facing listener in the build.
# -----------------------------------------------------------------------------
resource "aws_security_group" "sdm_gateway" {
  name        = "${local.name}-sdm-gateway"
  description = "StrongDM gateway: public client listener, outbound to control plane"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-sdm-gateway"
  }
}

resource "aws_vpc_security_group_ingress_rule" "gateway_client" {
  security_group_id = aws_security_group.sdm_gateway.id
  description       = "StrongDM clients and the relay reverse tunnel dial in here"

  # Open to the world by necessity: the gateway is the public entry point, and
  # the client population (your laptop, the agent VM, a customer's laptop during
  # the deep dive) is not a fixed CIDR. Authentication and authorization happen
  # above this layer, in the control plane and in Cedar.
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = var.gateway_listen_port
  to_port     = var.gateway_listen_port
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "gateway_all" {
  security_group_id = aws_security_group.sdm_gateway.id
  description       = "Outbound to the StrongDM control plane and package mirrors"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# -----------------------------------------------------------------------------
#  StrongDM relay — NO inbound rules at all.
#
#  This empty ingress list is the most important thing on this page. The relay
#  reaches RDS and the app servers, and reaches the gateway and control plane
#  outbound. Nothing reaches it. Point at this when someone asks "so what do we
#  have to open on our firewall?"
# -----------------------------------------------------------------------------
resource "aws_security_group" "sdm_relay" {
  name        = "${local.name}-sdm-relay"
  description = "StrongDM relay: egress-only, reverse-tunnels out to the gateway"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-sdm-relay"
  }
}

resource "aws_vpc_security_group_egress_rule" "relay_all" {
  security_group_id = aws_security_group.sdm_relay.id
  description       = "Outbound to control plane, gateway, RDS, app servers"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# -----------------------------------------------------------------------------
#  Agent VM — PicoClaw's host.
#
#  It dials the StrongDM gateway. Its only inbound path is SSH from the relay,
#  brokered as the StrongDM agent-vm resource.
#
#  Worth saying on stage: this host is assumed COMPROMISED. That is the threat
#  model. A pre-1.0 Go binary whose own README says "may have unresolved network
#  security issues" is running on it with an LLM deciding what to execute. The
#  design does not try to keep the agent host clean — it makes the agent host
#  boring to compromise, because there is nothing on it worth stealing.
# -----------------------------------------------------------------------------
resource "aws_security_group" "agent_vm" {
  name        = "${local.name}-agent-vm"
  description = "PicoClaw agent host: egress-only, assumed hostile"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-agent-vm"
  }
}

resource "aws_vpc_security_group_ingress_rule" "agent_ssh_from_relay" {
  security_group_id = aws_security_group.agent_vm.id
  description       = "Operator SSH brokered through the StrongDM relay"

  referenced_security_group_id = aws_security_group.sdm_relay.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "agent_all" {
  security_group_id = aws_security_group.agent_vm.id
  description       = "Outbound to StrongDM gateway, control plane, OpenAI, Slack"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# -----------------------------------------------------------------------------
#  App servers — reachable ONLY from the relay.
#
#  Note the source is a security-group reference, not a CIDR. If someone later
#  launches an instance in the private subnet, it does not inherit access; it
#  would have to be explicitly placed in the relay's security group.
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "orders-api hosts: SSH and HTTP from the StrongDM relay only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_relay" {
  security_group_id = aws_security_group.app.id
  description       = "SSH brokered through StrongDM. There is no other way in."

  referenced_security_group_id = aws_security_group.sdm_relay.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_relay" {
  security_group_id = aws_security_group.app.id
  description       = "orders-api HTTP, for health checks through the relay"

  # 8080 — the port app/orders-api/orders-api.service binds uvicorn to, and the
  # port AGENT.md, HEARTBEAT.md, verify.sh and break-it.sh all curl. This used
  # to say 3000, matching an inline stub that no longer exists.
  #
  # `local.app_listen_port` is declared in 20-compute.tf and is the single
  # source of truth; it is also what user-data writes into the unit.
  referenced_security_group_id = aws_security_group.sdm_relay.id
  from_port                    = local.app_listen_port
  to_port                      = local.app_listen_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound via NAT for packages, RDS, and Prometheus remote_write to Grafana Cloud"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# -----------------------------------------------------------------------------
#  mcp-host — the self-hosted MCP server. Reachable ONLY from the relay.
#
#  ###########################################################################
#  THIS SECURITY GROUP IS THE POINT OF §4.4. SPEND THIRTY SECONDS ON IT.
#  ###########################################################################
#
#  Most published MCP demos run the MCP server as a subprocess on the same
#  machine as the agent. That means the agent's host holds the upstream
#  credential, and any policy layer above it is advisory at best — the agent can
#  simply talk to the upstream directly and skip the gateway.
#
#  Here the container is on a different host, in a subnet the agent VM has no
#  route into, behind a security group whose only ingress source is the StrongDM
#  relay. The container holds the Grafana service account token. The agent holds
#  neither that token nor the caller bearer. The ONLY path between the agent and
#  Grafana runs through StrongDM, and it is not a path the agent could choose to
#  go around, because there is no other path.
#
#  That is the difference between a policy and a preference, and it is exactly
#  the internal-MCP-server pattern these customers are going to build.
#
#  Note the source is a security-GROUP reference, not a CIDR. An instance
#  launched into the same private subnet later does not inherit access; it would
#  have to be deliberately placed in the relay's security group.
# -----------------------------------------------------------------------------
resource "aws_security_group" "mcp_host" {
  name        = "${local.name}-mcp-host"
  description = "mcp-grafana container host: MCP port from the StrongDM relay only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-mcp-host"
  }
}

resource "aws_vpc_security_group_ingress_rule" "mcp_from_relay" {
  security_group_id = aws_security_group.mcp_host.id
  description       = "mcp-grafana streamable-http endpoint, brokered through StrongDM. There is no other way in."

  referenced_security_group_id = aws_security_group.sdm_relay.id
  from_port                    = var.mcp_grafana_port
  to_port                      = var.mcp_grafana_port
  ip_protocol                  = "tcp"
}

# NOTE THE ABSENCE. There is no SSH ingress rule on this host, not even from
# any operator CIDR. It runs one container and is administered through SSM
# Session Manager, which needs no open port at all. If you find yourself wanting
# to add 22/tcp here, use `aws ssm start-session` instead.

resource "aws_vpc_security_group_egress_rule" "mcp_all" {
  security_group_id = aws_security_group.mcp_host.id
  description       = "Outbound via NAT: Docker Hub for the pinned image, then Grafana Cloud"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# -----------------------------------------------------------------------------
#  RDS — reachable from the relay (StrongDM's path) and the app servers
#  (the application's own path). Nothing else. Not from the agent VM. Not from
#  the internet. Not from your laptop.
#
#  When the agent connects "to production", it is connecting to 127.0.0.1:5432
#  on its own host. That listener is the sdm client. The real database is three
#  hops away behind a security group that has never heard of the agent.
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "shopfront Postgres: relay and app servers only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-sg-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_relay" {
  security_group_id = aws_security_group.rds.id
  description       = "Postgres from the StrongDM relay - the brokered path"

  referenced_security_group_id = aws_security_group.sdm_relay.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id = aws_security_group.rds.id
  description       = "Postgres from orders-api - the application path"

  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
