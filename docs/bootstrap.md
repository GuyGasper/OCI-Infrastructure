# Bootstrap and DNS

## 1. Local and OCI prerequisites

Install Terraform and configure the OCI provider using `~/.oci/config` (or the
provider's supported environment variables). The principal running Terraform
needs permission to manage virtual networks, API Gateway, Object Storage, and
Certificates in the target compartment. A tenancy administrator can use a group
policy equivalent to:

```text
Allow group InfrastructureAdmins to manage virtual-network-family in compartment <compartment>
Allow group InfrastructureAdmins to manage api-gateway-family in compartment <compartment>
Allow group InfrastructureAdmins to manage object-family in compartment <compartment>
Allow group InfrastructureAdmins to manage leaf-certificate-family in compartment <compartment>
```

Use a dedicated compartment (for example `personal-platform`) rather than the
root compartment. Do not commit OCI keys, OCIDs in `.auto.tfvars`, certificate
private keys, or Terraform state.

## 2. Create the remote state bucket

The state bucket has to exist before Terraform can use it as a backend, so this
is a one-time bootstrap operation:

1. In OCI, open **Storage > Object Storage > Buckets** in the infrastructure
   compartment.
2. Create a private Standard bucket such as `terraform-state`.
3. Enable object versioning. Keep Oracle-managed encryption unless you already
   manage a Vault key.
4. Record the bucket name and the tenancy's Object Storage namespace.

The two roots store state at distinct object keys:

```text
terraform-state/shared/terraform.tfstate
terraform-state/wedding/terraform.tfstate
```

The native OCI backend provides state locking. Never make the state bucket
public: state can contain infrastructure identifiers and sensitive values.

## 3. Deploy the shared network locally

```bash
cd environments/shared
cp terraform.tfvars.example terraform.tfvars
# Replace the example values, then:
terraform init -reconfigure \
  -backend-config="bucket=terraform-state" \
  -backend-config="namespace=<object-storage-namespace>" \
  -backend-config="region=us-chicago-1" \
  -backend-config="key=shared/terraform.tfstate"
terraform apply
terraform output
```

This VCN exposes only TCP 443 inbound to resources attached to the gateway NSG.
There is no SSH rule and no compute instance. The wedding root reads the subnet
and NSG identifiers directly from this remote state.

## 4. Deploy the placeholder locally

```bash
cd ../wedding
cp terraform.tfvars.example terraform.tfvars
# Replace the example values, then:
terraform init -reconfigure \
  -backend-config="bucket=terraform-state" \
  -backend-config="namespace=<object-storage-namespace>" \
  -backend-config="region=us-chicago-1" \
  -backend-config="key=wedding/terraform.tfstate"
terraform apply
terraform output -raw site_url
```

The URL is immediately usable with OCI's generated hostname and managed default
TLS certificate. The bucket is public-read because API Gateway's simple HTTP
backend cannot sign Object Storage requests. Only publish non-sensitive website
assets to this bucket.

## 5. Configure GitHub Actions

### OCI automation identity

Create a dedicated OCI user such as `github-terraform`, add an API signing key
to that user, and place it in a group such as `TerraformDeployers`. Do not use
your personal OCI key. The group needs policies equivalent to:

```text
Allow group TerraformDeployers to manage virtual-network-family in compartment <compartment>
Allow group TerraformDeployers to manage api-gateway-family in compartment <compartment>
Allow group TerraformDeployers to manage object-family in compartment <compartment>
Allow group TerraformDeployers to read leaf-certificate-family in compartment <compartment>
```

The `object-family` grant includes access to the state bucket and wedding site
bucket. Narrow it with OCI policy conditions later if other buckets share this
compartment.

### GitHub production environment

In the GitHub repository, open **Settings > Environments**, create an
environment named `production`, and configure a required reviewer if your
repository visibility and GitHub plan support it. Restrict deployments to the
default/protected branch.

Add these environment **secrets**:

| Secret | Value |
| --- | --- |
| `OCI_TENANCY_OCID` | Tenancy OCID |
| `OCI_USER_OCID` | Dedicated automation user OCID |
| `OCI_FINGERPRINT` | API signing key fingerprint |
| `OCI_PRIVATE_KEY` | Entire PEM private key, including BEGIN/END lines |

Add these environment **variables**:

| Variable | Example |
| --- | --- |
| `OCI_REGION` | `us-chicago-1` |
| `OCI_COMPARTMENT_ID` | `ocid1.compartment.oc1..…` |
| `OCI_NAMESPACE` | Tenancy Object Storage namespace |
| `TF_STATE_BUCKET` | `terraform-state` |
| `OCI_CERTIFICATE_ID` | Optional certificate OCID; leave unset initially |

The private key exists only on the ephemeral runner and is not committed or
uploaded as an artifact.

### Run the deployment

1. Push the repository to GitHub.
2. Open **Actions > Deploy OCI infrastructure > Run workflow**.
3. On the first run, select `apply=true`. A plan-only first run cannot read the
   shared state because it does not exist yet.
4. Approve the `production` environment deployment if protection is enabled.
5. The workflow applies shared networking first, then plans and applies the
   wedding site using the newly written shared state.
6. For later reviews, run with `apply=false`; run again with `apply=true` after
   checking the plan log.

Pull requests and pushes to `main` also run formatting and provider-schema
validation without receiving OCI credentials. Applies are intentionally manual;
there is no unattended apply on every push.

## 6. Connect `sg2027wedding.com`

Do this after the generated URL works:

1. Obtain a certificate in OCI Certificates for `sg2027wedding.com` (and
   optionally `www.sg2027wedding.com`). Complete the certificate's DNS
   validation by adding the requested validation record in Namecheap Advanced
   DNS.
2. Set the GitHub environment variable `OCI_CERTIFICATE_ID` (or local
   `certificate_id`) to that certificate's OCID and apply again. API Gateway
   will use the hostname encoded by the certificate.
3. Read `gateway_public_ip` from `terraform output`.
4. In Namecheap Advanced DNS, add an `A` record with host `@` and that IP. For
   `www`, either provision it on a separate certificate/gateway or use
   Namecheap's redirect record to the apex domain.
5. Keep Namecheap nameservers unless you intentionally migrate the entire zone
   to OCI DNS. Remove conflicting parking/redirect records and use a short TTL
   (for example 300 seconds) during cutover.

DNS alone does not enable HTTPS: applying a certificate matching the custom
hostname before adding the final A record avoids a certificate-name failure.

## Next production steps

- Consider a customer-managed OCI Vault key for state encryption if your threat
  model requires key ownership beyond Oracle-managed encryption.
- Replace the public-read bucket pattern with a build/deployment architecture
  suited to the final frontend. OCI Load Balancer/CDN or another edge service is
  generally a better fit for a multi-asset SPA; retain API Gateway for APIs.
- Add budgets, logging, alarms, and a WAF/rate-limit policy before collecting
  RSVPs or other personal data.
- Create a separate `environments/personal-os` root and private application
  subnets. Do not put databases or internal APIs in this public gateway subnet.
