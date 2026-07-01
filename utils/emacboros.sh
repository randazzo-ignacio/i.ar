#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"

# =============================================================================
# Agentic Emacs -- Container Management Script
# =============================================================================

IMAGE_NAME="iar-emacboros"
CONTAINER_NAME="iar-emacboros"

# Default: remote Ollama instance
REMOTE_OLLAMA_HOST="10.66.0.3:11434"
LOCAL_OLLAMA_HOST="localhost:11434"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: emacboros.sh [OPTIONS]

Options:
  --local          Use a local Ollama instance (localhost:11434) instead of
                   the remote server. Enables host networking so the container
                   can reach Ollama on the host loopback interface.
  --mount PATH     Mount a host directory read-write inside the container at
                   the same absolute path. Can be specified multiple times.
                   The path must exist on the host.
  --mount-ro PATH  Mount a host directory read-only inside the container at
                   the same absolute path. Can be specified multiple times.
                   The path must exist on the host.
  --help, -h       Show this message and exit.

Examples:
  emacboros.sh --mount /home/nacho/projects/myapp
  emacboros.sh --mount-ro /etc/ansible --mount /home/nacho/infra
  emacboros.sh --local --mount /home/nacho/dev/scratch
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
USE_LOCAL=false
MOUNT_ARGS=()
MOUNT_RO_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            USE_LOCAL=true
            shift
            ;;
        --mount)
            [[ $# -lt 2 ]] && error "--mount requires a path argument" && exit 1
            MOUNT_PATH="$(realpath "$2")"
            [[ ! -d "${MOUNT_PATH}" ]] && error "--mount: directory does not exist: ${MOUNT_PATH}" && exit 1
            MOUNT_ARGS+=("${MOUNT_PATH}")
            shift 2
            ;;
        --mount-ro)
            [[ $# -lt 2 ]] && error "--mount-ro requires a path argument" && exit 1
            MOUNT_PATH="$(realpath "$2")"
            [[ ! -d "${MOUNT_PATH}" ]] && error "--mount-ro: directory does not exist: ${MOUNT_PATH}" && exit 1
            MOUNT_RO_ARGS+=("${MOUNT_PATH}")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# =============================================================================
# Build runtime options based on mode
# =============================================================================
if [[ "${USE_LOCAL}" == "true" ]]; then
    OLLAMA_HOST="${LOCAL_OLLAMA_HOST}"
    NET_OPTS="--network=host"
    info "Local mode: using Ollama at ${OLLAMA_HOST} with host networking"
else
    OLLAMA_HOST="${REMOTE_OLLAMA_HOST}"
    NET_OPTS=""
    info "Remote mode: using Ollama at ${OLLAMA_HOST}"
fi

# =============================================================================
# Build dynamic mount arguments
# =============================================================================
DYNAMIC_MOUNT_OPTS=()

for path in "${MOUNT_ARGS[@]:-}"; do
    [[ -z "${path}" ]] && continue
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:Z")
    info "Mounting read-write: ${path}"
done

for path in "${MOUNT_RO_ARGS[@]:-}"; do
    [[ -z "${path}" ]] && continue
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:ro,Z")
    info "Mounting read-only:  ${path}"
done

# =============================================================================
# Run the container with .emacs.d mounted
# =============================================================================
run() {
    info "Starting ${CONTAINER_NAME}"

    # shellcheck disable=SC2086
    podman run \
        --rm -it --name "${CONTAINER_NAME}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        --tmpfs /var/tmp:rw,size=64m \
        -v "${REPO_DIR}/emacs.d:/root/.emacs.d:Z" \
        -v "${REPO_DIR}/metaconfig:/root/.emacs.d/metaconfig:Z" \
        -v "${REPO_DIR}/knowledge/prompts:/root/.emacs.d/agents.d:Z" \
        \
        -v "${REPO_DIR}/emacs.d:/root/i.ar/emacs.d:Z" \
        -v "${REPO_DIR}/metaconfig:/root/i.ar/metaconfig:Z" \
        -v "${REPO_DIR}/knowledge:/root/i.ar/knowledge:Z" \
        -v "${REPO_DIR}/containers:/root/i.ar/containers:Z" \
        -v "${REPO_DIR}/infra:/root/i.ar/infra:Z" \
        -v "${REPO_DIR}/utils:/root/i.ar/utils:Z" \
        -v "${REPO_DIR}/README.org:/root/i.ar/README.org:Z" \
        "${DYNAMIC_MOUNT_OPTS[@]:-}" \
        "${IMAGE_NAME}" && \
        info "Container started" || \
        error "Container failed to start"
}

run
