# LXD Desktop Container Setup Guide for Open OnDemand

## Overview

This guide provides step-by-step instructions for setting up persistent LXD desktop containers integrated with Open OnDemand (OOD), FreeIPA authentication, and shared home directories.

### Architecture

```
User → Nginx Proxy Manager (58443) → Open OnDemand
                                           ↓
                                    LXD API/Service Account
                                           ↓
                              User Desktop Containers (Rocky 8 + XFCE)
                                           ↓
                                 Shared Storage (/mnt/unixhomes)
```

### Environment Details
- **FreeIPA Domain**: csn.corp
- **FreeIPA Realm**: CSN.CORP
- **LXD Host**: Ubuntu 22.04
- **Desktop OS**: Rocky Linux 8 with XFCE
- **Shared Storage**: `/mnt/unixhomes` on LXD host
- **Access**: Embedded NoVNC within OOD web interface

---

## Phase 1: Prepare LXD Host

### 1.1 Configure LXD for Remote Access

```bash
# On Ubuntu 22.04 LXD host
# Enable HTTPS API access
lxc config set core.https_address "[::]:8443"

# Set a secure password for initial authentication
lxc config set core.trust_password "ChangeThisSecurePassword123!"

# Enable storage pool if not already configured
lxc storage list
# If no storage pool exists:
lxc storage create default dir source=/var/lib/lxd/storage-pools/default

# Enable network bridge if not already configured
lxc network list
# If no bridge exists:
lxc network create lxdbr0
```

### 1.2 Configure Host Firewall

```bash
# Allow LXD API access only from OOD VM
# Replace OOD_VM_IP with your OOD server IP
OOD_VM_IP="10.x.x.x"

ufw allow from ${OOD_VM_IP} to any port 8443 proto tcp
ufw reload
```

### 1.3 Create Service Account for OOD

```bash
# Create dedicated service account
useradd -r -m -s /bin/bash ood-service

# Create SSH directory
mkdir -p /home/ood-service/.ssh
chmod 700 /home/ood-service/.ssh

# Generate SSH key on OOD VM and copy public key here
# This will be used later
touch /home/ood-service/.ssh/authorized_keys
chmod 600 /home/ood-service/.ssh/authorized_keys
chown -R ood-service:ood-service /home/ood-service/.ssh
```

### 1.4 Create Container Management Scripts

Create `/usr/local/bin/create-user-desktop.sh`:

```bash
#!/bin/bash
# Script: create-user-desktop.sh
# Purpose: Create or start user's persistent desktop container

set -e

USERNAME=$1
CONTAINER_NAME="${USERNAME}-desktop"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

# Verify user exists in FreeIPA
if ! id "$USERNAME" &>/dev/null; then
    echo "Error: User $USERNAME not found in system"
    exit 1
fi

# Get user UID and GID
USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")

echo "Processing desktop container for user: $USERNAME (UID: $USER_UID, GID: $USER_GID)"

# Check if container already exists
if lxc list --format csv -c n | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container ${CONTAINER_NAME} already exists"
    
    # Check if running
    if lxc list --format csv -c ns | grep "^${CONTAINER_NAME}" | grep -q "RUNNING"; then
        echo "Container is already running"
    else
        echo "Starting container..."
        lxc start ${CONTAINER_NAME}
        sleep 5
    fi
else
    echo "Creating new container from template..."
    
    # Create container from template
    lxc copy rocky8-desktop ${CONTAINER_NAME}
    
    # Configure UID/GID mapping for the user
    lxc config set ${CONTAINER_NAME} raw.idmap "both ${USER_UID} ${USER_UID}
both ${USER_GID} ${USER_GID}"
    
    # Mount shared home directory
    lxc config device add ${CONTAINER_NAME} unixhomes disk \
        source=/mnt/unixhomes \
        path=/home
    
    # Set environment variables
    lxc config set ${CONTAINER_NAME} environment.USER=${USERNAME}
    lxc config set ${CONTAINER_NAME} environment.HOME=/home/${USERNAME}
    
    # Start container
    lxc start ${CONTAINER_NAME}
    
    echo "Waiting for container to be ready..."
    sleep 10
    
    # Ensure user home directory exists and has correct permissions
    lxc exec ${CONTAINER_NAME} -- bash -c "
        if [ ! -d /home/${USERNAME} ]; then
            mkdir -p /home/${USERNAME}
            chown ${USER_UID}:${USER_GID} /home/${USERNAME}
            chmod 700 /home/${USERNAME}
        fi
    "
    
    # Initialize VNC server for user
    echo "Initializing VNC server..."
    lxc exec ${CONTAINER_NAME} -- su - ${USERNAME} -c "
        mkdir -p ~/.vnc
        echo 'session=xfce' > ~/.vnc/xstartup
        echo 'startxfce4 &' >> ~/.vnc/xstartup
        chmod +x ~/.vnc/xstartup
        vncserver :1 -geometry 1920x1080 -depth 24 -SecurityTypes None
    "
    
    # Start NoVNC websockify
    lxc exec ${CONTAINER_NAME} -- bash -c "
        nohup /usr/bin/websockify --web /usr/share/novnc 6080 localhost:5901 > /var/log/novnc.log 2>&1 &
    "
    
    echo "Container ${CONTAINER_NAME} created and initialized"
fi

# Get container IP
CONTAINER_IP=$(lxc list ${CONTAINER_NAME} --format csv -c 4 | awk '{print $1}')

if [ -z "$CONTAINER_IP" ]; then
    echo "Warning: Could not retrieve container IP"
    exit 1
fi

echo "Container is ready!"
echo "Container Name: ${CONTAINER_NAME}"
echo "Container IP: ${CONTAINER_IP}"
echo "NoVNC Port: 6080"
echo "VNC Display: :1"
```

Make it executable:

```bash
chmod +x /usr/local/bin/create-user-desktop.sh
```

Create `/usr/local/bin/stop-user-desktop.sh`:

