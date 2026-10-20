# OCI Infrastructure

Terraform for shared OCI foundations and independently deployed applications.

Personal OS and SG-Wedding each have an OKE cluster for a Java API and React/Nginx
frontend, private OCIR repositories, and a Kubernetes-managed HTTPS load balancer.
The existing wedding Object Storage/API Gateway placeholder remains until the
new application and DNS cutover are verified. See [docs/bootstrap.md](docs/bootstrap.md)
for the original state/backend bootstrap.

## Layout

- `modules/network`: reusable VCN, public API Gateway subnet, and NSG.
- `modules/static-site`: Object Storage object plus an API Gateway deployment.
- `modules/oke`: OKE Basic cluster, managed workers, dedicated subnets, and routing.
- `environments/shared`: account-level networking shared by multiple projects.
- `environments/wedding`: SG-Wedding OKE infrastructure, repositories, and retained placeholder.
- `environments/personal-os`: Personal OS OKE infrastructure and private container repositories.
- `kubernetes/personal-os`: Java API, React/Nginx frontend, and HTTPS load balancer manifests.
- `kubernetes/sg-wedding`: separate wedding application and HTTPS load balancer manifests.

Each environment has separate Terraform state. Both clusters use the existing
shared VCN with distinct endpoint, worker, and load balancer subnets. Wedding
reuses the existing private outbound route, NAT gateway, and service gateway
owned by Personal OS. The retained placeholder uses the original API Gateway
subnet and NSG. See [docs/personal-os.md](docs/personal-os.md) and
[docs/sg-wedding.md](docs/sg-wedding.md) for deployment, application image
contracts, TLS, and DNS cutover.
