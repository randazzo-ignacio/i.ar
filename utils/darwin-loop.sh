#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Darwin Loop -- Runs darwin cycles continuously until max-cycles or stopped.
#
# Each iteration:
#   1. Pre-flight: check Ollama is reachable
#   2. Clean up any stale container from previous cycle
#   3. Run darwin-cycle.sh (one full cycle)
#   4. On failure: git checkout . to erase uncommitted changes, reset to clean state
#   5. Cooldown between cycles
#   6. Track consecutive failures -- stop after max-failures in a row
#
# Usage: darwin-loop.sh --personalization PATH [OPTIONS]
#
# Intended to be left running unattended (e.g., over a weekend).
# Telegram notifications sent on loop start, each cycle result, and loop end.
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"
source "${REPO_DIR}/utils/telegram.sh"

# --- Defaults ---
MAX_CYCLES=50
COOLDOWN=60
TIMEOUT=7200
MAX_CONSECUTIVE_FAILURES=5
CONTAINER_NAME="darwin-cycle"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"
PERSONALIZATION_DIR=""
SSH_KEY_DIR="${HOME}/.ssh"
KNOWLEDGE_LABELS=()

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: darwin-loop.sh --personalization PATH [OPTIONS]

Required:
  --personalization PATH
                       Path to personalization directory (knowledge/, tasks/, audit/).
                       Passed through to darwin-cycle.sh.

Options:
  --max-cycles N         Maximum number of cycles (default: 50)
  --cooldown SECONDS     Seconds to wait between cycles (default: 60)
  --timeout SECONDS      Per-cycle timeout (default: 7200 = 120 min)
  --max-failures N       Max consecutive failures before stopping (default: 5)
  --knowledge LABEL      Knowledge directory label to load (default: iar/)
                         Can be specified multiple times to load multiple bases.
  --ollama-host HOST     Ollama API host:port (default: ${LOCAL_OLLAMA_HOST})
  --ssh-key-dir PATH     Directory containing darwin SSH keys (default: ~/.ssh)
  --help, -h             Show this message

Environment:
  EMACBOROS_OLLAMA_HOST     Ollama API host (overridden by --ollama-host)
  DARWIN_TELEGRAM_BOT_TOKEN  Telegram bot token
  DARWIN_TELEGRAM_CHAT_ID    Telegram chat ID

Examples:
  darwin-loop.sh --personalization ~/repos/iar-personalization
  darwin-loop.sh --personalization ~/repos/iar-personalization --max-cycles 10 --cooldown 120
  darwin-loop.sh --personalization ~/repos/iar-personalization --knowledge infra/ --timeout 3600
  darwin-loop.sh --personalization ~/repos/iar-personalization --knowledge iar/ --knowledge infra/ --max-failures 3
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
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
            LOCAL_OLLAMA_HOST="$2"
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
# Setup
# =============================================================================
LOG_FILE="${PERSONALIZATION_DIR}/audit/darwin-loop-$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "${LOG_FILE}")"

# --- Telegram helpers ---
tg_send() {
    local message="$1"
    if [[ -n "${DARWIN_TELEGRAM_BOT_TOKEN:-}" && -n "${DARWIN_TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -m 10 -X POST \
            "https://api.telegram.org/bot${DARWIN_TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg chat_id "$DARWIN_TELEGRAM_CHAT_ID" \
                       --arg text "$message" \
                       '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')" \
            > /dev/null 2>&1 || true
    fi
}

# --- Logging helper (tee to both stdout and logfile) ---
log() {
    echo -e "$@" | tee -a "${LOG_FILE}"
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
    git clean -fd emacs.d/ 2>&1 || true  # remove untracked .elc files etc.
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
info "Darwin Loop starting"
info "  Personalization: ${PERSONALIZATION_DIR}"
info "  Max cycles: ${MAX_CYCLES}"
info "  Cooldown: ${COOLDOWN}s"
info "  Per-cycle timeout: ${TIMEOUT}s"
info "  Max consecutive failures: ${MAX_CONSECUTIVE_FAILURES}"
info "  Ollama: ${LOCAL_OLLAMA_HOST}"
info "  SSH keys: ${SSH_KEY_DIR}"
info "  Log: ${LOG_FILE}"
info "=========================================="

tg_send "*Darwin Loop Started*
Max cycles: ${MAX_CYCLES}
Cooldown: ${COOLDOWN}s
Timeout: ${TIMEOUT}s per cycle
Ollama: ${LOCAL_OLLAMA_HOST}"

while [[ ${CYCLE} -lt ${MAX_CYCLES} ]]; do
    CYCLE=$((CYCLE + 1))
    CYCLE_START=$(date +%s)

    log ""
    log "${BLUE}[INF][$(timestamp)]${NC} --- Cycle ${CYCLE}/${MAX_CYCLES} ---"

    # Pre-flight: Ollama check
    if ! check_ollama "${LOCAL_OLLAMA_HOST}"; then
        error "Ollama unreachable at ${LOCAL_OLLAMA_HOST} -- skipping cycle ${CYCLE}"
        log "${RED}[ERR][$(timestamp)]${NC} Ollama unreachable, skipping cycle ${CYCLE}"
        FAILURES=$((FAILURES + 1))
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

        if [[ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]]; then
            error "Reached ${MAX_CONSECUTIVE_FAILURES} consecutive failures -- stopping loop"
            log "${RED}[ERR][$(timestamp)]${NC} Stopping loop: ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
            tg_send "*Darwin Loop: STOPPED*
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

    # Run one darwin cycle
    info "Starting cycle ${CYCLE} (timeout: ${TIMEOUT}s)"
    set +e
    KNOWLEDGE_ARGS=()
    for label in "${KNOWLEDGE_LABELS[@]:-}"; do
        [[ -z "${label}" ]] && continue
        KNOWLEDGE_ARGS+=("--knowledge" "${label}")
    done
    "${REPO_DIR}/utils/darwin-cycle.sh" \
        --personalization "${PERSONALIZATION_DIR}" \
        --timeout "${TIMEOUT}" \
        "${KNOWLEDGE_ARGS[@]}" \
        --ollama-host "${LOCAL_OLLAMA_HOST}" \
        --ssh-key-dir "${SSH_KEY_DIR}" 2>&1 | tee -a "${LOG_FILE}"
    CYCLE_EXIT=$?
    set -e

    CYCLE_END=$(date +%s)
    CYCLE_ELAPSED=$((CYCLE_END - CYCLE_START))

    if [[ ${CYCLE_EXIT} -eq 0 ]]; then
        SUCCESSES=$((SUCCESSES + 1))
        log "${GREEN}[INF][$(timestamp)]${NC} Cycle ${CYCLE} succeeded in ${CYCLE_ELAPSED}s (exit 0)"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *SUCCESS* (${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}"
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
            tg_send "*Darwin Loop: STOPPED*
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
info "Darwin Loop complete"
info "  Total cycles: ${CYCLE}"
info "  Successes: ${SUCCESSES}"
info "  Failures: ${FAILURES}"
info "  Elapsed: ${HOURS}h ${MINS}m"
info "=========================================="

tg_send "*Darwin Loop Complete*
Cycles: ${CYCLE}
Successes: ${SUCCESSES}
Failures: ${FAILURES}
Elapsed: ${HOURS}h ${MINS}m"

exit 0