#!/usr/bin/env bash
# ood-pun-setup.sh — Per-user provisioning on first OOD login
#
# Called by the nginx_stage wrapper as root, receives the username as $1.
# Runs every time a PUN starts (idempotent — checks before creating).
#
# Provisions:
#   1. Home directory     — created from /etc/skel with correct ownership
#   2. SSH keypair        — ECDSA key in ~/.ssh/id_ecdsa for shell app access
#   3. SSH client config  — StrictHostKeyChecking=no for compute nodes
#   4. authorized_keys    — own public key pre-authorized (passwordless SSH to self)
#   5. Slurm account      — sacctmgr account + user via slurmdbd (network call)
#
# Note: sacctmgr talks to slurmdbd over the network using munge auth.
# This works from the OOD container because Slurm client binaries and
# a running munged with the shared key are both present.
set -euo pipefail

user="${1:-}"
[[ -z "$user" ]] && exit 0

# ---- Resolve user from SSSD (IPA users only — skip local system users) ----
homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
uid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f3)
gid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f4)

[[ -z "$homedir" || -z "$uid" ]] && exit 0   # unknown user, skip

# Skip system UIDs (< 1000) — only provision real IPA users
[[ "$uid" -lt 1000 ]] && exit 0

# ---- 1. Home directory ----
if [[ ! -d "$homedir" ]]; then
    mkdir -p "$homedir"
    cp -a /etc/skel/. "$homedir/"
    chown -R "${uid}:${gid}" "$homedir"
    chmod 700 "$homedir"
    echo "$(date): created home directory $homedir for $user"
fi

# ---- 2. SSH keypair ----
ssh_dir="$homedir/.ssh"
ssh_key="$ssh_dir/id_ecdsa"
auth_keys="$ssh_dir/authorized_keys"

mkdir -p "$ssh_dir"
chown "${uid}:${gid}" "$ssh_dir"
chmod 700 "$ssh_dir"

if [[ ! -f "$ssh_key" ]]; then
    ssh-keygen -t ecdsa -b 521 -f "$ssh_key" -N "" -q
    chown "${uid}:${gid}" "$ssh_key" "${ssh_key}.pub"
    chmod 600 "$ssh_key"
    chmod 644 "${ssh_key}.pub"
    echo "$(date): generated SSH key $ssh_key for $user"
fi

# ---- 3. SSH client config ----
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

# ---- 4. authorized_keys ----
if [[ -f "${ssh_key}.pub" ]]; then
    pub=$(cat "${ssh_key}.pub")
    if ! grep -qF "$pub" "$auth_keys" 2>/dev/null; then
        echo "$pub" >> "$auth_keys"
        chown "${uid}:${gid}" "$auth_keys"
        chmod 600 "$auth_keys"
        echo "$(date): added public key to authorized_keys for $user"
    fi
fi

# ---- 5. Slurm account (via sacctmgr → slurmdbd, munge-authenticated) ----
if command -v sacctmgr &>/dev/null; then
    if ! sacctmgr list user "$user" -P -n 2>/dev/null | grep -q "^${user}|"; then
        sacctmgr -i add account "$user" \
            Cluster=hpc Description="$user" Organization="$user" 2>/dev/null || true
        sacctmgr -i add user "$user" \
            DefaultAccount="$user" Cluster=hpc 2>/dev/null || true
        echo "$(date): created Slurm account and user for $user"
    fi
fi

exit 0
