variable "compartment_id" { type = string }
variable "region" { type = string }
variable "subnet_id" { type = string }
variable "network_security_group_ids" { type = list(string) }
variable "name" { type = string }
variable "index_file" { type = string }

variable "certificate_id" {
  description = "Optional OCI Certificates or API Gateway certificate OCID for a custom hostname."
  type        = string
  default     = null
  nullable    = true
}
