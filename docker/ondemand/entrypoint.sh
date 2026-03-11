#!/usr/bin/env bash
# entrypoint.sh — Open OnDemand container startup
set -euo pipefail

LOG() { echo "[entrypoint] $*"; }
DIE() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 1. Munge key
# --------------------------------------------------------------------------
setup_munge() {
    if [[ ! -f /etc/munge/munge.key ]]; then
        DIE "No munge.key found at /etc/munge/munge.key. Mount the shared key from the slurm container."
    fi
    LOG "Munge key present (host-mounted, skipping chmod)"
}

# --------------------------------------------------------------------------
# 2. SSSD permissions
# --------------------------------------------------------------------------
fix_permissions() {
    chmod 600 /etc/sssd/sssd.conf 2>/dev/null || true
    chmod 600 /etc/pam.d/ood      2>/dev/null || true
}

# --------------------------------------------------------------------------
# 3. SSL certificate — generate self-signed if not mounted
# --------------------------------------------------------------------------
setup_ssl() {
    local cert=/etc/pki/tls/certs/ondemand.crt
    local key=/etc/pki/tls/private/ondemand.key

    if [[ -f "$cert" && -f "$key" ]]; then
        LOG "Using existing SSL certificate"
        return
    fi

    local servername
    servername=$(awk '/^servername:/{print $2}' /etc/ood/config/ood_portal.yml \
                 | tr -d "'\"" | head -1)
    servername="${servername:-ondemand.local}"

    LOG "Generating self-signed SSL certificate for: $servername"
    mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key" \
        -out  "$cert" \
        -subj "/CN=${servername}" 2>/dev/null
    chmod 600 "$key"
    LOG "Self-signed cert written to $cert"
}

# --------------------------------------------------------------------------
# 4. PAM mkhomedir for OOD users
# --------------------------------------------------------------------------
enable_mkhomedir() {
    local pam_file=/etc/pam.d/system-auth
    if ! grep -q pam_mkhomedir "$pam_file" 2>/dev/null; then
        echo "session optional pam_mkhomedir.so skel=/etc/skel umask=0077" >> "$pam_file"
    fi
}

# --------------------------------------------------------------------------
# 5. Generate Apache configs from ood_portal.yml
#    Port 8080 → OIDC auth, HTTP only — for external reverse proxy
#    Port 443  → PAM/Basic auth, HTTPS — for direct VPN access
# --------------------------------------------------------------------------
generate_apache_config() {
    local generate=/opt/ood/ood-portal-generator/bin/generate
    local template=/opt/ood/ood-portal-generator/templates/ood-portal.conf.erb

    [[ -x "$generate" ]] || DIE "ood-portal-generator not found at $generate"

    LOG "Generating Apache config (OIDC — port 8080, for external proxy)..."
    "$generate" \
        --config   /etc/ood/config/ood_portal.yml \
        --template "$template" \
        --output   /etc/httpd/conf.d/ood-portal.conf

    LOG "Generating Apache config (PAM/local — port 443, for VPN direct access)..."
    "$generate" \
        --config   /etc/ood/config/ood_portal_local.yml \
        --template "$template" \
        --output   /etc/httpd/conf.d/ood-portal-local.conf

    # The OIDC portal (port 8080, HTTP) does not generate a port 80 VirtualHost.
    # The local auth portal (port 443, HTTPS) generates port 80 → 443 redirect.
    # Keep that redirect — it is the only port 80 handler.

    LOG "Apache configs written"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    setup_munge
    fix_permissions
    setup_ssl
    enable_mkhomedir
    generate_apache_config

    LOG "Handing off to supervisord..."
    exec /usr/bin/supervisord -c /etc/supervisord.conf
}

main "$@"