```bash
#!/bin/bash
# Script: stop-user-desktop.sh
# Purpose: Stop user's desktop container

USERNAME=$1
CONTAINER_NAME="${USERNAME}-desktop"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

if lxc list --format csv -c n | grep -q "^${CONTAINER_NAME}$"; then
    echo "Stopping container ${CONTAINER_NAME}..."
    lxc stop ${CONTAINER_NAME}
    echo "Container stopped"
else
    echo "Container ${CONTAINER_NAME} does not exist"
    exit 1
fi
```

Make it executable:

```bash
chmod +x /usr/local/bin/stop-user-desktop.sh
```

Create `/usr/local/bin/delete-user-desktop.sh`:

```bash
#!/bin/bash
# Script: delete-user-desktop.sh
# Purpose: Delete user's desktop container

USERNAME=$1
CONTAINER_NAME="${USERNAME}-desktop"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

if lxc list --format csv -c n | grep -q "^${CONTAINER_NAME}$"; then
    echo "Deleting container ${CONTAINER_NAME}..."
    lxc stop ${CONTAINER_NAME} --force || true
    lxc delete ${CONTAINER_NAME}
    echo "Container deleted"
else
    echo "Container ${CONTAINER_NAME} does not exist"
    exit 1
fi
```

Make it executable:

```bash
chmod +x /usr/local/bin/delete-user-desktop.sh
```

### 1.5 Configure Sudo Access for Service Account

Create `/etc/sudoers.d/ood-service`:

```bash
# Allow ood-service to manage user desktop containers
ood-service ALL=(ALL) NOPASSWD: /usr/local/bin/create-user-desktop.sh
ood-service ALL=(ALL) NOPASSWD: /usr/local/bin/stop-user-desktop.sh
ood-service ALL=(ALL) NOPASSWD: /usr/local/bin/delete-user-desktop.sh
ood-service ALL=(ALL) NOPASSWD: /snap/bin/lxc list *
ood-service ALL=(ALL) NOPASSWD: /snap/bin/lxc exec *
```

Set correct permissions:

```bash
chmod 440 /etc/sudoers.d/ood-service
```

---

## Phase 2: Create Rocky 8 Desktop Container Template

### 2.1 Launch Base Container

```bash
# Launch Rocky Linux 8 container
lxc launch images:rockylinux/8/cloud rocky8-desktop-template

# Wait for container to be ready
sleep 10

# Enter the container
lxc exec rocky8-desktop-template -- bash
```

### 2.2 Configure Container (Inside Container)

```bash
# Update system
dnf update -y

# Install EPEL repository
dnf install -y epel-release

# Install XFCE Desktop Environment
dnf groupinstall -y "Xfce"
dnf install -y @base-x

# Install VNC and NoVNC components
dnf install -y tigervnc-server novnc python3-websockify

# Install additional utilities
dnf install -y \
    xorg-x11-fonts-Type1 \
    xorg-x11-fonts-misc \
    dejavu-sans-fonts \
    dejavu-sans-mono-fonts \
    dejavu-serif-fonts \
    firefox \
    gedit \
    xterm \
    which \
    net-tools \
    vim \
    git \
    curl \
    wget

# Install FreeIPA client
dnf install -y freeipa-client

# Join FreeIPA domain
ipa-client-install \
    --domain=csn.corp \
    --realm=CSN.CORP \
    --server=freeipa.csn.corp \
    --mkhomedir \
    --no-ntp \
    --force-join \
    --unattended \
    --principal=admin \
    --password='YourFreeIPAAdminPassword'

# Configure SSSD to use simple names (no domain suffix)
sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf

# Enable home directory creation on login
authselect enable-feature with-mkhomedir

# Restart SSSD
systemctl restart sssd

# Configure VNC server systemd service template
cat > /etc/systemd/system/vncserver@.service << 'EOF'
[Unit]
Description=Remote desktop service (VNC) for %i
After=syslog.target network.target

[Service]
Type=forking
User=%i
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver -geometry 1920x1080 -depth 24 -SecurityTypes None :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

# Create NoVNC systemd service
cat > /etc/systemd/system/novnc.service << 'EOF'
[Unit]
Description=NoVNC service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web /usr/share/novnc 6080 localhost:5901
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
systemctl daemon-reload

# DO NOT enable services in template - they'll be started per-user

# Clean up
dnf clean all

# Exit container
exit
```

### 2.3 Stop and Publish Template

```bash
# Stop the template container
lxc stop rocky8-desktop-template

# Publish as an image
lxc publish rocky8-desktop-template --alias rocky8-desktop \
    description="Rocky Linux 8 with XFCE desktop and FreeIPA integration"

# Verify image was created
lxc image list

# Optional: Delete the template container (keep the image)
# lxc delete rocky8-desktop-template
```

---

## Phase 3: Open OnDemand Integration

### 3.1 Configure LXD Remote on OOD Server

```bash
# On OOD VM
# Install LXD client (not daemon)
snap install lxd --channel=latest/stable

# Add LXD host as remote
# Replace LXD_HOST_IP with your LXD host IP
LXD_HOST_IP="10.x.x.x"

lxc remote add lxd-host https://${LXD_HOST_IP}:8443 \
    --password="ChangeThisSecurePassword123!" \
    --accept-certificate

# Test connection
lxc list lxd-host:

# Set as default remote for easier management
lxc remote set-default lxd-host
```

### 3.2 Setup SSH Key Authentication

```bash
# On OOD VM - generate SSH key for Apache user (or ondemand user)
su - apache
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Copy public key
cat ~/.ssh/id_ed25519.pub

# On LXD host - add to ood-service authorized_keys
# (Paste the public key from above)
echo "ssh-ed25519 AAAA... apache@ood-server" >> /home/ood-service/.ssh/authorized_keys

# On OOD VM - test SSH connection as apache user
ssh ood-service@LXD_HOST_IP "sudo /usr/local/bin/create-user-desktop.sh testuser"
```

### 3.3 Create OOD Interactive Desktop App

```bash
# On OOD VM
# Create app directory structure
sudo mkdir -p /var/www/ood/apps/sys/desktop-container/{form.yml,template,submit}
cd /var/www/ood/apps/sys/desktop-container
```

Create `manifest.yml`:

```yaml
---
name: Desktop Container
category: Interactive Apps
subcategory: Desktops
role: batch_connect
description: |
  Launch a persistent Rocky Linux 8 desktop container with XFCE
```

