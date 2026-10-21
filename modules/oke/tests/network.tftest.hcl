mock_provider "oci" {
  mock_data "oci_core_services" {
    defaults = {
      services = [{
        id         = "ocid1.service.oc1.iad.test"
        cidr_block = "all-iad-services-in-oracle-services-network"
      }]
    }
  }
}

variables {
  compartment_id        = "ocid1.compartment.oc1..test"
  vcn_id                = "ocid1.vcn.oc1.iad.test"
  public_route_table_id = "ocid1.routetable.oc1.iad.public"
  kubernetes_version    = "v1.36.4"
  node_image_id         = "ocid1.image.oc1.iad.test"
  availability_domain   = "TEST:US-ASHBURN-AD-1"
  admin_cidrs           = ["203.0.113.10/32"]
}

run "personal_os_keeps_default_network" {
  command = plan

  assert {
    condition     = length(oci_containerengine_cluster.this) == 1
    error_message = "Personal OS must continue owning the existing control plane."
  }

  assert {
    condition = (
      length(oci_core_nat_gateway.workers) == 1 &&
      length(oci_core_service_gateway.regional) == 1 &&
      length(oci_core_route_table.private) == 1
    )
    error_message = "Personal OS must retain its existing private routing resources."
  }

  assert {
    condition = (
      oci_core_subnet.this["endpoint"].cidr_block == "10.20.20.0/28" &&
      oci_core_subnet.this["workers"].cidr_block == "10.20.30.0/24" &&
      oci_core_subnet.this["ingress"].cidr_block == "10.20.40.0/24" &&
      oci_core_subnet.this["endpoint"].dns_label == "okeapi" &&
      oci_core_subnet.this["workers"].dns_label == "okeworkers" &&
      oci_core_subnet.this["ingress"].dns_label == "okelb"
    )
    error_message = "Default subnet ranges and DNS labels must not change for Personal OS."
  }
}

run "wedding_joins_shared_cluster_and_worker_network" {
  command = plan
  variables {
    name                       = "sg-wedding"
    private_route_table_id     = "ocid1.routetable.oc1.iad.existing"
    existing_cluster_id        = "ocid1.cluster.oc1.iad.existing"
    existing_worker_subnet_id  = "ocid1.subnet.oc1.iad.existing"
    existing_worker_nsg_id     = "ocid1.networksecuritygroup.oc1.iad.existing"
    load_balancer_backend_cidr = "10.20.30.0/24"
    subnet_dns_prefix          = "sgw"
    endpoint_cidr              = "10.20.50.0/28"
    worker_cidr                = "10.20.60.0/24"
    load_balancer_cidr         = "10.20.70.0/24"
  }

  assert {
    condition = (
      length(oci_containerengine_cluster.this) == 0 &&
      output.cluster_id == var.existing_cluster_id &&
      oci_containerengine_node_pool.this.cluster_id == var.existing_cluster_id &&
      one(one(oci_containerengine_node_pool.this.node_config_details).placement_configs).subnet_id == var.existing_worker_subnet_id &&
      toset(one(oci_containerengine_node_pool.this.node_config_details).nsg_ids) == toset([var.existing_worker_nsg_id])
    )
    error_message = "Wedding must add only its worker pool, using the shared cluster's worker subnet and NSG."
  }

  assert {
    condition = (
      oci_core_network_security_group_security_rule.egress["ingress_nodeport"].destination == "10.20.30.0/24" &&
      oci_core_network_security_group_security_rule.egress["ingress_health"].destination == "10.20.30.0/24" &&
      one(oci_containerengine_node_pool.this.initial_node_labels).key == "workload" &&
      one(oci_containerengine_node_pool.this.initial_node_labels).value == "sg-wedding"
    )
    error_message = "Wedding load balancing must reach the actual shared workers, and the new pool must carry its scheduling label."
  }
}

run "reject_shared_cluster_without_compatible_worker_network" {
  command = plan
  variables {
    existing_cluster_id = "ocid1.cluster.oc1.iad.existing"
  }
  expect_failures = [oci_containerengine_node_pool.this]
}

run "wedding_reuses_egress_with_distinct_subnets" {
  command = plan
  variables {
    name                   = "sg-wedding"
    private_route_table_id = "ocid1.routetable.oc1.iad.existing"
    subnet_dns_prefix      = "sgw"
    endpoint_cidr          = "10.20.50.0/28"
    worker_cidr            = "10.20.60.0/24"
    load_balancer_cidr     = "10.20.70.0/24"
  }

  assert {
    condition = (
      length(oci_core_nat_gateway.workers) == 0 &&
      length(oci_core_service_gateway.regional) == 0 &&
      length(oci_core_route_table.private) == 0 &&
      oci_core_subnet.this["workers"].route_table_id == "ocid1.routetable.oc1.iad.existing"
    )
    error_message = "Wedding must reuse private routing instead of creating duplicate VCN gateways."
  }

  assert {
    condition = (
      oci_core_subnet.this["workers"].prohibit_public_ip_on_vnic &&
      oci_core_subnet.this["endpoint"].dns_label == "sgwapi" &&
      oci_core_subnet.this["workers"].dns_label == "sgwworkers" &&
      oci_core_subnet.this["ingress"].dns_label == "sgwlb" &&
      oci_core_subnet.this["endpoint"].route_table_id == var.public_route_table_id &&
      oci_core_subnet.this["ingress"].route_table_id == var.public_route_table_id
    )
    error_message = "Wedding needs private workers, distinct DNS labels, and public endpoint/ingress routing."
  }
}
