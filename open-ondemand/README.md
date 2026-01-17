# Open OnDemand on Rocky Linux with NPM & Squid Proxy

**Linux Identity:** FreeIPA (`example.local`)  \
**Public URL:** https://ondemand.example.com or https://ondemand.example.com:58443  
**Internal Hostname:** `ood.example.local` (unchanged)  \
**Internal IP:** `10.1.41.100`
**Reverse Proxy:** NGINX Proxy Manager at `10.1.43.100`  \
**Outbound Proxy:** Squid at `10.1.43.100`  \
**SSL:** Let's Encrypt (handled by NPM for public), self-signed on OOD

## Authentication Options

Choose one authentication method:

1. **[Microsoft Entra ID (Azure AD)](#part-a-microsoft-entra-id-azure-ad-oidc-authentication)** - Via Microsoft 365
2. **[Keycloak](#part-b-keycloak-oidc-authentication)** - Self-hosted identity provider

---

## Environment Variables

**IMPORTANT:** Customize these variables for your environment before running commands:

```bash
# Domain names
export DOMAIN_LOCAL="example.local"
export DOMAIN_COM="example.com"
export EMAIL_DOMAIN="example.com"

# IP addresses
export OOD_IP="10.1.41.100"
export NPM_IP="10.1.43.100"
export SQUID_IP="10.1.43.100"

# Hostnames
export OOD_HOSTNAME="ood.${DOMAIN_LOCAL}"
export PUBLIC_HOSTNAME="ondemand.${DOMAIN_COM}"
export PUBLIC_PORT="443"  # Change to your NPM external port (e.g., 58443 for non-standard)
export SQUID_HOSTNAME="squid.${DOMAIN_LOCAL}"

# CHOOSE ONE AUTHENTICATION METHOD:

# ===== OPTION 1: Microsoft Entra ID (Azure AD) =====
export AUTH_METHOD="entra-id"
export AZURE_TENANT_ID="your-tenant-id"
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-client-secret"

# ===== OPTION 2: Keycloak =====
# export AUTH_METHOD="keycloak"
# export KEYCLOAK_URL="https://keycloak.example.com:8443"  # or port 8080 for non-HTTPS
# export KEYCLOAK_REALM="master"
# export KEYCLOAK_CLIENT_ID="ondemand"
# export KEYCLOAK_CLIENT_SECRET="your-client-secret"
```

Once exported, you can copy and run all commands directly. For example:
- `${OOD_HOSTNAME}` → `ood.example.local` or `ood.csn.corp`
- `${PUBLIC_HOSTNAME}` → `ondemand.example.com` or `ondemand.csn.corp`

---

## PART A: Microsoft Entra ID (Azure AD) OIDC Authentication

```
Browser / Internet
  ↓
NGINX Proxy Manager (10.1.43.100)
(Public SSL termination + reverse proxy)
  ↓ HTTPS
Open OnDemand (10.1.41.100)
(Apache + mod_auth_openidc)
  ↓ OIDC
Microsoft Entra ID (MS365)
  ↓
FreeIPA / SSSD (example.local)
  
OOD Outbound Traffic:
  ↓
Squid Proxy (10.1.43.100)
  ↓
Internet
```

User flow:
- User logs in to NPM public URL: `ondemand.example.com`
- NPM proxies to OOD internal HTTPS at `10.1.41.100:443`
- OOD redirects to Microsoft 365 OIDC (through Squid)
- User authenticates as `user@example.com`
- OOD maps → `user`
- FreeIPA resolves → `user@example.local`
- Session starts with NPM + OOD trust chain

---

## 2. Assumptions

- Rocky Linux 9 for OOD server (10.1.41.100)
- OOD server already joined to FreeIPA (`example.local`)
- Separate NPM VM at **10.1.43.100** (can be Docker host or standalone)
- Separate Squid proxy VM at **10.1.43.100**
- All three VMs on the same internal network (10.180.0.0/16)
- DNS A record: `ondemand.example.com → 10.1.43.100` (NPM public IP)
- DNS A record: `squid.example.local → 10.1.43.100` (internal)
- DNS A record: `ood.example.local → 10.1.41.100` (internal)
- Router forwards **80/443 → 10.1.43.100** (NPM, not OOD)
- OOD has no direct internet access (must use Squid)
- NPM/Squid can access internet for SSL certs and OIDC metadata

---

## 3. Network Setup

### 3.1 NPM Deployment

See the separate guide: **nginx-proxy-manager/ood_behind_nginx_proxy_manager_keep_existing_https_on_ood.md**

Key points:
- Deploy NGINX Proxy Manager on **10.1.43.100**
- Configure proxy host for `ondemand.example.com → https://10.1.41.100:443`
- NPM handles public SSL certificates
- Enable WebSocket support in NPM
- Add custom Nginx headers for OIDC trust

#### Advanced Nginx Configuration (for Non-Standard Ports)

If you're using a **non-standard port** (e.g., `https://ondemand.example.com:58443`), you must complete three steps:

**STEP 1: Make Apache listen on the non-standard port** on the OOD server.

Add to `/etc/httpd/conf.d/ssl.conf`:

```bash
sudo tee -a /etc/httpd/conf.d/ssl.conf > /dev/null <<EOF
Listen 58443 https
EOF
```

Restart Apache:

```bash
sudo systemctl restart httpd
```

Verify:

```bash
sudo ss -tlnp | grep httpd
```

**STEP 2: Update OOD portal configuration** to use the external port.

In `/etc/ood/config/ood_portal.yml`, set `port` to your external port:

```yaml
port: 58443
```

Regenerate the Apache config:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

**STEP 3: Configure NPM to rewrite Location headers** with the port.

Edit `/opt/nginx-proxy-manager/npm/data/nginx/proxy_host/2.conf` and use this location block:

```nginx
location / {
    # Set the REAL external port here (change 58443 to your port)
    set $external_port 58443;

    proxy_pass https://10.1.41.100:58443;
    
    # Standard headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    
    # CRITICAL: Tell OOD the internet-facing port (prevents redirect to internal hostname)
    proxy_set_header X-Forwarded-Port $external_port;
    proxy_set_header X-Forwarded-Host $host:$external_port;

    # CRITICAL: Rewrite Location headers to include the port
    # This fixes browser redirects to use the external port instead of default 443
    proxy_redirect https://$host/ https://$host:$external_port/;
    proxy_redirect http://$host/ https://$host:$external_port/;

    # Buffer sizes for OIDC tokens
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    # WebSocket & Timeouts
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
```

Reload Nginx in NPM:

```bash
sudo docker exec npm nginx -s reload
```

**WHY ALL THREE STEPS ARE NECESSARY:**
- **Step 1:** Apache must listen on the non-standard port
- **Step 2:** OOD portal generator creates VirtualHost on that port and sets OIDC redirect URI correctly
- **Step 3:** NPM's `proxy_redirect` directives rewrite HTTP Location headers to include the port in redirects (critical for OIDC flow)

### 3.2 Squid Proxy Deployment

See the separate guide: **nginx-proxy-manager/ood_with_npm_and_squid_proxy.md**

Key points:
- Deploy Squid proxy on **10.1.43.100**
- Configure to allow only OOD server (10.1.41.100) as source
- Listen on port 3128
- Allow Microsoft OIDC endpoints

### 3.3 Firewall Rules Summary

```
Internet → NPM (10.1.43.100): 80, 443 ✓
NPM → OOD (10.1.41.100): 443 ✓
OOD → Squid (10.1.43.100): 3128 ✓
Squid → Internet: 80, 443 ✓
```

---

## 4. Verify FreeIPA & SSSD

```bash
hostname -f
```

```bash
realm list
```

```bash
id someuser@example.local
```

Ensure home directories are auto-created:

```bash
sudo authselect current
```

```bash
grep mkhomedir /etc/sssd/sssd.conf
```

Enable if needed:

```bash
sudo authselect enable-feature with-mkhomedir
```

```bash
sudo systemctl restart sssd
```

---

## 5. Install Open OnDemand

### Enable repositories

```bash
sudo dnf config-manager --set-enabled crb
```

```bash
sudo dnf install -y epel-release
```

```bash
sudo dnf module enable ruby:3.3 nodejs:20 -y
```

```bash
sudo dnf install -y https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.el8.noarch.rpm
```

### Install packages

```bash
sudo dnf install -y ondemand mod_auth_openidc
```

```bash
sudo systemctl enable --now httpd
```

---

## 6. OOD SSL Certificate (Internal Only)

### IMPORTANT: NPM handles public SSL

OOD runs HTTPS with a self-signed cert that NPM ignores:

```bash
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/pki/tls/private/ood.key \
  -out /etc/pki/tls/certs/ood.crt \
  -subj "/CN=${OOD_HOSTNAME}"
```

```bash
sudo chown root:root /etc/pki/tls/private/ood.key
```

```bash
sudo chmod 600 /etc/pki/tls/private/ood.key
```

---

## 7. Register App in Microsoft Entra ID (Azure AD)

### App Registration

- Name: `OpenOnDemand`
- Account type: **Single tenant**
- Platform: **Web**

### Redirect URI (CRITICAL - MUST MATCH EXACTLY)

**IMPORTANT:** The redirect URI registered in Azure AD must match **exactly** what OOD sends during the OIDC flow. For non-standard ports, this includes the port number AND trailing slash.

**For non-standard ports:**
```
https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}/oidc/
```

**For standard port 443 (no port suffix):**
```
https://${PUBLIC_HOSTNAME}/oidc/
```

**Example for port 58443:**
```
https://ondemand.cn.creekside.network:58443/oidc/
```

**If you get error AADSTS50011** (redirect URI mismatch):
1. Check the exact URL in the error message from Azure AD
2. Go to **Azure Portal → App registrations → [Your App] → Authentication → Redirect URIs**
3. Add/update the URI to match **exactly** (including port and trailing slash)
4. Click **Save**
5. Try logging in again

> **Troubleshooting tip:** Check browser DevTools → Network tab during login. The redirect URL will show in the HTTP request headers.

### API Permissions

- `openid`
- `profile`
- `email`

Grant **Admin Consent**.

### Credentials

- Create a **Client Secret**
- Save **Client ID**, **Tenant ID**, **Client Secret**

---

## 8. Configure Squid Proxy on OOD Server

Before OIDC can work, OOD needs access to Microsoft's OIDC endpoints through Squid.

### 8.1 Set Environment Variables

Create `/etc/profile.d/squid-proxy.sh`:

```bash
sudo tee /etc/profile.d/squid-proxy.sh > /dev/null <<EOF
# Squid proxy configuration for outbound traffic
export http_proxy=http://${SQUID_HOSTNAME}:3128
export https_proxy=http://${SQUID_HOSTNAME}:3128
export HTTP_PROXY=http://${SQUID_HOSTNAME}:3128
export HTTPS_PROXY=http://${SQUID_HOSTNAME}:3128
export no_proxy=localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
EOF
```

```bash
sudo chmod +x /etc/profile.d/squid-proxy.sh
```

### 8.2 Apache-Specific Proxy Configuration

Create `/etc/httpd/conf.d/ood-squid-proxy.conf`:

```bash
sudo tee /etc/httpd/conf.d/ood-squid-proxy.conf > /dev/null <<EOF
# Environment variables for Apache processes to use Squid
SetEnv http_proxy http://${SQUID_HOSTNAME}:3128
SetEnv https_proxy http://${SQUID_HOSTNAME}:3128
SetEnv HTTP_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv HTTPS_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv no_proxy localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
SetEnv NO_PROXY localhost,127.0.0.1,10.0.0.0/8,.${DOMAIN_LOCAL}
EOF
```

### 8.3 Verify Squid Connectivity

```bash
nslookup ${SQUID_HOSTNAME}
```

```bash
telnet ${SQUID_HOSTNAME} 3128
```

```bash
export http_proxy=http://${SQUID_HOSTNAME}:3128
```

```bash
export https_proxy=http://${SQUID_HOSTNAME}:3128
```

```bash
curl -v https://login.microsoftonline.com
```

---

## 9. Configure User Mapping

OOD must map:

```
user@${DOMAIN_COM} → user
```

Add an user mapping script:

```bash
sudo mkdir -p /opt/ood/site
```

Required content:

```bash
sudo tee /opt/ood/site/remote-user-mapping.sh > /dev/null <<EOF
#!/bin/bash

function urldecode() { : "\${*//+/ }"; echo -e "\${_//%/\\\\x}"; }

REX="([^@]+)@${EMAIL_DOMAIN}"
INPUT_USER=\$(urldecode \$1)

if [[ \$INPUT_USER =~ \$REX ]]; then
  MATCH="\${BASH_REMATCH[1]}"
  echo "\$MATCH" | tr '[:upper:]' '[:lower:]'
else
  # can't write to standard out or error, so let's use syslog
  logger -t 'ood-mapping' "cannot map \$INPUT_USER"

  # and exit 1
  exit 1
fi
EOF
```

---

## 10. Configure Open OnDemand OIDC

Edit:

```bash
sudo vi /etc/ood/config/ood_portal.yml
```

### Final Working Configuration

**IMPORTANT:** For public URLs with reverse proxies, use the **public hostname**, not the internal one.

```bash
sudo tee /etc/ood/config/ood_portal.yml > /dev/null <<EOF
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
```

---

## 11. Add NPM Trust Headers & Port Reconstruction
0
Since NPM is the reverse proxy and uses a non-standard port, Apache needs to:
1. Trust headers from NPM
2. Reconstruct the full URL (with port) from X-Forwarded-Port for OIDC redirects

Create `/etc/httpd/conf.d/ood-npm-trust.conf`:

```bash
sudo tee /etc/httpd/conf.d/ood-npm-trust.conf > /dev/null <<EOF
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
```

---

## 12. Configure Apache to Listen on Port (If Non-Standard)

**Important:** If using a non-standard port (not 443), make sure Apache listens on it:

```bash
sudo grep "^Listen" /etc/httpd/conf.d/ssl.conf
```

If your port is missing, add it:

```bash
sudo tee -a /etc/httpd/conf.d/ssl.conf > /dev/null <<EOF
Listen 58443 https
EOF
```

## 13. Generate Apache Config (MANDATORY)

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
```

```bash
sudo systemctl restart httpd
```

Verify Apache is listening on the correct port:

```bash
sudo ss -tlnp | grep httpd
```

Verify VirtualHost configuration:

```bash
sudo apachectl -S
```

You should see:
```
*:58443                ondemand.cn.creekside.network (/etc/httpd/conf.d/ood-portal.conf:xx)
```

---

## 14. Test Login

### Step 1: Verify Network Connectivity

From OOD server:

```bash
telnet ${SQUID_HOSTNAME} 3128
```

```bash
export https_proxy=http://${SQUID_HOSTNAME}:3128
```

```bash
curl -v https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration | head -20
```

### Step 2: Test OOD Internal Access

From internal network (or through NPM):

```bash
curl -k https://${OOD_HOSTNAME}
```

```bash
curl -k https://${PUBLIC_HOSTNAME}
```

### Step 3: Web Browser Test

1. **Open browser to:** `https://${PUBLIC_HOSTNAME}`
   - This hits NPM, which proxies to OOD
2. **Should redirect to:** Microsoft 365 login
   - Check that redirect uses `${PUBLIC_HOSTNAME}` (not `${OOD_HOSTNAME}`)
3. **Authenticate** with `user@${DOMAIN_COM}`
4. **Complete MFA** (if enabled)
5. **Verify landing** on OOD dashboard

### Step 4: Verify User

```bash
whoami
```

```bash
id
```

```bash
ls /home/user
```

### Step 5: Monitor Logs

```bash
sudo tail -f /var/log/httpd/error_log
```

```bash
sudo grep -i oidc /var/log/httpd/error_log
```

```bash
sudo tail -f /var/log/squid/access.log | grep login.microsoftonline
```

---

## 15. Troubleshooting

### OIDC Errors

```bash
sudo tail -50 /var/log/httpd/error_log | grep -i oidc
```

**Common issue 1: Redirect URI mismatch (AADSTS50011)**

Error message:
```
AADSTS50011: The redirect URI 'https://ondemand.example.com:58443/oidc/' specified 
in the request does not match the redirect URIs configured for the application.
```

**FIX:**
1. Go to **Azure Portal → App registrations → [Your App] → Authentication → Redirect URIs**
2. Add/update the redirect URI to match **exactly** what the error shows (including port and trailing slash)
3. Example:
   ```
   https://ondemand.cn.creekside.network:58443/oidc/
   ```
4. Click **Save**
5. Try logging in again

**Common issue 2: Redirect goes to wrong port**

If the browser is redirected to `https://hostname/` instead of `https://hostname:58443/`:
- **Cause:** NPM is not rewriting Location headers with the port
- **FIX:** Ensure NPM config has `proxy_redirect` directives (see section 3.1)
- **Verify:** `curl -v https://hostname:58443/ | grep location` should show the port in the Location header

### Squid Connectivity Issues

```bash
telnet ${SQUID_HOSTNAME} 3128
```

```bash
export https_proxy=http://${SQUID_HOSTNAME}:3128
```

```bash
curl -v https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration
```

```bash
sudo tail -f /var/log/squid/access.log | grep login.microsoftonline
```

### User Not Found

```bash
getent passwd user
```

```bash
id user@${DOMAIN_LOCAL}
```

### NPM Not Reaching OOD

```bash
curl -k -v https://${OOD_IP}
```

```bash
sudo apachectl -S
```

```bash
sudo systemctl status httpd
```

### SELinux (debug only)

```bash
sudo getenforce
```

```bash
sudo setenforce 0  # Temporarily disable for testing
```

```bash
sudo setenforce 1  # Re-enable
```

---

## PART B: Keycloak OIDC Authentication

Keycloak is a self-hosted open-source identity provider. Use this section if you prefer to manage authentication with your own Keycloak instance instead of Azure AD.

### Architecture with Keycloak

```
Browser / Internet
  ↓
NGINX Proxy Manager (10.1.43.100)
(Public SSL termination + reverse proxy)
  ↓ HTTPS
Open OnDemand (10.1.41.100)
(Apache + mod_auth_openidc)
  ↓ OIDC
Keycloak (internal or external)
(Identity provider - your own server)
  ↓
FreeIPA / SSSD (example.local)
  
OOD Outbound Traffic:
  ↓
Squid Proxy (10.1.43.100)
  ↓
Internet (for Keycloak if external)
```

### B.1 Keycloak Setup Requirements

- Keycloak instance deployed (internal or external)
- HTTPS accessibility from OOD server (through Squid if needed)
- Realm and client created
- OOD registered as a client in Keycloak

### B.2 Configure Keycloak for OOD

**1. Create a new Realm (or use existing):**
- Log in to Keycloak Admin Console
- Create realm: `example` (or use default `master`)

**2. Create Client for OOD:**
- Go to Clients → Create
- Client ID: `ondemand`
- Client Protocol: `openid-connect`
- Access Type: `confidential`

**3. Configure Client:**
- **Valid Redirect URIs:**
  ```
  https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}/oidc/
  ```
  Example for port 58443:
  ```
  https://ondemand.example.com:58443/oidc/
  ```

- **Web Origins:**
  ```
  https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}
  ```

- **Access Type:** `confidential`
- **Standard Flow Enabled:** ON
- **Implicit Flow Enabled:** OFF
- **Direct Access Grants Enabled:** OFF

**4. Get Credentials:**
- Click **Credentials** tab
- Copy **Client Secret**
- Note: Client ID is `ondemand`

### B.3 Configure Squid Proxy for Keycloak Access

If Keycloak is external, OOD needs to reach it through Squid.

Create `/etc/httpd/conf.d/ood-keycloak-proxy.conf`:

```bash
sudo tee /etc/httpd/conf.d/ood-keycloak-proxy.conf > /dev/null <<EOF
# Allow Keycloak HTTPS access through Squid
# If Keycloak is internal, this may not be needed
SetEnv http_proxy http://${SQUID_HOSTNAME}:3128
SetEnv https_proxy http://${SQUID_HOSTNAME}:3128
EOF
```

### B.4 Verify Keycloak Connectivity

From OOD server:

```bash
export https_proxy=http://${SQUID_HOSTNAME}:3128
```

```bash
curl -v https://${KEYCLOAK_URL}/.well-known/openid-configuration | head -20
```

Should return JSON with OIDC endpoints.

### B.5 Create User Mapping Script for Keycloak

Keycloak can send username in different claims. Create a mapping script:

```bash
sudo mkdir -p /opt/ood/site
```

```bash
sudo tee /opt/ood/site/custom-user-mapping-keycloak.sh > /dev/null <<EOF
#!/bin/bash

function urldecode() { : "\${*//+/ }"; echo -e "\${_//%/\\\\x}"; }

# Keycloak sends username claim (can be email or preferred_username)
# This example assumes username in format: user or user@realm
INPUT_USER=\$(urldecode \$1)

# Remove realm suffix if present (e.g., user@keycloak → user)
USERNAME="\${INPUT_USER%%@*}"

# Convert to lowercase
echo "\$USERNAME" | tr '[:upper:]' '[:lower:]'
EOF

chmod +x /opt/ood/site/custom-user-mapping-keycloak.sh
```

### B.6 Configure OOD for Keycloak OIDC

Edit `/etc/ood/config/ood_portal.yml`:

```bash
sudo tee /etc/ood/config/ood_portal.yml > /dev/null <<EOF
# CRITICAL: Use PUBLIC hostname and EXTERNAL port (what browsers see)
servername: ${PUBLIC_HOSTNAME}
port: ${PUBLIC_PORT}

ssl:
  - 'SSLCertificateFile /etc/pki/tls/certs/ood.crt'
  - 'SSLCertificateKeyFile /etc/pki/tls/private/ood.key'

auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'

oidc_uri: /oidc/

# Keycloak OIDC Configuration
# Replace with your Keycloak instance URL and realm
oidc_provider_metadata_url: 'https://${KEYCLOAK_URL}/auth/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration'

oidc_client_id: '${KEYCLOAK_CLIENT_ID}'
oidc_client_secret: '${KEYCLOAK_CLIENT_SECRET}'

# Keycloak sends 'preferred_username' by default
# Adjust if you have custom claims
oidc_remote_user_claim: preferred_username

oidc_scope: 'openid profile email'

oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
oidc_state_max_number_of_cookies: 10
oidc_cookie_same_site: 'On'

# Use Keycloak-specific mapping script
user_map_cmd: '/opt/ood/site/custom-user-mapping-keycloak.sh'

user_env:
  REMOTE_USER
EOF
```

**Key differences from Azure AD:**
- `oidc_provider_metadata_url` points to Keycloak realm
- `oidc_remote_user_claim` is typically `preferred_username` (not `email`)
- Different mapping script that handles Keycloak username format

### B.7 Generate Apache Configuration

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
```

```bash
sudo systemctl restart httpd
```

Verify:

```bash
sudo apachectl -S | grep -i keycloak
```

### B.8 Configure NPM for Keycloak OOD Proxy

Same as Azure AD approach. Update NPM proxy config:

```nginx
location / {
    set $external_port ${PUBLIC_PORT};
    proxy_pass https://10.1.41.100:${PUBLIC_PORT};
    
    # Standard headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    
    # CRITICAL: Keycloak port handling
    proxy_set_header X-Forwarded-Port $external_port;
    proxy_set_header X-Forwarded-Host $host:$external_port;

    # Rewrite Location headers for non-standard ports
    proxy_redirect https://$host/ https://$host:$external_port/;
    proxy_redirect http://$host/ https://$host:$external_port/;

    # Buffers and timeouts
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
```

Reload NPM:

```bash
sudo docker exec npm nginx -s reload
```

### B.9 Troubleshooting Keycloak OIDC

**OIDC Metadata Not Found:**

```bash
export https_proxy=http://${SQUID_HOSTNAME}:3128
curl -v https://${KEYCLOAK_URL}/auth/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration
```

Should return JSON. If 404, check:
- Keycloak URL is correct
- Realm name is correct
- Keycloak is accessible from OOD server

**Login Redirect Loop:**

Keycloak might not trust the redirect URI. Check:
1. Keycloak Client → Valid Redirect URIs includes exact URL with port
2. Web Origins includes `https://${PUBLIC_HOSTNAME}:${PUBLIC_PORT}`
3. Client protocol is `openid-connect`

**Username Not Mapping Correctly:**

Check what claim Keycloak sends:

```bash
sudo tail -f /var/log/httpd/error_log | grep -i "oidc\|map"
```

Adjust `oidc_remote_user_claim` in `ood_portal.yml` if needed:
- `preferred_username` - Username (default)
- `email` - Email address
- Custom claim name - If you configured custom claims

**User Not Found in FreeIPA:**

Ensure the username that Keycloak sends matches FreeIPA:

```bash
id username@${DOMAIN_LOCAL}
```

If not found, adjust the user mapping script to match your Keycloak username format.

---

## 16. Recommended Next Steps

**For Entra ID:**
- Enforce MFA with Conditional Access
- Restrict Entra app to allowed users/groups

**For Keycloak:**
- Configure user federation (LDAP/FreeIPA sync)
- Set up password policies
- Enable MFA
- Configure roles and permissions

**For both:**
- Configure Slurm / PBS
- Enable Interactive Desktop (TurboVNC / noVNC)
- Add NFS-backed home directories

---

## 17. Tips:

1) Chrony service fix on LXD Rocky containers
```bash
mkdir -p /etc/systemd/system/chronyd.service.d/
```

```bash
cat <<EOF > /etc/systemd/system/chronyd.service.d/override.conf
[Unit]
ConditionCapability=

[Service]
ExecStart=
ExecStart=/usr/sbin/chronyd -x \$OPTIONS
EOF
```

```bash
systemctl daemon-reload
```

```bash
systemctl restart chronyd
```