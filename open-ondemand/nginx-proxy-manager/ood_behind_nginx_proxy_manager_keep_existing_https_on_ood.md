# Deploying NGINX Proxy Manager in Front of Open OnDemand (Keeping Existing HTTPS on OOD)

## Document Purpose

This guide describes how to deploy **NGINX Proxy Manager (NPM)** in front of an existing **Open OnDemand (OOD)** server **without changing OOD’s current HTTPS configuration**, authentication model, or Microsoft 365 (OIDC) integration.

In this model:
- OOD continues to use its **existing Let’s Encrypt certificates**
- NPM performs **public SSL termination**
- Backend HTTPS is preserved
- Expired backend certificates are **tolerated intentionally**

This approach minimizes configuration changes and avoids OIDC redirect issues.

---

## 1. Architecture Overview

```
Users / Internet
        |
        v
NGINX Proxy Manager
10.180.13.100
(SSL termination)
        |
        v
Open OnDemand Server
10.180.10.100
(HTTPS + MS365 OIDC)
```

### Key Characteristics

- **Public hostname remains unchanged** (critical for MS365 OIDC)
- **OIDC handled entirely by OOD**
- NPM is a **pure reverse proxy**
- Backend certificate validation is **disabled by design**

---

## 2. DNS Requirements

Your public DNS must point to **NGINX Proxy Manager**, not the OOD server:

```
ondemand.example.com → 10.180.13.100
```

> IMPORTANT:
> The hostname **must exactly match**:
> - Microsoft Entra ID redirect URIs
> - OOD `oidc_uri`
> - Apache `ServerName`

---

## 3. Deploy NGINX Proxy Manager

### 3.1 Docker Compose Deployment

On host **10.180.13.100**:

```yaml
version: "3.8"

services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
```

Start NPM:

```bash
docker compose up -d
```

---

### 3.2 Initial Login

Access the admin UI:

```
http://10.180.13.100:81
```

Default credentials:

```
Email:    admin@example.com
Password: changeme
```

---

## 4. SSL Strategy (This Guide’s Assumption)

### Chosen Model: Dual HTTPS (No Backend Changes)

```
Client → HTTPS → NPM → HTTPS → OOD
```

### Important Notes

- NPM **does not validate** backend TLS certificates by default
- Expired, self-signed, or mismatched certificates on OOD:
  - **Will not break user access**
  - **Will not impact MS365 login**
- OOD Let’s Encrypt renewal **may stop working silently**

This is acceptable **by design** for this deployment.

---

## 5. Configure Proxy Host in NPM

### 5.1 Create Proxy Host

Navigate to:

```
NPM → Hosts → Proxy Hosts → Add Proxy Host
```

#### Details Tab

```
Domain Names: ondemand.example.com
Scheme: https
Forward Hostname / IP: 10.180.10.100
Forward Port: 443
Cache Assets: OFF
Block Common Exploits: ON
Websockets Support: ON
```

> WebSockets are required for interactive OOD apps.

---

### 5.2 SSL Tab

```
SSL Certificate: Request a new SSL Certificate
Force SSL: ON
HTTP/2 Support: ON
HSTS: Optional
```

This certificate is the **only one visible to users**.

---

### 5.3 Advanced Configuration (Required)

Paste the following into **Advanced → Custom Nginx Configuration**:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-Port 443;

proxy_read_timeout 86400;
proxy_send_timeout 86400;
```

These headers ensure:
- Correct OIDC redirect URLs
- Proper session handling
- Stable WebSocket connections

---

## 6. Open OnDemand Server Configuration

### 6.1 Minimal Apache Trust Configuration

On **10.180.10.100**, edit:

```
/etc/httpd/conf.d/ood.conf
```

Add:

```apache
RemoteIPHeader X-Forwarded-For
RemoteIPTrustedProxy 10.180.13.100
```

Restart Apache:

```bash
systemctl restart httpd
```

> No SSL, OIDC, or virtual host changes are required.

---

## 7. Microsoft Entra ID (Azure AD) Validation

Ensure the redirect URI exists:

```
https://ondemand.example.com/oidc
```

No changes are required if OOD already worked before adding NPM.

---

## 8. Firewall Rules

Allow the following:

```
Clients → NPM (10.180.13.100): TCP 80, 443
NPM → OOD (10.180.10.100): TCP 443
```

---

## 9. Certificate Expiration Behavior (Intentional)

### If OOD Let’s Encrypt Certificates Expire

- User access: ✅ continues working
- MS365 login: ✅ unaffected
- NPM proxying: ✅ unaffected
- Backend HTTPS warnings: ⚠️ internal only

### Why This Is Safe Here

- Users never see backend certificates
- NPM does not verify backend TLS by default
- Internal RFC1918 network

---

## 10. Validation Checklist

- Open https://ondemand.example.com
- Redirects to Microsoft 365 login
- Successful login returns to OOD dashboard
- Interactive apps launch correctly
- No browser certificate warnings

---

## 11. Known Limitations (Accepted)

- Backend cert renewal may fail silently
- Internal HTTPS monitoring may show warnings
- Backend TLS trust is relaxed

These are **explicit trade-offs** chosen for minimal disruption.

---

## 12. Summary

| Component | Role |
|---------|-----|
| NGINX Proxy Manager | Public SSL + reverse proxy |
| Open OnDemand | OIDC auth + application routing |
| Microsoft 365 | Identity Provider |

This deployment prioritizes:
- Stability
- Minimal change
- OIDC safety

Future migration to HTTP backend or internal CA can be done later without user impact.

---

**End of Document**

