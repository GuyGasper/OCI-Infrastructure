variable "bastion_client_cidrs" {
  description = "Public IPv4 /32 addresses allowed to connect to Bastion. Empty disables Bastion; set SHARED_BASTION_CLIENT_CIDRS in Actions."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition = length(var.bastion_client_cidrs) <= 20 && alltrue([
      for cidr in var.bastion_client_cidrs : can(cidrnetmask(cidr)) && endswith(cidr, "/32") && cidr != "0.0.0.0/32"
    ])
    error_message = "Use up to 20 individual public IPv4 addresses in /32 notation, or [] to disable Bastion."
  }
}

variable "bastion_subnet_cidr" {
  description = "Dedicated private management subnet in the shared VCN; must not overlap existing subnets."
  type        = string
  default     = "10.20.90.0/28"

  validation {
    condition     = can(cidrnetmask(var.bastion_subnet_cidr))
    error_message = "Provide a valid IPv4 subnet CIDR."
  }
}

locals {
  bastion_enabled = length(var.bastion_client_cidrs) > 0
}

# Personal OS already owns the VCN's service gateway. Reuse it without reading
# application state or changing gateway ownership. Deploy OKE before enabling
# Bastion on a new VCN; leave the client allowlist empty for initial bootstrap.
data "oci_core_services" "bastion" {
  count = local.bastion_enabled ? 1 : 0
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

data "oci_core_service_gateways" "bastion" {
  count          = local.bastion_enabled ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  state          = "AVAILABLE"

  lifecycle {
    postcondition {
      condition = (
        length(self.service_gateways) == 1 &&
        alltrue([for gateway in self.service_gateways :
          !gateway.block_traffic && contains(
            [for service in gateway.services : service.service_id],
            one(data.oci_core_services.bastion[0].services).id
          )
        ])
      )
      error_message = "Bastion requires the existing OKE service gateway, with traffic enabled for all regional Oracle services. Deploy Personal OS networking first, or leave bastion_client_cidrs empty during bootstrap."
    }
  }
}

resource "oci_core_route_table" "bastion" {
  count          = local.bastion_enabled ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-bastion-services"

  route_rules {
    destination       = one(data.oci_core_services.bastion[0].services).cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = one(data.oci_core_service_gateways.bastion[0].service_gateways).id
  }
}

resource "oci_core_security_list" "bastion" {
  count          = local.bastion_enabled ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-bastion"

  egress_security_rules {
    protocol         = "6"
    destination      = var.database_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false
    description      = "Bastion port forwarding to the private database"
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.database_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false
    description      = "Bastion port forwarding to private VM SSH"
    tcp_options {
      min = 22
      max = 22
    }
  }

  egress_security_rules {
    protocol         = "6"
    destination      = one(data.oci_core_services.bastion[0].services).cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
    stateless        = false
    description      = "HTTPS to regional Oracle services through the service gateway"
    tcp_options {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_subnet" "bastion" {
  count                      = local.bastion_enabled ? 1 : 0
  compartment_id             = var.compartment_id
  vcn_id                     = module.network.vcn_id
  cidr_block                 = var.bastion_subnet_cidr
  display_name               = "shared-bastion"
  dns_label                  = "bastion"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.bastion[0].id
  security_list_ids          = [oci_core_security_list.bastion[0].id]
}

resource "oci_bastion_bastion" "database" {
  count                        = local.bastion_enabled ? 1 : 0
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_id
  target_subnet_id             = oci_core_subnet.bastion[0].id
  name                         = "sharedDatabase"
  client_cidr_block_allow_list = var.bastion_client_cidrs
  max_session_ttl_in_seconds   = 10800
  dns_proxy_status             = "DISABLED"
}

resource "oci_core_network_security_group_security_rule" "database_bastion" {
  count                     = local.bastion_enabled ? 1 : 0
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${oci_bastion_bastion.database[0].private_endpoint_ip_address}/32"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "Database administration from the managed Bastion private endpoint"
  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

output "database_bastion_id" {
  description = "Managed Bastion OCID for creating temporary database port-forwarding sessions; null when disabled."
  value       = local.bastion_enabled ? oci_bastion_bastion.database[0].id : null
}


resource "oci_core_network_security_group_security_rule" "database_bastion_ssh" {
  count                     = local.bastion_enabled ? 1 : 0
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${oci_bastion_bastion.database[0].private_endpoint_ip_address}/32"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "VM SSH administration from the Bastion private endpoint only"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}
