variable "compartment_id" { type = string }
variable "region" { type = string }
variable "subnet_id" { type = string }
variable "network_security_group_ids" { type = list(string) }
variable "name" { type = string }
variable "index_file" { type = string }

variable "domain_name" {
  description = "Optional custom DNS name represented by certificate_id."
  type        = string
  default     = null
  nullable    = true
}

variable "certificate_id" {
  description = "Optional OCI Certificates or API Gateway certificate OCID for a custom hostname."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.certificate_id == null ? true : (
      trimspace(var.certificate_id) == "" ||
      can(regex("^ocid1\\.(certificate|apigatewaycertificate)\\.", trimspace(var.certificate_id)))
    )
    error_message = "certificate_id must be empty or a valid OCI Certificates/API Gateway certificate OCID."
  }
}
