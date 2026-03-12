#!/usr/bin/env bash
# build.sh — Build the slurmctld/slurmdbd Docker image and export the munge key.
#
# Usage:
#   ./build.sh [options]
#
# Options:
#   -t TAG        Base image tag (default: slurm-ctld:latest)
#                 When pushing, arch suffix is appended automatically, e.g.
#                 ghcr.io/you/slurm-ctld:latest-arm64
#   -s VERSION    Slurm version to compile (default: 24.05.5)
#   -k KEYDIR     Host directory to copy the munge key into (default: ./munge)
#   -P            Push arch-specific tag to registry after build
#   -M            Create+push multi-arch manifest (requires both arch images
#                 already pushed to the registry). No build is performed.
#   -n            Do NOT copy munge key after build
#   -h            Show this help
#
# Typical multi-arch workflow:
#   # On ARM host (e.g. Apple Silicon / ARM server):
#   ./build.sh -t ghcr.io/you/slurm-ctld:latest -P
#
#   # On AMD64 host / VM:
#   ./build.sh -t ghcr.io/you/slurm-ctld:latest -P
#
#   # On either host, once both pushes are done:
#   ./build.sh -t ghcr.io/you/slurm-ctld:latest -M
#
# After a successful build the script:
#   1. Spins up a temporary container
#   2. Generates the munge key (if none exists in KEYDIR)
#   3. Copies the key to KEYDIR/munge.key on the host
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------- defaults -------------------------------------------------------
IMAGE_TAG="slurm-ctld:latest"
SLURM_VERSION="24.05.5"
KEY_DIR="$(dirname "$0")/munge"
SKIP_KEY_COPY=0
DO_PUSH=0
DO_MANIFEST=0
CONTEXT_DIR="$(dirname "$0")/slurm"
COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"

# ---------- helpers --------------------------------------------------------
log()  { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

# Detect current architecture and map to docker convention
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)          echo "amd64" ;;
        aarch64|arm64)   echo "arm64" ;;
        *)               die "Unsupported architecture: $machine" ;;
    esac
}

# Strip any existing arch suffix from TAG and append the given one
arch_tag() {
    local base="$1" arch="$2"
    # Remove trailing -amd64 or -arm64 if already present
    base="${base%-amd64}"
    base="${base%-arm64}"
    echo "${base}-${arch}"
}

usage() {
    sed -n '/^# Usage/,/^# ---/p' "$0" | head -n -1 | sed 's/^# \{0,3\}//'
    exit 0
}

# ---------- arg parsing ----------------------------------------------------
while getopts ":t:s:k:PMnh" opt; do
    case $opt in
        t) IMAGE_TAG="$OPTARG" ;;
        s) SLURM_VERSION="$OPTARG" ;;
        k) KEY_DIR="$OPTARG" ;;
        P) DO_PUSH=1 ;;
        M) DO_MANIFEST=1 ;;
        n) SKIP_KEY_COPY=1 ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        *) die "Unknown option: -$OPTARG" ;;
    esac
done

# ---------- pre-flight checks ----------------------------------------------
command -v docker &>/dev/null || die "docker not found in PATH"

# Manifest-only mode — no build needed
if [[ $DO_MANIFEST -eq 1 && $DO_PUSH -eq 0 ]]; then
    ARCH_AMD64=$(arch_tag "$IMAGE_TAG" "amd64")
    ARCH_ARM64=$(arch_tag "$IMAGE_TAG" "arm64")

    log "Creating multi-arch manifest: $IMAGE_TAG"
    log "  amd64 source: $ARCH_AMD64"
    log "  arm64 source: $ARCH_ARM64"

    # Remove stale local manifest if it exists
    docker manifest rm "$IMAGE_TAG" 2>/dev/null || true

    docker manifest create "$IMAGE_TAG" \
        "$ARCH_AMD64" \
        "$ARCH_ARM64"

    docker manifest push "$IMAGE_TAG"
    log "Manifest pushed: $IMAGE_TAG"
    exit 0
fi

[[ -f "$CONTEXT_DIR/Dockerfile" ]] || \
    die "Dockerfile not found at $CONTEXT_DIR/Dockerfile"

if [[ ! -f "$CONTEXT_DIR/conf/$slurmdbd.conf" ]]; then
    cat <<EOF > "$CONTEXT_DIR/conf/$slurmdbd.conf"
# slurmdbd.conf — Slurm Database Daemon configuration
# Reference: https://slurm.schedmd.com/slurmdbd.conf.html
# File must be owned by slurm, mode 0600

# ----- Authentication -----
AuthType=auth/munge

# ----- Daemon -----
DbdHost=slurmctld
DbdPort=6819
SlurmUser=slurm
DebugLevel=info
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurmdbd/slurmdbd.pid

# ----- Database (external MariaDB container) -----
StorageType=accounting_storage/mysql
StorageHost=mariadb          # hostname of the external MariaDB container
StoragePort=3306
StorageUser=slurm
StoragePass=UbHGnYGid10HMHvIotB05jWpNsnuTgSC
StorageLoc=slurm_acct_db
EOF

fi

for cfg in slurm.conf cgroup.conf sssd.conf supervisord.conf; do
    [[ -f "$CONTEXT_DIR/conf/$cfg" ]] || \
        die "Missing required config: $CONTEXT_DIR/conf/$cfg"
