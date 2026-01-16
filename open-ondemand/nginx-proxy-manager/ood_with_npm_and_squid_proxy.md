# Open OnDemand with Nginx Proxy Manager and Squid Outbound Proxy

## Document Purpose

This guide extends the existing **NGINX Proxy Manager (NPM)** deployment by adding a **Squid proxy server** to handle outbound internet traffic from the OOD server. This setup is necessary when:

- OOD server has **no direct internet access**
- All outbound traffic must route through a **Squid proxy** on a separate VM
- **MS365 OIDC authentication** must still work through the proxy chain
- NPM handles **inbound SSL/HTTPS** and reverse proxy duties

---

## 1. Architecture Overview

```
Users / Internet
        |
        v
NGINX Proxy Manager (10.180.13.100)
(Public SSL termination + reverse proxy)
        |
        v
Open OnDemand Server (10.180.10.100)
(HTTPS + MS365 OIDC)
        |
        v
Squid Proxy Server (10.180.14.100)
(Outbound internet traffic handling)
        |
        v
Internet
```

### Key Characteristics

- **NPM**: Handles inbound requests from users, SSL termination, reverse proxy
- **OOD**: Runs with OIDC authentication, routes outbound traffic through Squid
- **Squid**: Manages all outbound HTTP/HTTPS connections from OOD
- **OIDC authentication**: Works transparently through the proxy chain

---

## 2. DNS Requirements

```
ondemand.example.com → 10.180.13.100 (NPM public IP)
squid.example.local → 10.180.14.100  (internal Squid server)
ood.example.local → 10.180.10.100    (internal OOD server)
```

---

## 3. Prerequisites

This guide assumes:
- NPM already deployed at **10.180.13.100** (see existing NPM guide)
- OOD already running at **10.180.10.100** with OIDC configured
- New Squid server at **10.180.14.100** on the same internal network
- All three VMs can communicate on the internal network
- FreeIPA integration already working on OOD

---

## 4. Deploy Squid Proxy Server

### 4.1 Create Squid Configuration

On **10.180.14.100**, create `/etc/squid/squid.conf`:

```bash
sudo vi /etc/squid/squid.conf
```

Replace the entire file with:

```conf
# ===== NETWORK =====
http_port 3128
visible_hostname squid.example.local
forwarded_for delete

# ===== LOGGING =====
logformat combined    %>A %[ui %[un [%tl] "%rm %ru HTTP/%rv" %Hs %<st "%{Referer}>h" "%{User-Agent}>h" %Tr
access_log /var/log/squid/access.log combined
cache_log /var/log/squid/cache.log

# ===== ACL RULES =====
# Allow traffic from OOD server
acl localnet src 10.180.10.100

# Allow common OIDC/OAuth ports
acl Safe_ports port 80 443 22 3128
acl Connect_ports port 443 563

# Allow authentication services
acl oidc_services dstdom_regex ^login\.microsoftonline\.com$ ^graph\.microsoft\.com$

# ===== ACCESS RULES =====
# Deny non-safe ports
http_access deny !Safe_ports

# Deny CONNECT to non-SSL ports
http_access deny CONNECT !Connect_ports

# Allow OOD server with standard restrictions
http_access allow localnet
http_access allow oidc_services

# Default deny
http_access deny all

# ===== CACHING =====
cache_dir ufs /var/spool/squid 100 16 256
maximum_object_size 512 MB
maximum_object_size_in_memory 64 KB

# ===== TIMEOUTS =====
connect_timeout 10 seconds
read_timeout 15 minutes

# ===== PERFORMANCE =====
workers 4
max_filedescriptors 65536
```

### 4.2 Create System User and Directories

```bash
sudo useradd -r -s /bin/false squid 2>/dev/null || true
sudo mkdir -p /var/spool/squid /var/log/squid
sudo chown -R squid:squid /var/spool/squid /var/log/squid
sudo chmod -R 755 /var/spool/squid
```

