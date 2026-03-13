#!/usr/bin/env bash
# build.sh — Build HPC Docker images (slurm-ctld/slurmdbd and/or ondemand).
#
# Usage:
#   ./build.sh [options]
#
# Options:
#   -c TARGET     Component to build: slurm, ondemand, all (default: all)
#   -t TAG        Slurm image tag (default: slurm-ctld:latest)
#   -T TAG        OnDemand image tag (default: ondemand:latest)
#   -s VERSION    Slurm version to compile (default: 24.05.5)
#   -V VERSION    OnDemand package version (default: 4.1)
#   -k KEYDIR     Host directory to copy the munge key into (default: ./munge)
#   -P            Push arch-specific tag to registry after build
#   -M            Create+push multi-arch manifest for the slurm image (requires
#                 both arch images already pushed). No build is performed.
#   -n            Do NOT copy munge key after slurm build
#   -h            Show this help
#
# Typical multi-arch workflow (slurm image):
#   # On ARM host (e.g. Apple Silicon / ARM server):
#   ./build.sh -c slurm -t ghcr.io/you/slurm-ctld:latest -P
#
#   # On AMD64 host / VM:
#   ./build.sh -c slurm -t ghcr.io/you/slurm-ctld:latest -P
#
#   # On either host, once both pushes are done:
#   ./build.sh -c slurm -t ghcr.io/you/slurm-ctld:latest -M
#
# After a successful slurm build the script:
#   1. Spins up a temporary container
#   2. Generates the munge key (if none exists in KEYDIR)
#   3. Copies the key to KEYDIR/munge.key on the host
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------- defaults -------------------------------------------------------
BUILD_TARGET="all"          # slurm | ondemand | all
IMAGE_TAG="slurm-ctld:latest"
OOD_IMAGE_TAG="ondemand:latest"
SLURM_VERSION="24.05.5"
OOD_VERSION="4.1"
KEY_DIR="$(dirname "$0")/munge"
SKIP_KEY_COPY=0
DO_PUSH=0
DO_MANIFEST=0
CONTEXT_DIR="$(dirname "$0")/slurm"
OOD_CONTEXT_DIR="$(dirname "$0")/ondemand"
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
while getopts ":c:t:T:s:V:k:PMnh" opt; do
    case $opt in
        c) BUILD_TARGET="$OPTARG" ;;
        t) IMAGE_TAG="$OPTARG" ;;
        T) OOD_IMAGE_TAG="$OPTARG" ;;
        s) SLURM_VERSION="$OPTARG" ;;
        V) OOD_VERSION="$OPTARG" ;;
        k) KEY_DIR="$OPTARG" ;;
        P) DO_PUSH=1 ;;
        M) DO_MANIFEST=1 ;;
        n) SKIP_KEY_COPY=1 ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        *) die "Unknown option: -$OPTARG" ;;
    esac
done

case "$BUILD_TARGET" in
    slurm|ondemand|all) ;;
    *) die "Invalid -c target '$BUILD_TARGET'. Use: slurm, ondemand, all" ;;
esac

# ---------- pre-flight checks ----------------------------------------------
command -v docker &>/dev/null || die "docker not found in PATH"

# ---------- manifest-only mode (slurm image only) --------------------------
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

