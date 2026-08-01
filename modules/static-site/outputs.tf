output "gateway_hostname" {
  value = oci_apigateway_gateway.site.hostname
}

output "gateway_public_ip" {
  value = try(oci_apigateway_gateway.site.ip_addresses[0].ip_address, null)
}

output "site_url" {
  value = "https://${oci_apigateway_gateway.site.hostname}/"
}

output "bucket_name" {
  value = oci_objectstorage_bucket.site.name
}