Create `form.yml`:

```yaml
---
cluster:
  - "lxd"
attributes:
  desktop_session:
    widget: select
    label: "Desktop Session"
    help: "Select your desktop environment"
    options:
      - ["XFCE (Lightweight)", "xfce"]
    value: "xfce"
  
  bc_num_hours:
    value: 8
    min: 1
    max: 72
    step: 1
    help: "Maximum time your desktop will remain active"
  
  node_type:
    widget: hidden
    value: "container"

form:
  - desktop_session
  - bc_num_hours
```

Create `submit.yml.erb`:

```yaml
---
batch_connect:
  template: "basic"
  websockify_cmd: '/usr/bin/websockify'
  
script:
  native:
    container: "true"
```

Create `template/script.sh.erb`:

```bash
#!/bin/bash

# Open OnDemand batch connect script for LXD desktop containers

set -x
exec &> "<%= session.staged_root.join("output.log") %>"

# Environment variables
LXD_HOST="<%= ENV['LXD_HOST'] || '10.x.x.x' %>"
CONTAINER_NAME="<%= ENV['USER'] %>-desktop"

echo "Starting desktop container for user: <%= ENV['USER'] %>"
echo "Container name: ${CONTAINER_NAME}"
echo "LXD Host: ${LXD_HOST}"

# Create or start the container via SSH
ssh -o StrictHostKeyChecking=no ood-service@${LXD_HOST} \
    "sudo /usr/local/bin/create-user-desktop.sh <%= ENV['USER'] %>" 2>&1

# Wait for container to be fully ready
sleep 10

# Get container IP address
CONTAINER_IP=$(ssh -o StrictHostKeyChecking=no ood-service@${LXD_HOST} \
    "lxc list ${CONTAINER_NAME} --format csv -c 4" | awk '{print $1}')

if [ -z "$CONTAINER_IP" ]; then
    echo "Error: Could not get container IP address"
    exit 1
fi

echo "Container IP: ${CONTAINER_IP}"

# NoVNC is running on port 6080 in the container
host="${CONTAINER_IP}"
port="6080"
password="none"

# Create connection file for OOD
(
  umask 077
  echo "host=${host}" > "<%= session.staged_root.join("connection.yml") %>"
  echo "port=${port}" >> "<%= session.staged_root.join("connection.yml") %>"
  echo "password=${password}" >> "<%= session.staged_root.join("connection.yml") %>"
)

echo "Desktop container is ready!"
echo "Connect to: http://${host}:${port}/vnc.html"
```

Make the script executable:

```bash
chmod +x template/script.sh.erb
```

Create `view.html.erb`:

```erb
<p>Your desktop container is now running and ready to use.</p>

<p>
  <strong>Container:</strong> <%= ENV['USER'] %>-desktop<br>
  <strong>Status:</strong> Running<br>
</p>

<p>
  Click the "Connect to Desktop" button below to access your XFCE desktop environment.
</p>
```

### 3.4 Configure Cluster in OOD

Create or edit `/etc/ood/config/clusters.d/lxd.yml`:

```yaml
---
v2:
  metadata:
    title: "LXD Container Cluster"
    url: "https://your-ood-server.csn.corp"
    hidden: false
  
  login:
    host: "lxd-host.csn.corp"
  
  job:
    adapter: "linux_host"
    submit_host: "lxd-host.csn.corp"
    ssh_hosts:
      - lxd-host.csn.corp
    site_timeout: 7200
    debug: true
    singularity_bin: /usr/bin/apptainer
    singularity_bindpath: /etc,/media,/mnt,/opt,/run,/srv,/usr,/var,/home
    singularity_image: /path/to/default.sif
    # Strict host checking should be true in production
    strict_host_checking: false
    tmux_bin: /usr/bin/tmux
```

### 3.5 Set Environment Variables

Create `/etc/ood/config/apps/bc_desktop/env`:

```bash
# LXD host configuration
export LXD_HOST="10.x.x.x"
export LXD_REMOTE="lxd-host"
```

### 3.6 Update App Permissions

```bash
# Set correct ownership
chown -R apache:apache /var/www/ood/apps/sys/desktop-container

# Restart OOD
sudo systemctl restart httpd
```

---

## Phase 4: Testing and Verification

### 4.1 Test Container Creation Manually

```bash
# On LXD host
sudo /usr/local/bin/create-user-desktop.sh testuser

# Verify container is running
lxc list

# Check container IP
lxc list testuser-desktop --format csv -c 4

# Test VNC connection
# In a browser: http://CONTAINER_IP:6080/vnc.html
```

### 4.2 Test from OOD Interface

1. Log into OOD web interface: `https://your-server:58443`
2. Navigate to **Interactive Apps → Desktop Container**
3. Fill in the form and click **Launch**
4. Wait for the job to start
5. Click **Connect to Desktop**
6. Verify XFCE desktop loads correctly

### 4.3 Verify Home Directory Mounting

Inside the desktop container:

```bash
# Open terminal in XFCE desktop
ls -la ~/

# Create a test file
echo "test from container" > ~/container-test.txt

# Exit and check on host
# On LXD host:
ls -la /mnt/unixhomes/testuser/
cat /mnt/unixhomes/testuser/container-test.txt
```

### 4.4 Verify FreeIPA Integration

```bash
# In container terminal
id
# Should show correct UID/GID from FreeIPA

getent passwd $USER
# Should show user info from FreeIPA

# Test login with FreeIPA password
su - testuser
# Enter FreeIPA password
```

---

## Phase 5: Nginx Proxy Manager Configuration

### 5.1 Create Proxy Host for OOD

In Nginx Proxy Manager web interface:

1. **Add Proxy Host**
   - Domain Names: `ood.csn.corp`
   - Scheme: `https`
   - Forward Hostname/IP: `OOD_VM_IP`
   - Forward Port: `443`
   - Cache Assets: Enabled
   - Block Common Exploits: Enabled
   - Websockets Support: **ENABLED** (Critical for NoVNC)

2. **SSL Tab**
   - SSL Certificate: Use your certificate
   - Force SSL: Enabled
   - HTTP/2 Support: Enabled

