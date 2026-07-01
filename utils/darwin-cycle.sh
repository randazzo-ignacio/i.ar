#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"

# Darwin Cycle -- Autonomous self-improvement agent runner
# Runs one darwin cycle inside the Emacs container with --local mode.
# Intended to be called by a systemd timer or cron job.
#
# Usage: darwin-cycle.sh [--timeout SECONDS]

IMAGE_NAME="iar-emacboros"
CONTAINER_NAME="darwin-cycle"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"

TIMEOUT=7200
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            [[ $# -lt 2 ]] && error "--timeout requires a value" && exit 1
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: darwin-cycle.sh [--timeout SECONDS]

Runs one darwin autonomous cycle in the Emacs container.
Each cycle: darwin wakes up, makes one change, reviews it, tests it, commits if green.

Options:
  --timeout SECONDS  Maximum time for the cycle (default: 7200 = 120 min)
  --help, -h          Show this message
EOF
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

info "Starting darwin cycle with ${TIMEOUT}s timeout"
info "Using local Ollama at ${LOCAL_OLLAMA_HOST} with host networking"

podman run \
    --rm \
    --name "${CONTAINER_NAME}" \
    --security-opt no-new-privileges \
    --cap-drop=all \
    --cap-add=NET_RAW \
    --cap-add=NET_BIND_SERVICE \
    --network=host \
    -e "EMACBOROS_OLLAMA_HOST=${LOCAL_OLLAMA_HOST}" \
    -e "LANG=C.utf8" \
    --tmpfs /tmp:rw,size=256m \
    --tmpfs /run:rw,size=64m \
    --tmpfs /var/tmp:rw,size=64m \
    -v "${REPO_DIR}/emacs.d:/root/.emacs.d:Z" \
    -v "${REPO_DIR}/metaconfig:/root/.emacs.d/metaconfig:Z" \
    -v "${REPO_DIR}/knowledge/prompts:/root/.emacs.d/agents.d:Z" \
    -v "${REPO_DIR}/.git:/root/i.ar/.git:Z" \
    -v "${REPO_DIR}/emacs.d:/root/i.ar/emacs.d:Z" \
    -v "${REPO_DIR}/metaconfig:/root/i.ar/metaconfig:Z" \
    -v "${REPO_DIR}/knowledge:/root/i.ar/knowledge:Z" \
    -v "${REPO_DIR}/containers:/root/i.ar/containers:Z" \
    -v "${REPO_DIR}/infra:/root/i.ar/infra:Z" \
    -v "${REPO_DIR}/utils:/root/i.ar/utils:Z" \
    -v "${REPO_DIR}/README.org:/root/i.ar/README.org:Z" \
    -v "${SSH_KEY_DIR:-${HOME}/.ssh}/darwin_ed25519:/root/.ssh/id_ed25519:ro,Z" \
    -v "${SSH_KEY_DIR:-${HOME}/.ssh}/darwin_ed25519.pub:/root/.ssh/id_ed25519.pub:ro,Z" \
    -v "${SSH_KEY_DIR:-${HOME}/.ssh}/known_hosts:/root/.ssh/known_hosts:ro,Z" \
    -e "GIT_AUTHOR_NAME=Darwin Agent" \
    -e "GIT_AUTHOR_EMAIL=darwin@emacboros.local" \
    -e "GIT_COMMITTER_NAME=Darwin Agent" \
    -e "GIT_COMMITTER_EMAIL=darwin@emacboros.local" \
    -e "GIT_PAGER=cat" \
    -e "TERM=dumb" \
    --entrypoint /bin/bash \
    "${IMAGE_NAME}" \
    -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(darwin-run-cycle :timeout ${TIMEOUT})'" 2>&1

info "Darwin cycle container exited with code: $?"
