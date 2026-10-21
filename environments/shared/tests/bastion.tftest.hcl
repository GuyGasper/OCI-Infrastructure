mock_provider "oci" {
  mock_data "oci_core_services" {
    defaults = {
      services = [{
        id         = "ocid1.service.oc1.iad.test"
        cidr_block = "all-iad-services-in-oracle-services-network"
      }]
    }
  }
  mock_data "oci_core_service_gateways" {
    defaults = {
      service_gateways = [{
        id            = "ocid1.servicegateway.oc1.iad.existing"
        block_traffic = false
        services      = [{ service_id = "ocid1.service.oc1.iad.test" }]
      }]
    }
  }
  mock_resource "oci_bastion_bastion" {
    defaults = { private_endpoint_ip_address = "10.20.90.2" }
  }
}

variables {
  region                  = "us-chicago-1"
  compartment_id          = "ocid1.compartment.oc1..test"
  database_admin_password = "ExampleOnly12345"
}

run "disabled_without_client_allowlist" {
  command = plan

  assert {
    condition = (
      length(oci_bastion_bastion.database) == 0 &&
      length(oci_core_subnet.bastion) == 0 &&
      length(oci_core_route_table.bastion) == 0 &&
      length(oci_core_security_list.bastion) == 0 &&
      length(oci_core_network_security_group_security_rule.database_bastion) == 0 &&
      length(data.oci_core_service_gateways.bastion) == 0 &&
      output.database_bastion_id == null
    )
    error_message = "Empty allowlist must skip Bastion and existing-gateway discovery for initial shared bootstrap."
  }
}

run "restricted_database_tunnel" {
  command = apply
  variables {
    bastion_client_cidrs = ["203.0.113.10/32"]
  }

  assert {
    condition = (
      toset(oci_bastion_bastion.database[0].client_cidr_block_allow_list) == toset(["203.0.113.10/32"]) &&
      oci_bastion_bastion.database[0].max_session_ttl_in_seconds == 10800 &&
      oci_bastion_bastion.database[0].dns_proxy_status == "DISABLED" &&
      oci_bastion_bastion.database[0].target_subnet_id == oci_core_subnet.bastion[0].id &&
      oci_core_subnet.bastion[0].prohibit_public_ip_on_vnic
    )
    error_message = "Bastion must use its private subnet, explicit client IPs, expiring sessions, and no dynamic SOCKS access."
  }

  assert {
    condition = (
      length(oci_core_route_table.bastion[0].route_rules) == 1 &&
      one(oci_core_route_table.bastion[0].route_rules).network_entity_id == "ocid1.servicegateway.oc1.iad.existing" &&
      one(oci_core_route_table.bastion[0].route_rules).destination_type == "SERVICE_CIDR_BLOCK" &&
      length(oci_core_security_list.bastion[0].ingress_security_rules) == 0 &&
      length(oci_core_security_list.bastion[0].egress_security_rules) == 2 &&
      alltrue([for rule in oci_core_security_list.bastion[0].egress_security_rules :
        rule.protocol == "6" && !rule.stateless && (
          (rule.destination_type == "CIDR_BLOCK" && rule.destination == var.database_subnet_cidr &&
          one(rule.tcp_options).min == 1521 && one(rule.tcp_options).max == 1521) ||
          (rule.destination_type == "SERVICE_CIDR_BLOCK" && rule.destination == "all-iad-services-in-oracle-services-network" &&
          one(rule.tcp_options).min == 443 && one(rule.tcp_options).max == 443)
        )
      ])
    )
    error_message = "Management subnet must allow only database TLS and Oracle service HTTPS using the existing service gateway."
  }

  assert {
    condition = (
      oci_core_network_security_group_security_rule.database_bastion[0].network_security_group_id == oci_core_network_security_group.database.id &&
      oci_core_network_security_group_security_rule.database_bastion[0].source == "10.20.90.2/32" &&
      oci_core_network_security_group_security_rule.database_bastion[0].source_type == "CIDR_BLOCK" &&
      oci_core_network_security_group_security_rule.database_bastion[0].direction == "INGRESS" &&
      oci_core_network_security_group_security_rule.database_bastion[0].protocol == "6" &&
      !oci_core_network_security_group_security_rule.database_bastion[0].stateless &&
      one(oci_core_network_security_group_security_rule.database_bastion[0].tcp_options).destination_port_range[0].min == 1521 &&
      one(oci_core_network_security_group_security_rule.database_bastion[0].tcp_options).destination_port_range[0].max == 1521
    )
    error_message = "Database must allow only the Bastion's private endpoint /32 on TLS port 1521."
  }
}

run "reject_broad_client_network" {
  command = plan
  variables {
    bastion_client_cidrs = ["203.0.113.0/24"]
  }
  expect_failures = [var.bastion_client_cidrs]
}

run "reject_public_allow_all" {
  command = plan
  variables {
    bastion_client_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.bastion_client_cidrs]
}

run "reject_invalid_client_address" {
  command = plan
  variables {
    bastion_client_cidrs = ["invalid/32"]
  }
  expect_failures = [var.bastion_client_cidrs]
}

run "requires_existing_service_gateway" {
  command = plan
  variables {
    bastion_client_cidrs = ["203.0.113.10/32"]
  }
  override_data {
    target = data.oci_core_service_gateways.bastion[0]
    values = { service_gateways = [] }
  }
  expect_failures = [data.oci_core_service_gateways.bastion[0]]
}