### 4.3 Initialize Squid Cache

```bash
sudo /usr/sbin/squid -z
```

### 4.4 Enable and Start Squid

```bash
sudo systemctl enable squid
sudo systemctl start squid
sudo systemctl status squid
```

### 4.5 Verify Squid is Running

```bash
sudo netstat -tlnp | grep squid
sudo curl -x http://squid.example.local:3128 http://example.com
```

---

## 5. Configure Open OnDemand to Use Squid

### 5.1 System-Level Proxy Configuration

On **10.180.10.100** (OOD server), set environment variables that most tools respect:

#### Option A: Global System Environment (for all users)

Create `/etc/profile.d/squid-proxy.sh`:

```bash
sudo tee /etc/profile.d/squid-proxy.sh > /dev/null <<'EOF'
# Squid proxy configuration for outbound traffic
export http_proxy=http://squid.example.local:3128
export https_proxy=http://squid.example.local:3128
export HTTP_PROXY=http://squid.example.local:3128
export HTTPS_PROXY=http://squid.example.local:3128
export no_proxy=localhost,127.0.0.1,10.180.0.0/16,.example.local
export NO_PROXY=localhost,127.0.0.1,10.180.0.0/16,.example.local
EOF

sudo chmod +x /etc/profile.d/squid-proxy.sh
```

#### Option B: Apache-Specific Configuration

Edit `/etc/httpd/conf.d/ood-env.conf`:

```bash
sudo tee /etc/httpd/conf.d/ood-env.conf > /dev/null <<'EOF'
# Environment variables for Apache processes
SetEnv http_proxy http://squid.example.local:3128
SetEnv https_proxy http://squid.example.local:3128
SetEnv HTTP_PROXY http://squid.example.local:3128
SetEnv HTTPS_PROXY http://squid.example.local:3128
SetEnv no_proxy localhost,127.0.0.1,10.180.0.0/16,.example.local
SetEnv NO_PROXY localhost,127.0.0.1,10.180.0.0/16,.example.local
EOF
```

### 5.2 Node.js Application Proxy (if running node-based OOD apps)

Create `/etc/ondemand-d/nodes.d/squid-proxy.yml`:

```yaml
---
node_type: 'node'
title: 'Node.js Apps'
host: 'localhost'
port: 3000

# Environment passed to Node.js processes
env:
  http_proxy: 'http://squid.example.local:3128'
  https_proxy: 'http://squid.example.local:3128'
  HTTP_PROXY: 'http://squid.example.local:3128'
  HTTPS_PROXY: 'http://squid.example.local:3128'
  no_proxy: 'localhost,127.0.0.1,10.180.0.0/16,.example.local'
  NODE_TLS_REJECT_UNAUTHORIZED: '0'
```

### 5.3 curl Configuration

Create `/etc/curlrc` or `~/.curlrc`:

```bash
sudo tee /etc/curlrc > /dev/null <<'EOF'
proxy = http://squid.example.local:3128
EOF
```

### 5.4 wget Configuration

Create or edit `~/.wgetrc`:

```bash
cat > ~/.wgetrc <<'EOF'
# Wget proxy configuration
http_proxy=http://squid.example.local:3128
https_proxy=http://squid.example.local:3128
no_proxy=localhost,127.0.0.1,10.180.0.0/16,.example.local
EOF

chmod 600 ~/.wgetrc
```

### 5.5 YUM/DNF Package Manager Proxy (if needed for package updates)

Edit `/etc/dnf/dnf.conf` or `/etc/yum.conf`:

```bash
sudo bash -c 'echo "proxy=http://squid.example.local:3128" >> /etc/dnf/dnf.conf'
```

### 5.6 Restart Apache (OOD)

```bash
sudo systemctl restart httpd
```

---

## 6. OIDC Authentication Through Proxy

### 6.1 Critical: mod_auth_openidc Configuration

Edit `/etc/httpd/conf.d/auth_openidc.conf` and add proxy settings:

```apache
# Pass proxy environment to OIDC authentication
SetEnv http_proxy http://squid.example.local:3128
SetEnv https_proxy http://squid.example.local:3128
SetEnv HTTP_PROXY http://squid.example.local:3128
SetEnv HTTPS_PROXY http://squid.example.local:3128

# OIDC Configuration (existing settings)
OIDCProviderMetadataURL https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration
OIDCClientID your-client-id
OIDCClientSecret your-client-secret
OIDCRedirectURI https://ondemand.example.com/oidc
OIDCCryptoPassphrase your-crypto-passphrase
OIDCAuthRequestParams scope=openid%20profile%20email
OIDCRemoteUserClaimName preferred_username
```

### 6.2 Verify OIDC Metadata Fetch

Test that metadata can be fetched through Squid:

```bash
export http_proxy=http://squid.example.local:3128
export https_proxy=http://squid.example.local:3128

curl -v https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration
```

If successful, you should see the OIDC metadata.

---

## 7. Network Connectivity Verification

### 7.1 From OOD Server (10.180.10.100)

```bash
# Test DNS
nslookup squid.example.local

# Test Squid connectivity
telnet squid.example.local 3128

# Test proxy through curl
curl -x http://squid.example.local:3128 -v https://www.example.com

# Test OIDC endpoint
curl -x http://squid.example.local:3128 -v https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration | head -20
```

### 7.2 From Squid Server (10.180.14.100)

```bash
# Check listening ports
sudo netstat -tlnp | grep squid

# Monitor access logs in real-time
sudo tail -f /var/log/squid/access.log

# Check cache status
sudo squid -k check
```

### 7.3 Monitor Squid Cache

```bash
# See current connections
sudo tail -20 /var/log/squid/access.log

# Filter for errors
sudo grep "TCP_DENIED\|TCP_MISS" /var/log/squid/access.log | tail -20
```

---

## 8. Firewall Rules

### 8.1 OOD Server (10.180.10.100)

Allow outbound to Squid:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="10.180.14.100" port protocol="tcp" port="3128" accept'
sudo firewall-cmd --reload
```

### 8.2 Squid Server (10.180.14.100)

Allow inbound from OOD:

```bash
sudo firewall-cmd --permanent --add-source=10.180.10.100/32 --zone=trusted
sudo firewall-cmd --permanent --add-port=3128/tcp
sudo firewall-cmd --reload
```

### 8.3 NPM Server (10.180.13.100)

Ensure it can still reach OOD:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="10.180.10.100" port protocol="tcp" port="443" accept'
sudo firewall-cmd --reload
```

---

## 9. Testing Workflow

### 9.1 Test OIDC Login

1. Open browser to `https://ondemand.example.com`
2. Verify redirect to MS365 login
3. Check Squid logs for OIDC endpoint requests:

```bash
sudo grep "login.microsoftonline.com" /var/log/squid/access.log
```

4. Should see: `TCP_TUNNEL/200` for CONNECT requests to Microsoft endpoints

### 9.2 Test Application Access

1. Launch an interactive OOD app
2. Monitor Squid logs:

```bash
sudo tail -f /var/log/squid/access.log
```

3. Verify no `TCP_DENIED` entries for legitimate traffic

### 9.3 Test Package Manager (if needed)

```bash
sudo dnf update -y
# Check Squid logs for package repository requests
sudo grep "\.rpm\|\.repository" /var/log/squid/access.log | tail -10
```

---

## 10. Performance Tuning

### 10.1 Squid Cache Optimization

Edit `/etc/squid/squid.conf`:

```conf
# Increase cache size if needed
cache_dir ufs /var/spool/squid 500 16 256

# Memory cache
cache_mem 256 MB

# Cache hierarchy
cache_dir ufs /var/spool/squid 500 16 256 min-size=0 max-size=1024000

# Refresh patterns for common content
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?)     0    0%      0
refresh_pattern .               0       20%     4320
```

