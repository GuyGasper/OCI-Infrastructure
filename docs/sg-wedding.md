# SG-Wedding: OKE development environment

`environments/wedding` owns a managed worker pool in the existing Personal OS
OKE Basic cluster, its application load-balancer networking, and private
container repositories in the existing `wedding/terraform.tfstate`. It retains the
current Object Storage/API Gateway placeholder at its original `module.site`
address, including its certificate and outputs, until verification and DNS
cutover are complete. The new SG-Wedding application deploys to Kubernetes. The
application load balancer and TLS listener are created by the Kubernetes Service
after the worker pool and application images are ready. No second cluster is
created: the tenancy's one-cluster Basic limit is sufficient for this setup.

## Architecture

```text
sg2027wedding.com / www.sg2027wedding.com
  -> public OCI flexible load balancer :443 (TLS termination)
     -> React build served by unprivileged Nginx :8080 in OKE
        /api/* -> Java API ClusterIP service :8080 (prefix preserved)
        /*     -> React assets / SPA fallback
```

The shared cluster is OKE Basic. Wedding adds one `VM.Standard.A1.Flex` managed
worker (1 OCPU, 6 GiB RAM, 50 GiB boot volume) alongside the existing Personal OS
worker. There are two running workers total at the default settings. Both consume
compute allocations while running, including when idle. A single replica of
each app means node failure and maintenance can interrupt service. Both images must support
`linux/arm64`. Change the flex shape, matching image, CPU, and memory together
if you need x86. Each load balancer has a 10 Mbps minimum and 100 Mbps maximum;
usage above the minimum can incur charges. Check tenancy
quotas, regional A1 capacity, and current pricing; this configuration does not
guarantee an Always Free deployment. Compute, storage, and the load balancer can
incur charges. Increase node CPU/memory if system pods or rollouts cannot fit.

Both node pools use the existing private worker subnet and NSG. The wedding
load balancer uses its own subnet and NSG. All are in the existing shared VCN.

| Subnet | CIDR | Access |
| --- | --- | --- |
| Shared Kubernetes endpoint | `10.20.20.0/28` | Existing public API; Personal OS admin CIDRs control access |
| Shared workers | `10.20.30.0/24` | Private; both node pools use the existing NAT/service routing |
| Wedding load balancer | `10.20.70.0/24` | Public HTTPS on 443 |
| Retained wedding endpoint | `10.20.50.0/28` | Unused; retained from the partial apply for later cleanup |
| Retained wedding workers | `10.20.60.0/24` | Unused; retained from the partial apply for later cleanup |

Confirm these ranges are free before applying. Workers have no public IP or
inbound SSH rule. Flannel overlay pods use `10.244.0.0/16`, and services use
`10.96.0.0/16`; neither may overlap the VCN or connected networks. This initial
Flannel configuration does not enforce Kubernetes NetworkPolicies. The Java
Service is internal, but reachable by other pods in this cluster.

The retained wedding subnet DNS labels are `sgwapi`, `sgwworkers`, and `sgwlb`.
The worker pool, repositories, namespace, load balancer, and TLS secret remain
separate from Personal OS. The Kubernetes control plane and worker network are
shared. Pod selectors use `workload=sg-wedding` for wedding and
`workload=personal-os` for Personal OS, matching each node pool's initial label.
Wait for the wedding worker to be Ready before deploying wedding workloads;
its pods will stay Pending without a matching node. Namespaces and selectors
do not provide network isolation, and this Flannel setup does not enforce
NetworkPolicies. Both apps share control-plane upgrades and outages.

