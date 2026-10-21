data "oci_core_services" "regional" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_nat_gateway" "workers" {
  count          = var.private_route_table_id == null ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-nat"
}

resource "oci_core_service_gateway" "regional" {
  count          = var.private_route_table_id == null ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-services"
  services {
    service_id = one(data.oci_core_services.regional.services).id
  }
}

resource "oci_core_route_table" "private" {
  count          = var.private_route_table_id == null ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-private"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.workers[0].id
  }
  route_rules {
    destination       = one(data.oci_core_services.regional.services).cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.regional[0].id
  }
}

# Preserve existing Personal OS resource addresses when enabling routing reuse.
moved {
  from = oci_core_nat_gateway.workers
  to   = oci_core_nat_gateway.workers[0]
}
moved {
  from = oci_core_service_gateway.regional
  to   = oci_core_service_gateway.regional[0]
}
moved {
  from = oci_core_route_table.private
  to   = oci_core_route_table.private[0]
}

# Keep subnet security lists empty; all permissions are explicit NSG rules below.
resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-empty"
}

locals {
  subnets = {
    endpoint = { cidr = var.endpoint_cidr, private = false, dns = "${var.subnet_dns_prefix}api" }
    workers  = { cidr = var.worker_cidr, private = true, dns = "${var.subnet_dns_prefix}workers" }
    ingress  = { cidr = var.load_balancer_cidr, private = false, dns = "${var.subnet_dns_prefix}lb" }
  }
}

resource "oci_core_subnet" "this" {
  for_each                   = local.subnets
  compartment_id             = var.compartment_id
  vcn_id                     = var.vcn_id
  cidr_block                 = each.value.cidr
  display_name               = "${var.name}-${each.key}"
  dns_label                  = each.value.dns
  prohibit_public_ip_on_vnic = each.value.private
  route_table_id             = each.value.private ? (var.private_route_table_id != null ? var.private_route_table_id : oci_core_route_table.private[0].id) : var.public_route_table_id
  security_list_ids          = [oci_core_security_list.empty.id]
}

resource "oci_core_network_security_group" "this" {
  for_each       = local.subnets
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-${each.key}"
}

locals {
  # Flannel requires all protocols between workers, and TCP from control plane.
  ingress_rules = merge({
    workers_internal = { group = "workers", source = var.worker_cidr, protocol = "all", min = null, max = null }
    workers_control  = { group = "workers", source = var.endpoint_cidr, protocol = "6", min = null, max = null }
    workers_nodeport = { group = "workers", source = var.load_balancer_cidr, protocol = "6", min = 30000, max = 32767 }
    workers_health   = { group = "workers", source = var.load_balancer_cidr, protocol = "6", min = 10256, max = 10256 }
    endpoint_api     = { group = "endpoint", source = var.worker_cidr, protocol = "6", min = 6443, max = 6443 }
    endpoint_oke     = { group = "endpoint", source = var.worker_cidr, protocol = "6", min = 12250, max = 12250 }
    ingress_https    = { group = "ingress", source = "0.0.0.0/0", protocol = "6", min = 443, max = 443 }
    }, {
    for cidr in var.admin_cidrs : "admin_${cidr}" => {
      group = "endpoint", source = cidr, protocol = "6", min = 6443, max = 6443
    }
  })
  egress_rules = {
    workers_internet  = { group = "workers", destination = "0.0.0.0/0", type = "CIDR_BLOCK", min = null, max = null }
    endpoint_workers  = { group = "endpoint", destination = var.worker_cidr, type = "CIDR_BLOCK", min = null, max = null }
    endpoint_services = { group = "endpoint", destination = one(data.oci_core_services.regional.services).cidr_block, type = "SERVICE_CIDR_BLOCK", min = null, max = null }
    ingress_nodeport  = { group = "ingress", destination = var.load_balancer_backend_cidr != null ? var.load_balancer_backend_cidr : var.worker_cidr, type = "CIDR_BLOCK", min = 30000, max = 32767 }
    ingress_health    = { group = "ingress", destination = var.load_balancer_backend_cidr != null ? var.load_balancer_backend_cidr : var.worker_cidr, type = "CIDR_BLOCK", min = 10256, max = 10256 }
  }
}

resource "oci_core_network_security_group_security_rule" "ingress" {
  for_each                  = local.ingress_rules
  network_security_group_id = oci_core_network_security_group.this[each.value.group].id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  dynamic "tcp_options" {
    for_each = each.value.min == null ? [] : [each.value]
    content {
      destination_port_range {
        min = tcp_options.value.min
        max = tcp_options.value.max
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress" {
  for_each                  = local.egress_rules
  network_security_group_id = oci_core_network_security_group.this[each.value.group].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = each.value.destination
  destination_type          = each.value.type
  dynamic "tcp_options" {
    for_each = each.value.min == null ? [] : [each.value]
    content {
      destination_port_range {
        min = tcp_options.value.min
        max = tcp_options.value.max
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "worker_overlay_egress" {
  network_security_group_id = oci_core_network_security_group.this["workers"].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = var.worker_cidr
  destination_type          = "CIDR_BLOCK"
}

# Path MTU discovery must work through NAT, load balancers, and overlay networks.
resource "oci_core_network_security_group_security_rule" "pmtu" {
  for_each                  = local.subnets
  network_security_group_id = oci_core_network_security_group.this[each.key].id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pmtu_egress" {
  for_each                  = local.subnets
  network_security_group_id = oci_core_network_security_group.this[each.key].id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  icmp_options {
    type = 3
    code = 4
  }
}
