variable "region" { type = string }
variable "compartment_id" { type = string }
variable "state_bucket" { type = string }
variable "state_namespace" { type = string }

variable "certificate_id" {
  description = "OCI certificate for domain_name and its www hostname."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.(certificate|apigatewaycertificate)\\.", trimspace(var.certificate_id)))
    error_message = "certificate_id must be a valid OCI Certificates/API Gateway certificate OCID."
  }
}

data "terraform_remote_state" "shared" {
  backend = "oci"

  config = {
    bucket    = var.state_bucket
    namespace = var.state_namespace
    region    = var.region
    key       = "shared/terraform.tfstate"
  }
}

module "site" {
  source                     = "../../modules/static-site"
  name                       = "personal-os"
  domain_name                = "personal-os.tech"
  compartment_id             = var.compartment_id
  region                     = var.region
  subnet_id                  = data.terraform_remote_state.shared.outputs.api_gateway_subnet_id
  network_security_group_ids = [data.terraform_remote_state.shared.outputs.api_gateway_nsg_id]
  index_file                 = "${path.module}/site/index.html"
  certificate_id             = var.certificate_id
}

output "site_url" { value = module.site.site_url }
output "gateway_hostname" { value = module.site.gateway_hostname }
output "gateway_public_ip" { value = module.site.gateway_public_ip }
output "bucket_name" { value = module.site.bucket_name }
