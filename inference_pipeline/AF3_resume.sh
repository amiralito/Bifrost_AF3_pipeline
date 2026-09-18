#!/bin/bash
#===============================================================================
# AF3_resume.sh — resubmit whatever a screen is still missing
#===============================================================================
# Reads .af3_screen.conf from the output directory, so the chain dirs, batch
# name, seeds and ipSAE mode do not need repeating.
#
# Usage:
#   bash AF3_resume.sh --output <screen_output_dir> [--dry-run]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

CONTROLLER="${SCRIPT_DIR}/AF3_controller.sh"

OUTPUT_DIR=""; DRY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)  OUTPUT_DIR="$2"; shift 2 ;;
        --dry-run) DRY=true; shift ;;
        --help|-h) sed -n '3,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) af3_die "unknown option: $1" ;;
    esac
done

[[ -n "$OUTPUT_DIR" ]] || af3_die "--output is required"
OUTPUT_DIR=$(af3_abspath "$OUTPUT_DIR")
[[ -f "$CONTROLLER" ]] || af3_die "controller not found: $CONTROLLER"
af3_env_check || exit 1

CONF="${OUTPUT_DIR}/${AF3_CONF_NAME}"
[[ -f "$CONF" ]] || af3_die "no ${AF3_CONF_NAME} in $OUTPUT_DIR — rerun AF3_screen_submit.sh instead"
# shellcheck disable=SC1090
source "$CONF"
AF3_IPSAE_MODE="${IPSAE_MODE:-$AF3_IPSAE_MODE}"
AF3_IPSAE_LAYOUT="${IPSAE_LAYOUT:-$AF3_IPSAE_LAYOUT}"
# Reuse the ORIGINAL stoichiometry: it is baked into the output names, so a
# retry at different copy numbers would write archives the manifest never
# matches, and every job would look permanently missing.
RESUME_STOICH=()
[[ "${PROTOMERS_A:-1}" -gt 1 ]] && RESUME_STOICH+=(--protomers-a "$PROTOMERS_A")
[[ "${PROTOMERS_B:-1}" -gt 1 ]] && RESUME_STOICH+=(--protomers-b "$PROTOMERS_B")
for _ec in ${EXTRA_CHAINS:-}; do RESUME_STOICH+=(--extra-chain "$_ec"); done

MISSING_MANIFEST="${OUTPUT_DIR}/missing_manifest.tsv"
TOTAL=$(af3_manifest_total "$OUTPUT_DIR")
MISSING=$(af3_count_missing "$OUTPUT_DIR" "$MISSING_MANIFEST")

echo "==============================================================================="
echo "AF3 resume: $BATCH"
echo "==============================================================================="
echo "Complete:   $((TOTAL - MISSING)) / $TOTAL"
echo "Missing:    $MISSING"
echo "ipSAE mode: $AF3_IPSAE_MODE (layout: $AF3_IPSAE_LAYOUT)"
echo "Protomers:  A x${PROTOMERS_A:-1}, B x${PROTOMERS_B:-1}"
echo ""

if [[ $MISSING -eq 0 ]]; then
    echo "Nothing to do — the screen is complete."
    rm -f "$MISSING_MANIFEST"
    exit 0
fi

echo "First 10 missing:"
tail -n +2 "$MISSING_MANIFEST" | head -10 | awk -F'\t' '{printf "  job_%s: %s\n", $2, $NF}'
[[ $MISSING -gt 10 ]] && echo "  ... and $((MISSING - 10)) more"
echo ""

export AF3_IPSAE_MODE AF3_IPSAE_LAYOUT
CTRL=(
    sbatch
    --partition="$AF3_CPU_PARTITION"
    --job-name="${BATCH}_retry_ctrl"
    "$CONTROLLER"
    --script-dir "$AF3_SCRIPT_DIR"
    --manifest "$MISSING_MANIFEST"
    --chain-a "$CHAIN_A"
    --chain-b "$CHAIN_B"
    --output "$OUTPUT_DIR"
    --batch "${BATCH}_retry"
)
[[ ${#RESUME_STOICH[@]} -gt 0 ]] && CTRL+=("${RESUME_STOICH[@]}")
# shellcheck disable=SC2206
CTRL+=(--seeds $SEEDS)
[[ "$EXPAND" == "true" ]] && CTRL+=(--expand-seeds)

if $DRY; then
    echo "[dry-run] would submit:"
    printf '  %s\n' "${CTRL[*]}"
    exit 0
fi

echo "Submitting controller: $("${CTRL[@]}")"
echo ""
echo "Track with:  bash AF3_status.sh --output $OUTPUT_DIR"
