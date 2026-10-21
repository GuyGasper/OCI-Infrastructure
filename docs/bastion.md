# PostgreSQL administration through OCI Bastion

Managed Bastion provides expiring SSH tunnels from this PC to the private
PostgreSQL VM. Applications connect directly over the private worker network.
Bastion permits only configured public IPv4 /32 clients and uses a dedicated
private `10.20.90.0/28` subnet. Its egress allows VM SSH (22), database TLS (5432),
and regional Oracle services (443); it has no internet default route. The VM NSG
allows administration only from Bastion's private endpoint /32.

## Enable and authorize

Keep `SHARED_BASTION_CLIENT_CIDRS` set to a JSON array such as
`["203.0.113.10/32"]`, replacing the example with this PC's public address.
An empty array disables Bastion. Reapply shared state when your public IP changes.
Other devices behind the same router may share that public address; sessions
also require an authorized OCI identity and the SSH key. Use the existing WSL
key `/home/gasperg/.ssh/id_ed25519.pub` for sessions and VM administration.
Only the `.pub` key is shared; the private key remains in WSL.

The OCI identity creating sessions needs these equivalent compartment grants:

```text
Allow group DatabaseAdministrators to use bastion in compartment <compartment>
Allow group DatabaseAdministrators to manage bastion-session in compartment <compartment>
Allow group DatabaseAdministrators to read virtual-network-family in compartment <compartment>
Allow group DatabaseAdministrators to read instances in compartment <compartment>
Allow group DatabaseAdministrators to inspect work-requests in compartment <compartment>
```

Use actual group/compartment names and qualify identity domains as needed. See
[OCI Bastion IAM](https://docs.oracle.com/en-us/iaas/Content/Bastion/Reference/bastionpolicyreference.htm).
Port-forwarding sessions do not need the Managed SSH plugin in the VM.

## Open a VM SSH tunnel

1. After applying, open Bastion `sharedDatabase` in the OCI Console. Its OCID is
   also the shared Terraform output `database_bastion_id`.
2. Create an **SSH port forwarding** session, target `10.20.80.10`, port **22**.
   Use `database_private_ip` if the configured subnet differs.
3. Paste the approved WSL public key and choose a lifetime up to three hours.
4. Once active, copy the SSH command. In WSL use `~/.ssh/id_ed25519` for the private
   key and a loopback-only forwarding argument:
   `-L 127.0.0.1:2222:10.20.80.10:22`. Keep host-key verification enabled.
5. Leave that tunnel running. In a second WSL terminal connect with:

   ```bash
   ssh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@127.0.0.1
   ```

Verify the VM's SSH host key using a trusted OCI console connection before
accepting it the first time. Verify Bastion's host key too. Sessions expire
automatically and can be deleted early. If using the same key with a passphrase,
load it into your local SSH agent before running the secrets installer.

For full administration, use `sudo -u postgres psql` in this SSH shell. Check
bootstrap and backup status using [the database guide](database.md). No database
administrator password or public database listener is required.

## Connect a local PostgreSQL GUI

Use a PostgreSQL-capable client such as DBeaver or pgAdmin. Open a second Bastion
**SSH port forwarding** session to `10.20.80.10`, port **5432**, using the same public
key. Its SSH command should forward:

```text
-L 127.0.0.1:15432:10.20.80.10:5432
```

Copy the public CA certificate from `/srv/postgres/tls/root.crt` over your verified
VM SSH connection. Connect the GUI to `localhost:15432`, choose `personal_os` or
`sg_wedding` as both database and username, and use that app's root-only saved
password from `/srv/postgres/credentials/<database>.password`. Enable
**verify-full** TLS and select the CA file. The generated certificate includes
`localhost` and `127.0.0.1` specifically for these loopback tunnels; do not turn
off certificate verification. The database still authenticates each application
role and denies cross-database access.

For a Windows GUI, run its Bastion forwarding command in Windows OpenSSH using
an appropriate locally protected private key, or verify that Windows localhost
forwarding reaches the WSL tunnel on your setup. The VM's authorized key can
remain the WSL key; direct database forwarding uses the key chosen for that
Bastion session. Never expose the local listener on `0.0.0.0`.

See [OCI port-forwarding connection instructions](https://docs.oracle.com/en-us/iaas/Content/Bastion/Tasks/connect-port-forwarding.htm).
