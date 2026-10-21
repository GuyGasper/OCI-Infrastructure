# Personal OS: OKE development environment

`environments/personal-os` owns OKE infrastructure and private container
repositories in `personal-os/terraform.tfstate`. Personal OS deploys directly to
Kubernetes; it does not create a static Object Storage site or API Gateway. The
application load balancer and TLS listener are created by the Kubernetes Service
after the cluster and application images are ready.

This environment also owns the shared OKE control plane and private worker
network used by SG-Wedding. Wedding adds its own managed worker pool to this
cluster, with its own namespace, load balancer, certificate, and image
repositories. The OCI cluster keeps its existing `personal-os` name and state
ownership; it is not renamed or recreated.

## Architecture

```text
personal-os.tech / www.personal-os.tech
  -> public OCI flexible load balancer :443 (TLS termination)
     -> React build served by unprivileged Nginx :8080 in OKE
        /api/* -> Java API ClusterIP service :8080 (prefix preserved)
        /*     -> React assets / SPA fallback
```

The default is OKE Basic with one `VM.Standard.A1.Flex` managed worker (1 OCPU,
6 GiB RAM, 50 GiB boot volume). This is a development setup: node failure and
maintenance can interrupt service. Both application images must support
`linux/arm64`. Change the flex shape, matching image, CPU, and memory together
if you need x86. The load balancer has a 10 Mbps minimum and can scale up to
100 Mbps. Bandwidth beyond the minimum can incur usage charges. Check tenancy
quotas, regional A1 capacity, and current pricing; this configuration does not
guarantee an Always Free deployment. Compute, storage, and the load balancer can
incur charges. Increase node CPU/memory if system pods or rollouts cannot fit.

Personal OS adds these regional subnets inside the shared VCN, with NSGs
controlling access. The existing gateway subnet stays in place.

| Subnet | CIDR | Access |
| --- | --- | --- |
| Kubernetes endpoint | `10.20.20.0/28` | Public API on 6443 restricted to admin CIDRs |
| Workers | `10.20.30.0/24` | Private; NAT for internet, service gateway for OCI services |
| Load balancer | `10.20.40.0/24` | Public HTTPS on 443 |

Confirm these ranges are free before applying. Workers have no public IP or
inbound SSH rule. Flannel overlay pods use `10.244.0.0/16`, and services use
`10.96.0.0/16`; neither may overlap the VCN or connected networks. This initial
Flannel configuration does not enforce Kubernetes NetworkPolicies. The Java
Service is internal, but reachable by other pods in this cluster.

SG-Wedding reuses the control plane, worker subnet/NSG, private outbound route,
NAT gateway, and service gateway. See [docs/sg-wedding.md](sg-wedding.md). Do not
tear down this cluster or its networking while wedding depends on it. The
module's `moved` blocks preserve the existing cluster, gateways, and private
route table when enabling reuse; a plan must not replace those resources.

Personal OS app pods select nodes labeled `workload=personal-os`; wedding pods
select `workload=sg-wedding`. With both pools at their default size, there are
two running workers total, each with 1 OCPU and 6 GiB RAM. Keeping both workers
running consumes both allocations even when one app is idle. These scheduling
rules separate compute usage, but do not provide Kubernetes network isolation.

## OCI prerequisites

The shared state and VCN must already exist. Use the same region and compartment
as shared networking; check the existing deployment rather than assuming the
sample region is correct.

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
certificate is not required to provision the cluster; TLS is configured during
application deployment. For local deployment:

```bash
cd environments/personal-os
terraform init -reconfigure \
  -backend-config="bucket=<existing-state-bucket>" \
  -backend-config="namespace=<namespace>" \
  -backend-config="region=<region>" \
  -backend-config="key=personal-os/terraform.tfstate"
terraform plan -out=personal-os.tfplan
# Review additions, costs, and unexpected modifications/deletes before apply.
terraform apply personal-os.tfplan
terraform output
```

For GitHub Actions, retain existing `production` secrets/variables and add:

| Environment variable | Value |
| --- | --- |
| `PERSONAL_OS_KUBERNETES_VERSION` | Selected supported version with `v` prefix |
| `PERSONAL_OS_NODE_IMAGE_ID` | Matching OKE ARM64 image OCID in the same region |
| `PERSONAL_OS_AVAILABILITY_DOMAIN` | Full availability domain name |
| `PERSONAL_OS_ADMIN_CIDRS` | JSON array such as `["<your-public-ip>/32"]` |
| `PERSONAL_OS_NODE_SHAPE` | Optional; default `VM.Standard.A1.Flex` |
| `PERSONAL_OS_NODE_OCPUS` | Optional; default `1` |
| `PERSONAL_OS_NODE_MEMORY_GBS` | Optional; default `6` |
| `PERSONAL_OS_NODE_COUNT` | Optional; default `1` |

