# Personal OS bootstrap

The Personal OS placeholder reuses the shared VCN, API Gateway subnet, and HTTPS
network security group. It owns a separate public-read Object Storage bucket,
API Gateway, deployment, certificate binding, and Terraform state object.

## GitHub production environment

Add these environment variables in addition to the existing OCI configuration:

| Variable | Value |
| --- | --- |
| `PERSONAL_OS_CERTIFICATE_ID` | Active OCI certificate OCID for `personal-os.tech` and `www.personal-os.tech` |

The deployment workflow now prompts for a target. Select `personal-os`, run once
with apply disabled to inspect the plan, and then run again with apply enabled.
Its remote state is stored at `personal-os/terraform.tfstate` in the existing
private, versioned state bucket.

## Pre-DNS verification

After apply, use the gateway IP from the workflow summary:

```bash
curl --resolve "personal-os.tech:443:<gateway-ip>" https://personal-os.tech/
curl --resolve "www.personal-os.tech:443:<gateway-ip>" https://www.personal-os.tech/
```

Both calls must return the placeholder without `-k`. Then replace Namecheap's
parking/redirect records with `A` records for `@` and `www`, both pointing to
the gateway IP. Keep the certificate validation CNAME.

## Static placeholder limitation

This root currently uploads and serves only `/index.html` at `/`. The eventual
frontend repository should own its build and asset upload process. Before using
a multi-file build, extend the serving layer for asset paths, MIME types, cache
headers, and SPA fallback behavior; never publish Personal OS secrets or private
data in this public-read bucket.
