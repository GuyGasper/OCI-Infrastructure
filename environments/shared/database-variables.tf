variable "tenancy_id" {
  description = "Tenancy OCID for the backup instance-principal dynamic group and IAM policy."
  type        = string
}

variable "postgres_availability_domain" {
  description = "Availability domain for the VM and its persistent data volume."
  type        = string
}

variable "postgres_image_id" {
  description = "Pinned Canonical Ubuntu 24.04 ARM64 platform image OCID in this region."
  type        = string
  validation {
    condition     = startswith(var.postgres_image_id, "ocid1.image.")
    error_message = "Supply a real, pinned Ubuntu 24.04 ARM64 image OCID."
  }
}

variable "postgres_ssh_public_key" {
  description = "SSH public key for ubuntu administration through Bastion; never supply the private key."
  type        = string
  validation {
    condition     = can(regex("^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.postgres_ssh_public_key)))
    error_message = "Supply an OpenSSH ed25519 or RSA public key on one line."
  }
}

variable "database_subnet_cidr" {
  description = "Dedicated private database subnet in the shared VCN."
  type        = string
  default     = "10.20.80.0/24"
  validation {
    condition     = can(cidrhost(var.database_subnet_cidr, 10)) && can(cidrnetmask(var.database_subnet_cidr))
    error_message = "Provide an IPv4 subnet with room for host 10."
  }
}

variable "database_client_cidrs" {
  description = "Worker source CIDRs allowed to connect using PostgreSQL TLS. Both app pools use 10.20.30.0/24."
  type        = set(string)
  default     = ["10.20.30.0/24"]
  validation {
    condition = length(var.database_client_cidrs) > 0 && alltrue([
      for cidr in var.database_client_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "Provide IPv4 worker CIDRs; unrestricted public access is not allowed."
  }
}