Restart Squid:

```bash
sudo systemctl restart squid
```

### 10.2 OOD Connection Pool (for OIDC)

Edit `/etc/httpd/conf.d/auth_openidc.conf`:

```apache
# Connection pooling for OIDC metadata refresh
OIDCMetadataRefreshInterval 86400
OIDCHTTPTimeoutLong 60
```

---

## 11. Troubleshooting

### Issue: OIDC Login Fails

**Symptoms:**
- Redirect to MS365 login works
- But authentication fails or redirects back

**Solution:**
```bash
# 1. Check Squid is accessible
curl -x http://squid.example.local:3128 -v https://login.microsoftonline.com

# 2. Check Squid logs for blocked requests
sudo grep "TCP_DENIED" /var/log/squid/access.log | head -10

# 3. Verify OIDC metadata can be fetched
curl -x http://squid.example.local:3128 https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration

# 4. Check Apache error logs
sudo tail -50 /var/log/httpd/error_log | grep -i oidc
```

### Issue: Squid Connection Refused

**Symptoms:**
- `curl: (7) Failed to connect to proxy`

**Solution:**
```bash
# 1. Verify Squid is running
sudo systemctl status squid

# 2. Check if listening on 3128
sudo netstat -tlnp | grep 3128

# 3. Check firewall
sudo firewall-cmd --list-all

# 4. Verify DNS
nslookup squid.example.local

# 5. Test direct TCP
telnet squid.example.local 3128
```

### Issue: HTTPS Connections Blocked

**Symptoms:**
- `TCP_DENIED` in Squid logs
- HTTPS connections fail

**Solution:**
```conf
# In /etc/squid/squid.conf, ensure CONNECT is allowed:
acl Connect_ports port 443 563
http_access allow CONNECT Connect_ports
```

---

## 12. Validation Checklist

- [ ] Squid server running at 10.180.14.100:3128
- [ ] OOD can resolve `squid.example.local`
- [ ] OOD can connect to Squid on port 3128
- [ ] `curl -x http://squid.example.local:3128 https://example.com` works from OOD
- [ ] Environment variables set on OOD server
- [ ] OIDC metadata fetch succeeds through Squid
- [ ] MS365 login completes successfully
- [ ] Interactive OOD apps launch and respond
- [ ] Squid logs show successful requests (`TCP_TUNNEL/200`)
- [ ] No `TCP_DENIED` entries for legitimate traffic

---

## 13. Architecture Summary

| Component | IP | Port | Function |
|-----------|----|----|----------|
| NGINX Proxy Manager | 10.180.13.100 | 80, 443, 81 | Public SSL + reverse proxy |
| Open OnDemand | 10.180.10.100 | 443 | OIDC auth + app hosting |
| Squid Proxy | 10.180.14.100 | 3128 | Outbound traffic gateway |
| Microsoft 365 | Internet | 443 | OIDC identity provider |
| FreeIPA | 10.180.x.x | 389, 636 | Identity management |

---

## 14. Security Notes

1. **Squid ACLs**: Restrict source IPs to only OOD server (10.180.10.100)
2. **Port 3128**: Keep on internal network only—do not expose to internet
3. **Logging**: Monitor `/var/log/squid/access.log` for suspicious requests
4. **Credentials**: Never log HTTP authentication headers:
   ```conf
   # In squid.conf (already done):
   strip_query_string on
   ```
5. **HTTPS Inspection**: Squid does **not** decrypt HTTPS—only uses CONNECT tunneling (safe for OIDC)

---

## 15. Next Steps

### If You Need:

- **Advanced caching**: Configure refresh patterns for OOD API responses
- **Load balancing**: Add a second Squid server with failover
- **Monitoring**: Integrate Squid metrics into your monitoring system
- **SSL inspection** (advanced): Use a transparent Squid proxy with certificate injection (requires careful OIDC testing)

---

**End of Document**
