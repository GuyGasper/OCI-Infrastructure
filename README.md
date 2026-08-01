# OCI Infrastructure

Terraform for shared OCI foundations and independently deployed applications.

The initial implementation publishes a small wedding placeholder from Object
Storage through a public OCI API Gateway. See [docs/bootstrap.md](docs/bootstrap.md)
for prerequisites, the native OCI state backend, GitHub Actions deployment,
Namecheap DNS, and the production hardening path.

## Layout

- `modules/network`: reusable VCN, public API Gateway subnet, and NSG.
- `modules/static-site`: Object Storage object plus an API Gateway deployment.
- `environments/shared`: account-level networking shared by multiple projects.
- `environments/wedding`: resources owned by `sg2027wedding.com`.

Each environment has separate Terraform state. A later `personal-os` environment
can consume the shared subnet and NSG without coupling its lifecycle to the site.
