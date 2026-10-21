mock_provider "oci" {}

variables {
  region                  = "us-chicago-1"
  compartment_id          = "ocid1.compartment.oc1..test"
  database_admin_password = "ExampleOnly12345"
}

run "private_database_for_both_apps" {
  command = plan

  assert {
    condition = (
      oci_core_subnet.database.prohibit_public_ip_on_vnic &&
      oci_core_subnet.database.cidr_block == "10.20.80.0/24" &&
      length(oci_core_route_table.database.route_rules) == 0 &&
      length(oci_core_security_list.database.ingress_security_rules) == 0 &&
      length(oci_core_security_list.database.egress_security_rules) == 0
    )
    error_message = "Database subnet must be private with local routing and NSG-only access."
  }

  assert {
    condition = (
      length(oci_core_network_security_group_security_rule.database_tls) == 1 &&
      oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].source == "10.20.30.0/24" &&
      oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].source_type == "CIDR_BLOCK" &&
      oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].direction == "INGRESS" &&
      oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].protocol == "6" &&
      !oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].stateless &&
      one(oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].tcp_options).destination_port_range[0].min == 1521 &&
      one(oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].tcp_options).destination_port_range[0].max == 1521
    )
    error_message = "Only the shared worker subnet may initiate stateful TLS connections on 1521."
  }

  assert {
    condition = (
      oci_database_autonomous_database.shared.db_workload == "OLTP" &&
      oci_database_autonomous_database.shared.compute_model == "ECPU" &&
      oci_database_autonomous_database.shared.compute_count == 2 &&
      oci_database_autonomous_database.shared.data_storage_size_in_gb == 20 &&
      oci_database_autonomous_database.shared.license_model == "LICENSE_INCLUDED" &&
      !oci_database_autonomous_database.shared.is_free_tier &&
      !oci_database_autonomous_database.shared.is_dedicated &&
      !oci_database_autonomous_database.shared.is_auto_scaling_enabled &&
      !oci_database_autonomous_database.shared.is_auto_scaling_for_storage_enabled &&
      !oci_database_autonomous_database.shared.is_mtls_connection_required &&
      oci_database_autonomous_database.shared.private_endpoint_label == "shareddb"
    )
    error_message = "Shared ATP must use fixed paid serverless sizing and walletless TLS."
  }
}

run "database_uses_dedicated_network" {
  command = apply

  override_resource {
    target = module.network.oci_core_vcn.this
    values = { id = "ocid1.vcn.oc1.test.shared" }
  }
  override_resource {
    target = oci_core_subnet.database
    values = { id = "ocid1.subnet.oc1.test.database" }
  }
  override_resource {
    target = oci_core_network_security_group.database
    values = { id = "ocid1.networksecuritygroup.oc1.test.database" }
  }

  assert {
    condition = (
      oci_core_subnet.database.vcn_id == "ocid1.vcn.oc1.test.shared" &&
      oci_database_autonomous_database.shared.subnet_id == "ocid1.subnet.oc1.test.database" &&
      toset(oci_database_autonomous_database.shared.nsg_ids) == toset(["ocid1.networksecuritygroup.oc1.test.database"])
    )
    error_message = "Database must attach to its private subnet and NSG in the existing shared VCN."
  }
}

run "additional_worker_subnet" {
  command = plan
  variables {
    database_client_cidrs = ["10.20.30.0/24", "10.20.60.0/24"]
  }
  assert {
    condition     = length(oci_core_network_security_group_security_rule.database_tls) == 2
    error_message = "Explicit additional worker subnets must receive their own access rule."
  }
}

run "reject_public_access" {
  command = plan
  variables {
    database_client_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.database_client_cidrs]
}

run "reject_invalid_password" {
  command = plan
  variables {
    database_admin_password = "weak"
  }
  expect_failures = [var.database_admin_password]
}

run "reject_undersized_compute" {
  command = plan
  variables {
    database_ecpu_count = 1
  }
  expect_failures = [var.database_ecpu_count]
}

run "reject_undersized_storage" {
  command = plan
  variables {
    database_storage_gb = 19
  }
  expect_failures = [var.database_storage_gb]
}
