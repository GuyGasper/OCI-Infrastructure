variable "region" { type = string }
variable "compartment_id" { type = string }

module "network" {
  source         = "../../modules/network"
  compartment_id = var.compartment_id
}

output "api_gateway_subnet_id" { value = module.network.api_gateway_subnet_id }
output "api_gateway_nsg_id" { value = module.network.api_gateway_nsg_id }
output "vcn_id" { value = module.network.vcn_id }
