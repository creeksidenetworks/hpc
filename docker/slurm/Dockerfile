FROM rockylinux:8

LABEL maintainer="HPC Admin"
LABEL description="Slurm controller (slurmctld) and accounting daemon (slurmdbd) on Rocky Linux 8"

ARG SLURM_VERSION=24.05.5
ARG MUNGE_UID=990
ARG SLURM_UID=1000

ENV SLURM_VERSION=${SLURM_VERSION}

# --------------------------------------------------------------------------
# Create users before package install so RPM scriptlets reuse our UIDs/GIDs
# munge: home /var/lib/munge matches what the munge RPM expects
# slurm: built from source, no RPM scriptlet, home /var/lib/slurm
# --------------------------------------------------------------------------
RUN groupadd -g ${MUNGE_UID} munge && \
    useradd -r -u ${MUNGE_UID} -g munge -s /sbin/nologin \
            -d /var/lib/munge -c "Munge authentication" munge && \
    groupadd -g ${SLURM_UID} slurm && \
    useradd -r -u ${SLURM_UID} -g slurm -s /sbin/nologin \
            -d /var/lib/slurm -c "Slurm workload manager" slurm

# --------------------------------------------------------------------------
# Base packages
# --------------------------------------------------------------------------
RUN dnf -y install epel-release dnf-plugins-core && \
    dnf config-manager --set-enabled powertools && \
    dnf -y update && \
    dnf -y groupinstall "Development Tools" && \
    dnf -y install \
        # SSSD / LDAP / FreeIPA auth
        sssd \
        sssd-ldap \
        sssd-ipa \
        openldap-clients \
        # Munge
        munge \
        munge-libs \
        munge-devel \
        # MariaDB client (slurmdbd needs it; actual DB is external)
        mariadb-devel \
        mariadb \
        # Build deps for Slurm
        pam-devel \
        readline-devel \
        openssl-devel \
        perl \
        python3 \
        python3-devel \
        # Runtime utilities
        supervisor \
        curl \
        wget \
        less \
        procps-ng \
        net-tools \
        iputils \
        hostname \
        which \
        rsync \
        gettext \
        # JWT (optional but useful)
        libjwt-devel \
        http-parser-devel \
        json-c-devel \
        # Cron for periodic sync jobs
        cronie && \
    dnf clean all && rm -rf /var/cache/dnf

# --------------------------------------------------------------------------
# Build and install Slurm from source
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
    install -D -m 0644 etc/cgroup.conf.example     /etc/slurm/cgroup.conf && \
    install -D -m 0644 etc/slurm.conf.example      /etc/slurm/slurm.conf && \
    install -D -m 0600 etc/slurmdbd.conf.example   /etc/slurm/slurmdbd.conf && \
    cd / && rm -rf /tmp/slurm-build

# --------------------------------------------------------------------------
# Directory layout
# --------------------------------------------------------------------------
RUN mkdir -p \
        /etc/slurm \
        /var/spool/slurm/ctld \
        /var/spool/slurm/d \
        /var/log/slurm \
        /var/run/slurm \
        /var/run/slurmdbd \
        /var/lib/slurm && \
    chown -R slurm:slurm \
        /var/spool/slurm \
        /var/log/slurm \
        /var/run/slurm \
        /var/run/slurmdbd \
        /var/lib/slurm && \
    chmod 0755 /var/spool/slurm/ctld /var/spool/slurm/d

# --------------------------------------------------------------------------
# Copy config files and entrypoint
# --------------------------------------------------------------------------
COPY conf/slurm.conf        /etc/slurm/slurm.conf
COPY conf/slurmdbd.conf     /etc/slurm/slurmdbd.conf
COPY conf/cgroup.conf       /etc/slurm/cgroup.conf
COPY conf/sssd.conf         /etc/sssd/sssd.conf
COPY conf/supervisord.conf  /etc/supervisord.conf
COPY entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY scripts/sync-slurm-ipa.sh /usr/local/bin/sync-slurm-ipa.sh

RUN chmod 600 /etc/slurm/slurmdbd.conf && \
    chown slurm:slurm /etc/slurm/slurmdbd.conf && \
    chmod 600 /etc/sssd/sssd.conf && \
    chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/sync-slurm-ipa.sh && \
    # Install crontab: run sync every 10 minutes, log to /var/log/slurm/sync-ipa.log
    echo '*/10 * * * * root /usr/local/bin/sync-slurm-ipa.sh >> /var/log/slurm/sync-ipa.log 2>&1' \
        > /etc/cron.d/sync-slurm-ipa && \
    chmod 644 /etc/cron.d/sync-slurm-ipa

# Munge key placeholder — generated at runtime if not provided
RUN mkdir -p /etc/munge && chmod 700 /etc/munge

EXPOSE 6817 6819

VOLUME ["/etc/munge", "/etc/slurm", "/var/spool/slurm", "/var/log/slurm"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