3. **Advanced Tab**

```nginx
# Allow large file uploads
client_max_body_size 10G;

# WebSocket support for NoVNC
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

# Timeout settings for long-running sessions
proxy_connect_timeout 7200s;
proxy_send_timeout 7200s;
proxy_read_timeout 7200s;
send_timeout 7200s;

# Headers
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

### 5.2 Configure OOD to Accept Proxy Connections

On OOD server, edit `/etc/ood/config/ood_portal.yml`:

```yaml
---
servername: ood.csn.corp
port: 443
ssl:
  - 'SSLCertificateFile "/etc/pki/tls/certs/ood.crt"'
  - 'SSLCertificateKeyFile "/etc/pki/tls/private/ood.key"'

# Trust proxy headers
use_rewrites: true

# Allow WebSocket connections
lua_root: "/opt/ood/mod_ood_proxy/lib"
lua_log_level: "info"

# User map (if using custom mapping)
user_map_cmd: "/opt/ood/ood_auth_map/bin/ood_auth_map.regex"

# Logging
logroot: "/var/log/ood"
```

Update OOD Apache configuration:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

---

## Phase 6: Troubleshooting

### 6.1 Container Won't Start

```bash
# Check container status
lxc info CONTAINER_NAME

# Check logs
lxc console CONTAINER_NAME --show-log

# Check if storage is available
df -h /var/lib/lxd

# Verify UID/GID mapping
lxc config show CONTAINER_NAME | grep idmap
```

### 6.2 NoVNC Connection Fails

```bash
# Check if NoVNC is running in container
lxc exec CONTAINER_NAME -- netstat -tulpn | grep 6080

# Check if VNC server is running
lxc exec CONTAINER_NAME -- ps aux | grep vnc

# Restart NoVNC manually
lxc exec CONTAINER_NAME -- bash -c "
    pkill websockify
    nohup /usr/bin/websockify --web /usr/share/novnc 6080 localhost:5901 > /var/log/novnc.log 2>&1 &
"

# Check NoVNC logs
lxc exec CONTAINER_NAME -- tail -f /var/log/novnc.log
```

### 6.3 Home Directory Not Mounting

```bash
# Check if device is attached
lxc config device show CONTAINER_NAME

# Verify mount inside container
lxc exec CONTAINER_NAME -- mount | grep home

# Check permissions on host
ls -ld /mnt/unixhomes
ls -l /mnt/unixhomes/

# Verify UID mapping
lxc exec CONTAINER_NAME -- id USERNAME
id USERNAME  # On host
```

### 6.4 FreeIPA Authentication Fails

```bash
# Check SSSD status in container
lxc exec CONTAINER_NAME -- systemctl status sssd

# Test FreeIPA connectivity
lxc exec CONTAINER_NAME -- ping freeipa.csn.corp

# Check SSSD logs
lxc exec CONTAINER_NAME -- tail -f /var/log/sssd/sssd.log

# Re-join FreeIPA if needed
lxc exec CONTAINER_NAME -- ipa-client-install --uninstall
lxc exec CONTAINER_NAME -- ipa-client-install \
    --domain=csn.corp \
    --realm=CSN.CORP \
    --server=freeipa.csn.corp \
    --force-join
```

### 6.5 OOD Can't Connect to Container

```bash
# Test SSH from OOD to LXD host
# On OOD VM as apache user:
su - apache
ssh ood-service@LXD_HOST_IP "lxc list"

# Check container IP is reachable from OOD
ping CONTAINER_IP

# Test NoVNC URL directly
curl -I http://CONTAINER_IP:6080/vnc.html

# Check OOD logs
tail -f /var/log/httpd/error_log
tail -f /var/www/ood/apps/sys/desktop-container/output.log
```

---

## Phase 7: Maintenance and Operations

### 7.1 Container Lifecycle Management

**List all user containers:**
```bash
lxc list | grep desktop
```

**Stop idle containers:**
```bash
# List containers and their resource usage
lxc list --format json | jq -r '.[] | select(.name | endswith("-desktop")) | .name'

# Stop specific container
lxc stop USERNAME-desktop
```

**Delete unused containers:**
```bash
# Delete container (user data in /home is preserved on host)
lxc delete --force USERNAME-desktop
```

### 7.2 Backup and Recovery

**Backup container template:**
```bash
# Export template image
lxc image export rocky8-desktop /backup/rocky8-desktop

# This creates: /backup/rocky8-desktop.tar.gz
```

**Restore template:**
```bash
# Import backup
lxc image import /backup/rocky8-desktop.tar.gz --alias rocky8-desktop-backup

# Use restored image
lxc copy rocky8-desktop-backup NEW_CONTAINER_NAME
```

**Snapshot user container:**
```bash
# Create snapshot
lxc snapshot USERNAME-desktop backup-$(date +%Y%m%d)

# List snapshots
lxc info USERNAME-desktop | grep snap

# Restore from snapshot
lxc restore USERNAME-desktop backup-20260118
```

### 7.3 Updating the Template

When you need to update the desktop environment or install new software:

```bash
# Start a container from template
lxc launch rocky8-desktop update-template

# Make changes
lxc exec update-template -- bash
# Inside container: dnf update -y, install new packages, etc.
# Exit when done

# Stop container
lxc stop update-template

# Publish as new template version
lxc publish update-template --alias rocky8-desktop-v2

# Update default alias
lxc image alias delete rocky8-desktop
lxc image alias create rocky8-desktop rocky8-desktop-v2

# Clean up
lxc delete update-template
```

### 7.4 Monitoring

**Check container resource usage:**
```bash
# CPU and memory usage
lxc list --format table

# Detailed info for specific container
lxc info USERNAME-desktop

# Monitor real-time
watch -n 2 'lxc list --format table'
```

**Set resource limits:**
```bash
# Limit CPU (2 cores)
lxc config set USERNAME-desktop limits.cpu 2

# Limit memory (4GB)
lxc config set USERNAME-desktop limits.memory 4GB

# Limit disk I/O
lxc config device set USERNAME-desktop root limits.read 100MB
lxc config device set USERNAME-desktop root limits.write 100MB
```

---

## Phase 8: Security Hardening

### 8.1 Container Security

**Restrict container capabilities:**
```bash
# Edit template before publishing
lxc config set rocky8-desktop-template security.nesting false
lxc config set rocky8-desktop-template security.privileged false

