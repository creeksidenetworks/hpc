# Open OnDemand Setup Notes: Rocky 8 + FreeIPA

**Host:** `ood.usa.example.local`

**Access:** `https://ood.usa.example.local`

**Authentication:** PAM via SSSD (FreeIPA)

## 1. Repository & Package Installation

Ensure the system is prepared with the OOD repo and necessary Apache modules.

**Install OOD Release and EPEL**
```bash
sudo dnf install -y https://yum.osc.edu/ondemand/3.1/ondemand-release-web-3.1-1.el8.noarch.rpm
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled powertools
```
**Install Core Components**
```bash
sudo dnf install -y ondemand mod_authnz_pam

```

## 2. Portal Configuration

**Generate SSL Certificate:**

OOD runs HTTPS with a self-signed cert that NPM ignores:

```bash
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/pki/tls/private/ood.key \
  -out /etc/pki/tls/certs/ood.crt \
  -subj "/CN=ood.usa.example.local"
```

```bash
sudo chown root:root /etc/pki/tls/private/ood.key
sudo chmod 600 /etc/pki/tls/private/ood.key
```


The primary configuration is managed via `/etc/ood/config/ood_portal.yml`.

```bash
sudo sudo nano /etc/ood/config/ood_portal.yml
```

```yaml
servername: ood.usa.example.local
port: 443
ssl:
  - SSLCertificateKeyFile /etc/pki/tls/private/ood.key
  - SSLCertificateFile /etc/pki/tls/certs/ood.crt 

# Use PAM for FreeIPA Integration
auth:
  - "AuthType Basic"
  - "AuthName 'Open OnDemand'"
  - "AuthBasicProvider PAM"
  - "AuthPAMService ood"
  - "Require valid-user"

```

**Apply changes:**

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
```

## 3. Apache & Module Fixes

Because Rocky 8 may not automatically load the PAM module, these manual overrides are required.

### Force Load PAM Module

```bash
echo "LoadModule authnz_pam_module modules/mod_authnz_pam.so" | sudo tee /etc/httpd/conf.modules.d/00-authnz-pam.conf
```

## 4. FreeIPA (SSSD) Integration

For Apache to verify passwords against FreeIPA, it needs a PAM service definition and permission to talk to SSSD.

### Create PAM Service
```bash
echo "auth    required    pam_sss.so
account required    pam_sss.so" | sudo tee /etc/pam.d/ood
```

### Grant Pipe Permissions

By default, the `apache` user cannot access the SSSD PAM pipe.

```bash
sudo chmod 755 /var/lib/sss/pipes/
sudo chmod 666 /var/lib/sss/pipes/pam
```

## 5. Security & Firewall (Rocky 8)

Adjust SELinux and Firewalld to allow traffic on the non-standard port.

```bash
# SELinux: Allow Apache to bind to 443
sudo semanage port -a -t http_port_t -p tcp 443

# SELinux: Allow Apache to connect to user PUNs
sudo setsebool -P httpd_can_network_connect on

# Firewall: Open 8080
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

## 6. Service Management

Commands to restart the stack:

```bash
sudo systemctl restart sssd
sudo systemctl restart httpd

```

---

### Troubleshooting Checklist

* **Logs:** Check `/var/log/httpd/ood.usa.example.local_error.log`.
* **Config Test:** Run `apachectl configtest` to find syntax errors.
* **PUN Issues:** If you log in but get an error, check `/var/log/ondemand-nginx/$USER/error.log`.

---

Would you like me to help you configure the **Cluster Definition** files next so you can actually submit jobs to your scheduler through the dashboard?