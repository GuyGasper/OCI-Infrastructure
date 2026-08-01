variable "compartment_id" {
  description = "OCID of the compartment that owns the network."
  type        = string
}

variable "name" {
  description = "Prefix used for network resource names."
  type        = string
  default     = "personal-platform"
}

variable "vcn_cidr" {
  description = "CIDR for the shared VCN."
  type        = string
  default     = "10.20.0.0/16"
}

variable "gateway_subnet_cidr" {
  description = "CIDR for the regional public API Gateway subnet."
  type        = string
  default     = "10.20.10.0/24"
}
