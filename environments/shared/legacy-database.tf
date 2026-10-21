# Preserve the paid database created by the cancelled apply, without starting
# or recreating it. Keep its OCID configured until separately approved cleanup.
import {
  for_each = var.legacy_autonomous_database_id == null ? [] : [var.legacy_autonomous_database_id]
  to       = oci_database_autonomous_database.legacy[0]
  id       = each.value
}

moved {
  from = oci_database_autonomous_database.shared
  to   = oci_database_autonomous_database.legacy[0]
}

resource "oci_database_autonomous_database" "legacy" {
  count          = var.legacy_autonomous_database_id == null ? 0 : 1
  compartment_id = var.compartment_id
  db_name        = "sharedapps"
  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
    postcondition {
      condition     = self.state == "STOPPED"
      error_message = "The legacy paid Autonomous Database must remain STOPPED. Stop it in OCI before continuing."
    }
  }
}
