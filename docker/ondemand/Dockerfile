FROM rockylinux:8

LABEL maintainer="HPC Admin"
LABEL description="Open OnDemand web portal on Rocky Linux 8"

ARG SLURM_VERSION=24.05.5
ARG OOD_VERSION=4.1
ARG MUNGE_UID=990
ARG SLURM_UID=1000

ENV SLURM_VERSION=${SLURM_VERSION}
ENV OOD_VERSION=${OOD_VERSION}

# --------------------------------------------------------------------------
# Create munge and slurm users before package install so RPM scriptlets
# reuse our UIDs/GIDs
# --------------------------------------------------------------------------
RUN groupadd -g ${MUNGE_UID} munge && \
    useradd -r -u ${MUNGE_UID} -g munge -s /sbin/nologin \
            -d /var/lib/munge -c "Munge authentication" munge && \
    groupadd -g ${SLURM_UID} slurm && \
    useradd -r -u ${SLURM_UID} -g slurm -s /sbin/nologin \
            -d /var/lib/slurm -c "Slurm workload manager" slurm

# --------------------------------------------------------------------------
# Repos and base packages
# --------------------------------------------------------------------------
RUN dnf -y install epel-release dnf-plugins-core && \
    dnf config-manager --set-enabled powertools && \
    dnf -y update && \
    dnf module enable -y ruby:3.3 nodejs:22 && \
    dnf -y groupinstall "Development Tools" && \
    dnf -y install \
        munge munge-libs munge-devel \
        mariadb-devel \
        pam-devel readline-devel openssl-devel perl \
        python3 python3-devel \
        sssd sssd-ldap sssd-ipa openldap-clients \
        mod_auth_openidc \
        mod_authnz_pam \
        mod_ssl \
        supervisor cronie \
        curl wget less \
        procps-ng net-tools iputils hostname which \
        rsync gettext \
        openssh-clients && \
    dnf clean all && rm -rf /var/cache/dnf

# --------------------------------------------------------------------------
# Install Open OnDemand
# --------------------------------------------------------------------------
RUN rpm --import https://yum.osc.edu/ondemand/RPM-GPG-KEY-ondemand-SHA512 && \
    dnf install -y \
        https://yum.osc.edu/ondemand/${OOD_VERSION}/ondemand-release-web-${OOD_VERSION}-1.el8.noarch.rpm && \
    dnf install -y ondemand && \
    dnf clean all && rm -rf /var/cache/dnf

# --------------------------------------------------------------------------
# Build Slurm client from source (same version as slurmctld container)
# Provides sbatch, squeue, scontrol, scancel, sacct for job submission
# --------------------------------------------------------------------------
WORKDIR /tmp/slurm-build
RUN curl -fsSL \
      "https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2" \
      -o slurm.tar.bz2 && \
    tar xjf slurm.tar.bz2 && \
    cd slurm-${SLURM_VERSION} && \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/slurm \
        --with-munge \
        --with-mysql_config=/usr/bin \
        --enable-pam \
        --without-hdf5 \
        2>&1 | tail -20 && \
    make -j"$(nproc)" && \
    make install && \
    cd / && rm -rf /tmp/slurm-build

# --------------------------------------------------------------------------
# Directory layout
# --------------------------------------------------------------------------
RUN mkdir -p \
        /etc/ood/config/clusters.d \
        /etc/ood/config/apps \
        /etc/slurm \
        /etc/munge \
        /var/log/ondemand \
        /var/lib/slurm && \
    chmod 700 /etc/munge && \
    # Save built-in OOD system apps to a backup path inside the image.
    # The entrypoint seeds the host-mounted /var/www/ood/apps/sys from here
    # on first start so users can live-edit apps without losing built-ins.
    cp -a /var/www/ood/apps/sys /usr/share/ood-sys-apps-default

# --------------------------------------------------------------------------
# Copy configs and entrypoint
# --------------------------------------------------------------------------
COPY conf/ood_portal.yml.sample    /etc/ood/config/ood_portal.yml
COPY conf/ood_portal_local.yml     /etc/ood/config/ood_portal_local.yml
COPY conf/clusters.d/              /etc/ood/config/clusters.d/
COPY conf/sssd.conf                /etc/sssd/sssd.conf
COPY conf/supervisord.conf         /etc/supervisord.conf
COPY conf/pam.d/ood                /etc/pam.d/ood
COPY scripts/ood-pun-setup.sh      /usr/local/bin/ood-pun-setup.sh
COPY entrypoint.sh                 /usr/local/bin/entrypoint.sh

RUN chmod 600 /etc/sssd/sssd.conf \
              /etc/pam.d/ood && \
    chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/ood-pun-setup.sh && \
    # Enable mod_authnz_pam (disabled by default on Rocky 8)
    sed -i 's|^#.*LoadModule authnz_pam_module|LoadModule authnz_pam_module|' \
        /etc/httpd/conf.modules.d/55-authnz_pam.conf && \
    # Remove default ssl.conf VirtualHost — OOD generates its own SSL config
    rm -f /etc/httpd/conf.d/ssl.conf && \
    # Add Listen directives (ssl.conf normally provides 443; we also need 8080)
    # Port 443  — HTTPS, PAM/IPA auth, direct VPN access
    # Port 8080 — HTTP,  OIDC auth,   external reverse proxy access
    printf 'Listen 443 https\nListen 8080\n' \
        > /etc/httpd/conf.d/ood-listen.conf && \
    # Wrap nginx_stage to run per-user provisioning before the PUN starts.
    # nginx_stage runs as root — the wrapper extracts --user and delegates
    # all provisioning (home dir, SSH keys, Slurm account) to ood-pun-setup.sh.
    mv /opt/ood/nginx_stage/sbin/nginx_stage \
       /opt/ood/nginx_stage/sbin/nginx_stage.real && \
    printf '%s\n' \
        '#!/bin/bash' \
        'for i in "$@"; do' \
        '  [[ "$_prev" == "--user" ]] && _user="$i"; _prev="$i"' \
        'done' \
        '[[ -n "$_user" ]] && /usr/local/bin/ood-pun-setup.sh "$_user" \' \
        '    >> /var/log/ondemand/pun-setup.log 2>&1 || true' \
        'exec /opt/ood/nginx_stage/sbin/nginx_stage.real "$@"' \
        > /opt/ood/nginx_stage/sbin/nginx_stage && \
    chmod +x /opt/ood/nginx_stage/sbin/nginx_stage

EXPOSE 80 443 8080

VOLUME ["/var/www/ood/apps/sys", "/var/www/ood/public", "/etc/munge"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
