variable "region" { type = string }
variable "compartment_id" { type = string }
variable "state_bucket" { type = string }
variable "state_namespace" { type = string }

data "terraform_remote_state" "shared" {
  backend = "oci"

  config = {
    bucket    = var.state_bucket
    namespace = var.state_namespace
    region    = var.region
    key       = "shared/terraform.tfstate"
  }
}
