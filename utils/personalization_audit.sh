#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Personalization Audit -- Scan for large files in the personalization directory
#
# Reports all files sorted by size (largest first), with line counts for text
# files.  Highlights files over a configurable threshold so you can decide
# what to trim, summarize, or archive.
#
# Usage: personalization_audit.sh --personalization PATH [OPTIONS]
#
# Options:
#   --threshold BYTES    Highlight files larger than this (default: 10240 = 10KB)
#   --top N              Only show top N files (default: 30)
#   --json               Output as JSON (for programmatic use)
#   --help, -h           Show this message
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
# Source header.sh for logging functions (info, warn, error, etc.)
if [[ -f "${REPO_DIR}/metaconfig/header.sh" ]]; then
    source "${REPO_DIR}/metaconfig/header.sh"
elif [[ -f "/root/.emacs.d/metaconfig/header.sh" ]]; then
    source "/root/.emacs.d/metaconfig/header.sh"
fi

THRESHOLD=10240
TOP_N=30
JSON_OUTPUT=false
PERSONALIZATION_DIR=""

usage() {
    cat <<EOF
Usage: personalization_audit.sh --personalization PATH [OPTIONS]

Scans the personalization directory for large files and reports them
sorted by size (largest first).  Helps identify files that may need
summarizing, trimming, or archiving.

Required:
  --personalization PATH
                       Personalization directory to scan (must contain
                       knowledge/, tasks/, and audit/ subdirectories).

Options:
  --threshold BYTES    Highlight files larger than this (default: 10240 = 10KB)
  --top N              Only show top N files (default: 30)
  --json               Output as JSON (for programmatic use)
  --help, -h           Show this message

Examples:
  personalization_audit.sh --personalization ~/repos/iar-personalization
  personalization_audit.sh --personalization ~/repos/iar-personalization --threshold 50000
  personalization_audit.sh --personalization ~/repos/iar-personalization --json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --personalization)
            [[ $# -lt 2 ]] && error "--personalization requires a path argument" && exit 1
            PERSONALIZATION_DIR="$(realpath "$2")"
            [[ ! -d "${PERSONALIZATION_DIR}" ]] && error "Directory does not exist: ${PERSONALIZATION_DIR}" && exit 1
            shift 2
            ;;
        --threshold)
            [[ $# -lt 2 ]] && error "--threshold requires a value" && exit 1
            THRESHOLD="$2"
            shift 2
            ;;
        --top)
            [[ $# -lt 2 ]] && error "--top requires a value" && exit 1
            TOP_N="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
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

if [[ -z "${PERSONALIZATION_DIR}" ]]; then
    error "--personalization is required."
    echo ""
    usage
    exit 1
fi

# =============================================================================
# Scan
# =============================================================================

# Collect all files with their sizes, sorted by size descending.
# Only scan the three personalization subdirectories (knowledge/, tasks/, audit/).
# Exclude .git directory and common binary/ignore patterns.
mapfile -t FILES < <(
    for subdir in knowledge tasks audit; do
        dir="${PERSONALIZATION_DIR}/${subdir}"
        [[ -d "${dir}" ]] || continue
        find -L "${dir}" \
            -type f \
            -not -path '*/.git/*' \
            -not -name '*.elc' \
            -not -name '*.png' \
            -not -name '*.jpg' \
            -not -name '*.jpeg' \
            -not -name '*.gif' \
            -not -name '*.pdf' \
            -not -name '*.zip' \
            -not -name '*.gz' \
            -not -name '*.tar' \
            -exec stat --format='%s|%n' {} \; 2>/dev/null
    done \
    | sort -t'|' -k1 -rn \
    | head -n "${TOP_N}"
)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No files found in ${PERSONALIZATION_DIR}"
    exit 0
fi

# =============================================================================
# Output
# =============================================================================

if [[ "${JSON_OUTPUT}" == "true" ]]; then
    echo "["
    FIRST=true
    for entry in "${FILES[@]}"; do
        SIZE="${entry%%|*}"
        FILEPATH="${entry#*|}"
        # Get line count (try wc -l on all files, non-text will show "-" or error)
        LINES=$(wc -l < "${FILEPATH}" 2>/dev/null || echo "-")
        [[ -z "${LINES}" ]] && LINES="-"
        # Make path relative to personalization dir
        RELPATH="${FILEPATH#${PERSONALIZATION_DIR}/}"
        OVER_THRESHOLD=false
        [[ ${SIZE} -gt ${THRESHOLD} ]] && OVER_THRESHOLD=true

        [[ "${FIRST}" == "true" ]] && FIRST=false || echo ","
        printf '  {"path": "%s", "size_bytes": %s, "lines": %s, "over_threshold": %s}' \
            "${RELPATH}" "${SIZE}" "${LINES}" "${OVER_THRESHOLD}"
    done
    echo ""
    echo "]"
else
    # Human-readable output
    echo ""
    info "Personalization Audit: ${PERSONALIZATION_DIR}"
    info "Threshold: $(numfmt --to=iec ${THRESHOLD}) | Showing top ${#FILES[@]} files"
    echo ""
    printf "  %-10s  %8s  %s\n" "SIZE" "LINES" "PATH"
    printf "  %-10s  %8s  %s\n" "----------" "--------" "----------------------------------------"

    for entry in "${FILES[@]}"; do
        SIZE="${entry%%|*}"
        FILEPATH="${entry#*|}"
        RELPATH="${FILEPATH#${PERSONALIZATION_DIR}/}"

        # Get line count (try wc -l on all files, non-text will show "-" or error)
        LINES=$(wc -l < "${FILEPATH}" 2>/dev/null || echo "-")
        [[ -z "${LINES}" ]] && LINES="-"

        SIZE_HR=$(numfmt --to=iec "${SIZE}")

        # Highlight files over threshold
        if [[ ${SIZE} -gt ${THRESHOLD} ]]; then
            printf "  ${RED}%-10s${NC}  %8s  %s${NC}\n" "${SIZE_HR} *" "${LINES}" "${RELPATH}"
        else
            printf "  %-10s  %8s  %s\n" "${SIZE_HR}" "${LINES}" "${RELPATH}"
        fi
    done

    # Summary
    echo ""
    OVER_COUNT=0
    TOTAL_SIZE=0
    for entry in "${FILES[@]}"; do
        SIZE="${entry%%|*}"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
        [[ ${SIZE} -gt ${THRESHOLD} ]] && OVER_COUNT=$((OVER_COUNT + 1))
    done
    info "Files over threshold: ${OVER_COUNT}/${#FILES[@]}"
    info "Total size (top ${#FILES[@]}): $(numfmt --to=iec ${TOTAL_SIZE})"
    echo ""
fi