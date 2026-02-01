# Guide: Setting Up Rocky 8 XFCE Desktop Containers with Open OnDemand, Slurm, and Apptainer

## Architecture Overview

### 1) Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Ubuntu 22.04 Bare Metal Host                             │
│                    40 cores, 512GB RAM, 3.84TB SSD RAID1                    │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                           LXD Manager                              │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  ┌─────────────────┐        ┌──────────────────────────────────────┐       │
│  │ Shared Storage  │        │    VLAN Interfaces (macvlan)         │       │
│  │ /mnt/unixhomes  │        │    eth0.10, eth0.20, etc.            │       │
│  └────────┬────────┘        └──────────────────┬───────────────────┘       │
│           │                                     │                           │
│           │                                     ├─── Physical Router        │
│           │                                     │    - DHCP Server          │
│           │                                     │    - Firewall/ACLs        │
│           │                                     │    - VLAN routing         │
│           │                                     │                           │
│           │  ┌──────────────────────────────────┼─────────────────────┐    │
│           │  │                                  │                     │    │
│           ├──┤  FreeIPA Server (Container)      │                     │    │
│           │  │  - User Authentication           │                     │    │
│           │  │  - LDAP/Kerberos                 │                     │    │
│           │  │  - DNS Server                    │                     │    │
│           │  │  - Centralized User Management   │                     │    │
│           │  │  - macvlan NIC                   │                     │    │
│           │  └──────────────────────────────────┘                     │    │
│           │                                                           │    │
│           ├──┬─────────────────────────────────────────────────────┐ │    │
│           │  │  Open OnDemand Server (Container/VM)                │ │    │
│           │  │  - Web Portal (https://ood.example.local)           │ │    │
│           │  │  - User Interface for Desktop Launch                │ │    │
│           │  │  - Job Submission to Slurm                          │ │    │
│           │  │  - macvlan NIC                                      │ │    │
│           │  └─────────────────────────────────────────────────────┘ │    │
│           │                                                           │    │
│           ├──┬─────────────────────────────────────────────────────┐ │    │
│           │  │  Slurm Controller (VM)                              │ │    │
│           │  │  - Rocky 8                                          │ │    │
│           │  │  - slurmctld daemon                                 │ │    │
│           │  │  - Job scheduling and management                   │ │    │
│           │  │  - Munge authentication                             │ │    │
│           │  │  - macvlan NIC                                      │ │    │
│           │  │  - Proxy: proxy.example.local                       │ │    │
│           │  └─────────────────────────────────────────────────────┘ │    │
│           │                                                           │    │
│           ├──┬─────────────────────────────────────────────────────┐ │    │
│           │  │  Squid Proxy Server (Container)                     │ │    │
│           │  │  - proxy.example.local                              │ │    │
│           │  │  - Whitelisted URL access only                      │ │    │
│           │  │  - macvlan NIC                                      │ │    │
│           │  └─────────────────────────────────────────────────────┘ │    │
│           │                                                           │    │
│           │  ┌────────────────────────────────────────────────────┐  │    │
│           │  │         Desktop Compute Nodes (Containers)         │  │    │
│           │  │                                                    │  │    │
│           ├──┤  ┌──────────────┐  ┌──────────────┐  ┌─────────┐ │  │    │
│           │  │  │ desktop01    │  │ desktop02    │  │  ...    │ │  │    │
│           │  │  │ Rocky 8      │  │ Rocky 8      │  │ desktopN│ │  │    │
│           │  │  │ - XFCE GUI   │  │ - XFCE GUI   │  │         │ │  │    │
│           │  │  │ - VNC Server │  │ - VNC Server │  │         │ │  │    │
│           │  │  │ - noVNC      │  │ - noVNC      │  │         │ │  │    │
│           │  │  │ - slurmd     │  │ - slurmd     │  │         │ │  │    │
│           │  │  │ - Apptainer  │  │ - Apptainer  │  │         │ │  │    │
│           │  │  │ - macvlan NIC│  │ - macvlan NIC│  │         │ │  │    │
│           │  │  │ - Proxy cfg  │  │ - Proxy cfg  │  │         │ │  │    │
│           │  │  └──────────────┘  └──────────────┘  └─────────┘ │  │    │
│           │  └────────────────────────────────────────────────────┘  │    │
│           │                                                           │    │
└───────────┴───────────────────────────────────────────────────────────┴────┘

User Workflow:
1. User logs into Open OnDemand web interface (authenticated via FreeIPA)
2. User selects "Rocky 8 XFCE Desktop" and configures resources
3. OOD submits job to Slurm Controller
4. Slurm schedules job on available desktop container
5. Desktop container starts VNC server with user's session
6. User connects via noVNC in browser
7. User works in persistent desktop (can disconnect/reconnect)
8. Home directory (/mnt/unixhomes) is mounted and accessible
9. External access via proxy.example.local for allowed URLs only
```

### 2) Prerequisites

Before proceeding with this guide, ensure you have the following already configured:

#### Host System
- **OS**: Ubuntu 22.04 LTS installed on bare metal
- **Hardware**: 40 CPU cores, 512GB RAM, 3.84TB SATA SSD in RAID1
- **LXD**: Installed and initialized
  ```bash
  # Verify LXD is installed
  lxc --version
  ```

- **VLAN Interfaces**: Predefined VLAN interfaces configured on host (e.g., eth0.10, eth0.20)
  ```bash
  # Verify VLAN interfaces exist
  ip link show | grep eth0.
  ```

#### Network Infrastructure
- **Physical Router**: Handles DHCP for all VLANs
- **Firewall**: Router manages firewall rules between subnets
- **macvlan**: LXD containers use macvlan for direct network access
  ```bash
  # Verify macvlan parent interface is available
  ip link show
  ```

#### Shared Storage
- **Mount Point**: `/mnt/unixhomes` exists on host
- **Permissions**: Properly configured for user home directories
- **Accessibility**: Readable/writable by host system
  ```bash
  # Verify mount exists
  df -h /mnt/unixhomes
  
  # Check permissions
  ls -ld /mnt/unixhomes
  ```

#### FreeIPA Server
- **Status**: Already installed and running (container or VM)
- **Domain**: Configured (e.g., `example.local`)
- **Services**: LDAP, Kerberos, and DNS functional
- **DNS**: FreeIPA provides DNS resolution for all services
- **Network**: Connected via macvlan
- **Admin Access**: You have admin credentials
  ```bash
  # Verify FreeIPA is accessible
  ipa ping
  
  # Check DNS resolution
  dig @freeipa.example.local ood.example.local
  
  # Check you can authenticate
  kinit admin
  ```

#### Squid Proxy Server
- **Hostname**: `proxy.example.local`
- **Status**: Already installed and running
- **Access Control**: Configured with whitelisted URLs
- **Network**: Accessible from all containers
- **DNS**: Resolvable via FreeIPA DNS
  ```bash
  # Verify proxy is accessible
  curl -x http://proxy.example.local:3128 http://www.google.com
  ```

#### Open OnDemand Server
- **Status**: Already installed and running (container or VM)
- **Hostname**: `ood.example.local` (resolvable via FreeIPA DNS)
- **Web Access**: Accessible via HTTPS
- **Authentication**: Integrated with FreeIPA
- **Home Directory**: Can browse `/mnt/unixhomes` mounted from host
- **Network**: Connected via macvlan
  ```bash
  # On OOD server, verify home directory mount
  ls -la /mnt/unixhomes
  ```

#### Network Requirements
- **VLAN Assignment**: Know which VLAN interface to use for containers
- **DNS Resolution**: All hostnames resolve via FreeIPA DNS
- **Proxy Access**: Containers can reach proxy.example.local
- **Firewall Rules**: Router allows necessary traffic between subnets:
  - OOD → Slurm Controller: ports 6817, 6818
  - Slurm Controller → Desktop nodes: ports 6818
  - Desktop nodes → Slurm Controller: ports 6817
  - Users → OOD: port 443 (HTTPS)
  - Users → Desktop nodes: VNC/noVNC ports (via OOD proxy)
  - All containers → proxy.example.local: port 3128

#### What This Guide Will Add
This guide will help you set up:
1. ✅ Slurm Controller VM for job scheduling (with macvlan and proxy)
2. ✅ Rocky 8 desktop container template with XFCE (with macvlan and proxy)
3. ✅ VNC and noVNC for browser-based desktop access
4. ✅ Slurm compute nodes (desktop containers with macvlan)
5. ✅ Apptainer container runtime
6. ✅ Open OnDemand integration for desktop launching
7. ✅ Persistent desktop sessions users can reconnect to
8. ✅ Proxy configuration for external access

## Part 1: Slurm Controller Setup

### 1.1 Create Slurm Controller VM with macvlan

Create a Rocky 8 VM for Slurm controller. Replace `eth0.10` with your actual VLAN interface:

```bash
lxc launch images:rockylinux/8 slurm-controller --vm -c limits.cpu=4 -c limits.memory=8GB
```

Remove default network and add macvlan (replace `eth0.10` with your VLAN interface):

```bash
lxc config device remove slurm-controller eth0
lxc config device add slurm-controller eth0 nic nictype=macvlan parent=eth0.10
```

Add disk device for home directories:

```bash
lxc config device add slurm-controller unixhomes disk source=/mnt/unixhomes path=/mnt/unixhomes
```

Start the VM and enter it:

```bash
lxc start slurm-controller
lxc exec slurm-controller -- bash
```

### 1.2 Configure Proxy Settings

Configure system-wide proxy on the controller:

```bash
cat >> /etc/environment << 'EOF'
http_proxy=http://proxy.example.local:3128
https_proxy=http://proxy.example.local:3128
no_proxy=localhost,127.0.0.1,.example.local
HTTP_PROXY=http://proxy.example.local:3128
HTTPS_PROXY=http://proxy.example.local:3128
NO_PROXY=localhost,127.0.0.1,.example.local
EOF
```

Configure DNF to use proxy:

```bash
cat >> /etc/dnf/dnf.conf << 'EOF'
proxy=http://proxy.example.local:3128
EOF
```

Configure wget proxy:

```bash
cat > /etc/wgetrc << 'EOF'
http_proxy=http://proxy.example.local:3128
https_proxy=http://proxy.example.local:3128
use_proxy=on
EOF
```

Load environment variables:

```bash
source /etc/environment
```

### 1.3 Configure DNS to use FreeIPA

Configure the VM to use FreeIPA for DNS (replace with your FreeIPA server IP):

```bash
cat > /etc/resolv.conf << 'EOF'
nameserver <FREEIPA_SERVER_IP>
search example.local
EOF
```

Make resolv.conf immutable to prevent NetworkManager from overwriting:

```bash
chattr +i /etc/resolv.conf
```

Test DNS resolution:

```bash
nslookup proxy.example.local
nslookup ood.example.local
```

### 1.4 Configure FreeIPA Client on Controller

Install FreeIPA client:

```bash
dnf install -y freeipa-client
```

Join FreeIPA domain (replace with your actual domain and server):

```bash
ipa-client-install --domain=yourdomain.local --server=freeipa.yourdomain.local --mkhomedir
```

Enable oddjobd for home directory creation:

```bash
systemctl enable --now oddjobd
```

### 1.5 Create Slurm User in FreeIPA

Before installing Slurm, create the slurm user in FreeIPA so it's available on all nodes. On your FreeIPA server (or any IPA client with admin privileges):

```bash
ipa user-add slurm --first=Slurm --last=Manager --homedir=/var/lib/slurm --shell=/bin/bash
```

Note: FreeIPA will automatically assign a UID/GID from its configured range. If you need a specific UID for compatibility with existing systems, add `--uid=XXXX` to the command.

### 1.6 Install Slurm Controller

Back on the Slurm controller VM. Install EPEL and dependencies:

```bash
dnf install -y epel-release
dnf install -y munge munge-libs slurm slurm-slurmctld
```

Create necessary directories (the slurm user already exists from FreeIPA):

```bash
mkdir -p /var/lib/slurm /var/spool/slurm/ctld /var/log/slurm
chown -R slurm:slurm /var/lib/slurm /var/spool/slurm /var/log/slurm
chmod 755 /var/spool/slurm/ctld
```

### 1.7 Configure Munge

Generate munge key:

```bash
/usr/sbin/create-munge-key -f
```

Set permissions:

```bash
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
```

Start munge:

```bash
systemctl enable --now munge
```

### 1.8 Create Slurm Configuration

Create `/etc/slurm/slurm.conf`:

```bash
cat > /etc/slurm/slurm.conf << 'EOF'
ClusterName=lxd-cluster

SlurmctldHost=slurm-controller
SlurmctldPort=6817
SlurmdPort=6818

AuthType=auth/munge
CryptoType=crypto/munge

StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity,task/cgroup

ReturnToService=2

SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0
EOF
```

Set ownership and permissions:

```bash
chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf
```

Note: We'll add node definitions later after creating desktop containers.

### 1.7 Start Slurm Controller

```bash
systemctl enable --now slurmctld
systemctl status slurmctld
```

## Part 2: Rocky 8 Desktop Container Template

### 2.1 Create Base Container with macvlan

On the host, launch a new container:

```bash
lxc launch images:rockylinux/8 rocky8-desktop-template
```

Stop the container to configure networking:

```bash
lxc stop rocky8-desktop-template
```

Remove default network and add macvlan (replace `eth0.10` with your VLAN interface):

```bash
lxc config device remove rocky8-desktop-template eth0
lxc config device add rocky8-desktop-template eth0 nic nictype=macvlan parent=eth0.10
```

Configure container security and add home directory mount:

```bash
lxc config set rocky8-desktop-template security.nesting true
lxc config set rocky8-desktop-template security.privileged false
lxc config device add rocky8-desktop-template unixhomes disk source=/mnt/unixhomes path=/mnt/unixhomes
```

Start and enter the container:

```bash
lxc start rocky8-desktop-template
lxc exec rocky8-desktop-template -- bash
```

### 2.2 Configure DNS and Proxy

Configure DNS to use FreeIPA (replace with your FreeIPA server IP):

```bash
cat > /etc/resolv.conf << 'EOF'
nameserver <FREEIPA_SERVER_IP>
search example.local
EOF
```

Make resolv.conf immutable:

```bash
chattr +i /etc/resolv.conf
```

Configure system-wide proxy:

```bash
cat >> /etc/environment << 'EOF'
http_proxy=http://proxy.example.local:3128
https_proxy=http://proxy.example.local:3128
no_proxy=localhost,127.0.0.1,.example.local
HTTP_PROXY=http://proxy.example.local:3128
HTTPS_PROXY=http://proxy.example.local:3128
NO_PROXY=localhost,127.0.0.1,.example.local
EOF
```

Configure DNF proxy:

```bash
cat >> /etc/dnf/dnf.conf << 'EOF'
proxy=http://proxy.example.local:3128
EOF
```

Configure wget proxy:

```bash
cat > /etc/wgetrc << 'EOF'
http_proxy=http://proxy.example.local:3128
https_proxy=http://proxy.example.local:3128
use_proxy=on
EOF
```

Load environment variables:

```bash
source /etc/environment
```

Test DNS and proxy:

```bash
nslookup proxy.example.local
nslookup freeipa.example.local
curl -I http://www.google.com
```

### 2.3 Install Desktop Environment and VNC

Install EPEL:

```bash
dnf install -y epel-release
```

Install XFCE desktop:

```bash
dnf groupinstall -y "Server with GUI"
dnf install -y xfce4 xfce4-goodies
```

Install VNC server and noVNC:

```bash
dnf install -y tigervnc-server novnc python3-websockify
```

Install other useful packages:

```bash
dnf install -y supervisor firefox gedit vim
```

### 2.4 Configure FreeIPA Client

Install FreeIPA client packages:

```bash
dnf install -y freeipa-client sssd
```

Join FreeIPA (replace with your details):

```bash
ipa-client-install --domain=example.local --server=freeipa.example.local --mkhomedir
```

Enable oddjobd:

```bash
systemctl enable --now oddjobd
```

### 2.5 Install Slurm Compute Node

Install slurm:

```bash
dnf install -y munge munge-libs slurm slurm-slurmd
```

Create directories (the slurm user already exists from FreeIPA):

```bash
mkdir -p /var/spool/slurm/d /var/log/slurm
chown -R slurm:slurm /var/spool/slurm /var/log/slurm
```

### 2.6 Install Apptainer

Install dependencies:

```bash
dnf install -y golang libseccomp-devel squashfs-tools cryptsetup wget
```

Download and install Apptainer:

```bash
export VERSION=1.3.4
cd /tmp
wget https://github.com/apptainer/apptainer/releases/download/v${VERSION}/apptainer-${VERSION}.tar.gz
tar -xzf apptainer-${VERSION}.tar.gz
cd apptainer-${VERSION}

./mconfig
make -C builddir
make -C builddir install
```

Verify installation:

```bash
apptainer --version
```

Configure Apptainer to use proxy. Create `/etc/apptainer/apptainer.conf.d/proxy.conf`:

```bash
mkdir -p /etc/apptainer/apptainer.conf.d
cat > /etc/apptainer/apptainer.conf.d/proxy.conf << 'EOF'
# Proxy settings for Apptainer
http proxy = http://proxy.example.local:3128
https proxy = http://proxy.example.local:3128
EOF
```

### 2.7 Setup VNC Launch Script

Create `/usr/local/bin/start-vnc-desktop.sh`:

```bash
cat > /usr/local/bin/start-vnc-desktop.sh << 'EOF'
#!/bin/bash

USER_NAME=$1
DISPLAY_NUM=$2
VNC_PORT=$((5900 + DISPLAY_NUM))
NOVNC_PORT=$((6080 + DISPLAY_NUM))

if [ -z "$USER_NAME" ] || [ -z "$DISPLAY_NUM" ]; then
    echo "Usage: $0 <username> <display_number>"
    exit 1
fi

export USER=$USER_NAME
export HOME=$(getent passwd $USER_NAME | cut -d: -f6)

su - $USER_NAME -c "mkdir -p $HOME/.vnc"

if [ ! -f "$HOME/.vnc/passwd" ]; then
    su - $USER_NAME -c "echo 'password' | vncpasswd -f > $HOME/.vnc/passwd"
    chmod 600 $HOME/.vnc/passwd
    chown $USER_NAME:$(id -gn $USER_NAME) $HOME/.vnc/passwd
fi

cat > $HOME/.vnc/xstartup << 'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XEOF

chmod +x $HOME/.vnc/xstartup
chown $USER_NAME:$(id -gn $USER_NAME) $HOME/.vnc/xstartup

su - $USER_NAME -c "vncserver :$DISPLAY_NUM -geometry 1920x1080 -depth 24"

su - $USER_NAME -c "websockify --web=/usr/share/novnc $NOVNC_PORT localhost:$VNC_PORT &"

echo "VNC server started on display :$DISPLAY_NUM"
echo "noVNC accessible at http://$(hostname):$NOVNC_PORT/vnc.html"
EOF
```

Make it executable:

```bash
chmod +x /usr/local/bin/start-vnc-desktop.sh
```

### 2.8 Copy Munge Key and Slurm Config

Exit the container:

```bash
exit
```

On the host, copy munge key:

```bash
lxc file pull slurm-controller/etc/munge/munge.key - | lxc file push - rocky8-desktop-template/etc/munge/munge.key
```

Copy slurm config:

```bash
lxc file pull slurm-controller/etc/slurm/slurm.conf - | lxc file push - rocky8-desktop-template/etc/slurm/slurm.conf
```

Set permissions:

```bash
lxc exec rocky8-desktop-template -- chown munge:munge /etc/munge/munge.key
lxc exec rocky8-desktop-template -- chmod 400 /etc/munge/munge.key
lxc exec rocky8-desktop-template -- chown slurm:slurm /etc/slurm/slurm.conf
```

### 2.9 Enable Services

Enter the container:

```bash
lxc exec rocky8-desktop-template -- bash
```

Enable services (don't start them yet - we'll do this per instance):

```bash
systemctl enable munge
systemctl enable slurmd
```

Exit the container:

```bash
exit
```

### 2.9 Stop and Publish Template

```bash
lxc stop rocky8-desktop-template
lxc publish rocky8-desktop-template --alias rocky8-xfce-desktop
```

## Part 3: Configure Slurm for Desktop Nodes

### 3.1 Create Desktop Node Launch Script

On the host, create `/usr/local/bin/create-desktop-node.sh`. Replace `eth0.10` with your VLAN interface:

```bash
cat > /usr/local/bin/create-desktop-node.sh << 'EOF'
#!/bin/bash

NODE_ID=$1
VLAN_INTERFACE="eth0.10"

if [ -z "$NODE_ID" ]; then
    echo "Usage: $0 <node_id>"
    exit 1
fi

NODE_NAME="desktop$(printf '%02d' $NODE_ID)"

if lxc info $NODE_NAME &>/dev/null; then
    echo "Container $NODE_NAME already exists"
    lxc start $NODE_NAME 2>/dev/null || true
else
    lxc launch rocky8-xfce-desktop $NODE_NAME
    
    lxc stop $NODE_NAME
    
    lxc config device remove $NODE_NAME eth0
    lxc config device add $NODE_NAME eth0 nic nictype=macvlan parent=$VLAN_INTERFACE
    
    lxc config set $NODE_NAME limits.cpu=4
    lxc config set $NODE_NAME limits.memory=8GB
    
    lxc start $NODE_NAME
    
    sleep 10
    
    lxc exec $NODE_NAME -- systemctl start munge
    lxc exec $NODE_NAME -- systemctl start slurmd
fi

CONTAINER_IP=$(lxc list $NODE_NAME -c 4 -f csv | cut -d' ' -f1)

echo "Desktop node $NODE_NAME created/started with IP: $CONTAINER_IP"
echo "Add to slurm.conf: NodeName=$NODE_NAME NodeAddr=$CONTAINER_IP CPUs=4 RealMemory=8192 State=UNKNOWN"
EOF
```

Make it executable:

```bash
chmod +x /usr/local/bin/create-desktop-node.sh
```

### 3.2 Update Slurm Configuration

Create initial desktop nodes:

```bash
for i in {1..5}; do
    /usr/local/bin/create-desktop-node.sh $i
done
```

The script will output the IP addresses. Note these down.

Update slurm.conf on controller. Enter the controller:

```bash
lxc exec slurm-controller -- bash
```

Edit `/etc/slurm/slurm.conf` and add nodes (replace IP addresses with actual values from the previous step):

```bash
cat >> /etc/slurm/slurm.conf << 'EOF'

NodeName=desktop01 NodeAddr=10.x.x.x CPUs=4 RealMemory=8192 State=UNKNOWN
NodeName=desktop02 NodeAddr=10.x.x.x CPUs=4 RealMemory=8192 State=UNKNOWN
NodeName=desktop03 NodeAddr=10.x.x.x CPUs=4 RealMemory=8192 State=UNKNOWN
NodeName=desktop04 NodeAddr=10.x.x.x CPUs=4 RealMemory=8192 State=UNKNOWN
NodeName=desktop05 NodeAddr=10.x.x.x CPUs=4 RealMemory=8192 State=UNKNOWN

PartitionName=desktop Nodes=desktop[01-05] Default=YES MaxTime=INFINITE State=UP
EOF
```

Restart slurmctld:

```bash
systemctl restart slurmctld
```

Check nodes:

```bash
scontrol show nodes
```

Exit the controller:

```bash
exit
```

## Part 4: Open OnDemand Integration

### 4.1 Create Interactive Desktop App

On your OOD server, create the desktop app directory:

```bash
sudo mkdir -p /var/www/ood/apps/sys/rocky8_desktop
cd /var/www/ood/apps/sys/rocky8_desktop
```

### 4.2 Create `manifest.yml`

```yaml
---
name: Rocky 8 XFCE Desktop
category: Interactive Apps
subcategory: Desktops
role: batch_connect
description: Launch a Rocky 8 XFCE desktop session
```

### 4.3 Create `form.yml`

```yaml
---
cluster: "lxd-cluster"
attributes:
  desktop_size:
    widget: select
    label: "Desktop Size"
    options:
      - ["Small (2 cores, 4GB RAM)", "small"]
      - ["Medium (4 cores, 8GB RAM)", "medium"]
      - ["Large (8 cores, 16GB RAM)", "large"]
    value: "medium"
  num_hours:
    widget: "number_field"
    label: "Number of hours"
    value: 4
    min: 1
    max: 72
    step: 1
form:
  - desktop_size
  - num_hours
```

### 4.4 Create `submit.yml.erb`

```yaml
---
batch_connect:
  template: "vnc"
script:
  accounting_id: "<%= ENV['USER'] %>"
  wall_time: "<%= num_hours.to_i * 3600 %>"
  email_on_started: false
  native:
    - "-p"
    - "desktop"
    <%- case desktop_size when "small" -%>
    - "--ntasks=1"
    - "--cpus-per-task=2"
    - "--mem=4G"
    <%- when "medium" -%>
    - "--ntasks=1"
    - "--cpus-per-task=4"
    - "--mem=8G"
    <%- when "large" -%>
    - "--ntasks=1"
    - "--cpus-per-task=8"
    - "--mem=16G"
    <%- end -%>
```

### 4.5 Create `template/script.sh.erb`

Create the template directory:

```bash
mkdir -p template
```

Create `template/script.sh.erb`:

```bash
cat > template/script.sh.erb << 'EOF'
#!/bin/bash

export XDG_RUNTIME_DIR="${HOME}/.xdg_runtime"
mkdir -p $XDG_RUNTIME_DIR
chmod 700 $XDG_RUNTIME_DIR

DISPLAY_NUM=1
while [ -f /tmp/.X${DISPLAY_NUM}-lock ]; do
  DISPLAY_NUM=$((DISPLAY_NUM + 1))
done

export DISPLAY=:${DISPLAY_NUM}

mkdir -p ${HOME}/.vnc

echo "<%= password %>" | vncpasswd -f > ${HOME}/.vnc/passwd
chmod 600 ${HOME}/.vnc/passwd

cat > ${HOME}/.vnc/xstartup << 'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XEOF

chmod +x ${HOME}/.vnc/xstartup

vncserver ${DISPLAY} -geometry 1920x1080 -depth 24 -SecurityTypes None

VNC_PORT=$((5900 + DISPLAY_NUM))
WEBSOCKET_PORT=$((6080 + DISPLAY_NUM))

websockify --web=/usr/share/novnc ${WEBSOCKET_PORT} localhost:${VNC_PORT} &
WEBSOCKIFY_PID=$!

echo "VNC server running on ${HOSTNAME}:${VNC_PORT}"
echo "Websocket running on port ${WEBSOCKET_PORT}"

echo "${WEBSOCKET_PORT}" > connection.yml

wait $WEBSOCKIFY_PID
EOF
```

### 4.6 Configure OOD Cluster

Edit `/etc/ood/config/clusters.d/lxd-cluster.yml`:

```yaml
---
v2:
  metadata:
    title: "LXD Cluster"
  login:
    host: "slurm-controller.example.local"
  job:
    adapter: "slurm"
    cluster: "lxd-cluster"
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
  batch_connect:
    basic:
      script_wrapper: |
        module purge
        %s
      set_host: "host=$(hostname -s)"
    vnc:
      script_wrapper: |
        module purge
        export PATH="/usr/bin:$PATH"
        %s
      set_host: "host=$(hostname -f)"
```

### 4.7 Restart OOD

```bash
sudo systemctl restart httpd
```

## Part 5: Testing and Usage

### 5.1 Test Slurm

On controller or any node:

```bash
sinfo
squeue
srun -N1 hostname
```

### 5.2 Launch Desktop from OOD

1. Log in to Open OnDemand web interface
2. Navigate to "Interactive Apps" → "Rocky 8 XFCE Desktop"
3. Select desktop size and duration
4. Click "Launch"
5. Wait for job to start
6. Click "Launch Rocky 8 XFCE Desktop" button
7. Desktop should open in browser via noVNC

### 5.3 Reconnect to Desktop

Users can reconnect by:
1. Going to "My Interactive Sessions" in OOD
2. Finding their running session
3. Clicking the connect button

## Part 6: Maintenance and Scaling

### 6.1 Add More Desktop Nodes

On host:

```bash
/usr/local/bin/create-desktop-node.sh 6
/usr/local/bin/create-desktop-node.sh 7
```

Note the IP addresses from the output, then update slurm.conf on controller with new nodes and restart slurmctld.

### 6.2 Container Cleanup Script

Create `/usr/local/bin/cleanup-idle-desktops.sh`:

```bash
cat > /usr/local/bin/cleanup-idle-desktops.sh << 'EOF'
#!/bin/bash

for container in $(lxc list "desktop*" -c n -f csv); do
    JOBS=$(lxc exec slurm-controller -- squeue -h -w $container | wc -l)
    
    if [ $JOBS -eq 0 ]; then
        echo "Stopping idle container: $container"
        lxc stop $container
    fi
done
EOF
```

Make it executable:

```bash
chmod +x /usr/local/bin/cleanup-idle-desktops.sh
```

### 6.3 Monitoring

Set up basic monitoring on controller:

```bash
watch -n 5 'sinfo; echo ""; squeue'
```

## Troubleshooting

### Issue: Containers can't reach controller

**Solution**: Ensure macvlan networking and DHCP are working properly

Check VLAN interface on host:

```bash
ip link show | grep eth0.
ip addr show eth0.10
```

Verify container has received IP from DHCP:

```bash
lxc list
```

Check container can reach the network:

```bash
lxc exec <container> -- ping -c 3 proxy.example.local
lxc exec <container> -- ping -c 3 slurm-controller.example.local
```

Verify DNS resolution via FreeIPA:

```bash
lxc exec <container> -- nslookup slurm-controller.example.local
```

### Issue: Proxy not working

**Solution**: Verify proxy configuration and connectivity

Test proxy from container:

```bash
lxc exec <container> -- curl -x http://proxy.example.local:3128 -I http://www.google.com
```

Check environment variables are set:

```bash
lxc exec <container> -- env | grep -i proxy
```

Verify proxy hostname resolves:

```bash
lxc exec <container> -- nslookup proxy.example.local
```

### Issue: DNS resolution fails

**Solution**: Ensure FreeIPA DNS is configured correctly

Check resolv.conf:

```bash
lxc exec <container> -- cat /etc/resolv.conf
```

Verify immutable flag is set:

```bash
lxc exec <container> -- lsattr /etc/resolv.conf
```

Test DNS resolution:

```bash
lxc exec <container> -- dig @<FREEIPA_IP> example.local
```

### Issue: Munge authentication fails

**Solution**: Ensure munge keys are identical and have correct permissions

Check munge key permissions (should be `-r-------- 1 munge munge`):

```bash
lxc exec <container> -- ls -l /etc/munge/munge.key
```

### Issue: VNC doesn't start

**Solution**: Check display locks and permissions

Check for stale locks:

```bash
rm -f /tmp/.X*-lock
```

Check VNC logs:

```bash
tail -f ~/.vnc/*.log
```

## Summary

This guide provides a complete setup for your requirements. You can now launch persistent Rocky 8 XFCE desktops from Open OnDemand, managed by Slurm, running in LXD containers with Apptainer support and shared home directories.