# ---------- build slurm image ----------------------------------------------
build_slurm() {
    [[ -f "$CONTEXT_DIR/Dockerfile" ]] || \
        die "Dockerfile not found at $CONTEXT_DIR/Dockerfile"

    if [[ ! -f "$CONTEXT_DIR/conf/slurmdbd.conf" ]]; then
        cat <<EOF > "$CONTEXT_DIR/conf/slurmdbd.conf"
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
StoragePass=CHANGE_ME_DB_PASSWORD
StorageLoc=slurm_acct_db
EOF
        warn "Generated skeleton slurmdbd.conf — update StoragePass before use."
    fi

    for cfg in slurm.conf cgroup.conf sssd.conf supervisord.conf; do
        [[ -f "$CONTEXT_DIR/conf/$cfg" ]] || \
            die "Missing required config: $CONTEXT_DIR/conf/$cfg"
    done

    local local_tag
    local_tag=$(arch_tag "$IMAGE_TAG" "$CURRENT_ARCH")

    log "Building slurm image: $local_tag  (Slurm $SLURM_VERSION, arch=$CURRENT_ARCH)"
    docker build \
        --build-arg SLURM_VERSION="${SLURM_VERSION}" \
        --build-arg MUNGE_UID=990 \
        --build-arg SLURM_UID=1000 \
        -t "${local_tag}" \
        "${CONTEXT_DIR}"

    log "Image built successfully: $local_tag"
    docker tag "$local_tag" "$IMAGE_TAG"
    log "Also tagged as: $IMAGE_TAG"

    if [[ $DO_PUSH -eq 1 ]]; then
        log "Pushing $local_tag ..."
        docker push "$local_tag"
        log "Pushed: $local_tag"

        if [[ $DO_MANIFEST -eq 1 ]]; then
            local other_arch other_tag arch_amd64 arch_arm64
            other_arch=$([[ "$CURRENT_ARCH" == "amd64" ]] && echo "arm64" || echo "amd64")
            other_tag=$(arch_tag "$IMAGE_TAG" "$other_arch")
            arch_amd64=$(arch_tag "$IMAGE_TAG" "amd64")
            arch_arm64=$(arch_tag "$IMAGE_TAG" "arm64")

            log "Checking registry for $other_tag ..."
            if docker manifest inspect "$other_tag" &>/dev/null; then
                log "Creating multi-arch manifest: $IMAGE_TAG"
                docker manifest rm "$IMAGE_TAG" 2>/dev/null || true
                docker manifest create "$IMAGE_TAG" \
                    "$arch_amd64" \
                    "$arch_arm64"
                docker manifest push "$IMAGE_TAG"
                log "Manifest pushed: $IMAGE_TAG"
            else
                warn "Other arch image ($other_tag) not yet in registry."
                warn "After pushing from the $other_arch host, run:"
                warn "  ./build.sh -c slurm -t $IMAGE_TAG -M"
            fi
        fi
    fi
}

# ---------- build ondemand image -------------------------------------------
build_ondemand() {
    [[ -f "$OOD_CONTEXT_DIR/Dockerfile" ]] || \
        die "Dockerfile not found at $OOD_CONTEXT_DIR/Dockerfile"

    for cfg in sssd.conf supervisord.conf; do
        [[ -f "$OOD_CONTEXT_DIR/conf/$cfg" ]] || \
            die "Missing required config: $OOD_CONTEXT_DIR/conf/$cfg
  Copy $OOD_CONTEXT_DIR/conf/${cfg%.conf}.conf.sample to ${cfg} and fill in secrets."
    done

    local local_tag
    local_tag=$(arch_tag "$OOD_IMAGE_TAG" "$CURRENT_ARCH")

    log "Building ondemand image: $local_tag  (OOD $OOD_VERSION, Slurm $SLURM_VERSION, arch=$CURRENT_ARCH)"
    docker build \
        --build-arg OOD_VERSION="${OOD_VERSION}" \
        --build-arg SLURM_VERSION="${SLURM_VERSION}" \
        --build-arg MUNGE_UID=990 \
        --build-arg SLURM_UID=1000 \
        -t "${local_tag}" \
        "${OOD_CONTEXT_DIR}"

    log "Image built successfully: $local_tag"
    docker tag "$local_tag" "$OOD_IMAGE_TAG"
    log "Also tagged as: $OOD_IMAGE_TAG"

    if [[ $DO_PUSH -eq 1 ]]; then
        log "Pushing $local_tag ..."
        docker push "$local_tag"
        log "Pushed: $local_tag"
    fi
}

# ---------- determine arch and run builds ----------------------------------
CURRENT_ARCH=$(detect_arch)

[[ "$BUILD_TARGET" == "slurm"    || "$BUILD_TARGET" == "all" ]] && build_slurm
[[ "$BUILD_TARGET" == "ondemand" || "$BUILD_TARGET" == "all" ]] && build_ondemand

# ---------- munge key export (slurm builds only) ---------------------------
if [[ "$BUILD_TARGET" == "slurm" || "$BUILD_TARGET" == "all" ]]; then
    if [[ $SKIP_KEY_COPY -eq 1 ]]; then
        warn "Skipping munge key copy (-n flag set)"
    else
        mkdir -p "$KEY_DIR"
        EXISTING_KEY="$KEY_DIR/munge.key"
        LOCAL_TAG=$(arch_tag "$IMAGE_TAG" "$CURRENT_ARCH")

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
    fi

    # Auto-generate MariaDB passwords if still placeholder
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
fi

log "Done. To start services run:"
log "  docker compose -f $COMPOSE_FILE up -d"
