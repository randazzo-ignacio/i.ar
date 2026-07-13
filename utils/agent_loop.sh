#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Agent Loop -- Autonomous agent runner for any orchestrator agent
#
# Runs one or more cycles of an agent inside the Emacs container.
# Any orchestrator agent can be run autonomously -- just need a cycle prompt
# at agents.d/common/<agent>_cycle.org.
#
# Usage: agent_loop.sh --personalization PATH --agent NAME [OPTIONS]
#
# Default agent is "darwin".  For single-cycle runs, use --max-cycles 1.
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"
source "${REPO_DIR}/utils/telegram.sh"

IMAGE_NAME="iar-emacboros"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: agent_loop.sh --personalization PATH --agent NAME [OPTIONS]

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

  --agent NAME          Agent profile name (default: darwin).
                       Must exist as agents.d/agents/<name>/prompt.org and have
                       a cycle prompt at agents.d/common/<name>_cycle.org.

Options:
  --max-cycles N        Maximum number of cycles (default: 1).
                       Use --max-cycles 50 for a long-running loop.
  --cooldown SECONDS   Seconds to wait between cycles (default: 60).
  --max-failures N     Max consecutive failures before stopping (default: 5).
  --timeout SECONDS    Per-cycle timeout (default: 7200 = 120 min).
  --knowledge LABEL    Knowledge directory label to load (default: iar/).
                       Can be specified multiple times to load multiple bases.
  --ollama-host HOST    Ollama API host:port (default: ${LOCAL_OLLAMA_HOST}).
  --model NAME          Ollama model name (default: glm-5.2:cloud).
                       Must be in the model list in metaconfig/gptel.el.
                       Example: --model nemotron-3-super:120b
  --ctx N               Max context window size in tokens (default: 1048576).
                       Critical for local models -- KV cache scales linearly
                       with context. Use 131072 (128K) or 262144 (256K) for
                       local models. Cloud models can use the default 1M.
                       Example: --ctx 131072
  --mount PATH          Mount a host directory read-write inside the container
                       at the same absolute path. Can be specified multiple times.
  --mount-ro PATH       Mount a host directory read-only inside the container
                       at the same absolute path. Can be specified multiple times.
  --ssh-key-dir PATH    Directory containing agent SSH keys (default: ~/.ssh).
  --ssh-key NAME        SSH key name to use (default: emacboros_ed25519).
                       Looks for <name> and <name>.pub in --ssh-key-dir.
                       If the key does not exist, SSH mounts are skipped
                       (agent has no git push capability, but pull still works
                       via HTTPS).
  --gptel-fork PATH    Mount a local gptel fork directory (writable) into the
                       container and use it instead of the ELPA package.
  --self-modification  Enable self-modification mode (tier 2 file guard relaxation).
                       Default: OFF. Only needed for agents that edit .el files
                       (e.g. darwin). Most agents (gardener, auditor) should NOT
                       use this.
  --memory LIMIT       Podman memory limit (default: 8g). Caps container
                       memory to prevent host OOM kills on long sessions.
  --help, -h            Show this message and exit.

Environment:
  EMACBOROS_OLLAMA_HOST     Ollama API host (overridden by --ollama-host)
  AGENT_TELEGRAM_BOT_TOKEN  Telegram bot token for notifications
  AGENT_TELEGRAM_CHAT_ID    Telegram chat ID for notifications

