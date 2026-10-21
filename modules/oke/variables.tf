variable "compartment_id" { type = string }
variable "vcn_id" { type = string }
variable "public_route_table_id" { type = string }
variable "existing_cluster_id" {
  description = "Join this cluster instead of creating another control plane. The caller owns its lifecycle."
  type        = string
  default     = null
}
variable "existing_worker_subnet_id" {
  description = "Existing worker subnet for a node pool joining a shared cluster."
  type        = string
  default     = null
}
variable "existing_worker_nsg_id" {
  description = "Existing worker NSG for a node pool joining a shared cluster."
  type        = string
  default     = null
}
variable "load_balancer_backend_cidr" {
  description = "Worker CIDR reached by this load balancer; defaults to the module's worker subnet."
  type        = string
  default     = null
}
variable "private_route_table_id" {
  description = "Existing worker egress route table in this VCN. When set, reuse it instead of creating NAT/service gateways."
  type        = string
  default     = null
}
variable "subnet_dns_prefix" {
  description = "VCN-unique prefix for endpoint, worker, and ingress subnet DNS labels."
  type        = string
  default     = "oke"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,6}$", var.subnet_dns_prefix))
    error_message = "Use a lowercase letter followed by up to six lowercase letters or digits."
  }
}
variable "name" {
  type    = string
  default = "personal-os"
}
variable "kubernetes_version" {
  description = "Explicit OKE-supported version, including v prefix. Upgrade deliberately."
  type        = string
}
variable "node_image_id" {
  description = "OKE worker image matching Kubernetes version, region, and node architecture."
  type        = string
}
variable "availability_domain" { type = string }
variable "admin_cidrs" {
  description = "IPv4 networks allowed to reach the public Kubernetes API; use your public IP/32."
  type        = set(string)
  validation {
    condition = length(var.admin_cidrs) > 0 && alltrue([
      for cidr in var.admin_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 24, false)
    ])
    error_message = "Provide at least one IPv4 admin CIDR with prefix /24 or narrower."
  }
}
variable "node_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}
variable "node_ocpus" {
  type    = number
  default = 1
}
variable "node_memory_gbs" {
  type    = number
  default = 6
}
variable "node_count" {
  type    = number
  default = 1
  validation {
    condition     = var.node_count >= 1 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a positive integer."
  }
}
variable "endpoint_cidr" {
  type    = string
  default = "10.20.20.0/28"
}
variable "worker_cidr" {
  type    = string
  default = "10.20.30.0/24"
}
variable "load_balancer_cidr" {
  type    = string
  default = "10.20.40.0/24"
}
