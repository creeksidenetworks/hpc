#!/usr/bin/env bash
# ood-pun-setup.sh — Per-user provisioning called on every OOD login
#
# Invoked from two places:
#   1. nginx_stage wrapper (as root, $1 = username) — on every PUN start
#   2. pam_exec.so in /etc/pam.d/ood (as root, $PAM_USER = username) — on every login
#
# To avoid hammering sacctmgr on every HTTP request (Basic auth resends
# credentials per request), a cooldown stamp file is checked. Full provisioning
# runs at most once per hour; the home-directory check always runs (fast).
#
# Provisions:
#   1. Home directory     — created from /etc/skel with correct ownership
#   2. SSH keypair        — ECDSA key in ~/.ssh/id_ecdsa for shell app access
#   3. SSH client config  — StrictHostKeyChecking=no for compute nodes
#   4. authorized_keys    — own public key pre-authorized
#   5. Slurm account      — sacctmgr account + user via slurmdbd (munge auth)
set -euo pipefail

# Accept username from $1 (nginx_stage) or $PAM_USER (pam_exec)
user="${1:-${PAM_USER:-}}"
[[ -z "$user" ]] && exit 0

# ---- Resolve user from SSSD (skip unknown or system users) ----
homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
uid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f3)
gid=$(getent     passwd "$user" 2>/dev/null | cut -d: -f4)

[[ -z "$homedir" || -z "$uid" ]] && exit 0
[[ "$uid" -lt 1000 ]] && exit 0          # skip system UIDs

# ---- 1. Home directory (always checked — fast) ----
if [[ ! -d "$homedir" ]]; then
    mkdir -p "$homedir"
    cp -a /etc/skel/. "$homedir/"
    chown -R "${uid}:${gid}" "$homedir"
    chmod 700 "$homedir"
    echo "$(date): created home directory $homedir for $user"
fi

# ---- Cooldown: run full provisioning at most once per hour ----
stamp="$homedir/.ood-setup"
now=$(date +%s)
if [[ -f "$stamp" ]]; then
    last=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
    [[ $(( now - last )) -lt 3600 ]] && exit 0   # ran < 1 hour ago, skip
fi
touch "$stamp" && chown "${uid}:${gid}" "$stamp" 2>/dev/null || true

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

# ---- 5. Slurm account (sacctmgr → slurmdbd, munge-authenticated) ----
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
