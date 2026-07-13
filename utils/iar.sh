#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# i.ar -- Unified entry point for the agent system
#
# Two modes:
#   Interactive (default)  -- Drops you into an Emacs gptel chat buffer.
#   Loop (--loop)          -- Runs an agent autonomously for N cycles.
#
# Usage:
#   ./utils/iar.sh --personalization PATH [OPTIONS]
#   ./utils/iar.sh --loop --personalization PATH --agent NAME [OPTIONS]
#
# Container names auto-include the shell PID so multiple instances can run
# in parallel without collisions.
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"

# =============================================================================
# Dispatch: --status is handled by a separate script, not the main flow.
# =============================================================================
for arg in "$@"; do
    if [[ "${arg}" == "--status" ]]; then
        exec "${REPO_DIR}/utils/iar-status.sh" "$@"
    fi
done

source "${REPO_DIR}/metaconfig/header.sh"
source "${REPO_DIR}/utils/telegram.sh"

IMAGE_NAME="iar-emacboros"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: iar.sh --personalization PATH [OPTIONS]
       iar.sh --loop --personalization PATH --agent NAME [OPTIONS]

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

Mode:
  --loop               Run in autonomous loop mode (requires --agent).
                       Default: interactive mode (Emacs gptel chat buffer).

Options (both modes):
  --self-modification  Enable self-modification mode. Allows agents to modify
                       Emacs Lisp source files (init.el, init.d/**/*.el), container
                       configuration, and git hooks. Agent prompt files and
                       base_context.org remain protected regardless.
                       Default: disabled (all guards active).
  --ollama-host HOST    Ollama API host:port (default: ${LOCAL_OLLAMA_HOST}).
  --local              Shortcut for --ollama-host localhost:11434 with host networking.
  --model NAME          Ollama model name (default: glm-5.2:cloud).
                       Must be in the model list in metaconfig/gptel.el.
  --ctx N               Max context window in tokens (default: 1048576 = 1M).
                       Critical for local models -- KV cache scales linearly.
                       Use 131072 (128K) or 262144 (256K) for local models.
  --mount PATH          Mount a host directory read-write inside the container
                       at the same absolute path. Can be specified multiple times.
  --mount-ro PATH       Mount a host directory read-only inside the container
                       at the same absolute path. Can be specified multiple times.
  --gptel-fork PATH    Mount a local gptel fork directory (writable) into the
                       container and use it instead of the ELPA package.
  --ssh-key-dir PATH    Directory containing SSH keys (default: ~/.ssh).
  --ssh-key NAME        SSH key name to use (default: emacboros_ed25519).
                       Looks for <name> and <name>.pub in --ssh-key-dir.
                       If the key does not exist, SSH mounts are skipped
                       (agent has no git push capability, but pull still works
                       via HTTPS).
  --memory LIMIT       Podman memory limit (default: 8g). Caps container
                       memory to prevent host OOM kills on long sessions.
  --knowledge LABEL    Knowledge directory label to load (default: iar/).
                       Can be specified multiple times to load multiple bases.
  --help, -h            Show this message and exit.

Options (loop mode only):
  --agent NAME          Agent profile name (required in --loop mode).
                       Must exist as agents.d/agents/<name>/prompt.org and have
                       a cycle prompt at agents.d/common/<name>_cycle.org.
  --max-cycles N        Maximum number of cycles (default: 1).
  --cooldown SECONDS   Seconds to wait between cycles (default: 60).
  --max-failures N     Max consecutive failures before stopping (default: 5).
  --timeout SECONDS    Per-cycle timeout (default: 7200 = 120 min).

Environment:
  EMACBOROS_OLLAMA_HOST     Ollama API host (overridden by --ollama-host)
  AGENT_TELEGRAM_BOT_TOKEN  Telegram bot token for notifications (loop mode)
  AGENT_TELEGRAM_CHAT_ID    Telegram chat ID for notifications (loop mode)