# Prevent kernel module loading
lxc config set rocky8-desktop-template linux.kernel_modules false
```

**Enable AppArmor:**
```bash
# On Ubuntu host
lxc config set rocky8-desktop-template security.apparmor true
lxc config set rocky8-desktop-template security.apparmor.profile default
```

### 8.2 Network Security

**Restrict container network access:**
```bash
# Create isolated network profile
lxc profile create desktop-restricted

# Configure network with firewall rules
lxc profile device add desktop-restricted eth0 nic \
    nictype=bridged \
    parent=lxdbr0

# Apply to containers
lxc profile add USERNAME-desktop desktop-restricted
```

**Use proxy devices instead of direct network:**
```bash
# Remove direct network access
lxc config device remove USERNAME-desktop eth0

# Add proxy for specific services only
lxc config device add USERNAME-desktop novnc-proxy proxy \
    listen=tcp:0.0.0.0:6080 \
    connect=tcp:127.0.0.1:6080
```

### 8.3 Audit Logging

**Enable container logging:**
```bash
# Configure LXD audit logging
lxc config set core.audit_logging true

# View logs
journalctl -u snap.lxd.daemon

# Container-specific logs
lxc console USERNAME-desktop --show-log
```

---

## Appendix A: Configuration File Reference

### Complete cluster configuration for OOD

`/etc/ood/config/clusters.d/lxd.yml`:
```yaml
---
v2:
  metadata:
    title: "LXD Desktop Cluster"
    url: "https://ood.csn.corp:58443"
    hidden: false
  
  login:
    host: "lxd-host.csn.corp"
  
  job:
    adapter: "linux_host"
    submit_host: "lxd-host.csn.corp"
    ssh_hosts:
      - "lxd-host.csn.corp"
    site_timeout: 7200
    debug: true
    strict_host_checking: false
    tmux_bin: /usr/bin/tmux
```

### OOD Portal Configuration

`/etc/ood/config/ood_portal.yml`:
```yaml
---
servername: ood.csn.corp
port: 443
ssl:
  - 'SSLCertificateFile "/etc/pki/tls/certs/ood.crt"'
  - 'SSLCertificateKeyFile "/etc/pki/tls/private/ood.key"'
  - 'SSLCertificateChainFile "/etc/pki/tls/certs/ood-chain.crt"'

listen_addr_port:
  - '443'

servername_aliases:
  - 'ood.csn.corp'

proxy_server: 'nginx-proxy.csn.corp:58443'

logroot: '/var/log/ood'
errorlog: 'error.log'
accesslog: 'access.log'

use_rewrites: true
use_maintenance: true
maintenance_ip_allowlist:
  - '10.0.0.0/8'

security_csp_frame_ancestors: 
  - 'https://ood.csn.corp:58443'

security_strict_transport: true

lua_root: '/opt/ood/mod_ood_proxy/lib'
lua_log_level: 'info'

user_map_cmd: '/opt/ood/ood_auth_map/bin/ood_auth_map.regex'
user_map_match: '^([^@]+)@.*
user_env: REMOTE_USER

pun_stage_cmd: 'sudo /opt/ood/nginx_stage/sbin/nginx_stage'

auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'

# Session settings
oidc_uri: '/oidc'
oidc_discover_uri: 'https://login.microsoftonline.com/TENANT_ID/v2.0/.well-known/openid-configuration'
oidc_discover_root: 'https://ood.csn.corp:58443'

# FreeIPA integration for user mapping
httpd_auth:
  type: 'freeipa'
```

### Apache OOD Auth Configuration

`/opt/ood/ood_auth_map/bin/ood_auth_map.regex`:
```bash
#!/bin/bash
# Map OIDC authenticated users to local FreeIPA usernames

USERNAME="$1"

# Remove domain suffix if present (user@csn.corp -> user)
LOCAL_USER=$(echo "$USERNAME" | sed 's/@.*$//')

# Verify user exists in FreeIPA
if id "$LOCAL_USER" &>/dev/null; then
    echo "$LOCAL_USER"
    exit 0
else
    # User not found
    exit 1
fi
```

Make executable:
```bash
chmod +x /opt/ood/ood_auth_map/bin/ood_auth_map.regex
```

### Desktop Container App Complete Configuration

`/var/www/ood/apps/sys/desktop-container/manifest.yml`:
```yaml
---
name: Desktop Container
category: Interactive Apps
subcategory: Desktops
role: batch_connect
description: |
  Launch a persistent Rocky Linux 8 desktop container with XFCE desktop environment.
  Your home directory is automatically mounted and changes persist across sessions.
icon: fa://desktop
```

`/var/www/ood/apps/sys/desktop-container/form.yml`:
```yaml
---
cluster:
  - "lxd"

attributes:
  desktop_session:
    widget: select
    label: "Desktop Environment"
    help: "XFCE is a lightweight, fast desktop environment"
    options:
      - ["XFCE Desktop", "xfce"]
    value: "xfce"
  
  bc_num_hours:
    widget: number_field
    label: "Number of hours"
    help: "Maximum time your desktop session will remain active (1-72 hours)"
    value: 8
    min: 1
    max: 72
    step: 1
    required: true
  
  resolution:
    widget: select
    label: "Screen Resolution"
    help: "Select your preferred desktop resolution"
    options:
      - ["1920x1080 (Full HD)", "1920x1080"]
      - ["1600x900 (HD+)", "1600x900"]
      - ["1366x768 (HD)", "1366x768"]
      - ["2560x1440 (2K)", "2560x1440"]
    value: "1920x1080"
  
  node_type:
    widget: hidden
    value: "container"

form:
  - desktop_session
  - resolution
  - bc_num_hours
```

`/var/www/ood/apps/sys/desktop-container/submit.yml.erb`:
```yaml
---
batch_connect:
  template: "vnc"
  websockify_cmd: '/usr/bin/websockify'
  vnc_passwd: ''

script:
  native:
    container: "true"
    singularity_container: false
