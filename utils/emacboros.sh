#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"

# =============================================================================
# Agentic Emacs -- Container Management Script
# =============================================================================

IMAGE_NAME="iar-emacboros"
CONTAINER_NAME="iar-emacboros-$$"

# Default: remote Ollama instance
REMOTE_OLLAMA_HOST="10.66.0.3:11434"
LOCAL_OLLAMA_HOST="localhost:11434"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: emacboros.sh --personalization PATH [OPTIONS]

Required:
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
                       Use this to point at your personalization repository.

Options:
  --self-modification  Enable self-modification mode. Allows agents to modify
                       Emacs Lisp source files (init.el, init.d/**/*.el), container
                       configuration, and git hooks. Agent prompt files and
                       base_context.org remain protected regardless.
                       Default: disabled (all guards active).
  --local              Use a local Ollama instance (localhost:11434) instead of
                       the remote server. Enables host networking so the container
                       can reach Ollama on the host loopback interface.
  --ollama-host HOST    Ollama API host:port (overrides --local and default)
  --mount PATH         Mount a host directory read-write inside the container at
                       the same absolute path. Can be specified multiple times.
                       The path must exist on the host.
  --mount-ro PATH      Mount a host directory read-only inside the container at
                       the same absolute path. Can be specified multiple times.
                       The path must exist on the host.
  --gptel-fork PATH    Mount a local gptel fork directory (writable) into the
                       container and use it instead of the ELPA package.
                       Useful when a fix is merged upstream but hasn't shipped
                       in an ELPA release yet. The directory must contain
                       gptel.el. If not specified, the ELPA package is used.
  --memory LIMIT       Podman memory limit (default: 8g). Caps container
                       memory to prevent host OOM kills on long sessions.
                       Examples: 4g, 8g, 16g, 2g.
  --help, -h           Show this message and exit.

Examples:
  emacboros.sh --personalization ~/repos/iar-personalization
  emacboros.sh --personalization ~/repos/iar-personalization --self-modification
  emacboros.sh --personalization ~/repos/iar-personalization --local
  emacboros.sh --personalization ~/repos/iar-personalization --mount /home/nacho/projects/myapp
  emacboros.sh --personalization ~/repos/iar-personalization --mount-ro /etc/ansible --mount /home/nacho/infra
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
USE_LOCAL=false
PERSONALIZATION_DIR=""
CUSTOM_OLLAMA_HOST=""
SELF_MODIFICATION=false
GPTEL_FORK_PATH=""
MEMORY_LIMIT="8g"
MOUNT_ARGS=()
MOUNT_RO_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-modification)
            SELF_MODIFICATION=true
            shift
            ;;
        --local)
            USE_LOCAL=true
            shift
            ;;
        --ollama-host)
            [[ $# -lt 2 ]] && error "--ollama-host requires a value" && exit 1
            CUSTOM_OLLAMA_HOST="$2"
            shift 2
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
            PERSONALIZATION_DIR="$(realpath "$2")"
            [[ ! -d "${PERSONALIZATION_DIR}" ]] && error "--personalization: directory does not exist: ${PERSONALIZATION_DIR}" && exit 1
            # Verify required subdirectories exist
            for subdir in knowledge tasks audit; do
                [[ ! -d "${PERSONALIZATION_DIR}/${subdir}" ]] && \
                    error "--personalization: missing required subdirectory: ${PERSONALIZATION_DIR}/${subdir}" && exit 1
            done
            shift 2
            ;;
        --gptel-fork)
            [[ $# -lt 2 ]] && error "--gptel-fork requires a path argument" && exit 1
            GPTEL_FORK_PATH="$(realpath "$2")"
            [[ ! -d "${GPTEL_FORK_PATH}" ]] && error "--gptel-fork: directory does not exist: ${GPTEL_FORK_PATH}" && exit 1
            [[ ! -f "${GPTEL_FORK_PATH}/gptel.el" ]] && error "--gptel-fork: gptel.el not found in: ${GPTEL_FORK_PATH}" && exit 1
            shift 2
            ;;
        --memory)
            [[ $# -lt 2 ]] && error "--memory requires a value (e.g. 8g, 4g)" && exit 1
            MEMORY_LIMIT="$2"
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

# Validate required arguments
if [[ -z "${PERSONALIZATION_DIR}" ]]; then
    error "--personalization is required. Specify the path to your personalization directory."
    echo ""
    usage
    exit 1
fi

# =============================================================================
# Build runtime options based on mode
# =============================================================================
if [[ -n "${CUSTOM_OLLAMA_HOST}" ]]; then
    OLLAMA_HOST="${CUSTOM_OLLAMA_HOST}"
    NET_OPTS="--network=host"
    info "Using custom Ollama at ${OLLAMA_HOST} with host networking"
elif [[ "${USE_LOCAL}" == "true" ]]; then
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

    if [[ "${SELF_MODIFICATION}" == "true" ]]; then
        info "Self-modification: ENABLED (file guard tier 2 relaxed)"
        SELF_MOD_ENV="-e EMACBOROS_SELF_MODIFICATION=1"
    else
        info "Self-modification: disabled (all guards active)"
        SELF_MOD_ENV=""
    fi

    # --- Mount /root/i.ar only in self-modification mode ---
    # Without --self-modification, agents don't need repo access.
    # With --self-modification, mount each top-level item EXCEPT personalization/
    # and the already-separately-mounted dirs (emacs.d, metaconfig, prompts).
    # This gives access to .git, containers/, utils/, LICENSE, README.org,
    # .gitignore, .gitmodules -- but NOT the personalization submodule.
    IAR_MOUNT_OPTS=()
    if [[ "${SELF_MODIFICATION}" == "true" ]]; then
        # Skip personalization (submodule detached HEAD issue) and dirs
        # already mounted separately to /root/.emacs.d/*
        local skip_dirs="personalization emacs.d metaconfig prompts"
        while IFS= read -r entry; do
            local name; name="$(basename "${entry}")"
            [[ " ${skip_dirs} " =~ \ ${name}\  ]] && continue
            IAR_MOUNT_OPTS+=("-v" "${entry}:/root/i.ar/${name}:z")
        done < <(find "${REPO_DIR}" -maxdepth 1 -mindepth 1 | sort)
    fi

    # --- Gptel fork mount ---
    GPTEL_FORK_OPTS=""
    if [[ -n "${GPTEL_FORK_PATH}" ]]; then
        GPTEL_FORK_OPTS="-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork"
        info "Gptel fork: ${GPTEL_FORK_PATH} -> /root/.emacs.d/gptel-fork (writable)"
    else
        info "Gptel fork: not specified (using ELPA package)"
    fi

    # shellcheck disable=SC2086
    podman run \
        --rm -it --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        ${SELF_MOD_ENV} \
        ${GPTEL_FORK_OPTS} \
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
        ${IAR_MOUNT_OPTS[@]+"${IAR_MOUNT_OPTS[@]}"} \
        ${DYNAMIC_MOUNT_OPTS[@]+"${DYNAMIC_MOUNT_OPTS[@]}"} \
        "${IMAGE_NAME}" && \
        info "Container started" || \
        error "Container failed to start"
}

run
