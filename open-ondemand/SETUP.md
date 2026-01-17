# Open OnDemand Setup Instructions

This directory contains automated installation scripts for Open OnDemand with Microsoft Entra ID (Azure AD) authentication.

## Files

- **`setup.sh`** - Main installation script (run with `sudo`)
- **`ood.init`** - Configuration file (customize before running setup.sh)
- **`README.md`** - Comprehensive deployment guide

## Quick Start

### 1. Prepare Configuration File

Copy and customize `ood.init` with your environment details:

```bash
cp ood.init.example ood.init  # or edit the existing ood.init
vi ood.init
```

Required values to set:

```bash
DOMAIN_LOCAL=your-freeipa-domain.local    # e.g., corp.local
DOMAIN_COM=your-public-domain.com         # e.g., company.com
EMAIL_DOMAIN=your-email-domain.com        # e.g., company.com

OOD_IP=10.1.41.100                        # OOD server IP
NPM_IP=10.1.43.100                        # NGINX Proxy Manager IP
SQUID_IP=10.1.43.100                      # Squid proxy IP

OOD_HOSTNAME=ood.your-domain.local        # Internal OOD hostname
PUBLIC_HOSTNAME=ondemand.your-domain.com  # Public-facing hostname
PUBLIC_PORT=443                           # 443 or custom port (e.g., 58443)
SQUID_HOSTNAME=squid.your-domain.local    # Squid hostname

AZURE_TENANT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
AZURE_CLIENT_SECRET=your-client-secret
```

### 2. Run Installation Script

```bash
sudo ./setup.sh
```

The script will:
1. Load and validate all configuration values from `ood.init`
2. Display a summary of all settings
3. Ask for confirmation before proceeding
4. Verify system requirements (Rocky Linux 9, FreeIPA enrollment)
5. Install and configure Open OnDemand
6. Output next steps

### 3. Configure NGINX Proxy Manager

After the script completes:

1. Access NPM web UI at `https://NPM_IP:81`
2. Add a proxy host:
   - Domain: `PUBLIC_HOSTNAME`
   - Forward to: `https://OOD_IP:PUBLIC_PORT`
3. Add custom Nginx location block with `proxy_redirect` directives (see README.md section 3.1)

### 4. Update Azure AD Configuration

1. Go to **Azure Portal → App registrations → [Your App] → Authentication**
2. Add Redirect URI:
   ```
   https://PUBLIC_HOSTNAME:PUBLIC_PORT/oidc/
   ```
3. Click **Save**

### 5. Verify DNS

Ensure DNS resolves `PUBLIC_HOSTNAME` to NPM IP address:

```bash
nslookup PUBLIC_HOSTNAME
```

Should return: `NPM_IP`

### 6. Test Login

Open browser to:
```
https://PUBLIC_HOSTNAME:PUBLIC_PORT
```

Should redirect to Microsoft 365 login, then to OOD dashboard after authentication.

## Configuration File Format

The `ood.init` file uses simple `KEY=VALUE` format:

```bash
# Comments start with #
DOMAIN_LOCAL=example.local
AZURE_TENANT_ID=your-tenant-id
```

**Important:**
- No quotes around values
- No spaces around `=`
- All variables must be set (no empty values)
- Azure credentials must not contain placeholder text

## Troubleshooting

### Missing ood.init file

```
Error: Configuration file not found: /path/to/ood.init
```

**Fix:** Copy and customize `ood.init` in the same directory as `setup.sh`

### Missing configuration values

```
Error: Missing or invalid configuration values:
DOMAIN_LOCAL
AZURE_TENANT_ID
...
```

**Fix:** Edit `ood.init` and set all required values

### Installation fails on system verification

```
Error: This script requires Rocky Linux 9
Error: System is not enrolled in FreeIPA domain
```

**Fix:** 
- Ensure running on Rocky Linux 9: `cat /etc/os-release`
- Enroll in FreeIPA: `realm join DOMAIN_LOCAL`

## Manual Steps After Installation

1. **NPM Configuration** (cannot be automated due to UI-based setup):
   - Navigate to NPM web UI
   - Add proxy location block with `proxy_redirect` directives
   - See README.md section 3.1 for exact configuration

2. **Azure AD Redirect URI**:
   - Add exact redirect URI to Azure app registration
   - Must include port and trailing slash

3. **DNS Resolution**:
   - Verify `PUBLIC_HOSTNAME` resolves to NPM IP
   - Use `nslookup` or `dig` to verify

## Useful Commands

### Check Apache status
```bash
sudo systemctl status httpd
sudo ss -tlnp | grep httpd
```

### View Apache error log
```bash
sudo tail -f /var/log/httpd/error_log
```

### Test OOD connectivity from OOD server
```bash
curl -k https://localhost:PUBLIC_PORT/
```

### Reload Apache
```bash
sudo systemctl restart httpd
```

### Verify FreeIPA enrollment
```bash
realm list
id test-user@DOMAIN_LOCAL
```

### Check user mapping script
```bash
/opt/ood/site/custom-user-mapping.sh "user@EMAIL_DOMAIN"
```

## Next Steps

See **README.md** for:
- Complete architecture overview
- Network configuration details
- Troubleshooting OIDC errors
- Recommended security configurations
- Advanced customizations

## Support

For issues, check:
1. `/var/log/httpd/error_log` - Apache errors
2. `/var/log/httpd/access_log` - Access logs
3. `/var/log/squid/access.log` - Squid proxy logs (if Squid is separate)
4. README.md section 15 - Troubleshooting guide
