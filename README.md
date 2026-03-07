# HPC OnDemand

A single-script installer and management tool for deploying
[Open OnDemand](https://openondemand.org/) on a **Rocky Linux 8 (AMD64)** server,
backed by Slurm, FreeIPA, and Microsoft Entra ID (or any OIDC provider).

---

## Architecture

```
Browser  ──HTTPS──►  Open OnDemand (Apache + mod_auth_openidc)
                          │
                          ▼
                   Slurm (slurmctld + slurmd + slurmdbd)
                          │
                    MariaDB (accounting)
                          │
                    FreeIPA / SSSD (identity)
                          │
                    Xpra HTML5 (interactive apps)
```

- **Authentication** — OIDC via Entra ID or Keycloak; usernames mapped to POSIX accounts synced from FreeIPA.
- **Interactive apps** — GUI applications (GTKWave, Google Chrome, Xfce desktop) run as Slurm batch jobs, streamed over Xpra HTML5.
- **IPA → Slurm sync** — a systemd timer runs every 10 minutes to add/remove Slurm accounts as IPA group membership changes.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Rocky Linux 8 AMD64 | Fresh install recommended |
| Root access | Script must run as root |
| FreeIPA client joined | `realm list` must show the IPA domain |
| DNS resolves IPA server | `ipa.example.com` must be reachable |
| OIDC app registered | Entra ID or Keycloak client ID + secret ready |
| TLS certificate | Self-signed is auto-generated if none provided |

---

## Quick Start

### 1. Clone the repository

```bash
git clone <repo-url> /root/hpc
cd /root/hpc
```

### 2. Configure

Copy and edit the main configuration file:

```bash
cp conf/hpc.conf.example conf/hpc.conf   # if an example exists
vi conf/hpc.conf
```

`conf/hpc.conf` is gitignored and never committed. See [Configuration](#configuration) below.

### 3. Install

```bash
./hpc-ctl install
```

The install takes roughly 5–10 minutes. A full log is written to `/var/log/hpc-ctl.log`.

### 4. Verify

```bash
./hpc-ctl status
```

All components should show `[OK]`. Open `https://<SERVER_FQDN>:<ONDEMAND_PORT>` in a browser.

---

## Configuration

All settings live in `conf/hpc.conf`. The file is sourced line-by-line
(not via `bash source`) so values with special characters do not need quoting.

### `conf/hpc.conf`

```bash
# ── Cluster ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="HPC"
SERVER_FQDN="hpc.example.com"        # hostname of this server
PROXY_FQDN="hpc.example.com"         # public-facing FQDN (same unless behind a proxy)
ONDEMAND_PORT=8443                    # HTTPS port for the OOD portal

# ── FreeIPA ───────────────────────────────────────────────────────────────────
IPA_SERVER=ipa.example.com
IPA_DOMAIN=example.com
IPA_BASE_DN=dc=example,dc=com
IPA_USER_BASE=cn=users,cn=accounts,dc=example,dc=com
IPA_GROUP_BASE=cn=groups,cn=accounts,dc=example,dc=com
IPA_BIND_DN=uid=ldapauth,cn=sysaccounts,cn=etc,dc=example,dc=com
IPA_BIND_PASSWORD=<ldap-bind-password>
IPA_HPC_GROUP=hpc-users               # IPA group whose members get Slurm accounts

# ── OIDC ──────────────────────────────────────────────────────────────────────
# Microsoft Entra ID:
OIDC_PROVIDER_METADATA_URL=https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration
# Keycloak:
# OIDC_PROVIDER_METADATA_URL=https://keycloak.example.com/realms/<realm>/.well-known/openid-configuration

OIDC_CLIENT_ID=<client-id>
OIDC_CLIENT_SECRET=<client-secret>

# JWT claim that becomes the POSIX username.
# Append a regex to strip a domain suffix (Entra UPNs: user@domain → user).
OIDC_REMOTE_USER_CLAIM=preferred_username ^([^@]+)

OIDC_SCOPE=openid profile email
```

### `conf/cluster.conf` — compute node list

One hostname or IP per line. Lines starting with `#` are ignored.
The head node (`localhost`) is included by default so it also acts as a compute node.

```
localhost           # this server doubles as a compute node
cpn01.example.com
cpn02.example.com
```

### `conf/apps.conf` — interactive app list

One application binary name per line. An OOD batch-connect launcher is
auto-generated for each entry.

```
google-chrome
gtkwave
```

---

## Commands

```
./hpc-ctl <command> [options]
```

| Command | Description |
|---|---|
| `install [-c <conf_dir>]` | Full install: repos, Slurm, MariaDB, OOD, Xpra, SSSD, apps |
| `cpn -add <host>` | Add a compute node to Slurm and OOD |
| `cpn -remove <host>` | Remove a compute node from Slurm and OOD |
| `update` | Re-sync all nodes from `conf/cluster.conf` |
| `status` | Health check — services, Slurm, MariaDB, SSSD, OOD, firewall |

### `install`

```bash
./hpc-ctl install                  # use ./conf as config directory
./hpc-ctl install -c /etc/hpc/conf # use a custom config directory
```

Install order:
1. Slurm system user
2. Package repositories (EPEL, OOD, Xpra, MariaDB, Google Chrome)
3. System packages + OOD (with nodejs:22 and ruby:3.3 module activation)
4. Slurm (from EPEL), Munge, MariaDB
5. SSL certificate (self-signed if not present)
6. Open OnDemand portal config + OIDC
7. SSSD / FreeIPA integration
8. Xpra HTML5 + interactive app launchers
9. IPA → Slurm sync timer (every 10 minutes)
10. Firewall rules, service startup

### `cpn -add` / `cpn -remove`

Add or remove a compute node at runtime without re-running the full install.

```bash
./hpc-ctl cpn -add  cpn03.example.com
./hpc-ctl cpn -remove cpn03.example.com
```

The node is added to `conf/cluster.conf`, registered in `slurm.conf`,
and the Slurm node list in OOD is updated.

### `update`

Re-reads `conf/cluster.conf` and reconciles Slurm + OOD with the current
list. Use this after manually editing `cluster.conf`.

```bash
./hpc-ctl update
```

### `status`

```bash
./hpc-ctl status
```

Checks and reports:
- All required services (`munge`, `mariadb`, `slurmdbd`, `slurmctld`, `slurmd`, `httpd`, `sssd`, `crond`)
- Munge auth round-trip
- Slurm cluster name, partitions, and node states
- Slurm accounting DB reachability
- MariaDB `slurm_acct_db` access
- SSSD/IPA domain status
- OOD portal HTTP response
- Xpra installation
- Firewall ports
- IPA sync timer last run

---

## Interactive Apps

The following apps are available in OOD under **Interactive Apps**:

| App | Description |
|---|---|
| **Desktop** | Xfce desktop session via Xpra HTML5 |
| **GTKWave** | Waveform viewer for EDA |
| **Google Chrome** | Browser session for web-based tools |

Each app submits a Slurm batch job on launch. The job starts an Xpra server,
and the browser connects directly via the OOD reverse node proxy (`/rnode/`).

To add more apps, append the binary name to `conf/apps.conf` and run:

```bash
./hpc-ctl update
```

---

## IPA → Slurm User Sync

A systemd timer (`sync-slurm-ipa.timer`) runs `/usr/local/bin/sync-slurm-ipa.sh`
every 10 minutes. It:

1. Queries IPA for members of `IPA_HPC_GROUP` (default: `hpc-users`)
2. Creates missing Slurm accounts (`sacctmgr add account/user`)
3. Removes Slurm accounts for users no longer in the group

To trigger a sync immediately:

```bash
systemctl start sync-slurm-ipa.service
journalctl -u sync-slurm-ipa.service -f
```

---

## OIDC Redirect URI

Register the following redirect URI with your OIDC provider:

```
https://<PROXY_FQDN>/oidc/callback/
```

For **Entra ID**: App registrations → Authentication → Add a redirect URI (type: Web).

---

## File Layout

```
hpc/
├── hpc-ctl             # main management script
├── conf/
│   ├── hpc.conf        # site config (gitignored — contains credentials)
│   ├── cluster.conf    # compute node list
│   └── apps.conf       # interactive app list
└── scripts/
    └── sync-slurm-ipa.sh   # IPA → Slurm user sync (deployed to /usr/local/bin/)
```

---

## Troubleshooting

### Installation log

```bash
tail -f /var/log/hpc-ctl.log
```

### Service logs

```bash
journalctl -u slurmctld -f
journalctl -u slurmd -f
journalctl -u httpd -f
journalctl -u sssd -f
```

### OOD per-user nginx logs

```bash
tail -f /var/log/ondemand-nginx/<username>/error.log
```

### Job output

Each interactive session writes output to:

```
~/ondemand/data/sys/dashboard/batch_connect/sys/<app>/output/<uuid>/output.log
```

### User cannot submit jobs

1. Verify the user is in the `hpc-users` IPA group.
2. Run a manual sync: `systemctl start sync-slurm-ipa.service`
3. Restart slurmctld to reload the accounting cache: `systemctl restart slurmctld`

### OOD shows username mapping error

Ensure SSSD returns plain usernames (no `@domain` suffix):

```bash
getent passwd <username>   # pw_name should be 'user', not 'user@domain'
```

If not, check that `use_fully_qualified_names = False` and `full_name_format = %1$s`
are set in the `[domain/...]` section of `/etc/sssd/sssd.conf`.
