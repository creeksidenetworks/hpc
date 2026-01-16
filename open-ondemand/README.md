# Open OnDemand on Rocky Linux with NPM & Squid Proxy

**Authentication:** Microsoft Entra ID (MS365) via OIDC  \
**Linux Identity:** FreeIPA (`example.local`)  \
**Public URL:** https://ondemand.example.com  
**Internal Hostname:** `ood.example.local` (unchanged)  
**Internal IP:** `10.1.41.100`
**Reverse Proxy:** NGINX Proxy Manager at `10.1.43.100`  \
**Outbound Proxy:** Squid at `10.1.43.100`  \
**SSL:** Let's Encrypt (handled by NPM)

---

## Environment Variables

**IMPORTANT:** Customize these variables for your environment before running commands:

```bash
# Domain names
export DOMAIN_LOCAL="example.local"
export DOMAIN_COM="example.com"

# IP addresses
export OOD_IP="10.1.41.100"
export NPM_IP="10.1.43.100"
export SQUID_IP="10.1.43.100"

# Hostnames
export OOD_HOSTNAME="ood.${DOMAIN_LOCAL}"
export PUBLIC_HOSTNAME="ondemand.${DOMAIN_COM}"
export SQUID_HOSTNAME="squid.${DOMAIN_LOCAL}"

# Azure AD (update with your values)
export AZURE_TENANT_ID="your-tenant-id"
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-client-secret"
```

Once exported, you can copy and run all commands directly. For example:
- `${OOD_HOSTNAME}` → `ood.example.local` or `ood.csn.corp`
- `${PUBLIC_HOSTNAME}` → `ondemand.example.com` or `ondemand.csn.corp`

---

## 1. Architecture Overview

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

### Redirect URI (CRITICAL)

**MUST use the public NPM URL, NOT the internal OOD URL:**

```
https://${PUBLIC_HOSTNAME}/oidc
```

> This is the NPM public hostname, not ${OOD_HOSTNAME}

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
export no_proxy=localhost,127.0.0.1,10.180.0.0/16,.${DOMAIN_LOCAL}
export NO_PROXY=localhost,127.0.0.1,10.180.0.0/16,.${DOMAIN_LOCAL}
EOF
```

```bash
sudo chmod +x /etc/profile.d/squid-proxy.sh
```

### 8.2 Apache-Specific Proxy Configuration

Create `/etc/httpd/conf.d/ood-squid-proxy.conf`:

```apache
# Environment variables for Apache processes to use Squid
SetEnv http_proxy http://${SQUID_HOSTNAME}:3128
SetEnv https_proxy http://${SQUID_HOSTNAME}:3128
SetEnv HTTP_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv HTTPS_PROXY http://${SQUID_HOSTNAME}:3128
SetEnv no_proxy localhost,127.0.0.1,10.180.0.0/16,.${DOMAIN_LOCAL}
SetEnv NO_PROXY localhost,127.0.0.1,10.180.0.0/16,.${DOMAIN_LOCAL}
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

REX="([^@]+)@${DOMAIN_COM}"
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

```yaml
# Use internal hostname, NOT the public NPM hostname
servername: ${OOD_HOSTNAME}

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
oidc_cookie_same_site: 'None'

user_map_cmd: '/opt/ood/site/custom-user-mapping.sh'

user_env:
  REMOTE_USER
```

---

## 11. Add NPM Trust Headers

Since NPM is the reverse proxy, add trust configuration for NPM-provided headers:

Edit `/etc/httpd/conf.d/ood-npm-trust.conf`:

```apache
# Trust headers from NPM reverse proxy
RemoteIPHeader X-Forwarded-For
RemoteIPTrustedProxy ${NPM_IP}
RemoteIPInternalProxy ${NPM_IP}

# Preserve original protocol from NPM
SetEnvIf X-Forwarded-Proto https HTTPS=on
```

---

## 12. Generate Apache Config (MANDATORY)

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
```

```bash
sudo systemctl restart httpd
```

Verify:

```bash
sudo apachectl -S
```

---

## 13. Test Login

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

## 14. Troubleshooting

### OIDC Errors

```bash
sudo tail -50 /var/log/httpd/error_log | grep -i oidc
```

**Common issue: Redirect URI mismatch**
- Check Azure AD app has redirect URI: `https://${PUBLIC_HOSTNAME}/oidc`
- NOT `https://${OOD_HOSTNAME}/oidc`

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

## 15. Recommended Next Steps

- Enforce MFA with Conditional Access
- Restrict Entra app to allowed users/groups
- Configure Slurm / PBS
- Enable Interactive Desktop (TurboVNC / noVNC)
- Add NFS-backed home directories

---

## 16. Tips:

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