done

# ---------- determine tags -------------------------------------------------
CURRENT_ARCH=$(detect_arch)
LOCAL_TAG=$(arch_tag "$IMAGE_TAG" "$CURRENT_ARCH")   # e.g. ghcr.io/you/slurm-ctld:latest-arm64

# ---------- build ----------------------------------------------------------
log "Building image: $LOCAL_TAG  (Slurm $SLURM_VERSION, arch=$CURRENT_ARCH)"
docker build \
    --build-arg SLURM_VERSION="${SLURM_VERSION}" \
    --build-arg MUNGE_UID=990 \
    --build-arg SLURM_UID=1000 \
    -t "${LOCAL_TAG}" \
    "${CONTEXT_DIR}"

log "Image built successfully: $LOCAL_TAG"

# Also tag as the base tag (without arch suffix) for local docker compose use
docker tag "$LOCAL_TAG" "$IMAGE_TAG"
log "Also tagged as: $IMAGE_TAG"

# ---------- push -----------------------------------------------------------
if [[ $DO_PUSH -eq 1 ]]; then
    log "Pushing $LOCAL_TAG ..."
    docker push "$LOCAL_TAG"
    log "Pushed: $LOCAL_TAG"

    if [[ $DO_MANIFEST -eq 1 ]]; then
        OTHER_ARCH=$([[ "$CURRENT_ARCH" == "amd64" ]] && echo "arm64" || echo "amd64")
        OTHER_TAG=$(arch_tag "$IMAGE_TAG" "$OTHER_ARCH")
        ARCH_AMD64=$(arch_tag "$IMAGE_TAG" "amd64")
        ARCH_ARM64=$(arch_tag "$IMAGE_TAG" "arm64")

        log "Checking registry for $OTHER_TAG ..."
        if docker manifest inspect "$OTHER_TAG" &>/dev/null; then
            log "Creating multi-arch manifest: $IMAGE_TAG"
            docker manifest rm "$IMAGE_TAG" 2>/dev/null || true
            docker manifest create "$IMAGE_TAG" \
                "$ARCH_AMD64" \
                "$ARCH_ARM64"
            docker manifest push "$IMAGE_TAG"
            log "Manifest pushed: $IMAGE_TAG"
        else
            warn "Other arch image ($OTHER_TAG) not yet in registry."
            warn "After pushing from the $OTHER_ARCH host, run:"
            warn "  ./build.sh -t $IMAGE_TAG -M"
        fi
    fi
fi

# ---------- munge key export -----------------------------------------------
if [[ $SKIP_KEY_COPY -eq 1 ]]; then
    warn "Skipping munge key copy (-n flag set)"
    exit 0
fi

mkdir -p "$KEY_DIR"
EXISTING_KEY="$KEY_DIR/munge.key"

if [[ -f "$EXISTING_KEY" ]]; then
    warn "Munge key already exists at $EXISTING_KEY — not overwriting"
    warn "  Delete it and re-run if you need a fresh key."
else
    log "Spinning up temporary container to generate munge key..."
    docker run -d \
        --name slurm-munge-init \
        --rm \
        --entrypoint /bin/bash \
        "${LOCAL_TAG}" \
        -c 'dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key 2>/dev/null && sleep 5'

    sleep 3

    log "Copying munge key to host: $EXISTING_KEY"
    docker cp "slurm-munge-init:/etc/munge/munge.key" "$EXISTING_KEY"
    chown 990:990 "$EXISTING_KEY"
    chmod 400 "$EXISTING_KEY"

    docker stop slurm-munge-init &>/dev/null || true

    log "Munge key saved to $EXISTING_KEY"
    log "  Bind-mount this file into slurmctld and all compute nodes"
    log "  at /etc/munge/munge.key (mode 400, owned by munge:munge)"
fi

# ---------- auto-generate MariaDB passwords if still placeholder ------------
ENV_FILE="$(dirname "$0")/.env"
PLACEHOLDER="CHANGE"
if grep -q "${PLACEHOLDER}" "$ENV_FILE" 2>/dev/null; then
    log "Generating random MariaDB passwords in $ENV_FILE ..."
    NEW_ROOT=$(openssl rand -base64 24 | tr -d '/+=')
    NEW_SLURM=$(openssl rand -base64 24 | tr -d '/+=')
    sed -i "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=${NEW_ROOT}|" "$ENV_FILE"
    sed -i "s|^MARIADB_SLURM_PASSWORD=.*|MARIADB_SLURM_PASSWORD=${NEW_SLURM}|" "$ENV_FILE"
    # Sync the same slurm password into slurmdbd.conf
    SLURMDBD_CONF="$(dirname "$0")/slurm/conf/slurmdbd.conf"
    sed -i "s|^StoragePass=.*|StoragePass=${NEW_SLURM}|" "$SLURMDBD_CONF"
    # Sync into mariadb init SQL
    INIT_SQL="$(dirname "$0")/mariadb/init/01-slurm-grants.sql"
    sed -i "s|IDENTIFIED BY '.*'|IDENTIFIED BY '${NEW_SLURM}'|" "$INIT_SQL"
    log "Passwords written — keep $ENV_FILE safe and do not commit it."
fi

log "Done. To start services run:"
log "  docker compose -f $COMPOSE_FILE up -d"
