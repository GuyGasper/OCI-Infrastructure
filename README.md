# OCI Infrastructure

Terraform for shared OCI foundations and independently deployed applications.

Personal OS and SG-Wedding share one OKE Basic cluster, with a managed worker
pool and namespace per application. Each app has a Java API and React/Nginx
frontend, private OCIR repositories, and its own HTTPS load balancer and TLS secret.
Load balancers use a flexible 10 Mbps minimum and 100 Mbps maximum.
The existing wedding Object Storage/API Gateway placeholder remains until the
new application and DNS cutover are verified. See [docs/bootstrap.md](docs/bootstrap.md)
for the original state/backend bootstrap.

## Layout

- `modules/network`: reusable VCN, public API Gateway subnet, and NSG.
- `modules/static-site`: Object Storage object plus an API Gateway deployment.
- `modules/oke`: OKE Basic cluster creation/reuse, managed workers, subnets, and routing.
- `environments/shared`: networking and a private PostgreSQL VM shared by both apps.
- `environments/wedding`: SG-Wedding OKE infrastructure, repositories, and retained placeholder.
- `environments/personal-os`: Personal OS OKE infrastructure and private container repositories.
- `kubernetes/personal-os`: Java API, React/Nginx frontend, and HTTPS load balancer manifests.
- `kubernetes/sg-wedding`: separate wedding application and HTTPS load balancer manifests.

Each environment has separate Terraform state. Personal OS owns the shared
cluster and private worker network in the existing VCN. Wedding reads that
cluster ID from Personal OS state and adds its own worker pool in the same
worker subnet/NSG; its HTTPS load balancer keeps a separate subnet and NSG.
Shared state also owns a private PostgreSQL 16 VM (A1, 1 OCPU, 6 GB RAM,
50 GB boot and 50 GB persistent data storage), with separate databases and users
for both apps and daily verified backups to private Object Storage. Budget about
$20–25/month at full paid rates. See [docs/database.md](docs/database.md) for
prerequisites, deployment, secrets, backup limits, and the retained stopped Oracle
database. Optional [managed Bastion access](docs/bastion.md) provides temporary
SSH/database tunnels restricted to your configured public IPv4 /32.
Already-created unused wedding endpoint/worker networking is retained for later
cleanup. The retained placeholder uses the original API Gateway subnet and NSG.
See [docs/personal-os.md](docs/personal-os.md) and
[docs/sg-wedding.md](docs/sg-wedding.md) for deployment, application image
contracts, TLS, and DNS cutover.
