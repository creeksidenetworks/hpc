## 1. Nginx Proxy Manager (NPM) Configuration

In the NPM Web UI, create a new **Proxy Host**:

### **Details Tab**

* **Domain Names:** `ood.usa.logicsilicon.net`
* **Scheme:** `http`
* **Forward Hostname/IP:** (The IP or internal FQDN of your OOD VM)
* **Forward Port:** `8080`
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

```

---

## 2. Update OOD Server Configuration

Now, you must tell the OOD server that its "public" identity has changed. Even though OOD is receiving traffic on port 8080 via HTTP, it needs to know that the user sees `https://ood.usa.logicsilicon.net`.

Edit `/etc/ood/config/ood_portal.yml` on the **OOD VM**:

```yaml
# /etc/ood/config/ood_portal.yml
servername: ood.usa.logicsilicon.net
port: 8080
protocol: http

# This ensures OOD generates internal links with HTTPS
# even though the local Apache is running HTTP
proxy_server: https://ood.usa.logicsilicon.net

```

**Apply the changes:**

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd

```

---

## 3. Security Check: Trusted Proxies

OOD is now receiving all traffic from your NPM IP address. For security and proper logging, you should ensure Apache trusts the proxy IP.

### **The "Redirect Loop" Trap**

If you find yourself stuck in a loop where the URL keeps adding `/pun/sys/dashboard`, it is almost always because the `X-Forwarded-Proto` header isn't reaching OOD. Apache thinks the request is insecure and tries to redirect to what it *thinks* is a secure port.

Verify that your NPM "Advanced" config (Step 1) includes:
`proxy_set_header X-Forwarded-Proto $scheme;`

---

## Updated Documentation Note

Add this section to your Markdown notes:

### **Reverse Proxy via NPM**

* **External URL:** `https://ood.usa.logicsilicon.net`
* **Internal Access:** `http://<OOD_IP>:8080`
* **NPM Requirement:** **Websockets** must be enabled.
* **OOD Config:** `proxy_server` directive in `ood_portal.yml` must match the external HTTPS URL.

Would you like me to show you how to configure the **Interactive Desktop (VNC)** now that the proxy is set up to handle those connections?