# Shared Autonomous Database

`environments/shared` owns one paid, serverless Autonomous Transaction Processing
database for Personal OS and SG-Wedding. It uses Oracle Database 19c, 2 ECPUs,
20 GB storage, and the included license. Compute and storage autoscaling are
disabled. These settings incur OCI compute, storage, and backup charges; this
is not an Always Free database. See Oracle's [compute and storage model](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-compute-models.html).

The database has a private endpoint in the existing shared VCN, in a dedicated
`10.20.80.0/24` subnet with no internet route. Its empty subnet security list and
stateful NSG allow only TCP 1521 from `10.20.30.0/24`, the worker subnet used by
both application pools. Existing worker TCP egress already permits this traffic.
Flannel sends traffic outside its pod network through the workers, so the allow
rule uses the worker CIDR. There is no public database endpoint and no inbound
rule for Database Actions, APEX, or ORDS on 443. See Oracle's [private endpoint
network requirements](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/private-endpoints-autonomous.html).

This provides access from the shared workers, not isolation between Kubernetes
namespaces. Use a separate database user/schema for each app. The two apps must
not share ADMIN or receive privileges on each other's schema.

## Deploy

Extend the Terraform automation identity's existing network and state-bucket
permissions with this compartment policy (qualify the group with its identity
domain if required):

```text
Allow group TerraformDeployers to manage autonomous-database-family in compartment <compartment>
```

For GitHub Actions, add the production environment secret
`SHARED_DATABASE_ADMIN_PASSWORD`. Use 12-30 characters with uppercase, lowercase,
and a number; do not include double quotes or `admin` in any casing. Optional
production environment variables are `SHARED_DATABASE_NAME` (default `sharedapps`,
unique in the tenancy/region), `SHARED_DATABASE_ECPU_COUNT` (default `2`), and
`SHARED_DATABASE_STORAGE_GB` (default `20`). Run **Deploy OCI infrastructure** with
target `shared` and `apply=false`, review the plan, then run with `apply=true`.
The `all` target also deploys the database before either application environment.

For local Terraform, initialize the shared backend as described in
[bootstrap.md](bootstrap.md), copy `terraform.tfvars.example` to the ignored
`terraform.tfvars`, and enter the password without putting it in shell history:

```bash
read -rs -p 'Shared database ADMIN password: ' TF_VAR_database_admin_password
printf '\n'
export TF_VAR_database_admin_password
terraform -chdir=environments/shared plan -out=shared.tfplan
terraform -chdir=environments/shared apply shared.tfplan
unset TF_VAR_database_admin_password
```

Sensitive input hides the password from normal Terraform output, but the OCI
provider stores it in state and saved plans. Restrict access to the versioned
state bucket, keep plans private, and do not upload them as CI artifacts. The
password is never exported as a Terraform output. Keep the same secret available
for subsequent shared plans; update it deliberately when rotating ADMIN.

The plan should add the database, subnet, route table, security list, NSG, and
TLS ingress rule. It must not replace existing networking or either OKE pool.
The database uses `prevent_destroy = true`: intentional replacement or teardown
requires a separate reviewed change to remove that protection. Keep the resource
block and shared state while either application uses this database; removing the
resource block also removes Terraform's lifecycle protection.

If subnet layouts change, update `database_client_cidrs` and
`database_subnet_cidr` in the shared root's local tfvars, or add corresponding
workflow environment inputs. Do not add a dependency on application state to the
shared root. The current defaults work whether the database or cluster is
created first. A new worker subnet must also have suitable outbound rules.

## Connect both applications

After applying, connection metadata is available from shared state:

```bash
terraform -chdir=environments/shared output -raw database_id
terraform -chdir=environments/shared output -raw database_private_endpoint
terraform -chdir=environments/shared output -json database_connection_strings
```

