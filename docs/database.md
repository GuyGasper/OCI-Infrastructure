# Shared private PostgreSQL

Shared state owns a dedicated Ubuntu 24.04 ARM64 VM running PostgreSQL 16 for
Personal OS and SG-Wedding. Its A1 shape is fixed at **1 OCPU and 6 GB RAM**;
boot and persistent data volumes are **50 GB each**, balanced performance.
The VM has no public IP. The default database address is `10.20.80.10:5432`.

Budget approximately **$20–25/month before tax**, assuming full paid pricing,
730 hours/month, and modest backup storage. Compute is about $13.87/month and
100 GB of balanced volumes about $4.25/month; daily compressed backups add
usage-based Object Storage charges. Free allowances may reduce actual charges,
but are not assumed. Existing OKE, NAT, and service gateways are reused. Bastion
has no service charge. This is one server: maintenance or failure causes downtime.
This estimate excludes the stopped legacy Oracle database's remaining storage
and backup charges. See [OCI compute pricing](https://www.oracle.com/cloud/compute/pricing/),
[block volume pricing](https://www.oracle.com/cloud/storage/block-volumes/pricing/),
and [Object Storage pricing](https://www.oracle.com/cloud/storage/object-storage/pricing/).

## Before applying

The Personal OS network must already provide one unblocked NAT gateway and one
service gateway for all regional Oracle services. Shared state discovers them
through OCI without reading application state. Both application worker pools use
`10.20.30.0/24`; database ingress allows TLS on 5432 from that subnet. Bastion's
private endpoint gets separate /32 rules for database TLS and VM SSH on 22.
Outbound 80/443 supports Ubuntu packages and OCI backup APIs. Internet egress
uses NAT; regional Object Storage uses the service gateway. The empty database
subnet security list delegates access to the NSG.

The Terraform identity needs these permissions in addition to its existing
network and state-bucket permissions. Substitute the actual group/compartment,
and qualify identity domains where required:

```text
Allow group TerraformDeployers to manage instance-family in compartment <compartment>
Allow group TerraformDeployers to manage volume-family in compartment <compartment>
Allow group TerraformDeployers to manage object-family in compartment <compartment>
Allow group TerraformDeployers to manage bastion-family in compartment <compartment>
Allow group TerraformDeployers to read autonomous-database-family in compartment <compartment>
Allow group TerraformDeployers to manage dynamic-groups in tenancy
Allow group TerraformDeployers to manage policies in tenancy
```

The two tenancy grants allow Terraform to create the VM's backup identity and
bucket-scoped policy. They require a tenancy administrator to grant them; the
VM itself receives only create/read/inspect object access to its backup bucket,
with no overwrite or delete permission. The regional Object Storage service has
bucket-scoped lifecycle permissions. No OCI API key is installed on the VM.

Set these GitHub **production environment variables**:

| Variable | Value |
| --- | --- |
| `SHARED_POSTGRES_IMAGE_ID` | Pinned Canonical Ubuntu **24.04 aarch64** platform image in your OCI region; not an OKE image |
| `SHARED_POSTGRES_SSH_PUBLIC_KEY` | Contents of `/home/gasperg/.ssh/id_ed25519.pub`; public key only |
| `SHARED_POSTGRES_AVAILABILITY_DOMAIN` | VM/data volume AD; falls back to `PERSONAL_OS_AVAILABILITY_DOMAIN` |
| `SHARED_BASTION_CLIENT_CIDRS` | Existing JSON array of this PC's public IPv4 /32 |
| `SHARED_LEGACY_AUTONOMOUS_DATABASE_ID` | OCID of the stopped database left by the cancelled apply; keep set until approved cleanup |

The values selected for this installation are saved locally in the ignored
`.local/shared-postgres-github-variables.json`. They contain the approved WSL
public key and region-compatible Ubuntu image. Keep the SSH **private** key on
this PC. The existing `OCI_TENANCY_OCID` secret supplies the backup IAM tenancy.
`SHARED_DATABASE_ADMIN_PASSWORD`, `SHARED_DATABASE_NAME`,
`SHARED_DATABASE_ECPU_COUNT`, and `SHARED_DATABASE_STORAGE_GB` are no longer used.

Run **Deploy OCI infrastructure**, target `shared`, with `apply=false`, then
review and run with `apply=true`. After recovery imports for the cancelled run,
the expected plan is **12 additions, 3 updates, 0 deletions**. The updates change
the existing database route table, worker database port, and Bastion egress rules.
The original shared gateway network and application pools must not be replaced.
Do not cancel an apply after OCI has accepted a resource creation request;
OCI creation can continue after the runner stops.

For local Terraform, initialize the existing shared backend and use:

```bash
terraform -chdir=environments/shared plan \
  -var-file=../../.local/shared-postgres.tfvars.json -out=../../.local/shared-postgres.tfplan
terraform -chdir=environments/shared apply ../../.local/shared-postgres.tfplan
```

For a completely new tenancy, first apply only `module.network` in shared state
(`terraform apply -target=module.network` with configured shared inputs), deploy
Personal OS to create its OKE gateways, then apply the complete shared root.
The normal `all` workflow assumes this network bootstrap already exists.

## First boot and application configuration

Terraform completing means the VM and volume attachment exist; first-boot setup
continues through `postgres-bootstrap.service`. It retries failed package installs
and waits for the persistent volume attachment. It refuses to format the boot
disk, an unexpected filesystem, or an unrecognized existing data disk. PostgreSQL
is prevented from starting without the `/srv/postgres` mount.

Through the [Bastion SSH tunnel](bastion.md), run:

```bash
ssh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@127.0.0.1
sudo systemctl status postgres-bootstrap.service
sudo journalctl -u postgres-bootstrap.service --no-pager
sudo test -f /srv/postgres/bootstrap-complete
sudo -u postgres psql
```

Bootstrap generates separate restricted login roles and owned databases named
`personal_os` and `sg_wedding`. Each app can create its own schema objects;
it has no superuser, role creation, database creation, or replication privilege.
Both host authentication and SQL CONNECT permissions deny cross-application
access. Administration uses `sudo -u postgres psql` with local peer authentication.
This VM/subnet is shared infrastructure; Kubernetes namespace isolation alone
does not isolate database traffic.

Passwords are generated **on the VM**, stored in root-only files under
`/srv/postgres/credentials`, and preserved on reruns. They never pass through
Terraform inputs, state, or outputs. The private CA also persists on the data
volume. The server certificate renews automatically before expiry. Applications
use `sslmode=verify-full` with the public CA mounted at `/etc/database/root.crt`.

Create the two namespaces and configure your cluster kubeconfig using the app
guides. Open the local VM SSH tunnel on port 2222, connect once interactively to
verify its host key, then run from WSL:

```bash
python3 scripts/install-postgres-secrets.py --identity ~/.ssh/id_ed25519
```

The helper verifies SSH host keys and transfers the credentials in memory into
namespace-local `database-credentials` Secrets. Each contains `JDBC_URL`,
`DB_USERNAME`, `DB_PASSWORD`, and `DB_SSL_ROOT_CERT`. Both API manifests import
the secret and mount its CA; frontends receive neither. Apply the current
application manifests and restart the APIs when their code is ready. Existing
images can continue without the optional secret. Database-dependent images
must validate configuration at startup and use the **PostgreSQL JDBC driver**;
application code and schema migrations live in separate repositories.

Use a small pool per API (for example 10 connections); the server permits 60
connections total, including rollouts, maintenance, and backups. Verify real
read/write requests from both apps and their readiness behavior after deployment.

## Backups and operations

`postgres-backup.timer` runs daily around **03:00 UTC** and 15 minutes after boot.
It dumps both databases in custom format, restores each into a temporary database
as the corresponding restricted application role, and checks a SQL marker. It then archives dumps, global roles, credentials, TLS
material, and cluster configuration; uploads to private `shared-postgres-backups`;
and downloads the archive to verify SHA256. Only then does it mark the backup
successful. Temporary restores and local archives are removed automatically.
Object Storage expires backups after eight days, leaving roughly a week of
restore points; lifecycle deletion is asynchronous. Archives contain secrets:
restrict bucket access and never download them into tracked directories.

```bash
sudo systemctl start postgres-backup.service
sudo systemctl status postgres-backup.service
sudo journalctl -u postgres-backup.service --no-pager
sudo cat /srv/postgres/last-successful-backup
sudo systemctl list-timers 'postgres-*'
sudo systemctl --failed
```

IAM changes may take time to propagate. After applying, verify the first actual
OCI upload and readback succeeds before relying on backups. The CI integration
test performs real PostgreSQL dumps/restores and uses a fake Object Storage
client; it does not prove live OCI permissions or first-boot ARM behavior.

The hourly health unit fails if PostgreSQL is unavailable, disk use exceeds 80%,
or no off-VM backup succeeded within 30 hours. Failures appear in systemd/journal;
external email/push alerts are **not configured**. Monitor these units, configure
notifications before relying on unattended operation, and check security updates
and reboot requirements. Security package updates are enabled. Bootstrap script
changes do not silently replace or reconfigure an existing VM: copy reviewed
scripts/configuration through Bastion and rerun the service deliberately.
Changes to worker/Bastion private source addresses must also update the guest
configuration/firewall/HBA; changing only Terraform NSG rules is insufficient.

Backup/restore staging needs free space in addition to live data; the backup
requires at least 5 GB free and conservatively reserves twice the current
database sizes plus 2 GB for staging. Large databases require more storage. Monitor growth and expand storage before approaching capacity. Daily logical
backups permit about 24 hours of data loss; there is no WAL-based point-in-time
recovery, standby, automatic failover, or cross-region backup. Restore testing
on the same server does not replace a periodic full disaster-recovery exercise.

## Recovering and removing resources

The VM, persistent data volume, backup bucket, and retained Oracle database use
`prevent_destroy`. Keep their resource blocks; removing a block also removes
its lifecycle protection. Image/AD changes that replace the VM require a reviewed
recovery/migration change. Keep the data volume independently of the boot disk.

For logical recovery, stop application writes, fetch a known-good archive using
an authorized OCI identity, verify its SHA256 against object metadata, and extract
into a root-only temporary directory. Do not execute SQL or extract paths from
untrusted archives. Restore global roles before restoring app databases with
`pg_restore --exit-on-error`; preserve database ownership and revoke PUBLIC
CONNECT again. Restore the matching credentials and CA, reissue a server
certificate if the VM IP changed, then reinstall Kubernetes secrets. Do not drop
live databases until the chosen restore has been verified independently. A new
empty server can be bootstrapped and its generated credentials replaced with
the archived credentials after the archived roles/databases are restored.

The cancelled apply's unused Autonomous Database is imported as
`oci_database_autonomous_database.legacy[0]` and must remain **STOPPED**. Its
configuration ignores updates and refuses deletion. It is never recreated by
the PostgreSQL path. Keep `SHARED_LEGACY_AUTONOMOUS_DATABASE_ID` set on every plan;
unsetting it is blocked by destroy protection. Removing the remaining Oracle
storage/backup charges requires separately approved termination and a reviewed
Terraform cleanup. Do not restart that database while testing PostgreSQL.
