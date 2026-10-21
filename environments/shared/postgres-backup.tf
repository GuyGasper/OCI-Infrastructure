data "oci_objectstorage_namespace" "database" {
  compartment_id = var.compartment_id
}

resource "oci_objectstorage_bucket" "postgres" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.database.namespace
  name           = "shared-postgres-backups"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_identity_dynamic_group" "postgres" {
  compartment_id = var.tenancy_id
  name           = "shared-postgres-backup"
  description    = "Only the dedicated PostgreSQL VM may upload database backups"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.postgres.id}'}"
}

resource "oci_identity_policy" "postgres_backup" {
  compartment_id = var.tenancy_id
  name           = "shared-postgres-backup"
  description    = "VM backup uploads and regional lifecycle deletion, restricted to the backup bucket"
  statements = [
    "Allow dynamic-group id ${oci_identity_dynamic_group.postgres.id} to manage objects in compartment id ${var.compartment_id} where all {target.bucket.name = '${oci_objectstorage_bucket.postgres.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}",
    "Allow service objectstorage-${var.region} to manage object-family in compartment id ${var.compartment_id} where target.bucket.name = '${oci_objectstorage_bucket.postgres.name}'"
  ]
}

resource "oci_objectstorage_object_lifecycle_policy" "postgres" {
  bucket    = oci_objectstorage_bucket.postgres.name
  namespace = oci_objectstorage_bucket.postgres.namespace
  rules {
    name        = "expire-daily-backups"
    action      = "DELETE"
    is_enabled  = true
    time_amount = 8
    time_unit   = "DAYS"
    target      = "objects"
  }
  rules {
    name        = "abort-incomplete-uploads"
    action      = "ABORT"
    is_enabled  = true
    time_amount = 1
    time_unit   = "DAYS"
    target      = "multipart-uploads"
  }
  depends_on = [oci_identity_policy.postgres_backup]
}

output "database_backup_bucket" {
  value = oci_objectstorage_bucket.postgres.name
}
