# OCI Infrastructure

Terraform for shared OCI foundations and independently deployed applications.

The initial implementation publishes a small wedding placeholder from Object
Storage through a public OCI API Gateway. See [docs/bootstrap.md](docs/bootstrap.md)
for prerequisites, the native OCI state backend, GitHub Actions deployment,
Namecheap DNS, and the production hardening path.

## Layout

- `modules/network`: reusable VCN, public API Gateway subnet, and NSG.
- `modules/static-site`: Object Storage object plus an API Gateway deployment.
- `modules/oke`: OKE Basic cluster, managed workers, dedicated subnets, and routing.
- `environments/shared`: account-level networking shared by multiple projects.
- `environments/wedding`: resources owned by `sg2027wedding.com`.
- `environments/personal-os`: Personal OS OKE infrastructure and private container repositories.
- `kubernetes/personal-os`: Java API, React/Nginx frontend, and HTTPS load balancer manifests.

Each environment has separate Terraform state. Wedding uses the shared API
Gateway subnet and NSG. Personal OS owns dedicated Kubernetes endpoint, worker,
and load balancer subnets in the shared VCN. See [docs/personal-os.md](docs/personal-os.md) for
deployment, application image contracts, TLS, and DNS cutover.
