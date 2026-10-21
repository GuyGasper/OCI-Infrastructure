locals {
  cluster_id = var.existing_cluster_id != null ? var.existing_cluster_id : oci_containerengine_cluster.this[0].id
}

# Preserve the existing cluster when introducing the optional shared-cluster mode.
moved {
  from = oci_containerengine_cluster.this
  to   = oci_containerengine_cluster.this[0]
}

resource "oci_containerengine_cluster" "this" {
  count              = var.existing_cluster_id == null ? 1 : 0
  compartment_id     = var.compartment_id
  name               = var.name
  vcn_id             = var.vcn_id
  kubernetes_version = var.kubernetes_version
  type               = "BASIC_CLUSTER"
  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }
  endpoint_config {
    subnet_id            = oci_core_subnet.this["endpoint"].id
    is_public_ip_enabled = true
    nsg_ids              = [oci_core_network_security_group.this["endpoint"].id]
  }
  options {
    service_lb_subnet_ids = [oci_core_subnet.this["ingress"].id]
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }
  depends_on = [
    oci_core_network_security_group_security_rule.ingress,
    oci_core_network_security_group_security_rule.egress,
    oci_core_network_security_group_security_rule.pmtu,
    oci_core_network_security_group_security_rule.pmtu_egress,
  ]
}

resource "oci_containerengine_node_pool" "this" {
  compartment_id     = var.compartment_id
  cluster_id         = local.cluster_id
  name               = "${var.name}-workers"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape
  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }
  node_source_details {
    source_type             = "IMAGE"
    image_id                = var.node_image_id
    boot_volume_size_in_gbs = 50
  }
  node_config_details {
    size    = var.node_count
    nsg_ids = [var.existing_worker_nsg_id != null ? var.existing_worker_nsg_id : oci_core_network_security_group.this["workers"].id]
    placement_configs {
      availability_domain = var.availability_domain
      subnet_id           = var.existing_worker_subnet_id != null ? var.existing_worker_subnet_id : oci_core_subnet.this["workers"].id
    }
  }
  initial_node_labels {
    key   = "workload"
    value = var.name
  }
  lifecycle {
    precondition {
      condition     = (var.existing_worker_subnet_id == null) == (var.existing_worker_nsg_id == null)
      error_message = "Provide both an existing worker subnet and its NSG, or neither."
    }
    precondition {
      condition     = var.existing_cluster_id == null || (var.existing_worker_subnet_id != null && var.existing_worker_nsg_id != null)
      error_message = "Joining an existing cluster requires its worker subnet and NSG so control-plane and overlay traffic are allowed."
    }
  }
  depends_on = [oci_core_network_security_group_security_rule.worker_overlay_egress]
}
