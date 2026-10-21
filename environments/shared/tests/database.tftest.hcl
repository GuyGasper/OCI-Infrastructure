mock_provider "oci" {
  mock_data "oci_core_nat_gateways" {
    defaults = { nat_gateways = [{ id = "ocid1.natgateway.oc1.iad.existing", block_traffic = false }] }
  }
  mock_data "oci_core_services" {
    defaults = { services = [{ id = "ocid1.service.oc1.iad.test", cidr_block = "all-iad-services-in-oracle-services-network" }] }
  }
  mock_data "oci_core_service_gateways" {
    defaults = { service_gateways = [{ id = "ocid1.servicegateway.oc1.iad.existing", block_traffic = false, services = [{ service_id = "ocid1.service.oc1.iad.test" }] }] }
  }
  mock_data "oci_core_image" {
    defaults = { id = "ocid1.image.oc1.iad.test", operating_system = "Canonical Ubuntu", operating_system_version = "24.04", display_name = "Canonical-Ubuntu-24.04-aarch64-test" }
  }
  mock_resource "oci_bastion_bastion" {
    defaults = { private_endpoint_ip_address = "10.20.90.2" }
  }
}

variables {
  region                       = "us-ashburn-1"
  compartment_id               = "ocid1.compartment.oc1..test"
  tenancy_id                   = "ocid1.tenancy.oc1..test"
  postgres_availability_domain = "test:US-ASHBURN-AD-1"
  postgres_image_id            = "ocid1.image.oc1.iad.test"
  postgres_ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnly"
}

run "dedicated_small_private_vm" {
  command = apply
  assert {
    condition = (
      oci_core_instance.postgres.shape == "VM.Standard.A1.Flex" &&
      one(oci_core_instance.postgres.shape_config).ocpus == 1 &&
      one(oci_core_instance.postgres.shape_config).memory_in_gbs == 6 &&
      one(oci_core_instance.postgres.source_details).boot_volume_size_in_gbs == "50" &&
      one(oci_core_instance.postgres.create_vnic_details).assign_public_ip == "false" &&
      one(oci_core_instance.postgres.create_vnic_details).private_ip == "10.20.80.10" &&
      one(oci_core_instance.postgres.create_vnic_details).subnet_id == oci_core_subnet.database.id &&
      toset(one(oci_core_instance.postgres.create_vnic_details).nsg_ids) == toset([oci_core_network_security_group.database.id]) &&
      one(oci_core_instance.postgres.instance_options).are_legacy_imds_endpoints_disabled &&
      oci_core_subnet.database.prohibit_public_ip_on_vnic
    )
    error_message = "Use the agreed private A1 1-OCPU/6-GB VM with a 50-GB boot volume and IMDSv2."
  }
  assert {
    condition = (
      oci_core_volume.postgres.size_in_gbs == "50" &&
      oci_core_volume.postgres.vpus_per_gb == "10" &&
      oci_core_volume.postgres.availability_domain == oci_core_instance.postgres.availability_domain &&
      oci_core_volume_attachment.postgres.volume_id == oci_core_volume.postgres.id &&
      oci_core_volume_attachment.postgres.instance_id == oci_core_instance.postgres.id &&
      oci_core_volume_attachment.postgres.device == "/dev/oracleoci/oraclevdb" &&
      oci_core_volume_attachment.postgres.is_pv_encryption_in_transit_enabled &&
      length(oci_database_autonomous_database.legacy) == 0
    )
    error_message = "Data must persist independently on an encrypted 50-GB balanced volume; never create a new paid Autonomous Database."
  }
  assert {
    condition = (
      length(oci_core_security_list.database.ingress_security_rules) == 0 &&
      length(oci_core_security_list.database.egress_security_rules) == 0 &&
      length(oci_core_network_security_group_security_rule.database_tls) == 1 &&
      one(oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].tcp_options).destination_port_range[0].min == 5432 &&
      one(oci_core_network_security_group_security_rule.database_tls["10.20.30.0/24"].tcp_options).destination_port_range[0].max == 5432 &&
      length(oci_core_network_security_group_security_rule.database_packages) == 2 &&
      alltrue([for rule in oci_core_route_table.database.route_rules : contains(["ocid1.natgateway.oc1.iad.existing", "ocid1.servicegateway.oc1.iad.existing"], rule.network_entity_id)])
    )
    error_message = "Restrict database ingress to worker TLS and reuse existing OKE gateways for package and backup egress."
  }
  assert {
    condition = (
      oci_objectstorage_bucket.postgres.access_type == "NoPublicAccess" &&
      length(oci_objectstorage_object_lifecycle_policy.postgres.rules) == 2 &&
      anytrue([for rule in oci_objectstorage_object_lifecycle_policy.postgres.rules : rule.action == "DELETE" && rule.time_amount == "8"]) &&
      strcontains(oci_identity_dynamic_group.postgres.matching_rule, oci_core_instance.postgres.id) &&
      !strcontains(oci_identity_policy.postgres_backup.statements[0], "OBJECT_DELETE") &&
      !strcontains(oci_identity_policy.postgres_backup.statements[0], "OBJECT_OVERWRITE") &&
      alltrue([for statement in oci_identity_policy.postgres_backup.statements : strcontains(statement, "target.bucket.name = 'shared-postgres-backups'")])
    )
    error_message = "Backups must be private, expire after eight days, and grant this VM no delete/overwrite privilege."
  }
}

run "additional_worker_subnet" {
  command = plan
  variables { database_client_cidrs = ["10.20.30.0/24", "10.20.60.0/24"] }
  assert {
    condition     = length(oci_core_network_security_group_security_rule.database_tls) == 2
    error_message = "Each explicit worker subnet needs its own PostgreSQL ingress rule."
  }
}
run "reject_public_access" {
  command = plan
  variables { database_client_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.database_client_cidrs]
}
run "reject_private_key" {
  command = plan
  variables { postgres_ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----" }
  expect_failures = [var.postgres_ssh_public_key]
}
run "reject_wrong_image_architecture" {
  command = plan
  override_data {
    target = data.oci_core_image.postgres
    values = { operating_system = "Canonical Ubuntu", operating_system_version = "24.04", display_name = "Canonical-Ubuntu-24.04-x86_64-test" }
  }
  expect_failures = [data.oci_core_image.postgres]
}
