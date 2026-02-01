#!/bin/bash
#===============================================================================
# Open OnDemand Setup Utility
# Version: 2.0
# Description:
#   Interactive setup utility for Open OnDemand on Rocky Linux 9.
#   Supports Microsoft Entra ID and Keycloak authentication.
#===============================================================================

# Colors for terminal output
Red=$(tput setaf 1)
Green=$(tput setaf 2)
Yellow=$(tput setaf 3)
Blue=$(tput setaf 4)
Cyan=$(tput setaf 6)
Bold=$(tput bold)
Reset=$(tput sgr0)
Dim=$(tput dim)

print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))
    echo ""
    printf "${Cyan}%s${Reset}\n" "$(printf '═%.0s' $(seq 1 $width))"
    printf "${Cyan}║${Reset}%*s${Bold}%s${Reset}%*s${Cyan}║${Reset}\n" $padding "" "$title" $((width - padding - ${#title} - 2)) ""
    printf "${Cyan}%s${Reset}\n" "$(printf '═%.0s' $(seq 1 $width))"
}

print_step() {
    local step_num="$1"
    local title="$2"
    echo ""
    echo -e "${Yellow}[$step_num]${Reset} ${Bold}$title${Reset}"
    echo -e "${Dim}$(printf '─%.0s' $(seq 1 50))${Reset}"
}

print_ok() {
    echo -e "  ${Green}✓${Reset} $1"
}

print_warn() {
    echo -e "  ${Yellow}⚠${Reset} $1"
}

print_error() {
    echo -e "  ${Red}✗${Reset} $1"
}

print_info() {
    echo -e "  ${Blue}ℹ${Reset} $1"
}

print_summary() {
    local title="$1"
    shift
    local items=("$@")
    echo ""
    echo -e "${Cyan}┌─ $title ───────────-────${Reset}"
    for item in "${items[@]}"; do
        echo -e "${Cyan}│${Reset}  $item"
    done
    echo -e "${Cyan}└$(printf '─%.0s' $(seq 1 40))${Reset}"
}

function show_menu() {
    local title="$1"
    shift
    local default_choice=0
    
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        default_choice=$1
        shift
    fi
    
    local options=("$@")
    echo ""
    echo -e "${Green}${Bold}$title${Reset}"
    for i in "${!options[@]}"; do
        printf "  ${Cyan}%d)${Reset} %s\n" "$((i+1))" "${options[$i]}"
    done
    echo ""
    if [[ $default_choice -gt 0 ]]; then
        echo -n "  Select [$default_choice]: "
    else
        echo -n "  Select: "
    fi
    read user_choice
    
    if [[ -z "$user_choice" ]]; then
        user_choice=$default_choice
    fi
    if ! [[ "$user_choice" =~ ^[0-9]+$ ]] || (( user_choice < 1 || user_choice > ${#options[@]} )); then
        if [[ $default_choice -gt 0 ]]; then
            user_choice=$default_choice
        else
            user_choice=${#options[@]}
        fi
    fi
    menu_index=$((user_choice-1))
}

# Global variables with defaults
OOD_HOSTNAME=$(hostname -f)
DOMAIN_LOCAL=""
SQUID_HOSTNAME=""
NPM_IP=""
PUBLIC_PORT="443"

# Try to load defaults from ood.init if it exists
if [[ -f "ood.init" ]]; then
    source ood.init
fi

function install_ood_server() {
    print_header "Open OnDemand Server Installation"

    #---------------------------------------------------------------------------
    print_step "1" "Verifying System Requirements"
    #---------------------------------------------------------------------------
    
    # Check OS
    if ! grep -q "Rocky Linux.*9" /etc/os-release; then
        print_error "This script requires Rocky Linux 9"
        return 1
    fi
    print_ok "Rocky Linux 9 detected"

    # Check FreeIPA
    if realm list | grep -q "domain-name:"; then
        DOMAIN_LOCAL=$(realm list | grep "domain-name:" | awk '{print $2}')
        print_ok "Enrolled in FreeIPA domain: $DOMAIN_LOCAL"
    else
        print_error "System is not enrolled in FreeIPA. Please join domain first."
        return 1
    fi

    #---------------------------------------------------------------------------
    print_step "2" "Enabling Repositories"
    #---------------------------------------------------------------------------
    
    dnf config-manager --set-enabled crb &>/dev/null
    print_ok "CRB repository enabled"

    dnf install -y epel-release &>/dev/null
    print_ok "EPEL repository enabled"

    dnf module enable ruby:3.3 nodejs:20 -y &>/dev/null
    print_ok "Ruby 3.3 and Node.js 20 modules enabled"

    dnf install -y https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.el8.noarch.rpm &>/dev/null
    print_ok "Open OnDemand repository enabled"

    #---------------------------------------------------------------------------
    print_step "3" "Installing Packages"
    #---------------------------------------------------------------------------
    
    print_info "Installing Open OnDemand and mod_auth_openidc..."
    if dnf install -y ondemand mod_auth_openidc &>/dev/null; then
        print_ok "Packages installed successfully"
    else
        print_error "Failed to install packages"
        return 1
    fi

    systemctl enable httpd &>/dev/null
    systemctl start httpd &>/dev/null
    print_ok "Apache httpd enabled and started"

    #---------------------------------------------------------------------------
    print_step "4" "Configuring Internal SSL"
    #---------------------------------------------------------------------------
    
    read -p "  Enter OOD Hostname [${OOD_HOSTNAME}]: " input_hostname
    [[ -n "$input_hostname" ]] && OOD_HOSTNAME="$input_hostname"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /etc/pki/tls/private/ood.key \
      -out /etc/pki/tls/certs/ood.crt \
      -subj "/CN=${OOD_HOSTNAME}" 2>/dev/null

    chown root:root /etc/pki/tls/private/ood.key
    chmod 600 /etc/pki/tls/private/ood.key
    print_ok "Self-signed SSL certificate created for ${OOD_HOSTNAME}"

    #---------------------------------------------------------------------------
    print_step "5" "Configuring SSSD"
    #---------------------------------------------------------------------------
    
    if ! grep -q "mkhomedir" /etc/sssd/sssd.conf; then
        authselect enable-feature with-mkhomedir &>/dev/null
        systemctl restart sssd
        print_ok "Auto home directory creation enabled"
    else
        print_ok "Auto home directory creation already enabled"
    fi

    #---------------------------------------------------------------------------
    print_step "6" "Configuring Squid Proxy"
    #---------------------------------------------------------------------------
    
    read -p "  Enter Squid Proxy Hostname/IP [${SQUID_HOSTNAME}]: " input_squid
    [[ -n "$input_squid" ]] && SQUID_HOSTNAME="$input_squid"
    
    if [[ -z "$SQUID_HOSTNAME" ]]; then
        print_warn "Skipping Squid configuration (no hostname provided)"
    else
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
        
        tee /etc/httpd/conf.d/ood-squid-proxy.conf > /dev/null <<EOF
# Environment variables for Apache processes to use Squid
SetEnv http_proxy http://${SQUID_HOSTNAME}:3128
SetEnv https_proxy http://${SQUID_HOSTNAME}:3128
SetEnv HTTP_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv HTTPS_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv no_proxy localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
SetEnv NO_PROXY localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
EOF
        print_ok "Squid proxy configured for system and Apache"
    fi

    #---------------------------------------------------------------------------
    print_step "7" "Configuring NPM Trust"
    #---------------------------------------------------------------------------
    
    read -p "  Enter NGINX Proxy Manager IP [${NPM_IP}]: " input_npm
    [[ -n "$input_npm" ]] && NPM_IP="$input_npm"

    if [[ -n "$NPM_IP" ]]; then
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
        print_ok "NPM trust configuration created"
    else
        print_warn "Skipping NPM trust configuration"
    fi

    #---------------------------------------------------------------------------
    print_step "8" "Configuring Apache Port"
    #---------------------------------------------------------------------------
    
    read -p "  Enter Public Port (what browsers use) [${PUBLIC_PORT}]: " input_port
    [[ -n "$input_port" ]] && PUBLIC_PORT="$input_port"

    if [[ "${PUBLIC_PORT}" != "443" ]]; then
        if ! grep -q "^Listen ${PUBLIC_PORT} https" /etc/httpd/conf.d/ssl.conf; then
            tee -a /etc/httpd/conf.d/ssl.conf > /dev/null <<EOF
Listen ${PUBLIC_PORT} https
EOF
            print_ok "Apache configured to listen on port ${PUBLIC_PORT}"
        else
            print_ok "Apache already listening on port ${PUBLIC_PORT}"
        fi
    fi

    echo ""
    echo -e "${Green}${Bold}✓ Open OnDemand Server Installation Completed${Reset}"
    echo ""
}

function configure_entra_id() {
    print_header "Configure Azure Entra ID"

    read -p "  Enter Public Hostname (e.g. ondemand.example.com): " PUBLIC_HOSTNAME
    read -p "  Enter Public Port [${PUBLIC_PORT}]: " input_port
    [[ -n "$input_port" ]] && PUBLIC_PORT="$input_port"
    
    read -p "  Enter Azure Tenant ID: " AZURE_TENANT_ID
    read -p "  Enter Azure Client ID: " AZURE_CLIENT_ID
    read -s -p "  Enter Azure Client Secret: " AZURE_CLIENT_SECRET
    echo ""
    read -p "  Enter Email Domain (for user mapping): " EMAIL_DOMAIN

    # Create user mapping script
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
    print_ok "User mapping script created"

    # Configure OOD Portal
    tee /etc/ood/config/ood_portal.yml > /dev/null <<EOF
servername: ${PUBLIC_HOSTNAME}
port: ${PUBLIC_PORT}
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
    print_ok "OOD portal configuration updated"

    # Apply changes
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
    systemctl restart httpd
    print_ok "Apache configuration updated and restarted"
}

function configure_keycloak() {
    print_header "Configure Keycloak"

    read -p "  Enter Public Hostname (e.g. ondemand.example.com): " PUBLIC_HOSTNAME
    read -p "  Enter Public Port [${PUBLIC_PORT}]: " input_port
    [[ -n "$input_port" ]] && PUBLIC_PORT="$input_port"

    read -p "  Enter Keycloak URL (e.g. https://keycloak.example.com): " KEYCLOAK_URL
    read -p "  Enter Keycloak Realm: " KEYCLOAK_REALM
    read -p "  Enter Client ID: " KEYCLOAK_CLIENT_ID
    read -s -p "  Enter Client Secret: " KEYCLOAK_CLIENT_SECRET
    echo ""

    # Create user mapping script
    mkdir -p /opt/ood/site
    tee /opt/ood/site/custom-user-mapping-keycloak.sh > /dev/null <<EOF
#!/bin/bash
function urldecode() { : "\${*//+/ }"; echo -e "\${_//%/\\\\x}"; }
INPUT_USER=\$(urldecode \$1)
USERNAME="\${INPUT_USER%%@*}"
echo "\$USERNAME" | tr '[:upper:]' '[:lower:]'
EOF
    chmod +x /opt/ood/site/custom-user-mapping-keycloak.sh
    print_ok "User mapping script created"

    # Configure OOD Portal
    tee /etc/ood/config/ood_portal.yml > /dev/null <<EOF
servername: ${PUBLIC_HOSTNAME}
port: ${PUBLIC_PORT}
ssl:
  - 'SSLCertificateFile /etc/pki/tls/certs/ood.crt'
  - 'SSLCertificateKeyFile /etc/pki/tls/private/ood.key'
auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'
oidc_uri: /oidc/
oidc_provider_metadata_url: '${KEYCLOAK_URL}/auth/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration'
oidc_client_id: '${KEYCLOAK_CLIENT_ID}'
oidc_client_secret: '${KEYCLOAK_CLIENT_SECRET}'
oidc_scope: 'openid profile email'
oidc_remote_user_claim: preferred_username
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
oidc_state_max_number_of_cookies: 10
oidc_cookie_same_site: 'On'
user_map_cmd: '/opt/ood/site/custom-user-mapping-keycloak.sh'
user_env:
  REMOTE_USER
EOF
    print_ok "OOD portal configuration updated"

    # Apply changes
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
    systemctl restart httpd
    print_ok "Apache configuration updated and restarted"
}

function configure_authentication() {
    print_header "Configure Authentication"
    
    local auth_options=(
        "Azure Entra ID"
        "Keycloak"
        "Back to main menu"
    )
    
    show_menu "Select Authentication Method" 3 "${auth_options[@]}"
    
    case $menu_index in
        0) configure_entra_id;;
        1) configure_keycloak;;
        2) return;;
    esac
}

function main() {
    # Ensure running as root
    if [[ $(id -u) -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi

    while true; do
        local menu_items=(
            "Install Open OnDemand Server"
            "Configure Authentication"
            "Exit"
        )
        show_menu "Open OnDemand Setup" 3 "${menu_items[@]}"
        
        case $menu_index in
            0) install_ood_server;;
            1) configure_authentication;;
            2) 
                echo ""
                echo -e "${Dim}Exiting...${Reset}"
                exit 0
                ;;
        esac
    done
}

main "$@"