Select a `profiles` entry with `protocol=TCPS`, `tls_authentication=SERVER`,
`consumer_group=LOW`, and `host_format=FQDN`. Use its `value` as the connection
descriptor and prefix it with `jdbc:oracle:thin:@` for `JDBC_URL`. Check that the
descriptor uses port 1521 and certificate hostname verification
(`ssl_server_dn_match=yes`). Do not use a `MUTUAL` profile: it requires a client
wallet and port 1522, which is not opened. TLS remains encrypted and validates
the server certificate even though a client wallet is unnecessary. See Oracle's
[JDBC Thin connections with TLS](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/connect-jdbc-thin-tls.html).

Use a current Oracle JDBC driver compatible with the Java runtime, with the
standard trusted CA certificates. Connections must originate from an allowed
worker, or from a deliberately configured private administration path into the
VCN. A developer laptop or GitHub-hosted runner has no direct access. The default
NSG does not enable the web SQL console; use a SQL client from the permitted
private network to perform administration.

As ADMIN, create application users once, substituting unique passwords locally:

```sql
CREATE USER PERSONAL_OS IDENTIFIED BY "<unique-personal-os-password>"
  DEFAULT TABLESPACE DATA QUOTA 5G ON DATA;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO PERSONAL_OS;

CREATE USER SG_WEDDING IDENTIFIED BY "<unique-wedding-password>"
  DEFAULT TABLESPACE DATA QUOTA 5G ON DATA;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO SG_WEDDING;
```

These statements are a bootstrap example, not an idempotent migration. Use app
passwords that meet Oracle's password rules and contain no double quotes. The
5 GB quotas cap each schema's initial table/index allocation within the shared
20 GB database; adjust them as needed. Grant additional schema creation
privileges only if migrations require them. Do not grant DBA, `ANY` privileges,
or access to the other application's tables. Terraform creates the managed
database and networking; it does not connect as ADMIN or manage SQL users.

Create a `database-credentials` Kubernetes Secret independently in each namespace,
with these keys:

| Key | Personal OS | SG-Wedding |
| --- | --- | --- |
| `JDBC_URL` | Shared TLS JDBC URL | Same TLS JDBC URL |
| `DB_USERNAME` | `PERSONAL_OS` | `SG_WEDDING` |
| `DB_PASSWORD` | Personal OS user's password | Wedding user's password |

For example, use a private temporary env file outside the repository, populated
without echoing passwords to the terminal:

```bash
umask 077
credentials_file=$(mktemp)
# Populate this file securely with JDBC_URL, DB_USERNAME, and DB_PASSWORD.
# Each key uses KEY=value syntax, without shell quotes around the value.
kubectl -n personal-os create secret generic database-credentials \
  --from-env-file="$credentials_file" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$credentials_file"
# Repeat for sg-wedding using that application's own credentials.
```

Create the namespaces first using their `namespace.yaml` files if necessary, and
use the cluster kubeconfig documented in each application's guide. Both API
Deployments import this namespace-local secret; frontends do not receive it. The
secret reference is optional to allow existing APIs to run during transition.
Before deploying a database-dependent API image, create its secret and ensure
the application consumes these variables and validates them on startup. The
application source and Oracle JDBC dependencies live outside this repository.
Schema migrations run separately under each application's own user.

Environment variables are read when pods start. After installing or rotating a
secret, restart the relevant deployment (`personal-os-api` or `sg-wedding-api`)
and check its rollout. Verify a real database operation through each API, check
that each user can access its own tables and cannot read the other schema, and
confirm readiness becomes unhealthy when the database is unavailable.

## Validation

```bash
terraform fmt -check -recursive
terraform -chdir=environments/shared init -backend=false
terraform -chdir=environments/shared validate
terraform -chdir=environments/shared test
```

The tests use a mocked OCI provider, create no cloud resources, and require no
password secret or OCI credentials. They check private networking, the database's
subnet/NSG attachment, TLS source restrictions, fixed sizing, and invalid inputs.
They do not prove service quota, regional availability, or application access;
those require reviewing a real plan and verifying connectivity after deployment.
