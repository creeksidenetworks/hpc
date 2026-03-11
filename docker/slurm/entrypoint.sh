#!/usr/bin/env bash
# entrypoint.sh — Container startup for slurmctld + slurmdbd
set -euo pipefail

LOG() { echo "[entrypoint] $*"; }
DIE() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 1. Munge key
# --------------------------------------------------------------------------
setup_munge_key() {
    mkdir -p /etc/munge
    chmod 700 /etc/munge

    if [[ ! -f /etc/munge/munge.key ]]; then
        LOG "No munge.key found — generating a new one"
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key 2>/dev/null
        chmod 400 /etc/munge/munge.key
        chown munge:munge /etc/munge/munge.key
    else
        LOG "Using existing munge.key (host-mounted, skipping chmod)"
    fi
}

# --------------------------------------------------------------------------
# 2. Directory permissions
# --------------------------------------------------------------------------
fix_permissions() {
    install -d -o slurm -g slurm -m 0755 \
        /var/spool/slurm/ctld \
        /var/spool/slurm/d \
        /var/log/slurm \
        /var/run/slurm \
        /var/run/slurmdbd

    # slurmdbd.conf and sssd.conf may be host-mounted read-only; best-effort only
    chown slurm:slurm /etc/slurm/slurmdbd.conf 2>/dev/null || true
    chmod 600 /etc/slurm/slurmdbd.conf 2>/dev/null || true
    chmod 600 /etc/sssd/sssd.conf 2>/dev/null || true
}

# --------------------------------------------------------------------------
# 3. PAM mkhomedir — use pam_mkhomedir.so directly (no dbus/oddjobd needed)
# --------------------------------------------------------------------------
enable_mkhomedir() {
    local pam_file=/etc/pam.d/system-auth
    if ! grep -q pam_mkhomedir "$pam_file" 2>/dev/null; then
        echo "session optional pam_mkhomedir.so skel=/etc/skel umask=0077" >> "$pam_file"
    fi
}

# --------------------------------------------------------------------------
# 5. Wait for MariaDB to be reachable before starting slurmdbd
# --------------------------------------------------------------------------
wait_for_db() {
    local host storagehost
    # Strip inline comments before parsing the value
    host=$(awk -F'[=# \t]+' '/^StorageHost/{print $2}' /etc/slurm/slurmdbd.conf \
             | tr -d '[:space:]')
    host="${host:-mariadb}"
    LOG "Waiting for MariaDB at ${host}:3306 ..."
    local retries=30
    while ! bash -c "echo > /dev/tcp/${host}/3306" 2>/dev/null; do
        retries=$((retries - 1))
        [[ $retries -le 0 ]] && DIE "MariaDB not available after 30 attempts"
        sleep 2
    done
    LOG "MariaDB is up"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    setup_munge_key
    fix_permissions
    enable_mkhomedir
    wait_for_db

    LOG "Handing off to supervisord..."
    exec /usr/bin/supervisord -c /etc/supervisord.conf
}

main "$@"
