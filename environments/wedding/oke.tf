variable "kubernetes_version" { type = string }
variable "node_image_id" { type = string }
variable "availability_domain" { type = string }
variable "admin_cidrs" { type = set(string) }
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
}

data "oci_core_subnet" "existing_public" {
  subnet_id = data.terraform_remote_state.shared.outputs.api_gateway_subnet_id
}

# Reuse the VCN's existing private egress path, owned by Personal OS. This
# avoids duplicate NAT/service gateways and does not need new state outputs.
data "oci_core_subnets" "existing_workers" {
  compartment_id = var.compartment_id
  vcn_id         = data.terraform_remote_state.shared.outputs.vcn_id
  state          = "AVAILABLE"
  filter {
    name   = "display_name"
    values = ["personal-os-workers"]
  }
}

data "oci_core_subnet" "existing_workers" {
  subnet_id = one(data.oci_core_subnets.existing_workers.subnets).id
}

module "oke" {
  source                 = "../../modules/oke"
  name                   = "sg-wedding"
  compartment_id         = var.compartment_id
  vcn_id                 = data.terraform_remote_state.shared.outputs.vcn_id
  public_route_table_id  = data.oci_core_subnet.existing_public.route_table_id
  private_route_table_id = data.oci_core_subnet.existing_workers.route_table_id
  subnet_dns_prefix      = "sgw"
  endpoint_cidr          = "10.20.50.0/28"
  worker_cidr            = "10.20.60.0/24"
  load_balancer_cidr     = "10.20.70.0/24"
  kubernetes_version     = var.kubernetes_version
  node_image_id          = var.node_image_id
  availability_domain    = var.availability_domain
  admin_cidrs            = var.admin_cidrs
  node_shape             = var.node_shape
  node_ocpus             = var.node_ocpus
  node_memory_gbs        = var.node_memory_gbs
  node_count             = var.node_count
}

resource "oci_artifacts_container_repository" "app" {
  for_each       = toset(["frontend", "api"])
  compartment_id = var.compartment_id
  display_name   = "sg-wedding/${each.key}"
  is_public      = false
}

output "cluster_id" { value = module.oke.cluster_id }
output "node_pool_id" { value = module.oke.node_pool_id }
output "load_balancer_subnet_id" { value = module.oke.load_balancer_subnet_id }
output "load_balancer_nsg_id" { value = module.oke.load_balancer_nsg_id }
output "container_repositories" {
  value = { for name, repo in oci_artifacts_container_repository.app : name => repo.display_name }
}
output "kubeconfig_command" {
  value = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --region ${var.region} --file $HOME/.kube/sg-wedding --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}
