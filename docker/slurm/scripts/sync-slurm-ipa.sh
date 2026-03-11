#!/bin/bash
# IPA -> Slurm user sync
# IPA_* variables are injected via Docker Compose env_file (conf/ipa/ipa.conf).
# To apply updated IPA settings, recreate the container:
#   docker compose up -d --force-recreate slurmctld

group="${IPA_HPC_GROUP:-}"
[[ -z "$group" ]] && exit 0

members=$(ldapsearch -H ldaps://${IPA_SERVER} \
    -D "${IPA_BIND_DN}" \
    -w "${IPA_BIND_PASSWORD}" \
    -b "${IPA_GROUP_BASE}" \
    "(cn=${group})" member -LLL 2>/dev/null \
    | grep "^member:" \
    | sed 's/^member: uid=//;s/,.*//')

if [[ -z "$members" ]]; then
    echo "$(date): No members found in IPA group '$group' (or group does not exist)"
    exit 0
fi

for user in $members; do
    # Create home directory if missing
    homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [[ -n "$homedir" && ! -d "$homedir" ]]; then
        echo "$(date): Creating home directory for $user: $homedir"
        uid=$(getent passwd "$user" | cut -d: -f3)
        gid=$(getent passwd "$user" | cut -d: -f4)
        mkdir -p "$homedir"
        cp -a /etc/skel/. "$homedir/"
        chown -R "$uid:$gid" "$homedir"
        chmod 700 "$homedir"
    fi

    # Add Slurm account and user if not present
    if ! sacctmgr list user "$user" -P -n | grep -q "$user"; then
        echo "$(date): Adding Slurm account and user: $user"
        sacctmgr -i add account "$user" Cluster=hpc Description="$user" || true
        sacctmgr -i add user "$user" DefaultAccount="$user" Cluster=hpc || true
        sacctmgr -i add user "$user" DefaultAccount="$user" Cluster=hpc Partition=compute || true
        scontrol reconfigure || true
    fi

    # Generate SSH key for OOD shell access if not present
    if [[ -n "$homedir" && -d "$homedir" ]]; then
        uid=$(getent passwd "$user" | cut -d: -f3)
        gid=$(getent passwd "$user" | cut -d: -f4)
        ssh_dir="$homedir/.ssh"
        ssh_key="$ssh_dir/id_ecdsa"
        auth_keys="$ssh_dir/authorized_keys"
        if [[ ! -f "$ssh_key" ]]; then
            echo "$(date): Generating SSH key for $user"
            mkdir -p "$ssh_dir"
            ssh-keygen -t ecdsa -f "$ssh_key" -N "" -q
            chown -R "$uid:$gid" "$ssh_dir"
            chmod 700 "$ssh_dir"
        fi
        if [[ ! -f "$ssh_dir/config" ]]; then
            echo "$(date): Writing SSH config for $user"
            cat > "$ssh_dir/config" <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GSSAPIAuthentication no
    PreferredAuthentications publickey,password
EOF
            chown "$uid:$gid" "$ssh_dir/config"
            chmod 600 "$ssh_dir/config"
        fi
        if ! grep -qF "$(cat "${ssh_key}.pub" 2>/dev/null)" "$auth_keys" 2>/dev/null; then
            echo "$(date): Adding SSH public key to authorized_keys for $user"
            cat "${ssh_key}.pub" >> "$auth_keys"
            chown "$uid:$gid" "$auth_keys"
            chmod 600 "$auth_keys"
        fi
    fi
done
