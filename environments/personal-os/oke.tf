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

# Reuse the existing internet route. The placeholder stays until cutover is verified.
data "oci_core_subnet" "existing_public" {
  subnet_id = data.terraform_remote_state.shared.outputs.api_gateway_subnet_id
}

module "oke" {
  source                = "../../modules/oke"
  compartment_id        = var.compartment_id
  vcn_id                = data.terraform_remote_state.shared.outputs.vcn_id
  public_route_table_id = data.oci_core_subnet.existing_public.route_table_id
  kubernetes_version    = var.kubernetes_version
  node_image_id         = var.node_image_id
  availability_domain   = var.availability_domain
  admin_cidrs           = var.admin_cidrs
  node_shape            = var.node_shape
  node_ocpus            = var.node_ocpus
  node_memory_gbs       = var.node_memory_gbs
  node_count            = var.node_count
}

resource "oci_artifacts_container_repository" "app" {
  for_each       = toset(["frontend", "api"])
  compartment_id = var.compartment_id
  display_name   = "personal-os/${each.key}"
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
  value = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --region ${var.region} --file $HOME/.kube/personal-os --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}
