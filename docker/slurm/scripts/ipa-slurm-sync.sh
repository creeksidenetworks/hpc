#!/usr/bin/env bash
# ipa-slurm-sync.sh — Bidirectional sync of FreeIPA group membership to Slurm
#
# Runs every 10 minutes via crond on the slurmctld container.
# IPA connection variables are injected by docker-compose env_file (ipa/ipa.conf).
#
# Actions:
#   ADD    — new IPA group member gets: Slurm account, home dir, SSH keypair
#   ENABLE — re-admitted user has MaxSubmitJobs limit removed
#   SUSPEND— removed IPA member gets MaxSubmitJobs=0 (blocks submissions, keeps history)
#
# Only manages users with UID >= 1000 (IPA/SSSD users).
# System Slurm accounts (root, slurm, etc.) are never touched.

set -euo pipefail
LOG() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*"; }

group="${IPA_HPC_GROUP:-}"
[[ -z "$group" ]] && { LOG "IPA_HPC_GROUP not set — skipping"; exit 0; }

# --------------------------------------------------------------------------
# 1. Query IPA for current group members (uid only)
# --------------------------------------------------------------------------
ipa_members=$(ldapsearch \
    -H    "ldaps://${IPA_SERVER}" \
    -D    "${IPA_BIND_DN}" \
    -w    "${IPA_BIND_PASSWORD}" \
    -b    "${IPA_GROUP_BASE}" \
    -o    tls_cacert=/etc/ipa/ca.crt \
    "(cn=${group})" member -LLL 2>/dev/null \
    | grep "^member:" \
    | sed 's/^member: uid=//;s/,.*//' \
    | sort)

if [[ -z "$ipa_members" ]]; then
    LOG "No members found in IPA group '$group' (or group does not exist)"
    exit 0
fi

# --------------------------------------------------------------------------
# 2. Query Slurm for users currently associated with this cluster
#    Exclude system accounts (root, slurm) and blank lines
# --------------------------------------------------------------------------
slurm_users=$(sacctmgr list assoc Cluster=hpc format=User -P -n 2>/dev/null \
    | grep -v '^root$\|^slurm$\|^$' \
    | sort -u)

# --------------------------------------------------------------------------
# 3. ADD / RE-ENABLE: IPA members not yet (or no longer suspended) in Slurm
# --------------------------------------------------------------------------
for user in $ipa_members; do

    # Resolve user from SSSD; skip if not known yet
    homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    uid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f3)
    gid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f4)

    [[ -z "$homedir" || -z "$uid" ]] && continue
    [[ "$uid" -lt 1000 ]] && continue   # skip system UIDs

    # ---- Home directory ----
    if [[ ! -d "$homedir" ]]; then
        LOG "Creating home directory for $user: $homedir"
        mkdir -p "$homedir"
        cp -a /etc/skel/. "$homedir/"
        chown -R "${uid}:${gid}" "$homedir"
        chmod 700 "$homedir"
    fi

    # ---- SSH keypair ----
    ssh_dir="$homedir/.ssh"
    ssh_key="$ssh_dir/id_ecdsa"
    auth_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    chown "${uid}:${gid}" "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ ! -f "$ssh_key" ]]; then
        LOG "Generating SSH key for $user"
        ssh-keygen -t ecdsa -b 521 -f "$ssh_key" -N "" -q
        chown "${uid}:${gid}" "$ssh_key" "${ssh_key}.pub"
        chmod 600 "$ssh_key"
        chmod 644 "${ssh_key}.pub"
    fi

    if [[ ! -f "$ssh_dir/config" ]]; then
        cat > "$ssh_dir/config" <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GSSAPIAuthentication no
    PreferredAuthentications publickey,password
EOF
        chown "${uid}:${gid}" "$ssh_dir/config"
        chmod 600 "$ssh_dir/config"
    fi

    if [[ -f "${ssh_key}.pub" ]]; then
        pub=$(cat "${ssh_key}.pub")
        if ! grep -qF "$pub" "$auth_keys" 2>/dev/null; then
            echo "$pub" >> "$auth_keys"
            chown "${uid}:${gid}" "$auth_keys"
            chmod 600 "$auth_keys"
        fi
    fi

    # ---- Slurm account ----
    user_exists=$(sacctmgr list user "$user" -P -n 2>/dev/null | grep -c "^${user}|" || true)

    if [[ "$user_exists" -eq 0 ]]; then
        LOG "Adding Slurm account and user: $user"
        sacctmgr -i add account "$user" \
            Cluster=hpc Description="$user" Organization="$user" 2>/dev/null || true
        sacctmgr -i add user "$user" \
            DefaultAccount="$user" Cluster=hpc 2>/dev/null || true

    else
        # Re-enable if previously suspended (MaxSubmitJobs=0)
        suspended=$(sacctmgr list assoc \
            where user="$user" Cluster=hpc \
            format=MaxSubmitJobs -P -n 2>/dev/null \
            | grep -c '^0$' || true)
        if [[ "$suspended" -gt 0 ]]; then
            LOG "Re-enabling Slurm user $user (rejoined IPA group)"
            sacctmgr -i modify user "$user" \
                where Cluster=hpc \
                set MaxSubmitJobs=-1 2>/dev/null || true
        fi
    fi

done

# --------------------------------------------------------------------------
# 4. SUSPEND: Slurm users no longer in the IPA group
# --------------------------------------------------------------------------
for user in $slurm_users; do
    [[ -z "$user" ]] && continue

    # Only manage IPA users (UID >= 1000)
    uid=$(getent passwd "$user" 2>/dev/null | cut -d: -f3)
    [[ -z "$uid" || "$uid" -lt 1000 ]] && continue

    if ! echo "$ipa_members" | grep -q "^${user}$"; then
        # Check not already suspended
        suspended=$(sacctmgr list assoc \
            where user="$user" Cluster=hpc \
            format=MaxSubmitJobs -P -n 2>/dev/null \
            | grep -c '^0$' || true)
        if [[ "$suspended" -eq 0 ]]; then
            LOG "Suspending Slurm user $user (removed from IPA group '$group')"
            sacctmgr -i modify user "$user" \
                where Cluster=hpc \
                set MaxSubmitJobs=0 2>/dev/null || true
        fi
    fi

done

LOG "Sync complete"
