## 1. Nginx Proxy Manager (NPM) Configuration

In the NPM Web UI, create a new **Proxy Host**:

### **Details Tab**

* **Domain Names:** `ood.example.com`
* **Scheme:** `https`
* **Forward Hostname/IP:** (The IP or internal FQDN of your OOD VM)
* **Forward Port:** `443`
* **Websockets Support:** **ON** (Essential for Shell/VNC)
* **Block Common Exploits:** ON

### **SSL Tab**

* **SSL Certificate:** Select your certificate (Let's Encrypt or Custom).
* **Force SSL:** ON
* **HTTP/2 Support:** ON

### **Advanced Tab (Crucial)**

OOD requires the original host header and several proxy headers to function without getting stuck in redirect loops. Paste this into the **Custom Nginx Configuration** box:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Real-IP $remote_addr;

# Increase upload limits for File Manager
client_max_body_size 10G;

# Allow NPM to talk to OOD's self-signed certificate
proxy_ssl_verify off;
proxy_ssl_server_name on;

```

---

## 2. Update OOD Server Configuration

Now, you must tell the OOD server that its "public" identity has changed. Even though OOD is receiving traffic on port 8080 via HTTP, it needs to know that the user sees `https://ood.example.com`.

Edit `/etc/ood/config/ood_portal.yml` on the **OOD VM**:

```yaml
# /etc/ood/config/ood_portal.yml
servername: ood.example.com
proxy_server: ood.example.com

ssl:
  - SSLCertificateKeyFile /etc/pki/tls/private/ood.key
  - SSLCertificateFile /etc/pki/tls/certs/ood.crt

auth:
  - "AuthType Basic"
  - "AuthName 'Open OnDemand'"
  - "AuthBasicProvider PAM"
  - "AuthPAMService ood"
  - "Require valid-user"

```

**Apply the changes:**

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd

```

---