```

`/var/www/ood/apps/sys/desktop-container/template/script.sh.erb`:
```bash
#!/bin/bash

#
# Open OnDemand Batch Connect Script for LXD Desktop Containers
# This script creates or starts a user's persistent desktop container
#

set -e
set -x

# Redirect all output to log file
exec &> "<%= session.staged_root.join("output.log") %>"

echo "========================================"
echo "Desktop Container Launch Script"
echo "========================================"
echo "User: <%= ENV['USER'] %>"
echo "Session ID: <%= session.id %>"
echo "Time: $(date)"
echo "Resolution: <%= context.resolution || '1920x1080' %>"
echo "========================================"

# Configuration
LXD_HOST="${LXD_HOST:-10.x.x.x}"
CONTAINER_NAME="<%= ENV['USER'] %>-desktop"
RESOLUTION="<%= context.resolution || '1920x1080' %>"
VNC_DISPLAY=":1"
VNC_PORT="5901"
NOVNC_PORT="6080"

echo "LXD Host: ${LXD_HOST}"
echo "Container: ${CONTAINER_NAME}"

# Function to check if container is ready
check_container_ready() {
    local container=$1
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
               ood-service@${LXD_HOST} \
               "lxc list ${container} --format csv -c s" | grep -q "RUNNING"; then
            echo "Container is running"
            return 0
        fi
        echo "Waiting for container to be ready... (attempt $((attempt+1))/${max_attempts})"
        sleep 2
        ((attempt++))
    done
    
    echo "ERROR: Container failed to become ready"
    return 1
}

# Create or start the container
echo "Creating or starting container..."
ssh -o StrictHostKeyChecking=no ood-service@${LXD_HOST} \
    "sudo /usr/local/bin/create-user-desktop.sh <%= ENV['USER'] %>" 2>&1

# Wait for container to be ready
if ! check_container_ready "${CONTAINER_NAME}"; then
    echo "ERROR: Container is not ready after timeout"
    exit 1
fi

# Additional wait for services to fully initialize
echo "Waiting for container services to initialize..."
sleep 10

# Get container IP address
echo "Retrieving container IP address..."
CONTAINER_IP=$(ssh -o StrictHostKeyChecking=no ood-service@${LXD_HOST} \
    "lxc list ${CONTAINER_NAME} --format csv -c 4" | awk '{print $1}')

if [ -z "$CONTAINER_IP" ]; then
    echo "ERROR: Could not retrieve container IP address"
    echo "Container info:"
    ssh -o StrictHostKeyChecking=no ood-service@${LXD_HOST} \
        "lxc info ${CONTAINER_NAME}"
    exit 1
fi

echo "Container IP: ${CONTAINER_IP}"

# Verify NoVNC is accessible
echo "Verifying NoVNC service..."
max_retries=15
retry=0
while [ $retry -lt $max_retries ]; do
    if curl -s -f -m 5 "http://${CONTAINER_IP}:${NOVNC_PORT}/vnc.html" > /dev/null 2>&1; then
        echo "NoVNC is accessible"
        break
    fi
    echo "Waiting for NoVNC to be ready... (attempt $((retry+1))/${max_retries})"
    sleep 2
    ((retry++))
done

if [ $retry -eq $max_retries ]; then
    echo "WARNING: NoVNC may not be ready, but continuing anyway"
fi

# Set connection parameters for OOD
host="${CONTAINER_IP}"
port="${NOVNC_PORT}"
password=""

# Create connection.yml file for Open OnDemand
echo "Creating connection configuration..."
(
  umask 077
  cat > "<%= session.staged_root.join("connection.yml") %>" << EOF
host: ${host}
port: ${port}
password: ${password}
display: ${VNC_DISPLAY}
websocket: true
EOF
)

echo "========================================"
echo "Desktop container is ready!"
echo "Container Name: ${CONTAINER_NAME}"
echo "Container IP: ${CONTAINER_IP}"
echo "NoVNC URL: http://${CONTAINER_IP}:${NOVNC_PORT}/vnc.html"
echo "========================================"

# Keep script running for the duration of the session
# OOD will handle cleanup when user disconnects
echo "Session will remain active for <%= context.bc_num_hours %> hours"
sleep <%= context.bc_num_hours.to_i * 3600 %>

echo "Session time expired. Desktop container will remain running for future sessions."
```

`/var/www/ood/apps/sys/desktop-container/view.html.erb`:
```erb
<div class="card mb-3">
  <div class="card-header">
    <h5><i class="fa fa-desktop"></i> Desktop Container Session</h5>
  </div>
  <div class="card-body">
    <dl class="row">
      <dt class="col-sm-3">Container Name:</dt>
      <dd class="col-sm-9"><code><%= ENV['USER'] %>-desktop</code></dd>
      
      <dt class="col-sm-3">Desktop Environment:</dt>
      <dd class="col-sm-9">XFCE 4</dd>
      
      <dt class="col-sm-3">Status:</dt>
      <dd class="col-sm-9"><span class="badge badge-success">Running</span></dd>
      
      <dt class="col-sm-3">Session Duration:</dt>
      <dd class="col-sm-9"><%= context.bc_num_hours %> hours</dd>
      
      <dt class="col-sm-3">Resolution:</dt>
      <dd class="col-sm-9"><%= context.resolution || '1920x1080' %></dd>
    </dl>
    
    <div class="alert alert-info" role="alert">
      <strong>Note:</strong> Your container is persistent. Even after this session ends, 
      the container will remain available for future sessions. All files in your home 
      directory are preserved.
    </div>
  </div>
</div>

<div class="card">
  <div class="card-header">
    <h6>Desktop Features</h6>
  </div>
  <div class="card-body">
    <ul>
      <li>Full XFCE desktop environment</li>
      <li>Firefox web browser</li>
      <li>Text editor (gedit)</li>
      <li>Terminal access (xterm)</li>
      <li>Your home directory mounted from shared storage</li>
      <li>FreeIPA authentication and user management</li>
    </ul>
  </div>
</div>
```

### Environment Configuration

`/etc/ood/config/apps/bc_desktop/env`:
```bash
# LXD Desktop Container Environment Configuration

