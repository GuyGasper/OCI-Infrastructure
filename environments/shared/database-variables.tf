variable "database_admin_password" {
  description = "ADMIN password, supplied through TF_VAR_database_admin_password or a deployment secret. Stored in Terraform state; never use ADMIN as an application user."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition = (
      length(var.database_admin_password) >= 12 &&
      length(var.database_admin_password) <= 30 &&
      can(regex("[A-Z]", var.database_admin_password)) &&
      can(regex("[a-z]", var.database_admin_password)) &&
      can(regex("[0-9]", var.database_admin_password)) &&
      !strcontains(var.database_admin_password, "\"") &&
      !strcontains(lower(var.database_admin_password), "admin")
    )
    error_message = "Use 12-30 characters with uppercase, lowercase, and a number; omit double quotes and the word admin."
  }
}

variable "database_name" {
  description = "Database name, unique within the tenancy and region."
  type        = string
  default     = "sharedapps"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,29}$", var.database_name))
    error_message = "Use up to 30 alphanumeric characters, starting with a letter."
  }
}

variable "database_ecpu_count" {
  description = "Provisioned ECPUs for the paid serverless database; autoscaling is disabled."
  type        = number
  default     = 2

  validation {
    condition     = var.database_ecpu_count >= 2 && floor(var.database_ecpu_count) == var.database_ecpu_count
    error_message = "Provision at least 2 ECPUs, in whole increments."
  }
}

variable "database_storage_gb" {
  description = "Provisioned database storage in GB; storage autoscaling is disabled."
  type        = number
  default     = 20

  validation {
    condition     = var.database_storage_gb >= 20 && floor(var.database_storage_gb) == var.database_storage_gb
    error_message = "Provision at least 20 GB of storage, in whole increments."
  }
}

variable "database_subnet_cidr" {
  description = "Dedicated private database subnet in the shared VCN; must not overlap existing subnets."
  type        = string
  default     = "10.20.80.0/24"

  validation {
    condition     = can(cidrnetmask(var.database_subnet_cidr))
    error_message = "Provide a valid IPv4 subnet CIDR."
  }
}

variable "database_client_cidrs" {
  description = "Worker source CIDRs permitted to connect over TLS. Both app pools currently use 10.20.30.0/24."
  type        = set(string)
  default     = ["10.20.30.0/24"]

  validation {
    condition = length(var.database_client_cidrs) > 0 && alltrue([
      for cidr in var.database_client_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "Provide at least one IPv4 worker CIDR; access from 0.0.0.0/0 is not allowed."
  }
}