The cluster ID comes from `personal-os/terraform.tfstate`. The shared worker
subnet, worker NSG, and route table are discovered within the same VCN. The
control plane, original worker pool, worker network, NAT gateway, and service
gateway remain owned by the Personal OS Terraform state. OCI's default
[gateway limits](https://docs.oracle.com/en-us/iaas/Content/General/service-limits/default.htm)
are one NAT and one service gateway per VCN. Do not destroy the Personal OS
cluster or network while wedding uses it. Moving that ownership to a separate
shared environment would require a deliberate state migration, not a rename.

Wedding state owns two additional ingress rules on the shared worker NSG for
its load balancer's NodePort and health-check traffic. The wedding load balancer's
egress rules target the actual shared worker CIDR. Existing unused endpoint and
worker subnets/NSGs remain managed to avoid destructive cleanup during migration.

## OCI prerequisites

The shared state and VCN must already exist. Use the same region and compartment
as shared networking; check the existing deployment rather than assuming the
sample region is correct.

The Personal OS cluster, worker subnet/NSG, and outbound routing must exist too.
The module's `moved` blocks preserve Personal OS's existing cluster, gateway and
route table resources when enabling reuse. Review a Personal OS plan
as well: the address changes must not replace or destroy infrastructure.

Have a tenancy administrator extend the existing Terraform automation group's
compartment policies for OKE, compute, volumes, and private image repositories:

```text
Allow group TerraformDeployers to manage cluster-family in compartment <compartment>
Allow group TerraformDeployers to manage instance-family in compartment <compartment>
Allow group TerraformDeployers to manage volume-family in compartment <compartment>
Allow group TerraformDeployers to manage repos in compartment <compartment>
Allow group TerraformDeployers to inspect compartments in compartment <compartment>
```

Retain existing `manage virtual-network-family` and state-bucket permissions.
Use domain-qualified group names when appropriate. The person applying Kubernetes
manifests also needs OCI cluster access and Kubernetes RBAC permissions to create
the namespace, secrets, deployments, and services. Image publishing/pulling needs
separate OCIR credentials with appropriate repository permissions. See Oracle's
[OKE policy requirements](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengpolicyconfig.htm)
and [cluster access documentation](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutaccesscontrol.htm).

Select a supported Kubernetes version and matching OKE worker image for the
region and ARM architecture. Pin both values. OCI CLI discovery commands:

```bash
oci ce cluster-options get --cluster-option-id all --region <region>
oci ce node-pool-options get --node-pool-option-id all --region <region>
oci iam availability-domain list --compartment-id <tenancy-ocid>
```

## Plan and provision

Create `terraform.tfvars` from the example with your OCI and OKE inputs. A
new certificate is not required to provision the cluster; TLS is configured
during application deployment. Retain the current `certificate_id` value for
the existing placeholder. For local deployment:

```bash
cd environments/wedding
terraform init -reconfigure \
  -backend-config="bucket=<existing-state-bucket>" \
  -backend-config="namespace=<namespace>" \
  -backend-config="region=<region>" \
  -backend-config="key=wedding/terraform.tfstate"
terraform plan -out=sg-wedding.tfplan
# Review additions, costs, and unexpected modifications/deletes before apply.
terraform apply sg-wedding.tfplan
terraform output
```

For GitHub Actions, retain existing `production` secrets/variables and add:

| Environment variable | Value |
| --- | --- |
| `WEDDING_KUBERNETES_VERSION` | Must match the current shared control plane version, including `v` prefix |
| `WEDDING_NODE_IMAGE_ID` | Matching OKE ARM64 image OCID in the same region |
| `WEDDING_AVAILABILITY_DOMAIN` | Full availability domain name |
| `WEDDING_ADMIN_CIDRS` | Retained endpoint rules only; shared API access uses `PERSONAL_OS_ADMIN_CIDRS` |
| `WEDDING_NODE_SHAPE` | Optional; default `VM.Standard.A1.Flex` |
| `WEDDING_NODE_OCPUS` | Optional; default `1` |
| `WEDDING_NODE_MEMORY_GBS` | Optional; default `6` |
| `WEDDING_NODE_COUNT` | Optional; default `1` |

You can copy the corresponding `PERSONAL_OS_*` values for the same region,
Kubernetes version, worker image, availability domain, and admin IP, after
confirming they are still valid. Worker sizing and counts remain independent,
but control-plane upgrades must be coordinated. Upgrade/apply Personal OS first,
then update the wedding version and matching image; a mismatch fails planning.
Keep `OCI_CERTIFICATE_ID`
unchanged: it still configures the existing wedding API Gateway, not OKE.

Run **Deploy OCI infrastructure**, target `wedding`, with apply disabled
first. Review the plan; then run with apply enabled. This provisions
infrastructure only; it does not build apps or apply Kubernetes manifests. The
workflow summary publishes the cluster ID and load balancer subnet/NSG IDs.
Obtain the public load balancer IP from Kubernetes after app deployment. The
new OKE endpoint uses the separate `sg-wedding-tls` Kubernetes secret.

For target `all`, the workflow processes Personal OS before wedding because
wedding reads its cluster state. The first shared-cluster plan after the partial
apply should add one wedding worker pool and its two shared-worker NSG rules,
update the two wedding load-balancer egress rules, and leave the existing site
and all subnets intact. It must not create another cluster. Check OKE worker,
compute, volume, and load-balancer limits before applying.

## Application image contracts

Application source and Docker builds belong in the SG-Wedding application repo.
Terraform creates private OCIR repositories `sg-wedding/api` and
`sg-wedding/frontend`. Publish immutable versions or digests there.

The SG-Wedding application repository is managed separately; no app source,
Dockerfiles, or publishing workflow are added by these infrastructure changes.
When that workflow is ready, configure its own GitHub `production` environment:

| Setting | Type | Value |
| --- | --- | --- |
| `OCIR_REGISTRY` | Variable | `iad.ocir.io` for Ashburn |
| `OCIR_NAMESPACE` | Variable | Your tenancy's Object Storage namespace |
| `OCIR_USERNAME` | Secret | Full registry username, including namespace and identity domain when applicable |
| `OCIR_AUTH_TOKEN` | Secret | OCI auth token with push access to both wedding repositories |

These values are not inherited from another repository. Publishing images does
not deploy workloads to OKE. The Kubernetes API admin CIDR also means ordinary
hosted GitHub runners cannot deploy directly without a separate access
arrangement; use local deployment for this initial setup.

- **Java API:** ARM64 JRE, listens on `0.0.0.0:8080`, runs as UID/GID 10001,
  serves application routes under `/api`, and provides internal HTTP health
  endpoints `/health/live` and `/health/ready` without authentication. Liveness
  should not depend on external services. Readiness should reflect ability to
  handle requests. The root filesystem is read-only; `/tmp` is writable. Log to
  stdout.
- **React frontend:** build assets into `/usr/share/nginx/html` in an ARM64
  unprivileged Nginx image compatible with UID/GID 101, a read-only root filesystem,
  and temporary files under `/tmp` (for example, the nginx-unprivileged layout).
  The manifests mount this repo's server config. Use relative `/api` URLs so the
  browser uses the same HTTPS origin for frontend and API.

Manifests define one replica per app, probes, resources, and restricted pod
security. The API requests 200m CPU and 512Mi memory, with limits of 1 CPU and
1Gi; the frontend requests 50m CPU and 64Mi memory. Keep capacity for an extra
API pod during rolling updates. A future application deployment workflow should
wait for the API rollout before updating the frontend so both services do not
start rolling at once. Runtime app secrets are injected separately. No database
or app secrets are defined by this scaffold.

## Connect, configure secrets, and deploy

Install OCI CLI, kubectl, Terraform, and Python 3 locally. Run the Terraform
`kubeconfig_command` output, then select that explicit kubeconfig:

```bash
export KUBECONFIG="$HOME/.kube/sg-wedding"
kubectl get nodes -L workload
kubectl apply -f kubernetes/sg-wedding/namespace.yaml
```

The wedding and Personal OS kubeconfig files point to the same cluster. Keep
using the explicit `sg-wedding` namespace; a separate kubeconfig filename is not
a security boundary.

Create `ocir-pull` from a Docker configuration containing a dedicated read-only
OCIR user's auth token. Use `docker login <registry>` to populate that file
without putting the token in command history:

```bash
kubectl -n sg-wedding create secret generic ocir-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=<path-to-dedicated-docker-config.json>
kubectl -n sg-wedding create secret tls sg-wedding-tls \
  --cert=<full-certificate-chain.pem> --key=<private-key.pem>
```

The pull configuration must contain usable registry credentials under `auths`;
a `credsStore` or `credHelpers` reference to your local Windows credential
manager alone cannot authenticate a Kubernetes worker. Do not commit this file
or the TLS private key.

The certificate must cover both `sg2027wedding.com` and `www.sg2027wedding.com`.
Supply the actual certificate chain and matching private key, or separately
configure OCI Certificates integration. Keep keys outside Git and rotate the TLS secret before expiry;
verify the served certificate after rotation. The Service follows Oracle's
[TLS and load-balancer annotations](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancers-subtopic.htm).

From the infrastructure repo root, generate an ignored local overlay:

```bash
python3 scripts/render-sg-wedding.py \
  --api-image '<registry>/<namespace>/sg-wedding/api:<version>' \
  --frontend-image '<registry>/<namespace>/sg-wedding/frontend:<version>'
kubectl kustomize .local/sg-wedding
kubectl apply --dry-run=server -k .local/sg-wedding
kubectl apply -k .local/sg-wedding
kubectl -n sg-wedding rollout status deployment/sg-wedding-api
kubectl -n sg-wedding rollout status deployment/sg-wedding-frontend
kubectl -n sg-wedding get service sg-wedding-web
```

The renderer reads `terraform output -json` from `environments/wedding`, then
inserts its load balancer subnet/NSG and the published image references. If
Terraform ran only in Actions, initialize this same backend locally first. The
renderer never applies resources. Do not apply the base manifests directly:
they intentionally contain unresolved image and OCID values. ConfigMap content
hashing rolls out the frontend when Nginx configuration changes.

Kubernetes owns the load balancer; Terraform owns its subnet/security rules.
Do not edit the generated listener/backends manually in OCI. Only 443 is exposed;
HTTP-to-HTTPS redirection on port 80 is not configured initially.

The flexible 10-100 Mbps range takes effect when the application's rendered
Service manifest is applied. Terraform infrastructure deployment alone does not
update application Services or existing load balancer bandwidth. Oracle bills
bandwidth at the greater of the configured minimum or actual per-minute usage,
plus the load balancer base charge; the maximum is a ceiling, not a continuous
100 Mbps allocation. Always Free-only accounts cannot raise the 10 Mbps cap.
See Oracle's [bandwidth settings and billing](https://docs.oracle.com/en-us/iaas/Content/Balance/Tasks/managingloadbalancer_topic-Creating_Load_Balancers.htm).

## Verification and DNS cutover

Use the Service's external IP to verify HTTPS and routing before changing DNS:

```bash
curl --fail --resolve 'sg2027wedding.com:443:<lb-ip>' https://sg2027wedding.com/
curl --fail --resolve 'www.sg2027wedding.com:443:<lb-ip>' https://www.sg2027wedding.com/
curl --fail --resolve 'sg2027wedding.com:443:<lb-ip>' https://sg2027wedding.com/<react-client-route>
curl --fail --resolve 'sg2027wedding.com:443:<lb-ip>' https://sg2027wedding.com/api/<known-api-route>
```

Verify a real asset path, React client route, and API response, healthy workloads,
listener certificates, and healthy load balancer backends. Do not use `-k`. Then
change Namecheap `@` and `www` A records to the load balancer IP. Remove conflicting
records, including stale AAAA records if IPv6 was set, and retain certificate
validation records. Verify both hostnames through normal DNS after propagation.
Record the previous DNS values for rollback.

Keep `module.site`, `site/index.html`, `certificate_id`, `OCI_CERTIFICATE_ID`,
and the existing site outputs until the new application works on both domains
after DNS propagation. Their later removal is a separate change: review its
destruction plan for only the old wedding Object Storage/API Gateway resources.
Do not remove shared cluster infrastructure or either worker pool during cleanup.

The legacy static-site module freezes its existing index object's `source`
while the placeholder is retained. The OCI provider includes the file's local
modification time in this field, which otherwise proposes a replacement on each
fresh checkout. Changes to the placeholder HTML are intentionally not published
during migration. Remove that lifecycle rule before using this legacy module
for a site whose HTML should be updated again.

For wedding teardown, delete only its Kubernetes resources and wait for its
load balancer to disappear before destroying wedding infrastructure. The shared
control plane and Personal OS state must remain. For whole-cluster teardown,
remove both apps' load-balancer Services and their load balancers first.

## Shared database

Both applications use the private PostgreSQL 16 VM owned by `environments/shared`.
Follow [database setup](database.md) to deploy it and install this application's
namespace-local `database-credentials` Secret. Each app has a separate database
and restricted role. The API imports `JDBC_URL`, `DB_USERNAME`, and `DB_PASSWORD`,
and mounts the public CA at `/etc/database/root.crt` for `sslmode=verify-full`.
The optional secret supports the transition; database-dependent API images must
validate configuration at startup and use the PostgreSQL JDBC driver. Application
code and schema migrations are maintained in the application repository.
