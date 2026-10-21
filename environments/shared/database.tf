locals {
  database_ip = cidrhost(var.database_subnet_cidr, 10)
}

# Discover existing OKE gateways without introducing a shared -> application
# remote-state cycle. A new installation bootstraps module.network first.
data "oci_core_nat_gateways" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  state          = "AVAILABLE"
  lifecycle {
    postcondition {
      condition     = length(self.nat_gateways) == 1 && alltrue([for gateway in self.nat_gateways : !gateway.block_traffic])
      error_message = "Deploy Personal OS networking first: PostgreSQL requires the existing, unblocked OKE NAT gateway."
    }
  }
}

data "oci_core_services" "database" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

data "oci_core_service_gateways" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  state          = "AVAILABLE"
  lifecycle {
    postcondition {
      condition = length(self.service_gateways) == 1 && alltrue([for gateway in self.service_gateways :
        !gateway.block_traffic && contains([for service in gateway.services : service.service_id], one(data.oci_core_services.database.services).id)
      ])
      error_message = "PostgreSQL backups require the existing OKE gateway for all regional Oracle services."
    }
  }
}

resource "oci_core_route_table" "database" {
  compartment_id = var.compartment_id
  vcn_id         = module.network.vcn_id
  display_name   = "shared-database-private-routes"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = one(data.oci_core_nat_gateways.database.nat_gateways).id
  }
  route_rules {
    destination       = one(data.oci_core_services.database.services).cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = one(data.oci_core_service_gateways.database.service_gateways).id
  }
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

# Flannel SNATs outbound pod traffic to the worker IPs. Separate SQL roles and
# databases enforce application isolation within that shared worker network.
resource "oci_core_network_security_group_security_rule" "database_tls" {
  for_each                  = var.database_client_cidrs
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Application workers to PostgreSQL over TLS"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "database_packages" {
  for_each                  = toset(["80", "443"])
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Ubuntu packages and OCI HTTPS; internet traffic uses existing NAT"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

data "oci_core_image" "postgres" {
  image_id = var.postgres_image_id
  lifecycle {
    postcondition {
      condition     = self.operating_system == "Canonical Ubuntu" && self.operating_system_version == "24.04" && strcontains(self.display_name, "aarch64")
      error_message = "PostgreSQL requires a Canonical Ubuntu 24.04 aarch64 platform image."
    }
  }
}

resource "oci_core_volume" "postgres" {
  availability_domain = var.postgres_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "shared-postgres-data"
  size_in_gbs         = 50
  vpus_per_gb         = 10
  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_core_instance" "postgres" {
  availability_domain                 = var.postgres_availability_domain
  compartment_id                      = var.compartment_id
  display_name                        = "shared-postgres"
  shape                               = "VM.Standard.A1.Flex"
  is_pv_encryption_in_transit_enabled = true
  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }
  source_details {
    source_type             = "image"
    source_id               = data.oci_core_image.postgres.id
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
  }
  create_vnic_details {
    assign_public_ip = false
    subnet_id        = oci_core_subnet.database.id
    private_ip       = local.database_ip
    hostname_label   = "postgres"
    nsg_ids          = [oci_core_network_security_group.database.id]
  }
  launch_options {
    # OCI requires network_type when launch_options is supplied. These match
    # the pinned Ubuntu ARM64 image and A1 paravirtualized devices.
    network_type                        = "PARAVIRTUALIZED"
    boot_volume_type                    = "PARAVIRTUALIZED"
    remote_data_volume_type             = "PARAVIRTUALIZED"
    firmware                            = "UEFI_64"
    is_consistent_volume_naming_enabled = true
  }
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }
  metadata = {
    ssh_authorized_keys = trimspace(var.postgres_ssh_public_key)
    user_data = base64encode(templatefile("${path.module}/postgres/cloud-init.yaml.tftpl", {
      bootstrap = base64gzip(file("${path.module}/postgres/bootstrap.py"))
      backup    = base64gzip(file("${path.module}/postgres/backup.py"))
      config = base64encode(jsonencode({
        private_ip    = local.database_ip
        worker_cidrs  = sort(tolist(var.database_client_cidrs))
        bastion_cidrs = local.bastion_enabled ? ["${oci_bastion_bastion.database[0].private_endpoint_ip_address}/32"] : []
        region        = var.region
        namespace     = data.oci_objectstorage_namespace.database.namespace
        backup_bucket = oci_objectstorage_bucket.postgres.name
      }))
    }))
  }
  lifecycle {
    prevent_destroy = true
    # Patching scripts does not replace a data-bearing VM. Deploy guest updates
    # explicitly over SSH; image upgrades require a reviewed replacement.
    ignore_changes = [metadata["user_data"]]
  }
}

resource "oci_core_volume_attachment" "postgres" {
  attachment_type                     = "paravirtualized"
  instance_id                         = oci_core_instance.postgres.id
  volume_id                           = oci_core_volume.postgres.id
  device                              = "/dev/oracleoci/oraclevdb"
  is_pv_encryption_in_transit_enabled = true
}

output "database_id" {
  description = "Shared PostgreSQL VM OCID."
  value       = oci_core_instance.postgres.id
}
output "database_private_ip" {
  value = local.database_ip
}
output "database_jdbc_urls" {
  description = "Use the matching namespace secret and /etc/database/root.crt CA mount."
  value = { for app in ["personal_os", "sg_wedding"] : app =>
    "jdbc:postgresql://${local.database_ip}:5432/${app}?sslmode=verify-full&sslrootcert=/etc/database/root.crt"
  }
}
