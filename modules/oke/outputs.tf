output "cluster_id" { value = local.cluster_id }
output "node_pool_id" { value = oci_containerengine_node_pool.this.id }
output "load_balancer_subnet_id" { value = oci_core_subnet.this["ingress"].id }
output "load_balancer_nsg_id" { value = oci_core_network_security_group.this["ingress"].id }
