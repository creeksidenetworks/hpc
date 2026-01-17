#!/bin/bash
set -e

################################################################################
# Open OnDemand Installation Script for Rocky Linux 9
# with Microsoft Entra ID (Azure AD) OIDC Authentication
# Behind NGINX Proxy Manager with Squid Proxy
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

################################################################################
# SECTION 1: LOAD AND VALIDATE CONFIGURATION
################################################################################

log "==============================================="
log "Step 1: Loading configuration from ood.init"
log "==============================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root. Use 'sudo $0'"
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ood.init"

# Check if ood.init exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found: ${CONFIG_FILE}
    
Please create ood.init in the same directory as this script.
You can copy the template and customize it with your values."
fi

log "Reading configuration from: ${CONFIG_FILE}"

# Source the configuration file
source "$CONFIG_FILE"

# Validate all required variables are present and not empty
missing_vars=()

required_vars=(
    "DOMAIN_LOCAL"
    "DOMAIN_COM"
    "EMAIL_DOMAIN"
    "OOD_IP"
    "NPM_IP"
    "SQUID_IP"
    "OOD_HOSTNAME"
    "PUBLIC_HOSTNAME"
    "PUBLIC_PORT"
    "SQUID_HOSTNAME"
    "AZURE_TENANT_ID"
    "AZURE_CLIENT_ID"
    "AZURE_CLIENT_SECRET"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        missing_vars+=("$var")
    fi
done

# Check for placeholder values in Azure credentials
if [[ "$AZURE_TENANT_ID" == "your-tenant-id-here" ]] || \
   [[ "$AZURE_CLIENT_ID" == "your-client-id-here" ]] || \
   [[ "$AZURE_CLIENT_SECRET" == "your-client-secret-here" ]]; then
    missing_vars+=("Azure AD credentials (currently set to placeholder values)")
fi

# If any variables are missing, display error and exit
if [[ ${#missing_vars[@]} -gt 0 ]]; then
    error "Missing or invalid configuration values:
    
${missing_vars[@]}

Please edit ood.init and provide all required values.

Example:
  DOMAIN_LOCAL=example.local
  DOMAIN_COM=example.com
  EMAIL_DOMAIN=example.com
  OOD_IP=10.1.41.100
  NPM_IP=10.1.43.100
  SQUID_IP=10.1.43.100
  OOD_HOSTNAME=ood.example.local
  PUBLIC_HOSTNAME=ondemand.example.com
  PUBLIC_PORT=443
  SQUID_HOSTNAME=squid.example.local
  AZURE_TENANT_ID=your-actual-tenant-id
  AZURE_CLIENT_ID=your-actual-client-id
  AZURE_CLIENT_SECRET=your-actual-client-secret"
fi

# Export all variables
export DOMAIN_LOCAL
export DOMAIN_COM
export EMAIL_DOMAIN
export OOD_IP
export NPM_IP
export SQUID_IP
export OOD_HOSTNAME
export PUBLIC_HOSTNAME
export PUBLIC_PORT
export SQUID_HOSTNAME
export AZURE_TENANT_ID
export AZURE_CLIENT_ID
export AZURE_CLIENT_SECRET

success "Configuration loaded successfully"

# Display configuration summary
log "==============================================="
log "Configuration Summary"
log "==============================================="
echo ""
echo "FreeIPA Configuration:"
echo "  Local Domain: ${DOMAIN_LOCAL}"
echo "  OOD Hostname: ${OOD_HOSTNAME}"
echo ""
echo "Public Configuration:"
echo "  Public Domain: ${DOMAIN_COM}"
echo "  Public Hostname: ${PUBLIC_HOSTNAME}"
echo "  Public Port: ${PUBLIC_PORT}"
echo "  Public URL: https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}"
echo ""
echo "Network Configuration:"
echo "  OOD Server IP: ${OOD_IP}"
echo "  NPM Server IP: ${NPM_IP}"
echo "  Squid Proxy IP: ${SQUID_IP}"
echo "  Squid Hostname: ${SQUID_HOSTNAME}"
echo ""
echo "Azure AD Configuration:"
echo "  Tenant ID: ${AZURE_TENANT_ID}"
echo "  Client ID: ${AZURE_CLIENT_ID}"
echo "  Client Secret: $(echo ${AZURE_CLIENT_SECRET} | cut -c1-10)... (hidden)"
echo ""
echo "Email Domain (for user mapping):"
echo "  ${EMAIL_DOMAIN}"
echo ""

# Get user confirmation
read -p "Proceed with installation using these settings? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
    log "Installation cancelled by user"
    exit 0
fi

success "Configuration validated and confirmed"

################################################################################
# SECTION 2: SYSTEM VERIFICATION
################################################################################

log "==============================================="
log "Step 2: Verifying system requirements"
log "==============================================="

# Check if running on Rocky Linux 9
if ! grep -q "Rocky Linux.*9" /etc/os-release; then
    error "This script requires Rocky Linux 9. Current OS: $(grep PRETTY_NAME /etc/os-release)"
fi
success "Rocky Linux 9 verified"

# Check FreeIPA enrollment
if ! realm list | grep -q "${DOMAIN_LOCAL}"; then
    error "System is not enrolled in FreeIPA domain ${DOMAIN_LOCAL}. Run: realm join ${DOMAIN_LOCAL}"
fi
success "FreeIPA enrollment verified"

# Check sudo access
if ! sudo -n true 2>/dev/null; then
    error "Current user does not have passwordless sudo access"
fi
success "Sudo access verified"

################################################################################
# SECTION 3: ENABLE REPOSITORIES
################################################################################

log "==============================================="
log "Step 3: Enabling repositories"
log "==============================================="

dnf config-manager --set-enabled crb
success "CRB repository enabled"

dnf install -y epel-release
success "EPEL repository enabled"

dnf module enable ruby:3.3 nodejs:20 -y
success "Ruby 3.3 and Node.js 20 modules enabled"

dnf install -y https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.el8.noarch.rpm
success "Open OnDemand repository enabled"

################################################################################
# SECTION 4: INSTALL PACKAGES
################################################################################

log "==============================================="
log "Step 4: Installing packages"
log "==============================================="

log "Installing Open OnDemand and mod_auth_openidc..."
dnf install -y ondemand mod_auth_openidc
success "Packages installed"

systemctl enable httpd
systemctl start httpd
success "Apache httpd enabled and started"

################################################################################
# SECTION 5: CREATE SSL CERTIFICATE
################################################################################

log "==============================================="
log "Step 5: Creating self-signed SSL certificate"
log "==============================================="

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/pki/tls/private/ood.key \
  -out /etc/pki/tls/certs/ood.crt \
  -subj "/CN=${OOD_HOSTNAME}"

chown root:root /etc/pki/tls/private/ood.key
chmod 600 /etc/pki/tls/private/ood.key

success "SSL certificate created"

################################################################################
# SECTION 6: ENABLE SSSD HOME DIRECTORY CREATION
################################################################################

log "==============================================="
log "Step 6: Configuring SSSD for auto home creation"
log "==============================================="

if ! grep -q "mkhomedir" /etc/sssd/sssd.conf; then
    authselect enable-feature with-mkhomedir
    systemctl restart sssd
    success "Auto home directory creation enabled"
else
    success "Auto home directory creation already enabled"
fi

################################################################################
# SECTION 7: CONFIGURE SQUID PROXY
################################################################################

log "==============================================="
log "Step 7: Configuring Squid proxy for outbound HTTPS"
log "==============================================="

tee /etc/profile.d/squid-proxy.sh > /dev/null <<EOF
# Squid proxy configuration for outbound traffic
export http_proxy=http://${SQUID_HOSTNAME}:3128
export https_proxy=http://${SQUID_HOSTNAME}:3128
export HTTP_PROXY=http://${SQUID_HOSTNAME}:3128
export HTTPS_PROXY=http://${SQUID_HOSTNAME}:3128
export no_proxy=localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
EOF

chmod +x /etc/profile.d/squid-proxy.sh
source /etc/profile.d/squid-proxy.sh

success "Squid proxy environment variables configured"

tee /etc/httpd/conf.d/ood-squid-proxy.conf > /dev/null <<EOF
# Environment variables for Apache processes to use Squid
SetEnv http_proxy http://${SQUID_HOSTNAME}:3128
SetEnv https_proxy http://${SQUID_HOSTNAME}:3128
SetEnv HTTP_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv HTTPS_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv no_proxy localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
SetEnv NO_PROXY localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
EOF

success "Apache Squid proxy configuration created"

################################################################################
# SECTION 8: CREATE USER MAPPING SCRIPT
################################################################################

log "==============================================="
log "Step 8: Creating user mapping script"
log "==============================================="

mkdir -p /opt/ood/site

tee /opt/ood/site/custom-user-mapping.sh > /dev/null <<EOF
#!/bin/bash

function urldecode() { : "\${*//+/ }"; echo -e "\${_//%/\\\\x}"; }

REX="([^@]+)@${EMAIL_DOMAIN}"
INPUT_USER=\$(urldecode \$1)

if [[ \$INPUT_USER =~ \$REX ]]; then
  MATCH="\${BASH_REMATCH[1]}"
  echo "\$MATCH" | tr '[:upper:]' '[:lower:]'
else
  logger -t 'ood-mapping' "cannot map \$INPUT_USER"
  exit 1
fi
EOF

chmod +x /opt/ood/site/custom-user-mapping.sh
success "User mapping script created"

################################################################################
# SECTION 9: CONFIGURE NPM TRUST HEADERS
################################################################################

log "==============================================="
log "Step 9: Configuring Apache to trust NPM headers"
log "==============================================="

tee /etc/httpd/conf.d/ood-npm-trust.conf > /dev/null <<EOF
# Trust headers from NPM reverse proxy
RemoteIPHeader X-Forwarded-For
RemoteIPTrustedProxy ${NPM_IP}
RemoteIPInternalProxy ${NPM_IP}

# Preserve original protocol from NPM
SetEnvIf X-Forwarded-Proto https HTTPS=on

# Ensure headers are preserved
RequestHeader set X-Forwarded-Host "%{HTTP_X_FORWARDED_HOST}e"
RequestHeader set X-Forwarded-For "%{HTTP_X_FORWARDED_FOR}e"
RequestHeader set X-Forwarded-Proto "%{HTTP_X_FORWARDED_PROTO}e"
EOF

success "NPM trust configuration created"

################################################################################
# SECTION 10: CONFIGURE APACHE TO LISTEN ON NON-STANDARD PORT (IF NEEDED)
################################################################################

if [[ "${PUBLIC_PORT}" != "443" ]]; then
    log "==============================================="
    log "Step 10: Configuring Apache to listen on port ${PUBLIC_PORT}"
    log "==============================================="

    if ! grep -q "^Listen ${PUBLIC_PORT} https" /etc/httpd/conf.d/ssl.conf; then
        tee -a /etc/httpd/conf.d/ssl.conf > /dev/null <<EOF
Listen ${PUBLIC_PORT} https
EOF
        success "Apache configured to listen on port ${PUBLIC_PORT}"
    else
        success "Apache already listening on port ${PUBLIC_PORT}"
    fi
fi

################################################################################
# SECTION 11: CONFIGURE OPEN ONDEMAND OIDC
################################################################################

log "==============================================="
log "Step 11: Configuring Open OnDemand OIDC"
log "==============================================="

tee /etc/ood/config/ood_portal.yml > /dev/null <<EOF
# CRITICAL: Use PUBLIC hostname and EXTERNAL port (what browsers see)
# NOT the internal hostname or internal port
servername: ${PUBLIC_HOSTNAME}
port: ${PUBLIC_PORT}

# Use the self-signed certificate we created
ssl:
  - 'SSLCertificateFile /etc/pki/tls/certs/ood.crt'
  - 'SSLCertificateKeyFile /etc/pki/tls/private/ood.key'

auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'

oidc_uri: /oidc/
oidc_provider_metadata_url: 'https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0/.well-known/openid-configuration'
oidc_client_id: '${AZURE_CLIENT_ID}'
oidc_client_secret: '${AZURE_CLIENT_SECRET}'

oidc_scope: 'openid profile email'
oidc_remote_user_claim: email

oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
oidc_state_max_number_of_cookies: 10
oidc_cookie_same_site: 'On'

user_map_cmd: '/opt/ood/site/custom-user-mapping.sh'

user_env:
  REMOTE_USER
EOF

success "OOD portal YAML configured"

################################################################################
# SECTION 12: GENERATE APACHE CONFIG
################################################################################

log "==============================================="
log "Step 12: Generating Apache configuration"
log "==============================================="

/opt/ood/ood-portal-generator/sbin/update_ood_portal
success "Apache configuration generated"

################################################################################
# SECTION 13: RESTART APACHE
################################################################################

log "==============================================="
log "Step 13: Restarting Apache"
log "==============================================="

systemctl restart httpd
success "Apache restarted"

################################################################################
# SECTION 14: VERIFY CONFIGURATION
################################################################################

log "==============================================="
log "Step 14: Verifying configuration"
log "==============================================="

# Check if Apache is listening on the correct port
if ss -tlnp | grep -q "httpd.*:${PUBLIC_PORT}"; then
    success "Apache is listening on port ${PUBLIC_PORT}"
else
    error "Apache is NOT listening on port ${PUBLIC_PORT}"
fi

# Check VirtualHost
if apachectl -S | grep -q "${PUBLIC_HOSTNAME}"; then
    success "VirtualHost for ${PUBLIC_HOSTNAME} is configured"
else
    error "VirtualHost for ${PUBLIC_HOSTNAME} not found"
fi

# Check SSL certificate
if [[ -f /etc/pki/tls/certs/ood.crt ]] && [[ -f /etc/pki/tls/private/ood.key ]]; then
    success "SSL certificate files exist"
else
    error "SSL certificate files not found"
fi

# Check user mapping script
if [[ -x /opt/ood/site/custom-user-mapping.sh ]]; then
    success "User mapping script is executable"
else
    error "User mapping script not executable"
fi

################################################################################
# SECTION 15: TESTING AND NEXT STEPS
################################################################################

log "==============================================="
log "Installation Complete!"
log "==============================================="

echo ""
echo "Configuration Summary:"
echo "  Public URL: https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}"
echo "  OOD Hostname: ${OOD_HOSTNAME}"
echo "  NPM IP: ${NPM_IP}"
echo "  Squid IP: ${SQUID_IP}"
echo ""

echo "Next Steps:"
echo "1. Configure NPM proxy:"
echo "   - Navigate to NPM web UI (port 81)"
echo "   - Add proxy host: ${PUBLIC_HOSTNAME} → https://${OOD_IP}:${PUBLIC_PORT}"
echo "   - Add Location block with proxy_redirect directives (see README.md section 3.1)"
echo ""
echo "2. Update Azure AD app registration:"
echo "   - Go to Azure Portal → App registrations → [Your App] → Authentication"
echo "   - Add Redirect URI:"
echo "     https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}/oidc/"
echo "   - Click Save"
echo ""
echo "3. Verify DNS:"
echo "   - Ensure ${PUBLIC_HOSTNAME} resolves to NPM IP (${NPM_IP})"
echo ""
echo "4. Test login:"
echo "   - Open browser to: https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}"
echo "   - Should redirect to Microsoft 365 login"
echo "   - After login, should land on OOD dashboard"
echo ""

echo "Useful Commands:"
echo "  Check Apache status:"
echo "    sudo systemctl status httpd"
echo ""
echo "  View Apache error log:"
echo "    sudo tail -f /var/log/httpd/error_log"
echo ""
echo "  Test OOD connectivity:"
echo "    curl -k https://localhost:${PUBLIC_PORT}/"
echo ""
echo "  Reload Apache:"
echo "    sudo systemctl restart httpd"
echo ""

success "Installation script completed successfully!"