# LXD host IP address
export LXD_HOST="10.x.x.x"

# LXD remote name (as configured in 'lxc remote list')
export LXD_REMOTE="lxd-host"

# SSH connection settings
export SSH_USER="ood-service"
export SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Container settings
export CONTAINER_TIMEOUT="300"
export VNC_DISPLAY=":1"
export NOVNC_PORT="6080"

# Debugging
export DEBUG="false"
```

---

## Appendix B: Nginx Proxy Manager Configuration

### Complete NPM Proxy Host Configuration

**Domain:** `ood.csn.corp` → OOD VM  
**Port:** 58443 (external) → 443 (internal)

**Details Tab:**
```
Domain Names: ood.csn.corp
Scheme: https
Forward Hostname / IP: 10.x.x.x (OOD VM IP)
Forward Port: 443
Cache Assets: ON
Block Common Exploits: ON
Websockets Support: ON
```

**SSL Tab:**
```
SSL Certificate: (Select your certificate)
Force SSL: ON
HTTP/2 Support: ON
HSTS Enabled: ON
HSTS Subdomains: ON
```

**Advanced Tab:**
```nginx
# WebSocket configuration for NoVNC
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

# Proxy headers
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Timeout configuration for long-running sessions
proxy_connect_timeout 7200s;
proxy_send_timeout 7200s;
proxy_read_timeout 7200s;
send_timeout 7200s;

# Buffer settings
proxy_buffering off;
proxy_request_buffering off;

# Large file upload support
client_max_body_size 10G;
client_body_buffer_size 128k;

# Additional headers for security
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;

