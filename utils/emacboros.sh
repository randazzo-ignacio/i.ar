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

# Default: personalization directory (can be overridden with --personalization)
# The personalization directory must contain three subdirectories:
#   knowledge/  -- injectable knowledge bases (loaded via C-c k)
#   tasks/      -- per-agent personal files (TODO.md, IDEAS.md, LOGS.md, SUMMARY.md, MEMORIES.md)
#   audit/      -- per-agent HISTORY.log files and the global audit.log
PERSONALIZATION_DIR="${REPO_DIR}/personalization"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: emacboros.sh [OPTIONS]

Options:
  --local              Use a local Ollama instance (localhost:11434) instead of
                       the remote server. Enables host networking so the container
                       can reach Ollama on the host loopback interface.
  --mount PATH         Mount a host directory read-write inside the container at
                       the same absolute path. Can be specified multiple times.
                       The path must exist on the host.
  --mount-ro PATH      Mount a host directory read-only inside the container at
                       the same absolute path. Can be specified multiple times.
                       The path must exist on the host.
  --personalization PATH
                       Mount a personalization directory into the container.
                       The directory must contain three subdirectories:
                         knowledge/  -- injectable knowledge bases
                         tasks/      -- per-agent personal files
                         audit/      -- per-agent history logs and global audit log
                       These are mounted at:
                         /root/.emacs.d/knowledge
                         /root/.emacs.d/tasks
                         /root/.emacs.d/audit
                       Defaults to the bundled personalization/ directory in the repo.
                       Use this to point at a separate personalization repository.
  --help, -h           Show this message and exit.

Examples:
  emacboros.sh --mount /home/nacho/projects/myapp
  emacboros.sh --mount-ro /etc/ansible --mount /home/nacho/infra
  emacboros.sh --local --mount /home/nacho/dev/scratch
  emacboros.sh --personalization /home/nacho/repos/iar-personalization
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
        --personalization)
            [[ $# -lt 2 ]] && error "--personalization requires a path argument" && exit 1
            PERSONALIZATION_PATH="$(realpath "$2")"
            [[ ! -d "${PERSONALIZATION_PATH}" ]] && error "--personalization: directory does not exist: ${PERSONALIZATION_PATH}" && exit 1
            # Verify required subdirectories exist
            for subdir in knowledge tasks audit; do
                [[ ! -d "${PERSONALIZATION_PATH}/${subdir}" ]] && \
                    error "--personalization: missing required subdirectory: ${PERSONALIZATION_PATH}/${subdir}" && exit 1
            done
            PERSONALIZATION_DIR="${PERSONALIZATION_PATH}"
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
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:z")
    info "Mounting read-write: ${path}"
done

for path in "${MOUNT_RO_ARGS[@]:-}"; do
    [[ -z "${path}" ]] && continue
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:ro,z")
    info "Mounting read-only:  ${path}"
done

# =============================================================================
# Run the container with .emacs.d mounted
# =============================================================================
run() {
    info "Starting ${CONTAINER_NAME}"
    info "Personalization: ${PERSONALIZATION_DIR}"

    # shellcheck disable=SC2086
    podman run \
        --rm -it --name "${CONTAINER_NAME}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        -e "LANG=C.utf8" \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        --tmpfs /var/tmp:rw,size=64m \
        -v "${REPO_DIR}/emacs.d:/root/.emacs.d:z" \
        -v "${REPO_DIR}/metaconfig:/root/.emacs.d/metaconfig:z" \
        -v "${REPO_DIR}/prompts:/root/.emacs.d/agents.d:z" \
        -v "${PERSONALIZATION_DIR}/knowledge:/root/.emacs.d/knowledge:z" \
        -v "${PERSONALIZATION_DIR}/tasks:/root/.emacs.d/tasks:z" \
        -v "${PERSONALIZATION_DIR}/audit:/root/.emacs.d/audit:z" \
        \
        -v "${REPO_DIR}/:/root/i.ar/:z" \
        ${DYNAMIC_MOUNT_OPTS[@]+"${DYNAMIC_MOUNT_OPTS[@]}"} \
        "${IMAGE_NAME}" && \
        info "Container started" || \
        error "Container failed to start"
}

run