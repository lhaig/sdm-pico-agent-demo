# StrongDM gateway and relay. Their sensitive computed bootstrap tokens are
# written directly to SSM in 20-compute.tf and therefore exist in Terraform
# state. Use an encrypted remote backend with tightly restricted access.

resource "sdm_node" "gateway" {
  gateway {
    name           = "${local.name}-gateway"
    listen_address = "${aws_eip.sdm_gateway.public_ip}:${var.gateway_listen_port}"
    bind_address   = "0.0.0.0:${var.gateway_listen_port}"

    tags = {
      Project = "nightshift"
      tier    = "public"
    }
  }
}

resource "sdm_node" "relay" {
  relay {
    name = "${local.name}-relay"

    tags = {
      Project = "nightshift"
      tier    = "private"
    }
  }
}
