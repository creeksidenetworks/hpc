# Slurm + Open OnDemand Installation Guide
## Rocky Linux 8 with FreeIPA Integration

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Architecture](#architecture)
4. [Step 1: Create FreeIPA Service Account](#step-1-create-freeipa-service-account)
5. [Step 2: Install Slurm Packages](#step-2-install-slurm-packages)
6. [Step 3: Configure Munge Authentication](#step-3-configure-munge-authentication)
7. [Step 4: Configure Slurm](#step-4-configure-slurm)
8. [Step 5: Configure Cgroups](#step-5-configure-cgroups)
9. [Step 6: Configure Firewall](#step-6-configure-firewall)
10. [Step 7: Start Slurm Services](#step-7-start-slurm-services)
11. [Step 8: Install Desktop Components](#step-8-install-desktop-components)
12. [Step 9: Configure Open OnDemand for Slurm](#step-9-configure-open-ondemand-for-slurm)
13. [Step 10: Configure XFCE Desktop App](#step-10-configure-xfce-desktop-app)
14. [Step 11: Configure Shell App](#step-11-configure-shell-app)
15. [Step 12: Testing and Verification](#step-12-testing-and-verification)
16. [Troubleshooting](#troubleshooting)
17. [Appendix](#appendix)

---

## Overview

This guide covers the installation and configuration of:
- **Slurm** workload manager with FreeIPA integration
- **Open OnDemand** web portal integration
- **XFCE Desktop** via interactive sessions
- **Shell Access** through Open OnDemand

### Key Features
- Centralized user management via FreeIPA
- Slurm service account managed in FreeIPA (UID: 1668602000)
- Two worker nodes for job execution
- Web-based desktop and terminal access

---

## Prerequisites

### Infrastructure
- **Open OnDemand Server**: Rocky Linux 8, Open OnDemand installed, FreeIPA client configured
- **Worker Node 1**: Rocky Linux 8, FreeIPA client configured
- **Worker Node 2**: Rocky Linux 8, FreeIPA client configured
- **FreeIPA Server**: Accessible from all nodes

### Network Requirements
- All nodes can resolve each other via DNS/FreeIPA
- Firewall rules allow communication between nodes
- NTP synchronized across all nodes

### User Information
- FreeIPA users with UIDs starting at 1668600004
- Service account UID: 1668602000 (reserved for slurm)

### Hostnames (Replace with your actual hostnames)
- Controller/OOD: `ood-server.example.com`
- Worker 1: `worker1.example.com`
- Worker 2: `worker2.example.com`

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  FreeIPA Server                                     │
│  - User Authentication (uid=1668600000+)            │
│  - Slurm Service Account (uid=1668602000)           │
└─────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
┌───────▼──────┐  ┌───────▼──────┐  ┌──────▼───────┐
│ OOD Server   │  │  Worker 1    │  │  Worker 2    │
│ + Slurmctld  │  │  + Slurmd    │  │  + Slurmd    │
│ + Slurmd     │  │  + XFCE      │  │  + XFCE      │
│ + Apache     │  │              │  │              │
└──────────────┘  └──────────────┘  └──────────────┘
```

---

## Configuration Variables

Before starting the installation, set your environment variables. These will be used throughout the guide for easy copy/paste:

```bash
# Set your hostnames and update these to match your actual infrastructure
export OOD_SERVER="ood-server.example.com"
export WORKER1="worker1.example.com"
export WORKER2="worker2.example.com"

# Slurm service account UID (should match FreeIPA)
export SLURM_UID="1668602000"
export SLURM_GID="1668602000"

# Worker node specifications (adjust based on your hardware)
export WORKER1_CPUS="8"
export WORKER1_MEMORY="16000"
export WORKER2_CPUS="8"
export WORKER2_MEMORY="16000"
```

Replace the example values with your actual hostnames and hardware specifications. Once set, you can use these variables in commands throughout the installation.

---

## Step 1: Create FreeIPA Service Account

### 1.1 Create Slurm User in FreeIPA

On the **FreeIPA server** (or any client with admin privileges):

First, authenticate as FreeIPA admin, then create the slurm service account with the specified UID. When prompted, set a temporary password (which will be locked later). Finally, lock the account since service accounts don't need password login, and create a host-based access control rule for security.

```bash
kinit admin

ipa user-add slurm \
  --first=Slurm \
  --last=Workload-Manager \
  --uid=$SLURM_UID \
  --gidnumber=$SLURM_GID \
  --homedir=/var/lib/slurm \
  --shell=/sbin/nologin \
  --password

ipa user-disable slurm

ipa hbacrule-add slurm_hosts
ipa hbacrule-add-host slurm_hosts --hosts=$OOD_SERVER
ipa hbacrule-add-host slurm_hosts --hosts=$WORKER1
ipa hbacrule-add-host slurm_hosts --hosts=$WORKER2
ipa hbacrule-add-user slurm_hosts --users=slurm
```

### 1.2 Verify User Creation

On **all nodes** (controller + workers):

Force an SSSD cache refresh, then verify that the slurm user is visible and correctly configured with the expected UID/GID and information.

```bash
sudo sss_cache -E

id slurm

getent passwd slurm
```

---

## Step 2: Install Slurm Packages

### 2.1 Install on All Nodes

Run on **controller and both workers**:

First install the EPEL repository, then install Slurm and Munge packages, followed by additional tools for system administration.

```bash
sudo dnf install -y epel-release

sudo dnf install -y slurm slurm-slurmd slurm-slurmctld slurm-perlapi \
                    munge munge-libs

sudo dnf install -y vim nano htop
```

### 2.2 Handle Automatic User Creation

The packages may create local `slurm` and `munge` users. We need to keep the local `munge` user (service daemon requirement) but remove the local `slurm` user and use FreeIPA instead. Check if a local slurm user was created with a low UID, and if so, remove it. Then verify that the FreeIPA slurm user and local munge user are properly configured.

```bash
id slurm 2>/dev/null

if [ $(id -u slurm 2>/dev/null || echo 0) -lt 1000000 ]; then
  sudo systemctl stop slurmd slurmctld 2>/dev/null
  sudo userdel slurm 2>/dev/null
  sudo groupdel slurm 2>/dev/null
  echo "Local slurm user removed, will use FreeIPA user"
fi

id slurm

id munge
```

### 2.3 Create Required Directories

On **all nodes**:

Create the necessary Slurm spool and log directories, set ownership to the FreeIPA slurm user, set proper permissions, create the slurm home directory, and verify the ownership.

```bash
sudo mkdir -p /var/spool/slurm/ctld
sudo mkdir -p /var/spool/slurm/d
sudo mkdir -p /var/log/slurm

sudo chown -R slurm:slurm /var/spool/slurm/ctld
sudo chown -R slurm:slurm /var/spool/slurm/d
sudo chown -R slurm:slurm /var/log/slurm

sudo chmod 755 /var/spool/slurm/ctld
sudo chmod 755 /var/spool/slurm/d
sudo chmod 755 /var/log/slurm

sudo mkdir -p /var/lib/slurm
sudo chown slurm:slurm /var/lib/slurm
sudo chmod 755 /var/lib/slurm

ls -la /var/spool/slurm/
ls -la /var/log/ | grep slurm
```

---

## Step 3: Configure Munge Authentication

Munge provides authentication between Slurm components across nodes.

### 3.1 Configure SSH Keys for Passwordless Root Access

On the **controller** (Open OnDemand server):

Generate an ECDSA SSH key pair for the root user to enable passwordless access to worker nodes. This will simplify distribution of files like the munge key.

```bash
sudo ssh-keygen -t ecdsa -b 521 -f /root/.ssh/id_ecdsa -N ""
```

Copy the public key to each worker node's authorized_keys:

```bash
sudo ssh-copy-id -i /root/.ssh/id_ecdsa.pub -o StrictHostKeyChecking=no root@$WORKER1

sudo ssh-copy-id -i /root/.ssh/id_ecdsa.pub -o StrictHostKeyChecking=no root@$WORKER2
```

Test passwordless SSH access:

```bash
sudo ssh -i /root/.ssh/id_ecdsa root@$WORKER1 "hostname"

sudo ssh -i /root/.ssh/id_ecdsa root@$WORKER2 "hostname"
```

### 3.2 Generate Munge Key (Controller Only)

On the **controller** (Open OnDemand server):

Generate the munge key and set correct permissions for security.

```bash
sudo /usr/sbin/create-munge-key -f

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
```

### 3.2 Generate Munge Key (Controller Only)

On the **controller** (Open OnDemand server):

Generate the munge key and set correct permissions for security.

```bash
sudo /usr/sbin/create-munge-key -f

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
```

### 3.3 Distribute Munge Key to Workers

On the **controller**, use SCP with the SSH key to copy the munge key to both worker nodes:

```bash
sudo scp -i /root/.ssh/id_ecdsa /etc/munge/munge.key root@$WORKER1:/etc/munge/

sudo scp -i /root/.ssh/id_ecdsa /etc/munge/munge.key root@$WORKER2:/etc/munge/
```

### 3.4 Set Permissions on Workers

On **each worker**, set proper permissions on the munge key:

```bash
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

sudo ls -la /etc/munge/munge.key
```

### 3.5 Start Munge Service

On **all nodes**:

Enable and start the munge service, check its status, and test the munge functionality.

```bash
sudo systemctl enable munge
sudo systemctl start munge

sudo systemctl status munge

munge -n | unmunge
```

### 3.5 Test Munge Between Nodes

On the **controller**:

Create a test credential, copy it to a worker node, and verify it can be successfully decoded.

```bash
munge -n > /tmp/munge.test

sudo scp -i /root/.ssh/id_ecdsa /tmp/munge.test root@$WORKER1:/tmp/

sudo ssh -i /root/.ssh/id_ecdsa root@$WORKER1 "unmunge < /tmp/munge.test"
```

---

## Step 4: Configure Slurm

### 4.1 Gather Node Information

On **each worker**, collect hardware specifications including CPU count, available memory, and the fully qualified hostname:

```bash
nproc

free -m | grep Mem: | awk '{print $2}'

hostname -f
```

Example output:
- worker1: 8 CPUs, 16000 MB RAM
- worker2: 8 CPUs, 16000 MB RAM

### 4.2 Create slurm.conf

On the **controller**, create `/etc/slurm/slurm.conf`:

```bash
sudo tee /etc/slurm/slurm.conf > /dev/null <<EOF
#
# slurm.conf - Slurm configuration file
#

# CLUSTER CONFIGURATION
ClusterName=hpc-cluster
SlurmctldHost=$OOD_SERVER

# SLURM USER
SlurmUser=slurm
SlurmdUser=root

# CONTROLLER CONFIGURATION
SlurmctldPort=6817
SlurmdPort=6818
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurm/d
StateSaveLocation=/var/spool/slurm/ctld

# LOGGING
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# AUTHENTICATION
AuthType=auth/munge
CryptoType=crypto/munge

# SCHEDULING
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# PROCESS TRACKING
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup

# TIMEOUTS
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# RESOURCE LIMITS
DefMemPerCPU=1000
MaxJobCount=10000
SchedulerTimeSlice=30

# ACCOUNTING
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30

# NODE HEALTH CHECK (optional)
# HealthCheckProgram=/usr/sbin/nhc
# HealthCheckInterval=300

# COMPUTE NODES
# Update with your actual hostnames and hardware specs
NodeName=$WORKER1 CPUs=$WORKER1_CPUS RealMemory=$WORKER1_MEMORY State=UNKNOWN
NodeName=$WORKER2 CPUs=$WORKER2_CPUS RealMemory=$WORKER2_MEMORY State=UNKNOWN

# PARTITIONS
PartitionName=general Nodes=$WORKER1,$WORKER2 Default=YES MaxTime=INFINITE State=UP Priority=1
PartitionName=debug Nodes=$WORKER1,$WORKER2 MaxTime=1:00:00 State=UP Priority=10
EOF
```

**Important: Update the following in the config:**
- `SlurmctldHost=ood-server.example.com` → your controller hostname
- `NodeName=worker1.example.com CPUs=8 RealMemory=16000` → your worker1 specs
- `NodeName=worker2.example.com CPUs=8 RealMemory=16000` → your worker2 specs
- `PartitionName` node lists → your worker hostnames

### 4.3 Set Permissions

On the **controller**, set ownership and readable permissions on the configuration file:

```bash
sudo chown slurm:slurm /etc/slurm/slurm.conf
sudo chmod 644 /etc/slurm/slurm.conf
```

### 4.4 Distribute Configuration to Workers

**Option A: Using SCP**

On the **controller**, copy the configuration file to both workers using the SSH key:

```bash
sudo scp -i /root/.ssh/id_ecdsa /etc/slurm/slurm.conf root@$WORKER1:/etc/slurm/

sudo scp -i /root/.ssh/id_ecdsa /etc/slurm/slurm.conf root@$WORKER2:/etc/slurm/
```

**Option B: Configuration Management**

If using Ansible, Puppet, or similar, distribute via your config management tool.

### 4.5 Verify Configuration

On **all nodes**, test the configuration syntax to ensure it's valid:

```bash
slurmd -C
```

---

## Step 5: Configure Cgroups

Cgroups provide resource isolation for Slurm jobs.

### 5.1 Create cgroup.conf

On **all nodes**, create `/etc/slurm/cgroup.conf`:

```bash
sudo tee /etc/slurm/cgroup.conf > /dev/null <<'EOF'
###
# Slurm cgroup configuration
###

CgroupAutomount=yes
CgroupReleaseAgentDir="/etc/slurm/cgroup"

ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
ConstrainDevices=yes

# Memory constraints
AllowedRAMSpace=100
AllowedSwapSpace=0

# Device constraints
AllowedDevicesFile=/etc/slurm/cgroup_allowed_devices_file.conf
EOF

sudo chown slurm:slurm /etc/slurm/cgroup.conf
sudo chmod 644 /etc/slurm/cgroup.conf
```

### 5.2 Create Allowed Devices File

On **all nodes**:

```bash
sudo tee /etc/slurm/cgroup_allowed_devices_file.conf > /dev/null <<'EOF'
/dev/null
/dev/urandom
/dev/zero
/dev/sda*
/dev/cpu/*/*
/dev/pts/*
EOF

sudo chown slurm:slurm /etc/slurm/cgroup_allowed_devices_file.conf
sudo chmod 644 /etc/slurm/cgroup_allowed_devices_file.conf
```

### 5.3 Enable Cgroup Controllers

On **all nodes**, add cgroup controllers to the kernel command line if not already present, and verify the configuration:

```bash
sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0"

cat /proc/cmdline | grep cgroup
```

---

## Step 6: Configure Firewall

### 6.1 Controller Firewall Rules

On the **controller**, open the necessary ports for Slurm services, reload the firewall, and verify the changes:

```bash
sudo firewall-cmd --permanent --add-port=6817/tcp

sudo firewall-cmd --permanent --add-port=6818/tcp

sudo firewall-cmd --permanent --add-port=6819/tcp

sudo firewall-cmd --reload

sudo firewall-cmd --list-ports
```

### 6.2 Worker Firewall Rules

On **each worker**, open the port for the Slurmd compute daemon, reload the firewall, and verify:

```bash
sudo firewall-cmd --permanent --add-port=6818/tcp

sudo firewall-cmd --reload

sudo firewall-cmd --list-ports
```

### 6.3 SELinux Considerations

If SELinux is enforcing (check with `getenforce`), configure port contexts for Slurm services. If semanage is not available, install the required package first:

```bash
sudo semanage port -a -t slurmd_port_t -p tcp 6818
sudo semanage port -a -t slurmctld_port_t -p tcp 6817

sudo dnf install -y policycoreutils-python-utils
```

---

## Step 7: Start Slurm Services

### 7.1 Start Controller Service

On the **controller**:

**Enable and start slurmctld**
```bash
sudo systemctl enable slurmctld
sudo systemctl start slurmctld
```

```bash
sudo systemctl status slurmctld
```

**Check logs**
```bash
sudo tail -f /var/log/slurm/slurmctld.log
```

**Troubleshooting**: If slurmctld fails to start, check the journal for errors, verify the configuration, and check file permissions:

```bash
sudo journalctl -xeu slurmctld

slurmd -C

ls -la /var/spool/slurm/ctld
ls -la /var/log/slurm/
```

### 7.2 Start Worker Services

On **each worker**, enable and start the slurmd service, check its status, and view the logs:

```bash
sudo systemctl enable slurmd
sudo systemctl start slurmd

sudo systemctl status slurmd

sudo tail -f /var/log/slurm/slurmd.log
```

### 7.3 Verify Cluster Status

On the **controller**, check cluster status, node details, and node states. If nodes show as DOWN or DRAIN, resume them using the variables:

```bash
sinfo

scontrol show nodes

sinfo -Nel

sudo scontrol update nodename=$WORKER1 state=resume
sudo scontrol update nodename=$WORKER2 state=resume
```

### 7.4 Test Job Submission

On the **controller** (as a regular user), test job submission by running a simple hostname command, submitting a batch job, checking the queue, and reviewing job history:

```bash
srun -N1 hostname

sbatch --wrap="sleep 30 && hostname"

squeue

sacct
```

---

## Step 8: Install Desktop Components

For users to launch XFCE desktop sessions through Open OnDemand.

### 8.1 Install XFCE on Workers

On **each worker**, install the XFCE desktop environment, VNC server, desktop applications, and supporting utilities:

```bash
sudo dnf groupinstall -y "Server with GUI"
sudo dnf groupinstall -y "Xfce"

sudo dnf install -y tigervnc-server turbovnc websockify

sudo dnf install -y xfce4-terminal firefox chromium

sudo dnf install -y dejavu-sans-fonts dejavu-serif-fonts liberation-fonts

sudo dnf install -y xorg-x11-apps xorg-x11-fonts-Type1 xorg-x11-fonts-misc
```

### 8.2 Configure VNC

On **each worker**, create the VNC directory structure and xstartup script template:

```bash
sudo mkdir -p /etc/skel/.vnc

sudo tee /etc/skel/.vnc/xstartup > /dev/null <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF

sudo chmod +x /etc/skel/.vnc/xstartup
```

### 8.3 Install Additional Tools (Optional)

On **each worker**, install development tools, scientific computing packages, and text editors:

```bash
sudo dnf groupinstall -y "Development Tools"

sudo dnf install -y python3 python3-pip python3-numpy python3-scipy python3-matplotlib

sudo dnf install -y gedit vim-enhanced emacs-nox
```

---

## Step 9: Configure Open OnDemand for Slurm

### 9.1 Create Cluster Configuration

On the **Open OnDemand server**, create the cluster configuration:

```bash
sudo mkdir -p /etc/ood/config/clusters.d

sudo tee /etc/ood/config/clusters.d/hpc-cluster.yml > /dev/null <<EOF
---
v2:
  metadata:
    title: "HPC Cluster"
    url: "https://$OOD_SERVER"
    hidden: false
  login:
    host: "$OOD_SERVER"
  job:
    adapter: "slurm"
    cluster: "hpc-cluster"
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
    bin_overrides:
      sbatch: "/usr/bin/sbatch"
      squeue: "/usr/bin/squeue"
      scontrol: "/usr/bin/scontrol"
      scancel: "/usr/bin/scancel"
EOF
```

**Update:**
- `url: "https://ood-server.example.com"` → your OOD URL
- `host: "ood-server.example.com"` → your controller hostname

### 9.2 Set Permissions

```bash
sudo chown -R root:root /etc/ood/config/clusters.d
sudo chmod 644 /etc/ood/config/clusters.d/hpc-cluster.yml
```

### 9.3 Verify Configuration

Test the cluster configuration and check for errors:

```bash
sudo -u apache /opt/ood/ood-portal-generator/bin/generate -c /etc/ood/config/ood_portal.yml

sudo cat /etc/ood/config/clusters.d/hpc-cluster.yml
```

---

## Step 10: Configure XFCE Desktop App

### 10.1 Create Desktop App Directory

On the **Open OnDemand server**:

```bash
sudo mkdir -p /etc/ood/config/apps/bc_desktop
```

### 10.2 Create Form Configuration

```bash
sudo tee /etc/ood/config/apps/bc_desktop/form.yml > /dev/null <<'EOF'
---
cluster: "hpc-cluster"
attributes:
  desktop: "xfce"
  bc_account: null
  bc_queue:
    label: "Partition"
    help: "Select the partition to submit the job to"
    value: "general"
  bc_num_hours:
    value: 1
    min: 1
    max: 24
    step: 1
    help: "Maximum wall time in hours"
  bc_num_slots:
    label: "Number of cores"
    value: 1
    min: 1
    max: 8
    step: 1
    help: "Number of CPU cores to allocate"
  node_type:
    widget: "select"
    label: "Node Type"
    help: "Select the type of compute node"
    options:
      - ["Standard (general)", "general"]
      - ["Debug (debug)", "debug"]
form:
  - bc_queue
  - bc_num_hours
  - bc_num_slots
  - node_type
  - desktop
  - bc_account
EOF
```

### 10.3 Create Submit Configuration

```bash
sudo tee /etc/ood/config/apps/bc_desktop/submit.yml.erb > /dev/null <<'EOF'
---
batch_connect:
  template: "vnc"
  websockify_cmd: '/usr/bin/websockify'
  script_wrapper: |
    module purge
    %s
script:
  accounting_id: "<%= bc_account %>"
  queue_name: "<%= node_type %>"
  wall_time: "<%= bc_num_hours.to_i * 3600 %>"
  native:
    - "-n"
    - "<%= bc_num_slots.to_i %>"
    - "--mem-per-cpu"
    - "4000"
EOF
```

### 10.4 Create Script Template

```bash
sudo mkdir -p /etc/ood/config/apps/bc_desktop/template

sudo tee /etc/ood/config/apps/bc_desktop/template/script.sh.erb > /dev/null <<'EOF'
#!/bin/bash

# Slurm directives (will be added by OOD)
#SBATCH --output=<%= session_dir %>/output.log

# Load desktop environment
export DESKTOP_SESSION=xfce
export XDG_SESSION_DESKTOP=xfce
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share
export XDG_CONFIG_DIRS=/etc/xdg
export XDG_CURRENT_DESKTOP=XFCE

# Set VNC resolution
export GEOMETRY="<%= bc_vnc_resolution %>"

# Source user environment
if [ -f ~/.bashrc ]; then
  source ~/.bashrc
fi

# Create .vnc directory if it doesn't exist
mkdir -p ~/.vnc

# Create xstartup if it doesn't exist
if [ ! -f ~/.vnc/xstartup ]; then
  cat > ~/.vnc/xstartup << 'XSTARTUP_EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XSTARTUP_EOF
  chmod +x ~/.vnc/xstartup
fi

# Start XFCE desktop
exec /usr/bin/startxfce4
EOF
```

### 10.5 Set Permissions

```bash
sudo chown -R root:root /etc/ood/config/apps/bc_desktop
sudo find /etc/ood/config/apps/bc_desktop -type f -exec chmod 644 {} \;
sudo find /etc/ood/config/apps/bc_desktop -type d -exec chmod 755 {} \;
```

---

## Step 11: Configure Shell App

### 11.1 Create Shell App Configuration

On the **Open OnDemand server**:

```bash
sudo mkdir -p /etc/ood/config/apps/shell

sudo tee /etc/ood/config/apps/shell/env > /dev/null <<EOF
OOD_SHELL_ORIGIN_CHECK=off

DEFAULT_SSHHOST=$OOD_SERVER
EOF
```

### 11.2 Create Cluster-Specific Shell Access

```bash
sudo tee /etc/ood/config/apps/shell/clusters.yml > /dev/null <<EOF
---
clusters:
  - id: "hpc-cluster"
    title: "HPC Cluster Login"
    host: "$OOD_SERVER"
  - id: "worker1"
    title: "Worker 1 Shell"
    host: "$WORKER1"
  - id: "worker2"
    title: "Worker 2 Shell"
    host: "$WORKER2"
EOF
```

### 11.3 Set Permissions

```bash
sudo chown -R root:root /etc/ood/config/apps/shell
sudo chmod 644 /etc/ood/config/apps/shell/*
```

---

## Step 12: Testing and Verification

### 12.1 Restart Open OnDemand Services

On the **Open OnDemand server**:

```bash
# Restart Apache
sudo systemctl restart httpd24-httpd

# Or restart NGINX for per-user NGINX instances
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean
sudo systemctl restart httpd24-httpd

# Check status
sudo systemctl status httpd24-httpd
```

### 12.2 Test Slurm Functionality

As a **regular user** (not root):

```bash
# Check cluster status
sinfo

# Run simple test
srun -N1 hostname

# Submit batch job
cat > test_job.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=test
#SBATCH --output=test_%j.out
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
#SBATCH --partition=general

hostname
date
sleep 10
echo "Job completed successfully!"
EOF

sbatch test_job.sh

squeue

cat test_*.out
```

### 12.3 Test Open OnDemand Web Interface

1. **Access Open OnDemand**:
   - Open browser: `https://ood-server.example.com`
   - Login with FreeIPA credentials

2. **Test Shell Access**:
   - Navigate to: **Clusters** → **Shell Access**
   - Should open terminal in browser
   - Run: `sinfo` to verify Slurm access

3. **Test XFCE Desktop**:
   - Navigate to: **Interactive Apps** → **XFCE Desktop**
   - Select parameters:
     - Partition: general
     - Number of hours: 1
     - Number of cores: 1
     - Node Type: Standard
   - Click **Launch**
   - Wait for job to start (status will change to "Running")
   - Click **Launch XFCE Desktop**
   - Desktop should open in browser

4. **Verify Desktop Functionality**:
   - Test terminal application
   - Open Firefox or Chromium
   - Create test file in home directory
   - Verify file persistence after reconnecting

### 12.4 Test User Permissions

Verify that users can access their home directory in jobs and that user IDs are correctly resolved from FreeIPA:

```bash
sbatch --wrap="ls -la $HOME"

cat slurm-*.out

sbatch --wrap="id"
cat slurm-*.out
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. Slurm Nodes Show as DOWN or DRAIN

**Problem**: `sinfo` shows nodes in DOWN or DRAIN state.

**Solution**:
```bash
# Check node status
scontrol show node worker1.example.com

# Resume nodes
sudo scontrol update nodename=worker1.example.com state=resume
sudo scontrol update nodename=worker2.example.com state=resume

# If nodes still DOWN, check slurmd on worker:
sudo systemctl status slurmd
sudo journalctl -xeu slurmd
```

#### 2. Munge Authentication Failures

**Problem**: Jobs fail with "munge authentication error".

**Solution**: Verify munge is running on all nodes, test munge functionality, check key permissions and consistency, and restart if needed:

```bash
sudo systemctl status munge

munge -n | unmunge

ls -la /etc/munge/munge.key

md5sum /etc/munge/munge.key

sudo systemctl restart munge
```

**Problem**: Slurm services fail with permission errors.

**Solution**: Verify the FreeIPA slurm user exists, fix directory ownership, and restart services:

```bash
id slurm

sudo chown -R slurm:slurm /var/spool/slurm
sudo chown -R slurm:slurm /var/log/slurm

sudo systemctl restart slurmctld
sudo systemctl restart slurmd
```

#### 4. XFCE Desktop Won't Launch

**Problem**: Desktop session fails to start or shows black screen.

**Solution**: Check if XFCE is installed, verify VNC packages, check job output logs, and verify the xstartup script:

```bash
rpm -qa | grep xfce

sudo dnf groupinstall -y "Xfce"

rpm -qa | grep vnc

cat ~/ondemand/data/sys/dashboard/batch_connect/sys/bc_desktop/output/*/output.log

cat ~/.vnc/xstartup
```

#### 5. Users Can't Submit Jobs

**Problem**: Regular users receive "Access denied" when submitting jobs.

**Solution**: Verify the user exists in FreeIPA, check user access to Slurm, verify configuration allows the user, and check partition access:

```bash
id <username>

squeue -u <username>

grep -i "AllowUsers\|DenyUsers" /etc/slurm/slurm.conf

scontrol show partition general
```

#### 6. Open OnDemand Can't Connect to Slurm

**Problem**: OOD shows "Unable to connect to Slurm".

**Solution**: Verify cluster configuration, test Slurm access as the Apache user, check permissions, and restart OOD:

```bash
cat /etc/ood/config/clusters.d/hpc-cluster.yml

sudo -u apache /usr/bin/sinfo

sudo -u apache cat /etc/slurm/slurm.conf

sudo systemctl restart httpd24-httpd
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean
```

#### 7. SELinux Blocking Slurm

**Problem**: SELinux blocking Slurm operations.

**Solution**: Check for SELinux denials, temporarily set to permissive mode for testing, create a policy if needed, and re-enable enforcing:

```bash
sudo ausearch -m avc -ts recent | grep slurm

sudo setenforce 0

sudo ausearch -m avc -ts recent | audit2allow -M slurm_policy
sudo semodule -i slurm_policy.pp

sudo setenforce 1
```

### Log File Locations

- **Slurmctld**: `/var/log/slurm/slurmctld.log`
- **Slurmd**: `/var/log/slurm/slurmd.log`
- **Munge**: `/var/log/munge/munged.log`
- **Open OnDemand**: `/var/log/httpd24/error.log`
- **OOD NGINX**: `~/ondemand/data/logs/`
- **Job output**: User's home directory or specified output path

### Useful Commands

Common Slurm commands for cluster information, job management, node management, and accounting:

```bash
sinfo -Nel
scontrol show config
scontrol show nodes

squeue -u $USER
scancel <job_id>
scontrol show job <job_id>

sudo scontrol update nodename=<node> state=resume
sudo scontrol update nodename=<node> state=drain reason="maintenance"

sudo scontrol reconfigure

sacct -u $USER
sacct -j <job_id> --format=JobID,JobName,Partition,State,Elapsed
```

---

## Appendix

### A. Upgrading to Keycloak/FreeIPA Authentication


#### Keycloak + FreeIPA Integration

1. **Install Keycloak** on a separate server
2. **Configure FreeIPA as identity provider** in Keycloak
3. **Update Open OnDemand** to use Keycloak for authentication:

```yaml
# /etc/ood/config/ood_portal.yml
---
auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'

oidc_uri: "/oidc"
oidc_provider_metadata_url: "https://keycloak.example.com/realms/hpc/.well-known/openid-configuration"
oidc_client_id: "ondemand"
oidc_client_secret: "<secret>"
oidc_remote_user_claim: "preferred_username"
oidc_scope: "openid profile email"
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
oidc_state_max_number_of_cookies: "10 true"
oidc_cookie_same_site: "On"
```

4. **Regenerate Apache configuration**:
```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd24-httpd
```

### B. Slurm Accounting Database (Optional)

For job tracking and resource usage accounting, install and configure MariaDB, create the Slurm database, and install the slurmdbd service:

```bash
sudo dnf install -y mariadb-server

sudo systemctl enable mariadb
sudo systemctl start mariadb

sudo mysql_secure_installation

sudo mysql -u root -p << 'EOF'
CREATE DATABASE slurm_acct_db;
CREATE USER 'slurm'@'localhost' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
EOF

sudo dnf install -y slurm-slurmdbd

sudo systemctl enable slurmdbd
sudo systemctl start slurmdbd
```

### C. Shared Storage Setup

For shared home directories (recommended):

**Option 1: NFS**

On the NFS server, install NFS utilities, create the export directory, configure exports, and start the service:

```bash
sudo dnf install -y nfs-utils

sudo mkdir -p /export/home
sudo chown -R root:root /export/home

echo "/export/home *(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports

sudo systemctl enable nfs-server
sudo systemctl start nfs-server
sudo exportfs -a
```

On all compute nodes, install the NFS client, mount the home directories, and add to fstab for persistence:

```bash
sudo dnf install -y nfs-utils

sudo mkdir -p /home
sudo mount nfs-server.example.com:/export/home /home

echo "nfs-server.example.com:/export/home /home nfs defaults 0 0" | sudo tee -a /etc/fstab
```

**Option 2: FreeIPA Automount**

Use FreeIPA's automount feature for centralized home directory management.

### D. Resource Limits and Fair Share

Add to `/etc/slurm/slurm.conf`:

```bash
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStorageTRES=gres/gpu,mem,cpu

PriorityType=priority/multifactor
PriorityDecayHalfLife=7-0
PriorityMaxAge=14-0
PriorityWeightFairshare=100000
PriorityWeightAge=1000
PriorityWeightJobSize=1000
PriorityWeightPartition=1000
```

### E. GPU Support (If Available)

If your workers have GPUs:

```bash
# In slurm.conf, add to NodeName:
NodeName=worker1 CPUs=8 RealMemory=16000 Gres=gpu:2 State=UNKNOWN

# Create gres.conf
sudo tee /etc/slurm/gres.conf > /dev/null <<'EOF'
NodeName=worker1 Name=gpu File=/dev/nvidia0
NodeName=worker1 Name=gpu File=/dev/nvidia1
EOF
```

### F. Monitoring and Alerting

**Install Prometheus Slurm Exporter**:

```bash
# Install exporter
sudo dnf install -y prometheus-slurm-exporter

# Configure and start
sudo systemctl enable prometheus-slurm-exporter
sudo systemctl start prometheus-slurm-exporter
```

**Grafana Dashboard**: Import Slurm dashboard for visualization.

### G. Backup Recommendations

**Critical Files to Backup**:
- `/etc/slurm/slurm.conf`
- `/etc/slurm/cgroup.conf`
- `/etc/slurm/gres.conf` (if used)
- `/etc/munge/munge.key`
- `/etc/ood/config/`
- `/var/spool/slurm/ctld/` (state files)

**Backup Script Example**:

```bash
#!/bin/bash
BACKUP_DIR="/backup/slurm/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

cp -r /etc/slurm $BACKUP_DIR/
cp /etc/munge/munge.key $BACKUP_DIR/
cp -r /etc/ood/config $BACKUP_DIR/
tar -czf $BACKUP_DIR/slurm_state.tar.gz /var/spool/slurm/ctld/
```

---

## Additional Resources

- **Slurm Documentation**: https://slurm.schedmd.com/documentation.html
- **Open OnDemand Documentation**: https://osc.github.io/ood-documentation/
- **FreeIPA Documentation**: https://www.freeipa.org/page/Documentation
- **Rocky Linux Documentation**: https://docs.rockylinux.org/

---

## Version History

- **v1.0** - Initial release (February 2026)
- FreeIPA-managed Slurm service account (UID: 1668602000)
- Rocky Linux 8 configuration
- XFCE desktop integration
- Shell access configuration

---

**Document End**