# NoVNC specific paths
location ~ ^/rnode/ {
    proxy_pass https://10.x.x.x;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}

location ~ ^/node/ {
    proxy_pass https://10.x.x.x;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

---

## Appendix C: Systemd Service Files

### LXD Container Monitor Service

Create `/etc/systemd/system/lxd-container-monitor.service`:
```ini
[Unit]
Description=LXD Desktop Container Monitor
After=snap.lxd.daemon.service
Requires=snap.lxd.daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lxd-container-monitor.sh
Restart=on-failure
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
```

Create `/usr/local/bin/lxd-container-monitor.sh`:
```bash
#!/bin/bash
# Monitor and log container activity

LOG_FILE="/var/log/lxd-containers.log"

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    CONTAINER_COUNT=$(lxc list --format csv | wc -l)
    RUNNING_COUNT=$(lxc list --format csv -c ns | grep RUNNING | wc -l)
    
    echo "${TIMESTAMP} - Total: ${CONTAINER_COUNT}, Running: ${RUNNING_COUNT}" >> ${LOG_FILE}
    
    # Log resource usage
    lxc list --format csv -c nsM | while IFS=, read name status memory; do
        if [ "$status" = "RUNNING" ]; then
            echo "${TIMESTAMP} - ${name}: Memory=${memory}" >> ${LOG_FILE}
        fi
    done
    
    sleep 300  # Run every 5 minutes
done
```

Make executable and enable:
```bash
chmod +x /usr/local/bin/lxd-container-monitor.sh
systemctl enable lxd-container-monitor.service
systemctl start lxd-container-monitor.service
```

### Container Cleanup Service

Create `/etc/systemd/system/lxd-container-cleanup.service`:
```ini
[Unit]
Description=Clean up idle LXD desktop containers
After=snap.lxd.daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lxd-container-cleanup.sh
User=root
```

Create `/etc/systemd/system/lxd-container-cleanup.timer`:
```ini
[Unit]
Description=Run LXD container cleanup daily

[Timer]
OnCalendar=daily
OnBootSec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

Create `/usr/local/bin/lxd-container-cleanup.sh`:
```bash
#!/bin/bash
# Clean up containers idle for more than 7 days

IDLE_DAYS=7
LOG_FILE="/var/log/lxd-cleanup.log"

echo "$(date): Starting container cleanup" >> ${LOG_FILE}

lxc list --format csv -c n | grep "\-desktop$" | while read container; do
    # Get last state change time
    LAST_CHANGE=$(lxc info ${container} | grep "Last used" | awk '{print $3, $4}')
    
    if [ -n "$LAST_CHANGE" ]; then
        LAST_TIMESTAMP=$(date -d "$LAST_CHANGE" +%s)
        NOW=$(date +%s)
        IDLE_SECONDS=$((NOW - LAST_TIMESTAMP))
        IDLE_DAYS_ACTUAL=$((IDLE_SECONDS / 86400))
        
        if [ $IDLE_DAYS_ACTUAL -gt $IDLE_DAYS ]; then
            echo "$(date): Stopping idle container: ${container} (idle for ${IDLE_DAYS_ACTUAL} days)" >> ${LOG_FILE}
            lxc stop ${container} || true
        fi
    fi
done

echo "$(date): Cleanup completed" >> ${LOG_FILE}
```

Make executable and enable:
```bash
chmod +x /usr/local/bin/lxd-container-cleanup.sh
systemctl enable lxd-container-cleanup.timer
systemctl start lxd-container-cleanup.timer
```

---

## Appendix D: LXD Profiles

### Desktop Container Profile

Create a reusable profile for desktop containers:

```bash
lxc profile create desktop-container
lxc profile edit desktop-container
```

Profile configuration:
```yaml
name: desktop-container
description: Profile for desktop containers with home directory mount
config:
  limits.cpu: "4"
  limits.memory: 8GB
  security.nesting: "false"
  security.privileged: "false"
  boot.autostart: "false"
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    type: disk
    size: 50GB
  unixhomes:
    path: /home
    source: /mnt/unixhomes
    type: disk
```

Apply profile to containers:
```bash
lxc profile add USERNAME-desktop desktop-container
```

### High-Performance Desktop Profile

For users who need more resources:

```bash
lxc profile create desktop-hpc
lxc profile edit desktop-hpc
```

```yaml
name: desktop-hpc
description: High-performance desktop container profile
config:
  limits.cpu: "8"
  limits.memory: 16GB
  limits.cpu.priority: "10"
  security.nesting: "false"
  security.privileged: "false"
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    type: disk
    size: 100GB
  unixhomes:
    path: /home
    source: /mnt/unixhomes
    type: disk
```

---

## Appendix E: Useful Commands Reference

### LXD Management Commands

**List all containers:**
```bash
lxc list
lxc list --format table
lxc list --format json | jq
```

**Container operations:**
```bash
# Start container
lxc start CONTAINER_NAME

# Stop container
lxc stop CONTAINER_NAME

# Restart container
lxc restart CONTAINER_NAME

# Delete container
lxc delete CONTAINER_NAME --force

# Execute command in container
lxc exec CONTAINER_NAME -- command

# Get shell in container
lxc exec CONTAINER_NAME -- /bin/bash

# Copy files to/from container
lxc file push /local/file CONTAINER_NAME/remote/path
lxc file pull CONTAINER_NAME/remote/file /local/path
```

**Container information:**
```bash
# Detailed info
lxc info CONTAINER_NAME

# Show logs
lxc console CONTAINER_NAME --show-log

# Resource usage
lxc list --columns ns4cM

# Network info
lxc network list
lxc network show lxdbr0
```

**Snapshots:**
```bash
# Create snapshot
lxc snapshot CONTAINER_NAME SNAPSHOT_NAME

# List snapshots
lxc info CONTAINER_NAME

# Restore snapshot
lxc restore CONTAINER_NAME SNAPSHOT_NAME

# Delete snapshot
lxc delete CONTAINER_NAME/SNAPSHOT_NAME
```

### OOD Management Commands

**Restart OOD services:**
```bash
# Restart Apache/httpd
sudo systemctl restart httpd

# Restart PUN (Per-User Nginx) for specific user
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean -u USERNAME
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_show -u USERNAME

# Reload OOD portal configuration
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl reload httpd
```

**Check OOD status:**
```bash
# Apache status
sudo systemctl status httpd

# View logs
sudo tail -f /var/log/httpd/error_log
sudo tail -f /var/log/httpd/ssl_error_log

# Check user PUN logs
sudo tail -f /var/log/ondemand-nginx/USERNAME/error.log
```

**Manage OOD apps:**
```bash
# List installed apps
ls -la /var/www/ood/apps/sys/

# Update app permissions
sudo chown -R apache:apache /var/www/ood/apps/sys/APP_NAME

# Clear app cache
sudo rm -rf /var/www/ood/apps/sys/APP_NAME/tmp
```

### User Management Commands

**FreeIPA user operations:**
```bash
# List users
ipa user-find

# Get user details
ipa user-show USERNAME

# Check user groups
ipa group-find --user=USERNAME

# Verify user can authenticate
id USERNAME
getent passwd USERNAME
```

**Check user's container:**
```bash
# As root on LXD host
lxc list USERNAME-desktop

# Get container status
lxc info USERNAME-desktop

# Check if user can access container
lxc exec USERNAME-desktop -- su - USERNAME -c "whoami"
```

### Troubleshooting Commands

**Network debugging:**
```bash
# Test connectivity from OOD to LXD host
ping LXD_HOST_IP
ssh ood-service@LXD_HOST_IP "lxc list"

# Test container network
lxc exec CONTAINER_NAME -- ping -c 3 8.8.8.8
lxc exec CONTAINER_NAME -- curl -I https://google.com

# Check NoVNC accessibility
curl -I http://CONTAINER_IP:6080/vnc.html
```

**Service status checks:**
```bash
# In container - check VNC
lxc exec CONTAINER_NAME -- ps aux | grep vnc
lxc exec CONTAINER_NAME -- netstat -tulpn | grep 5901

# Check NoVNC/websockify
lxc exec CONTAINER_NAME -- ps aux | grep websockify
lxc exec CONTAINER_NAME -- netstat -tulpn | grep 6080

# Check SSSD (FreeIPA)
lxc exec CONTAINER_NAME -- systemctl status sssd
lxc exec CONTAINER_NAME -- sssctl domain-status csn.corp
```

**Resource monitoring:**
```bash
# Host resources
df -h
free -h
top

# Container resources
lxc exec CONTAINER_NAME -- df -h
lxc exec CONTAINER_NAME -- free -h
lxc exec CONTAINER_NAME -- top -b -n 1
```

---

## Appendix F: Security Checklist

### Pre-Production Security Review

Before deploying to production, verify:

**LXD Host Security:**
- [ ] Host firewall (ufw) is enabled and configured
- [ ] LXD API is only accessible from OOD server
- [ ] SSH is configured with key-based authentication only
- [ ] Root SSH login is disabled
- [ ] ood-service account has minimal required sudo privileges
- [ ] Regular system updates are scheduled
- [ ] Audit logging is enabled

**Container Security:**
- [ ] Containers are unprivileged
- [ ] Security nesting is disabled
- [ ] AppArmor profiles are enabled
- [ ] Resource limits are set on all containers
- [ ] Container images are from trusted sources
- [ ] Regular container template updates are scheduled

**Network Security:**
- [ ] Nginx Proxy Manager SSL certificates are valid
- [ ] TLS 1.2 minimum is enforced
- [ ] HSTS is enabled
- [ ] Squid proxy whitelist is configured
- [ ] Internal networks are isolated from external
- [ ] Port 58443 is the only public-facing port

**Authentication & Authorization:**
- [ ] FreeIPA is properly secured
- [ ] Entra ID synchronization is working
- [ ] OOD OIDC configuration is correct
- [ ] User UID/GID mapping is consistent
- [ ] sudo privileges are minimal and audited
- [ ] Session timeouts are configured

**Data Security:**
- [ ] /mnt/unixhomes has correct permissions
- [ ] Home directories are backed up
- [ ] Sensitive data is encrypted at rest
- [ ] Container snapshots are scheduled
- [ ] Backup retention policy is defined

**Monitoring & Logging:**
- [ ] Container activity is logged
- [ ] Failed authentication attempts are monitored
- [ ] Resource usage alerts are configured
- [ ] Log rotation is configured
- [ ] Logs are backed up to secure location

**Documentation:**
- [ ] Network diagram is documented
- [ ] Disaster recovery procedures are written
- [ ] Admin contact information is current
- [ ] User documentation is available
- [ ] Change management process is defined

---

## Appendix G: Future Enhancements