Run **Deploy OCI infrastructure**, target `personal-os`, with apply disabled
first. Review the plan; then run with apply enabled. This provisions
infrastructure only; it does not build apps or apply Kubernetes manifests. The
workflow summary publishes the cluster ID and load balancer subnet/NSG IDs.
Obtain the public load balancer IP from Kubernetes after app deployment. The old
`PERSONAL_OS_CERTIFICATE_ID` variable is no longer used and can be removed from
the GitHub environment if present.

## Application image contracts

Application source and Docker builds belong in the Personal-OS application repo.
Terraform creates private OCIR repositories `personal-os/api` and
`personal-os/frontend`. Publish immutable versions or digests there.

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
API pod during rolling updates. The application CI/CD workflow waits for the API
rollout before updating the frontend so both services do not start rolling at
once. Runtime app secrets are injected separately. No database or app secrets
are defined by this scaffold.

## Connect, configure secrets, and deploy

Install OCI CLI, kubectl, Terraform, and Python 3 locally. Run the Terraform
`kubeconfig_command` output, then select that explicit kubeconfig:

```bash
export KUBECONFIG="$HOME/.kube/personal-os"
kubectl get nodes
kubectl apply -f kubernetes/personal-os/namespace.yaml
```

Create `ocir-pull` from a Docker configuration containing a dedicated read-only
OCIR user's auth token. Use `docker login <registry>` to populate that file
without putting the token in command history:

```bash
kubectl -n personal-os create secret generic ocir-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=<path-to-dedicated-docker-config.json>
kubectl -n personal-os create secret tls personal-os-tls \
  --cert=<full-certificate-chain.pem> --key=<private-key.pem>
```

The certificate must cover both `personal-os.tech` and `www.personal-os.tech`.
Supply the actual certificate chain and matching private key, or separately
configure OCI Certificates integration. Keep keys outside Git and rotate the TLS secret before expiry;
verify the served certificate after rotation. The Service follows Oracle's
[TLS and load-balancer annotations](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancers-subtopic.htm).

From the infrastructure repo root, generate an ignored local overlay:

```bash
python3 scripts/render-personal-os.py \
  --api-image '<registry>/<namespace>/personal-os/api:<version>' \
  --frontend-image '<registry>/<namespace>/personal-os/frontend:<version>'
kubectl kustomize .local/personal-os
kubectl apply --dry-run=server -k .local/personal-os
kubectl apply -k .local/personal-os
kubectl -n personal-os rollout status deployment/personal-os-api
kubectl -n personal-os rollout status deployment/personal-os-frontend
kubectl -n personal-os get service personal-os-web
```

The renderer reads `terraform output -json` from `environments/personal-os`, then
inserts its load balancer subnet/NSG and the published image references. If
Terraform ran only in Actions, initialize this same backend locally first. The
renderer never applies resources. Do not apply the base manifests directly:
they intentionally contain unresolved image and OCID values. ConfigMap content
hashing rolls out the frontend when Nginx configuration changes.

Kubernetes owns the load balancer; Terraform owns its subnet/security rules.
Do not edit the generated listener/backends manually in OCI. Only 443 is exposed;
HTTP-to-HTTPS redirection on port 80 is not configured initially.

The 10-100 Mbps bandwidth settings are Service annotations. An infrastructure
Terraform apply alone does not update an existing load balancer: deploy the
rendered application manifests using the current published image references to
apply the new range. Keep the minimum and maximum explicit so defaults do not
change during Kubernetes upgrades. See Oracle's
[bandwidth settings and billing](https://docs.oracle.com/en-us/iaas/Content/Balance/Tasks/managingloadbalancer_topic-Creating_Load_Balancers.htm).

## Verification and DNS cutover

Use the Service's external IP to verify HTTPS and routing before changing DNS:

```bash
curl --fail --resolve 'personal-os.tech:443:<lb-ip>' https://personal-os.tech/
curl --fail --resolve 'www.personal-os.tech:443:<lb-ip>' https://www.personal-os.tech/
curl --fail --resolve 'personal-os.tech:443:<lb-ip>' https://personal-os.tech/<react-client-route>
curl --fail --resolve 'personal-os.tech:443:<lb-ip>' https://personal-os.tech/api/<known-api-route>
```

Verify a real asset path, React client route, and API response, healthy workloads,
listener certificates, and healthy load balancer backends. Do not use `-k`. Then
change Namecheap `@` and `www` A records to the load balancer IP. Remove conflicting
records, including stale AAAA records if IPv6 was set, and retain certificate
validation records. Verify both hostnames through normal DNS after propagation.
Record the previous DNS values for rollback.

For eventual cluster teardown, delete the Kubernetes
LoadBalancer Service and wait for the OCI load balancer to disappear before
destroying cluster networking.

## Shared database

Both applications use the private Autonomous Transaction Processing database
owned by `environments/shared`. Follow [database setup](database.md) to deploy it,
create a separate application schema, and install `database-credentials` in this
application's namespace before deploying a database-dependent API image. The API
deployment imports `JDBC_URL`, `DB_USERNAME`, and `DB_PASSWORD` from that secret.
The reference is optional so existing API images can run during the transition;
database-dependent images must validate their required configuration at startup.
Application code must use the Oracle JDBC driver and consume these variables.
