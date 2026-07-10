#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"
source "${REPO_DIR}/utils/telegram.sh"

# =============================================================================
# Darwin Cycle -- Autonomous self-improvement agent runner
# Runs one darwin cycle inside the Emacs container with --local mode.
# Intended to be called by a systemd timer or cron job (via darwin-loop.sh).
#
# Usage: darwin-cycle.sh --personalization PATH [OPTIONS]
# =============================================================================

IMAGE_NAME="iar-emacboros"
CONTAINER_NAME="darwin-cycle"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: darwin-cycle.sh --personalization PATH [OPTIONS]

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

Options:
  --timeout SECONDS    Maximum time for the cycle (default: 7200 = 120 min)
  --knowledge LABEL     Knowledge directory label to load (default: iar/)
                       Can be specified multiple times to load multiple bases.
                       Examples: --knowledge iar/ --knowledge infra/
  --ollama-host HOST    Ollama API host:port (default: ${LOCAL_OLLAMA_HOST})
  --mount PATH          Mount a host directory read-write inside the container
                       at the same absolute path. Can be specified multiple times.
  --mount-ro PATH       Mount a host directory read-only inside the container
                       at the same absolute path. Can be specified multiple times.
  --ssh-key-dir PATH    Directory containing darwin SSH keys (default: ~/.ssh)
                       Expects: darwin_ed25519, darwin_ed25519.pub, known_hosts
  --help, -h            Show this message and exit.

Environment:
  DARWIN_TELEGRAM_BOT_TOKEN  Telegram bot token for notifications
  DARWIN_TELEGRAM_CHAT_ID    Telegram chat ID for notifications

Examples:
  darwin-cycle.sh --personalization ~/repos/iar-personalization
  darwin-cycle.sh --personalization ~/repos/iar-personalization --timeout 3600
  darwin-cycle.sh --personalization ~/repos/iar-personalization --knowledge infra/
  darwin-cycle.sh --personalization ~/repos/iar-personalization --knowledge iar/ --knowledge infra/
  darwin-cycle.sh --personalization ~/repos/iar-personalization --ollama-host localhost:11434
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
TIMEOUT=7200
OLLAMA_HOST="${LOCAL_OLLAMA_HOST}"
PERSONALIZATION_DIR=""
SSH_KEY_DIR="${HOME}/.ssh"
MOUNT_ARGS=()
MOUNT_RO_ARGS=()
KNOWLEDGE_LABELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --timeout)
            [[ $# -lt 2 ]] && error "--timeout requires a value" && exit 1
            TIMEOUT="$2"
            shift 2
            ;;
        --ollama-host)
            [[ $# -lt 2 ]] && error "--ollama-host requires a value" && exit 1
            OLLAMA_HOST="$2"
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
        --ssh-key-dir)
            [[ $# -lt 2 ]] && error "--ssh-key-dir requires a value" && exit 1
            SSH_KEY_DIR="$(realpath "$2")"
            [[ ! -d "${SSH_KEY_DIR}" ]] && error "--ssh-key-dir: directory does not exist: ${SSH_KEY_DIR}" && exit 1
            shift 2
            ;;
        --knowledge)
            [[ $# -lt 2 ]] && error "--knowledge requires a label argument" && exit 1
            KNOWLEDGE_LABELS+=("$2")
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
# Build knowledge labels for Emacs eval
# =============================================================================
KNOWLEDGE_EVAL=""
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    # Build a Lisp list: ("iar/" "infra/")
    LABELS_LISP=""
    for label in "${KNOWLEDGE_LABELS[@]}"; do
        LABELS_LISP+="\"${label}\" "
    done
    KNOWLEDGE_EVAL=":knowledge (list ${LABELS_LISP})"
fi

# =============================================================================
# Run the container
# =============================================================================
info "Starting darwin cycle"
info "  Personalization: ${PERSONALIZATION_DIR}"
info "  Timeout: ${TIMEOUT}s"
info "  Ollama: ${OLLAMA_HOST}"
info "  SSH keys: ${SSH_KEY_DIR}"
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    info "  Knowledge: ${KNOWLEDGE_LABELS[*]}"
else
    info "  Knowledge: iar/ (default)"
fi

podman run \
    --rm \
    --name "${CONTAINER_NAME}" \
    --security-opt no-new-privileges \
    --cap-drop=all \
    --cap-add=NET_RAW \
    --cap-add=NET_BIND_SERVICE \
    --network=host \
    -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
    -e "DARWIN_TELEGRAM_BOT_TOKEN=${DARWIN_TELEGRAM_BOT_TOKEN:-}" \
    -e "DARWIN_TELEGRAM_CHAT_ID=${DARWIN_TELEGRAM_CHAT_ID:-}" \
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
    -v "${REPO_DIR}/:/root/i.ar/:z" \
    -v "${SSH_KEY_DIR}/darwin_ed25519:/root/.ssh/id_ed25519:ro,z" \
    -v "${SSH_KEY_DIR}/darwin_ed25519.pub:/root/.ssh/id_ed25519.pub:ro,z" \
    -v "${SSH_KEY_DIR}/known_hosts:/root/.ssh/known_hosts:ro,z" \
    -e "GIT_AUTHOR_NAME=Darwin Agent" \
    -e "GIT_AUTHOR_EMAIL=darwin@emacboros.local" \
    -e "GIT_COMMITTER_NAME=Darwin Agent" \
    -e "GIT_COMMITTER_EMAIL=darwin@emacboros.local" \
    -e "GIT_PAGER=cat" \
    -e "TERM=dumb" \
    --entrypoint /bin/bash \
    "${IMAGE_NAME}" \
    -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(darwin-run-cycle :timeout ${TIMEOUT} ${KNOWLEDGE_EVAL})'" 2>&1

EXIT_CODE=$?
info "Darwin cycle container exited with code: ${EXIT_CODE}"
exit ${EXIT_CODE}