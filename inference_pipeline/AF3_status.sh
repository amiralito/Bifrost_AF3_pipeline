#!/bin/bash
#===============================================================================
# AF3_status.sh — how far along is a screen
#===============================================================================
# Usage:
#   bash AF3_status.sh --output <screen_output_dir>
#
# Compares manifest.tsv against the archives actually on disk. Replaces
# AF3_find_missing.sh (which guessed seed suffixes 1-5); this matches both the
# bare and _seed<N> archive names exactly.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)  OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h) sed -n '3,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) af3_die "unknown option: $1" ;;
    esac
done

[[ -n "$OUTPUT_DIR" ]] || af3_die "--output is required"
OUTPUT_DIR=$(af3_abspath "$OUTPUT_DIR")

TOTAL=$(af3_manifest_total "$OUTPUT_DIR")
MISSING=$(af3_count_missing "$OUTPUT_DIR")
DONE=$((TOTAL - MISSING))
PCT=$(awk -v d="$DONE" -v t="$TOTAL" 'BEGIN{printf "%.1f", (t?100*d/t:0)}')

echo "==============================================================================="
echo "AF3 screen status: $OUTPUT_DIR"
echo "==============================================================================="
if [[ -f "${OUTPUT_DIR}/${AF3_CONF_NAME}" ]]; then
    # shellcheck disable=SC1090
    source "${OUTPUT_DIR}/${AF3_CONF_NAME}"
    echo "Batch:       ${BATCH:-?}   seeds: ${SEEDS:-?}   ipSAE: ${IPSAE_MODE:-?}"
    echo "Created:     ${CREATED:-?}"
    echo "Container:   ${SIF:-?}"
    echo "Protomers:   A x${PROTOMERS_A:-1}, B x${PROTOMERS_B:-1}${EXTRA_CHAINS:+   extra: $EXTRA_CHAINS}"
fi
echo "Complete:    $DONE / $TOTAL  (${PCT}%)"
echo "Missing:     $MISSING"

IPSAE_DIR="${OUTPUT_DIR}/ipsae_scores"
# Recursive: the default layout nests one folder per job under ipsae_scores/
[[ -d "$IPSAE_DIR" ]] \
    && echo "ipSAE:       $(find "$IPSAE_DIR" -name '*_10_10.txt' | wc -l) score files in $(find "$IPSAE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) job folder(s)"
[[ -f "${OUTPUT_DIR}/ipsae_failed.tsv" ]] \
    && echo "ipSAE fails: $(( $(wc -l < "${OUTPUT_DIR}/ipsae_failed.tsv") - 1 ))"

ME="${USER:-$(id -un)}"
RUNNING=$( { squeue -u "$ME" -h 2>/dev/null || true; } | wc -l )
echo "In queue:    $RUNNING job(s) for $ME"
echo ""
[[ $MISSING -gt 0 ]] \
    && echo "Resubmit the gaps with:  bash AF3_resume.sh --output $OUTPUT_DIR"
exit 0