Examples:
  # Single darwin cycle (needs --self-modification for code edits)
  agent_loop.sh --personalization ~/repos/iar-personalization --self-modification

  # Long-running darwin loop
  agent_loop.sh --personalization ~/repos/iar-personalization --self-modification --max-cycles 50

  # Run gardener agent (single tick, no self-modification, no SSH key needed)
  agent_loop.sh --personalization ~/repos/iar-personalization --agent gardener

  # Run auditor agent autonomously
  agent_loop.sh --personalization ~/repos/iar-personalization --agent auditor --max-cycles 10

  # Use a shared SSH key instead of per-agent key
  agent_loop.sh --personalization ~/repos/iar-personalization --agent darwin --ssh-key emacboros_ed25519 --self-modification

  # With knowledge and custom timeout
  agent_loop.sh --personalization ~/repos/iar-personalization --knowledge infra/ --timeout 3600

  # Run playground loop on GPU model on sophon (10.66.0.5)
  agent_loop.sh --personalization ~/repos/iar-personalization \
    --agent playground --model nemotron-3-super:120b --ctx 131072 \
    --ollama-host 10.66.0.5:11434 --max-cycles 999 --cooldown 300

  # Run on daftpunk CPU model (10.66.0.3)
  agent_loop.sh --personalization ~/repos/iar-personalization \
    --agent playground --model granite4.1:30b --ctx 131072 \
    --ollama-host 10.66.0.3:11434 --max-cycles 999 --cooldown 300
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
AGENT_NAME="darwin"
MAX_CYCLES=1
COOLDOWN=60
TIMEOUT=7200
MAX_CONSECUTIVE_FAILURES=5
OLLAMA_HOST="${LOCAL_OLLAMA_HOST}"
OLLAMA_MODEL=""
OLLAMA_CTX=""
PERSONALIZATION_DIR=""
SSH_KEY_DIR="${HOME}/.ssh"
SSH_KEY_NAME=""  # set after agent name is parsed
GPTEL_FORK_PATH=""
SELF_MODIFICATION=0
MEMORY_LIMIT="8g"
MOUNT_ARGS=()
MOUNT_RO_ARGS=()
KNOWLEDGE_LABELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
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
    LABELS_LISP=""
    for label in "${KNOWLEDGE_LABELS[@]}"; do
        LABELS_LISP+="\"${label}\" "
    done
    KNOWLEDGE_EVAL=":knowledge (list ${LABELS_LISP})"
fi

# =============================================================================
# Derived values
# =============================================================================
CONTAINER_NAME="${AGENT_NAME}-cycle-$$"
SSH_KEY_NAME="${SSH_KEY_NAME:-emacboros_ed25519}"
GIT_AUTHOR_NAME="$(tr '[:lower:]' '[:upper:]' <<< "${AGENT_NAME:0:1}")${AGENT_NAME:1} Agent"
GIT_AUTHOR_EMAIL="${AGENT_NAME}@emacboros.local"
LOG_FILE="${PERSONALIZATION_DIR}/audit/${AGENT_NAME}-loop-$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "${LOG_FILE}")"

# =============================================================================
# Logging helper (tee to both stdout and logfile)
# =============================================================================
log() {
    echo -e "$@" | tee -a "${LOG_FILE}"
}

# --- Telegram helpers ---
tg_send() {
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

# --- Reset working tree on failure ---
reset_worktree() {
    info "Resetting working tree to clean state"
    cd "${REPO_DIR}"
    git checkout . 2>&1 || true
    git clean -fd emacs.d/ 2>&1 || true
}

# =============================================================================
# Check SSH key availability
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
# Run one cycle inside the container
# =============================================================================
run_cycle() {
    info "Starting ${AGENT_NAME} cycle ${CYCLE}/${MAX_CYCLES} (timeout: ${TIMEOUT}s)"

    podman run \
        --rm \
        --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        --network=host \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        $([[ -n "${OLLAMA_MODEL}" ]] && echo "-e EMACBOROS_OLLAMA_MODEL=${OLLAMA_MODEL}") \
        $([[ -n "${OLLAMA_CTX}" ]] && echo "-e EMACBOROS_OLLAMA_CTX=${OLLAMA_CTX}") \
        -e "AGENT_TELEGRAM_BOT_TOKEN=${AGENT_TELEGRAM_BOT_TOKEN:-}" \
        -e "AGENT_TELEGRAM_CHAT_ID=${AGENT_TELEGRAM_CHAT_ID:-}" \
        $([[ -n "${GPTEL_FORK_PATH}" ]] && echo "-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork") \
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
        "${SSH_MOUNT_OPTS[@]}" \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_PAGER=cat" \
        -e "TERM=dumb" \
        $([[ "${SELF_MODIFICATION:-0}" -eq 1 ]] && echo "-e EMACBOROS_SELF_MODIFICATION=1") \
        "${DYNAMIC_MOUNT_OPTS[@]}" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(iar-run-cycle :agent \"${AGENT_NAME}\" :timeout ${TIMEOUT} :self-modification ${SELF_MODIFICATION:-0} ${KNOWLEDGE_EVAL})'" 2>&1 | tee -a "${LOG_FILE}"

    return ${PIPESTATUS[0]}
}

# =============================================================================
# Main loop
# =============================================================================
CYCLE=0
SUCCESSES=0
FAILURES=0
CONSECUTIVE_FAILURES=0
LOOP_START=$(date +%s)

info "=========================================="
info "Agent Loop starting"
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
Ollama: ${OLLAMA_HOST}"

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