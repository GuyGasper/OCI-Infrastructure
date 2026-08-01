output "vcn_id" {
  value = oci_core_vcn.this.id
}

output "api_gateway_subnet_id" {
  value = oci_core_subnet.api_gateway.id
}

output "api_gateway_nsg_id" {
  value = oci_core_network_security_group.api_gateway.id
}
