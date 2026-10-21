# SQL Developer access through OCI Bastion

The optional managed Bastion in shared state lets SQL Developer on your PC reach
the private Autonomous Database over a temporary SSH tunnel. Application traffic
continues to use the private database endpoint directly.

```text
SQL Developer -> local SSH tunnel -> OCI managed Bastion -> private DB:1521
```

Bastion has a dedicated private `10.20.90.0/28` subnet. Its security list permits
only outbound TCP 1521 to the database subnet and TCP 443 to regional Oracle
services. Its route table reuses the existing OKE service gateway, with no NAT
or internet default route. A database NSG rule permits TCP 1521 from only the
Bastion's private endpoint /32. The database subnet and application worker rules
are unchanged. No jump VM or public database listener is created.

## Before applying

Personal OS networking must already be deployed: it owns the existing VCN service
gateway, which must be available and enabled for all regional Oracle services.
The shared root discovers this gateway using OCI, without reading application
state or transferring gateway ownership. Do not destroy that gateway while
Bastion uses it. For a new deployment, bootstrap shared infrastructure with
Bastion disabled, deploy Personal OS, then enable Bastion. See Oracle's
[Bastion prerequisites](https://docs.oracle.com/en-us/iaas/Content/Bastion/Tasks/create-bastion.htm).

Confirm `10.20.90.0/28` is unused. Change `bastion_subnet_cidr` locally if needed;
the Actions workflow currently uses its default.

Add this policy for the Terraform automation group, in addition to its existing
network, database, and state-bucket permissions:

```text
Allow group TerraformDeployers to manage bastion-family in compartment <compartment>
```

Your own OCI identity also needs permission to create/read/delete sessions and
read the network resources. If it does not already have administrator access,
an administrator can use a group policy equivalent to:

```text
Allow group DatabaseAdministrators to use bastion in compartment <compartment>
Allow group DatabaseAdministrators to manage bastion-session in compartment <compartment>
Allow group DatabaseAdministrators to read virtual-network-family in compartment <compartment>
Allow group DatabaseAdministrators to read instances in compartment <compartment>
Allow group DatabaseAdministrators to inspect work-requests in compartment <compartment>
```

Replace the group and compartment names and qualify identity domains as needed.
Port forwarding to the database does not require an instance agent or managed
SSH session. See Oracle's [Bastion IAM reference](https://docs.oracle.com/en-us/iaas/Content/Bastion/Reference/bastionpolicyreference.htm).

In GitHub **Settings > Environments > production > Environment variables**, add
`SHARED_BASTION_CLIENT_CIDRS` with a JSON array of your public IPv4 /32 addresses:

```json
["203.0.113.10/32"]
```

Replace the example with your actual public address. You can check it in
PowerShell using:

```powershell
Invoke-RestMethod -Uri 'https://api4.ipify.org'
```

The address may change with your ISP or VPN. Other devices behind the same router
can share this public address, so sessions also require OCI authorization and an
SSH key. Never commit your private key. Only individual IPv4 /32 entries are
accepted, with at most 20 addresses. With the variable unset or `[]`, Terraform
does not create Bastion or its networking. Keep the variable set on later runs;
clearing it will plan removal of Bastion and its administration path.

For local deployment, set `bastion_client_cidrs = ["<your-public-ip>/32"]` in the
ignored `environments/shared/terraform.tfvars`.

Push the changes and run **Deploy OCI infrastructure**, target `shared`, with
apply unchecked. Adding Bastion to an existing database adds five resources: the
Bastion, private subnet, route table, security list, and database ingress rule.
If the database is also new, expect eleven additions total. Existing gateway,
worker, and database resources must not be replaced. Apply after reviewing the
plan. Terraform owns the Bastion; temporary sessions are created on demand and
are not part of Terraform state.

## Create a session after applying

1. On this PC, create or select an SSH key pair. For a dedicated key, run
   `ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\oci-db-bastion"` in
   PowerShell and protect it with a passphrase. Share only the `.pub` file.
2. In the OCI Console, find the Bastion named `sharedDatabase` in your compartment.
   Its OCID is also exported as `database_bastion_id` from shared state.
3. Create a session of type **SSH port forwarding**, not Managed SSH or SOCKS.
4. Set the target to the Autonomous Database's **private IP**, port **1521**.
   Get the IP from the database's Network information or the shared output
   `database_private_ip`. Use an IP target: Bastion FQDN/SOCKS support is disabled.
5. Upload/paste your SSH public key. Choose a session lifetime of up to three
   hours (10800 seconds).
6. Once the session is active, choose **Copy SSH command**. Replace the private
   key placeholder with the private key path on this PC and the local port with
   **11521**. Bind the local forwarding listener to `127.0.0.1`; the forwarding
   portion should look like `-L 127.0.0.1:11521:<database-private-ip>:1521`.
7. Run that command in a Windows PowerShell terminal and leave it open. It
   establishes a tunnel and normally does not return a shell prompt. Keep normal
   SSH host-key verification enabled. Closing it ends your local tunnel; sessions
   also expire automatically and can be deleted early in OCI.

Use Windows OpenSSH for SQL Developer running on Windows, so the tunnel and SQL
Developer use the same local network stack. OCI documents the
[port-forwarding connection steps](https://docs.oracle.com/en-us/iaas/Content/Bastion/Tasks/connect-port-forwarding.htm).

## Configure SQL Developer and preserve TLS verification

Use the database's TLS connection profile (`TCPS`, `SERVER`, `LOW`, `FQDN`) as
described in [database setup](database.md). Keep its service name and security
parameters, including `ssl_server_dn_match=yes`. A tunnel changes where traffic
goes; it does not change the database certificate's identity. Do not disable
certificate checking to work around a hostname error.

One way to keep the original database hostname while using a local tunnel:

1. Note the `HOST` in that private TLS connection descriptor.
2. Using an administrator text editor, add this entry to the Windows hosts file
   `C:\Windows\System32\drivers\etc\hosts`:

   ```text
   127.0.0.1 <original-private-database-hostname>
   ```

3. In SQL Developer, use its custom JDBC URL connection option. Prefix the TLS
   descriptor with `jdbc:oracle:thin:@`, retain the original `HOST`, and change
   only its `PORT` from `1521` to local port `11521`. This routes through localhost
   while retaining the database hostname for certificate verification.
4. Connect as `ADMIN` with the password stored in your password manager, using
   the normal database role. Create the separate application users from
   [database setup](database.md), then use their accounts for application work.

Keep the original private connection descriptor in the applications' Kubernetes
secrets, with port 1521. The hosts entry and port 11521 are only for this PC.
Remove the hosts entry when you no longer need this tunnel configuration.

The network rules and mocked tests can be checked before deployment. The SSH
session, SQL Developer connection, and certificate verification must be tested
against the live database after applying.
