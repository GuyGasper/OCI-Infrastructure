# Both applications use Flannel on the Personal OS worker subnet. Keep this
# CIDR configurable without making shared state depend on application state.
resource "oci_core_route_table" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-database-local-routes"
}

resource "oci_core_security_list" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-database-empty"
}

resource "oci_core_subnet" "database" {
  compartment_id             = var.compartment_id
  vcn_id                     = module.network.vcn_id
  cidr_block                 = var.database_subnet_cidr
  display_name               = "shared-database"
  dns_label                  = "database"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.database.id
  security_list_ids          = [oci_core_security_list.database.id]
}

resource "oci_core_network_security_group" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-database"
}

# Stateful ingress permits replies without granting general database egress.
# TLS on 1521 works with the Java APIs without distributing a client wallet.
resource "oci_core_network_security_group_security_rule" "database_tls" {
  for_each                  = var.database_client_cidrs
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Application workers to shared Autonomous Database over TLS"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 1521
      max = 1521
    }
  }
}

resource "oci_database_autonomous_database" "shared" {
  compartment_id                      = var.compartment_id
  display_name                        = "shared-applications"
  db_name                             = var.database_name
  db_workload                         = "OLTP"
  db_version                          = "19c"
  admin_password                      = var.database_admin_password
  compute_model                       = "ECPU"
  compute_count                       = var.database_ecpu_count
  data_storage_size_in_gb             = var.database_storage_gb
  license_model                       = "LICENSE_INCLUDED"
  is_dedicated                        = false
  is_free_tier                        = false
  is_auto_scaling_enabled             = false
  is_auto_scaling_for_storage_enabled = false
  is_mtls_connection_required         = false
  subnet_id                           = oci_core_subnet.database.id
  nsg_ids                             = [oci_core_network_security_group.database.id]
  private_endpoint_label              = "shareddb"

  lifecycle {
    prevent_destroy = true
  }
}

output "database_id" {
  description = "Shared Autonomous Database OCID; owned by shared state."
  value       = oci_database_autonomous_database.shared.id
}

output "database_private_endpoint" {
  description = "Private hostname of the database inside the shared VCN."
  value       = oci_database_autonomous_database.shared.private_endpoint
}

output "database_connection_strings" {
  description = "Oracle connection descriptors and TLS profiles; contains no passwords."
  value       = oci_database_autonomous_database.shared.connection_strings
}