Examples:
  # Interactive session with self-modification
  iar.sh --self-modification --personalization ~/repos/iar-personalization --gptel-fork ~/repos/gptel

  # Interactive session (no self-modification)
  iar.sh --personalization ~/repos/iar-personalization --gptel-fork ~/repos/gptel

  # Darwin autonomous loop
  iar.sh --loop --self-modification --personalization ~/repos/iar-personalization \\
    --agent darwin --gptel-fork ~/repos/gptel --max-cycles 50

  # Gardener autonomous loop
  iar.sh --loop --personalization ~/repos/iar-personalization \\
    --agent gardener --gptel-fork ~/repos/gptel --max-cycles 10

  # Playground loop on GPU model (sophon)
  iar.sh --loop --personalization ~/repos/iar-personalization \\
    --agent playground --model nemotron-3-super:120b --ctx 131072 \\
    --ollama-host 10.66.0.5:11434 --max-cycles 999 --cooldown 300

  # Playground loop on CPU model (daftpunk)
  iar.sh --loop --personalization ~/repos/iar-personalization \\
    --agent playground --model granite4.1:30b --ctx 131072 \\
    --ollama-host 10.66.0.3:11434 --max-cycles 999 --cooldown 300
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
MODE="interactive"
AGENT_NAME=""
MAX_CYCLES=1
COOLDOWN=60
TIMEOUT=7200
MAX_CONSECUTIVE_FAILURES=5
OLLAMA_HOST="${LOCAL_OLLAMA_HOST}"
OLLAMA_MODEL=""
OLLAMA_CTX=""
USE_LOCAL=false
PERSONALIZATION_DIR=""
SSH_KEY_DIR="${HOME}/.ssh"
SSH_KEY_NAME=""
GPTEL_FORK_PATH=""
SELF_MODIFICATION=0
MEMORY_LIMIT="8g"
MOUNT_ARGS=()
MOUNT_RO_ARGS=()
KNOWLEDGE_LABELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop)
            MODE="loop"
            shift
            ;;
        --personalization)
            [[ $# -lt 2 ]] && error "--personalization requires a path argument" && exit 1
            PERSONALIZATION_DIR="$(realpath "$2")"
            [[ ! -d "${PERSONALIZATION_DIR}" ]] && error "--personalization: directory does not exist: ${PERSONALIZATION_DIR}" && exit 1
            for subdir in knowledge tasks audit; do
                [[ ! -d "${PERSONALIZATION_DIR}/${subdir}" ]] && \
                    error "--personalization: missing required subdirectory: ${PERSONALIZATION_DIR}/${subdir}" && exit 1
            done
            shift 2
            ;;
        --agent)
            [[ $# -lt 2 ]] && error "--agent requires a name argument" && exit 1
            AGENT_NAME="$2"
            shift 2
            ;;
        --max-cycles)
            [[ $# -lt 2 ]] && error "--max-cycles requires a value" && exit 1
            MAX_CYCLES="$2"
            shift 2
            ;;
        --cooldown)
            [[ $# -lt 2 ]] && error "--cooldown requires a value" && exit 1
            COOLDOWN="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -lt 2 ]] && error "--timeout requires a value" && exit 1
            TIMEOUT="$2"
            shift 2
            ;;
        --max-failures)
            [[ $# -lt 2 ]] && error "--max-failures requires a value" && exit 1
            MAX_CONSECUTIVE_FAILURES="$2"
            shift 2
            ;;
        --ollama-host)
            [[ $# -lt 2 ]] && error "--ollama-host requires a value" && exit 1
            OLLAMA_HOST="$2"
            shift 2
            ;;
        --local)
            USE_LOCAL=true
            shift
            ;;
        --model)
            [[ $# -lt 2 ]] && error "--model requires a value" && exit 1
            OLLAMA_MODEL="$2"
            shift 2
            ;;
        --ctx)
            [[ $# -lt 2 ]] && error "--ctx requires a value" && exit 1
            OLLAMA_CTX="$2"
            shift 2
            ;;
        --knowledge)
            [[ $# -lt 2 ]] && error "--knowledge requires a label argument" && exit 1
            KNOWLEDGE_LABELS+=("$2")
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
        --ssh-key)
            [[ $# -lt 2 ]] && error "--ssh-key requires a value" && exit 1
            SSH_KEY_NAME="$2"
            shift 2
            ;;
        --gptel-fork)
            [[ $# -lt 2 ]] && error "--gptel-fork requires a path argument" && exit 1
            GPTEL_FORK_PATH="$(realpath "$2")"
            [[ ! -d "${GPTEL_FORK_PATH}" ]] && error "--gptel-fork: directory does not exist: ${GPTEL_FORK_PATH}" && exit 1
            [[ ! -f "${GPTEL_FORK_PATH}/gptel.el" ]] && error "--gptel-fork: gptel.el not found in: ${GPTEL_FORK_PATH}" && exit 1
            shift 2
            ;;
        --self-modification)
            SELF_MODIFICATION=1
            shift
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

# Mode-specific validation
if [[ "${MODE}" == "loop" && -z "${AGENT_NAME}" ]]; then
    error "--agent is required in --loop mode."
    echo ""
    usage
    exit 1
fi

# Warn about loop-only flags in interactive mode
if [[ "${MODE}" == "interactive" ]]; then
    [[ -n "${AGENT_NAME}" ]] && warn "--agent is ignored in interactive mode (load agents via C-c a inside Emacs)"
    [[ "${MAX_CYCLES}" -ne 1 ]] && warn "--max-cycles is ignored in interactive mode"
    [[ "${COOLDOWN}" -ne 60 ]] && warn "--cooldown is ignored in interactive mode"
    [[ "${TIMEOUT}" -ne 7200 ]] && warn "--timeout is ignored in interactive mode"
fi

# =============================================================================
# Derived values
# =============================================================================
SSH_KEY_NAME="${SSH_KEY_NAME:-emacboros_ed25519}"

if [[ "${MODE}" == "loop" ]]; then
    CONTAINER_NAME="${AGENT_NAME}-loop-$$"
    GIT_AUTHOR_NAME="$(tr '[:lower:]' '[:upper:]' <<< "${AGENT_NAME:0:1}")${AGENT_NAME:1} Agent"
    GIT_AUTHOR_EMAIL="${AGENT_NAME}@emacboros.local"
else
    CONTAINER_NAME="iar-interactive-$$"
    GIT_AUTHOR_NAME="i.ar Agent"
    GIT_AUTHOR_EMAIL="agent@emacboros.local"
fi

# =============================================================================
# Ollama host resolution
# =============================================================================
if [[ "${USE_LOCAL}" == "true" ]]; then
    OLLAMA_HOST="localhost:11434"
    NET_OPTS="--network=host"
    info "Local mode: using Ollama at ${OLLAMA_HOST} with host networking"
else
    NET_OPTS="--network=host"
    info "Using Ollama at ${OLLAMA_HOST} with host networking"
fi

# =============================================================================
# Logging (loop mode only)
# =============================================================================
if [[ "${MODE}" == "loop" ]]; then
    LOG_FILE="${PERSONALIZATION_DIR}/audit/${AGENT_NAME}-loop-$(date +%Y-%m-%d).log"
    mkdir -p "$(dirname "${LOG_FILE}")"
else
    LOG_FILE="/dev/null"
fi

log() {
    if [[ "${MODE}" == "loop" ]]; then
        echo -e "$@" | tee -a "${LOG_FILE}"
    else
        echo -e "$@"
    fi
}

# --- Telegram helpers (loop mode only) ---
tg_send() {
    [[ "${MODE}" != "loop" ]] && return
    local message="$1"
    if [[ -n "${AGENT_TELEGRAM_BOT_TOKEN:-}" && -n "${AGENT_TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -m 10 -X POST \
            "https://api.telegram.org/bot${AGENT_TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg chat_id "$AGENT_TELEGRAM_CHAT_ID" \
                       --arg text "$message" \
                       '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')" \
            > /dev/null 2>&1 || true
    fi
}

# --- Pre-flight: check Ollama is reachable ---
check_ollama() {
    local host="$1"
    if curl -s -m 5 "http://${host}/api/tags" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# --- Clean up stale container ---
cleanup_container() {
    if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        warn "Removing stale container: ${CONTAINER_NAME}"
        podman rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi
}

# --- Reset working tree on failure (loop mode only) ---
reset_worktree() {
    [[ "${MODE}" != "loop" ]] && return
    info "Resetting working tree to clean state"
    cd "${REPO_DIR}"
    git checkout . 2>&1 || true
    git clean -fd emacs.d/ 2>&1 || true
}

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

# Build IAR_EXTRA_MOUNTS env var for mount awareness.
# Format: "path:rw,path:ro" -- comma-separated, passed to container so
# agents know what extra directories are available without being told.
EXTRA_MOUNTS_ENV=""
if [[ ${#MOUNT_ARGS[@]} -gt 0 || ${#MOUNT_RO_ARGS[@]} -gt 0 ]]; then
    MOUNT_PAIRS=()
    for path in "${MOUNT_ARGS[@]:-}"; do
        [[ -z "${path}" ]] && continue
        MOUNT_PAIRS+=("${path}:rw")
    done
    for path in "${MOUNT_RO_ARGS[@]:-}"; do
        [[ -z "${path}" ]] && continue
        MOUNT_PAIRS+=("${path}:ro")
    done
    EXTRA_MOUNTS_ENV=$(IFS=','; echo "${MOUNT_PAIRS[*]}")
fi

# =============================================================================
# SSH key availability
# =============================================================================
SSH_MOUNT_OPTS=()
if [[ -f "${SSH_KEY_DIR}/${SSH_KEY_NAME}" ]]; then
    SSH_MOUNT_OPTS+=(
        "-v" "${SSH_KEY_DIR}/${SSH_KEY_NAME}:/root/.ssh/id_ed25519:ro,z"
        "-v" "${SSH_KEY_DIR}/${SSH_KEY_NAME}.pub:/root/.ssh/id_ed25519.pub:ro,z"
        "-v" "${SSH_KEY_DIR}/known_hosts:/root/.ssh/known_hosts:ro,z"
    )
    info "SSH key: ${SSH_KEY_DIR}/${SSH_KEY_NAME}"
else
    warn "SSH key not found: ${SSH_KEY_DIR}/${SSH_KEY_NAME} -- git push disabled (pull still works)"
fi

# =============================================================================
# Knowledge labels for Emacs eval (loop mode)
# =============================================================================
KNOWLEDGE_EVAL=""
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    LABELS_LISP=""
    for label in "${KNOWLEDGE_LABELS[@]}"; do
        LABELS_LISP+="\"${label}\" "
    done
    KNOWLEDGE_EVAL=":knowledge (list ${LABELS_LISP})"
fi

# =============================================================================
# Gptel fork mount
# =============================================================================
GPTEL_FORK_OPTS=""
if [[ -n "${GPTEL_FORK_PATH}" ]]; then
    GPTEL_FORK_OPTS="-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork"
    info "Gptel fork: ${GPTEL_FORK_PATH} -> /root/.emacs.d/gptel-fork (writable)"
else
    info "Gptel fork: not specified (using ELPA package)"
fi

# =============================================================================
# Self-modification i.ar mount
# =============================================================================
# In self-modification mode, mount the repo at /root/i.ar/ so agents can
# edit code. Without self-modification, mount it read-only for reference.
if [[ "${SELF_MODIFICATION}" -eq 1 ]]; then
    IAR_MOUNT_OPTS=("-v" "${REPO_DIR}/:/root/i.ar/:z")
    info "i.ar repo: ${REPO_DIR} -> /root/i.ar/ (writable, self-modification)"
else
    IAR_MOUNT_OPTS=("-v" "${REPO_DIR}/:/root/i.ar/:ro,z")
    info "i.ar repo: ${REPO_DIR} -> /root/i.ar/ (read-only)"
fi

# =============================================================================
# Build common Podman arguments
# =============================================================================
build_podman_args() {
    local interactive_flag="$1"  # "-it" or ""
    local entrypoint_cmd="$2"    # full command string for --entrypoint

    echo \
        --rm ${interactive_flag} \
        --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        $([[ -n "${OLLAMA_MODEL}" ]] && echo "-e EMACBOROS_OLLAMA_MODEL=${OLLAMA_MODEL}") \
        $([[ -n "${OLLAMA_CTX}" ]] && echo "-e EMACBOROS_OLLAMA_CTX=${OLLAMA_CTX}") \
        -e "AGENT_TELEGRAM_BOT_TOKEN=${AGENT_TELEGRAM_BOT_TOKEN:-}" \
        -e "AGENT_TELEGRAM_CHAT_ID=${AGENT_TELEGRAM_CHAT_ID:-}" \
        $([[ -n "${GPTEL_FORK_PATH}" ]] && echo "-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork") \
        $([[ "${SELF_MODIFICATION:-0}" -eq 1 ]] && echo "-e EMACBOROS_SELF_MODIFICATION=1") \
        $([[ -n "${EXTRA_MOUNTS_ENV}" ]] && echo "-e IAR_EXTRA_MOUNTS=${EXTRA_MOUNTS_ENV}") \
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
        "${IAR_MOUNT_OPTS[@]}" \
        "${SSH_MOUNT_OPTS[@]}" \
        "${DYNAMIC_MOUNT_OPTS[@]}" \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_PAGER=cat" \
        -e "TERM=dumb" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "${entrypoint_cmd}"
}

# =============================================================================
# Interactive mode
# =============================================================================
run_interactive() {
    info "=========================================="
    info "i.ar Interactive Session"
    info "  Personalization: ${PERSONALIZATION_DIR}"
    info "  Ollama: ${OLLAMA_HOST}"
    info "  Model: ${OLLAMA_MODEL:-glm-5.2:cloud (default)}"
    info "  Context: ${OLLAMA_CTX:-1048576 (default)}"
    if [[ "${SELF_MODIFICATION}" -eq 1 ]]; then
        info "  Self-modification: ENABLED"
    else
        info "  Self-modification: disabled"
    fi
    info "  Container: ${CONTAINER_NAME}"
    info "=========================================="

    # shellcheck disable=SC2086
    podman run --rm -it \
        --read-only \
        --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        $([[ -n "${OLLAMA_MODEL}" ]] && echo "-e EMACBOROS_OLLAMA_MODEL=${OLLAMA_MODEL}") \
        $([[ -n "${OLLAMA_CTX}" ]] && echo "-e EMACBOROS_OLLAMA_CTX=${OLLAMA_CTX}") \
        $([[ -n "${GPTEL_FORK_PATH}" ]] && echo "-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork") \
        $([[ "${SELF_MODIFICATION:-0}" -eq 1 ]] && echo "-e EMACBOROS_SELF_MODIFICATION=1") \
        $([[ -n "${EXTRA_MOUNTS_ENV}" ]] && echo "-e IAR_EXTRA_MOUNTS=${EXTRA_MOUNTS_ENV}") \
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
        "${IAR_MOUNT_OPTS[@]}" \
        "${SSH_MOUNT_OPTS[@]}" \
        "${DYNAMIC_MOUNT_OPTS[@]}" \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_PAGER=cat" \
        "${IMAGE_NAME}" && \
        info "Session ended" || \
        error "Container failed to start"
}

# =============================================================================
# Loop mode -- run one cycle
# =============================================================================
run_cycle() {
    info "Starting ${AGENT_NAME} cycle ${CYCLE}/${MAX_CYCLES} (timeout: ${TIMEOUT}s)"

    # shellcheck disable=SC2086
    podman run \
        --rm \
        --read-only \
        --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        $([[ -n "${OLLAMA_MODEL}" ]] && echo "-e EMACBOROS_OLLAMA_MODEL=${OLLAMA_MODEL}") \
        $([[ -n "${OLLAMA_CTX}" ]] && echo "-e EMACBOROS_OLLAMA_CTX=${OLLAMA_CTX}") \
        -e "AGENT_TELEGRAM_BOT_TOKEN=${AGENT_TELEGRAM_BOT_TOKEN:-}" \
        -e "AGENT_TELEGRAM_CHAT_ID=${AGENT_TELEGRAM_CHAT_ID:-}" \
        $([[ -n "${GPTEL_FORK_PATH}" ]] && echo "-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork") \
        $([[ "${SELF_MODIFICATION:-0}" -eq 1 ]] && echo "-e EMACBOROS_SELF_MODIFICATION=1") \
        $([[ -n "${EXTRA_MOUNTS_ENV}" ]] && echo "-e IAR_EXTRA_MOUNTS=${EXTRA_MOUNTS_ENV}") \
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
        "${IAR_MOUNT_OPTS[@]}" \
        "${SSH_MOUNT_OPTS[@]}" \
        "${DYNAMIC_MOUNT_OPTS[@]}" \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_PAGER=cat" \
        -e "TERM=dumb" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(iar-run-cycle :agent \"${AGENT_NAME}\" :timeout ${TIMEOUT} :self-modification ${SELF_MODIFICATION:-0} ${KNOWLEDGE_EVAL})'" 2>&1 | tee -a "${LOG_FILE}"

    return ${PIPESTATUS[0]}
}

# =============================================================================
# Main
# =============================================================================
if [[ "${MODE}" == "interactive" ]]; then
    run_interactive
    exit $?
fi

# =============================================================================
# Loop mode -- cycle management
# =============================================================================
CYCLE=0
SUCCESSES=0
FAILURES=0
CONSECUTIVE_FAILURES=0
LOOP_START=$(date +%s)
LOOP_REASON=""

info "=========================================="
info "i.ar Agent Loop"
info "  Agent: ${AGENT_NAME}"
info "  Personalization: ${PERSONALIZATION_DIR}"
info "  Max cycles: ${MAX_CYCLES}"
info "  Cooldown: ${COOLDOWN}s"
info "  Per-cycle timeout: ${TIMEOUT}s"
info "  Max consecutive failures: ${MAX_CONSECUTIVE_FAILURES}"
info "  Ollama: ${OLLAMA_HOST}"
info "  Model: ${OLLAMA_MODEL:-glm-5.2:cloud (default)}"
info "  Context: ${OLLAMA_CTX:-1048576 (default)}"
if [[ -f "${SSH_KEY_DIR}/${SSH_KEY_NAME}" ]]; then
    info "  SSH key: ${SSH_KEY_DIR}/${SSH_KEY_NAME}"
else
    info "  SSH key: (none -- git push disabled)"
fi
info "  Log: ${LOG_FILE}"
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    info "  Knowledge: ${KNOWLEDGE_LABELS[*]}"
else
    info "  Knowledge: iar/ (default)"
fi
info "=========================================="

tg_send "*${AGENT_NAME^} Loop Started*
Max cycles: ${MAX_CYCLES}
Cooldown: ${COOLDOWN}s
Timeout: ${TIMEOUT}s per cycle
Ollama: ${OLLAMA_HOST}
Model: ${OLLAMA_MODEL:-glm-5.2:cloud}"

while [[ ${CYCLE} -lt ${MAX_CYCLES} ]]; do
    CYCLE=$((CYCLE + 1))
    CYCLE_START=$(date +%s)

    log ""
    log "${BLUE}[INF][$(timestamp)]${NC} --- Cycle ${CYCLE}/${MAX_CYCLES} ---"

    # Pre-flight: Ollama check
    if ! check_ollama "${OLLAMA_HOST}"; then
        error "Ollama unreachable at ${OLLAMA_HOST} -- skipping cycle ${CYCLE}"
        log "${RED}[ERR][$(timestamp)]${NC} Ollama unreachable, skipping cycle ${CYCLE}"
        FAILURES=$((FAILURES + 1))
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

        if [[ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]]; then
            error "Reached ${MAX_CONSECUTIVE_FAILURES} consecutive failures -- stopping loop"
            log "${RED}[ERR][$(timestamp)]${NC} Stopping loop: ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
            tg_send "*${AGENT_NAME^} Loop: STOPPED*
Reason: ${MAX_CONSECUTIVE_FAILURES} consecutive failures (Ollama unreachable)
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}"
            exit 1
        fi

        warn "Waiting ${COOLDOWN}s before retry..."
        sleep ${COOLDOWN}
        continue
    fi

    # Reset consecutive failures -- Ollama is back
    CONSECUTIVE_FAILURES=0

    # Clean up any stale container from previous cycle
    cleanup_container

    # Run one cycle
    set +e
    run_cycle
    CYCLE_EXIT=$?
    set -e

    CYCLE_END=$(date +%s)
    CYCLE_ELAPSED=$((CYCLE_END - CYCLE_START))

    if [[ ${CYCLE_EXIT} -eq 0 ]]; then
        SUCCESSES=$((SUCCESSES + 1))
        log "${GREEN}[INF][$(timestamp)]${NC} Cycle ${CYCLE} succeeded in ${CYCLE_ELAPSED}s (exit 0)"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *SUCCESS* (${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}"
    elif [[ ${CYCLE_EXIT} -eq 2 ]]; then
        SUCCESSES=$((SUCCESSES + 1))
        log "${GREEN}[INF][$(timestamp)]${NC} Cycle ${CYCLE} completed task in ${CYCLE_ELAPSED}s (exit 2 -- loop stop)"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *TASK COMPLETE* (${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}
Loop stopping -- task finished."
        log "${BLUE}[INF][$(timestamp)]${NC} Task complete, stopping loop."
        LOOP_REASON="task complete"
        break
    else
        FAILURES=$((FAILURES + 1))
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "${RED}[ERR][$(timestamp)]${NC} Cycle ${CYCLE} failed in ${CYCLE_ELAPSED}s (exit ${CYCLE_EXIT})"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *FAILED* (exit ${CYCLE_EXIT}, ${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}

Resetting working tree..."

        # Reset working tree to clean state so next cycle starts fresh
        reset_worktree

        if [[ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]]; then
            error "Reached ${MAX_CONSECUTIVE_FAILURES} consecutive failures -- stopping loop"
            log "${RED}[ERR][$(timestamp)]${NC} Stopping loop: ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
            tg_send "*${AGENT_NAME^} Loop: STOPPED*
Reason: ${MAX_CONSECUTIVE_FAILURES} consecutive cycle failures
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}"
            exit 1
        fi
    fi

    # Cooldown between cycles (skip on last cycle)
    if [[ ${CYCLE} -lt ${MAX_CYCLES} ]]; then
        info "Cooldown: ${COOLDOWN}s before next cycle"
        sleep ${COOLDOWN}
    fi
done

# =============================================================================
# Loop complete
# =============================================================================
LOOP_END=$(date +%s)
LOOP_ELAPSED=$((LOOP_END - LOOP_START))
HOURS=$((LOOP_ELAPSED / 3600))
MINS=$(((LOOP_ELAPSED % 3600) / 60))

info "=========================================="
info "Agent Loop complete"
info "  Agent: ${AGENT_NAME}"
info "  Total cycles: ${CYCLE}"
info "  Successes: ${SUCCESSES}"
info "  Failures: ${FAILURES}"
info "  Elapsed: ${HOURS}h ${MINS}m"
info "=========================================="

tg_send "*${AGENT_NAME^} Loop Complete*
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}
Elapsed: ${HOURS}h ${MINS}m
Reason: ${LOOP_REASON:-max cycles reached}"

exit 0