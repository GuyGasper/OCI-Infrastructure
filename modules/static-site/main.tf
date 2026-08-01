data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

resource "oci_objectstorage_bucket" "site" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.name}-site"
  access_type    = "ObjectRead"
  storage_tier   = "Standard"
  versioning     = "Enabled"
}

resource "oci_objectstorage_object" "index" {
  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = oci_objectstorage_bucket.site.name
  object       = "index.html"
  source       = var.index_file
  content_type = "text/html; charset=utf-8"
}

locals {
  index_url = "https://objectstorage.${var.region}.oraclecloud.com/n/${data.oci_objectstorage_namespace.this.namespace}/b/${oci_objectstorage_bucket.site.name}/o/${oci_objectstorage_object.index.object}"
}

resource "oci_apigateway_gateway" "site" {
  compartment_id             = var.compartment_id
  display_name               = "${var.name}-gateway"
  endpoint_type              = "PUBLIC"
  subnet_id                  = var.subnet_id
  network_security_group_ids = var.network_security_group_ids
  certificate_id             = var.certificate_id
}

resource "oci_apigateway_deployment" "site" {
  compartment_id = var.compartment_id
  gateway_id     = oci_apigateway_gateway.site.id
  display_name   = "${var.name}-site"
  path_prefix    = "/"

  specification {
    routes {
      path    = "/"
      methods = ["GET", "HEAD"]

      backend {
        type = "HTTP_BACKEND"
        url  = local.index_url
      }
    }
  }
}
