#!/bin/bash
#===============================================================================
# AF3_screen_submit.sh — launch an all-vs-all AF3 inference screen
#===============================================================================
# Generates the manifest itself (no separate manifest step) and submits the
# controller. Also writes .af3_screen.conf into the output directory so
# AF3_status.sh and AF3_resume.sh need only --output afterwards.
#
# Usage:
#   bash AF3_screen_submit.sh --chain-a <dir> --chain-b <dir> --output <dir> \
#        [--batch NAME] [--seeds "1 2 3"] [--expand-seeds] \
#        [--ipsae-mode all|top] [--ipsae-layout job|flat] \
#        [--protomers-a N] [--protomers-b N] [--extra-chain PATH[:N]] \
#        [--start-chunk N] [--dry-run]
#
#   --seeds "1 2 3"        pass several seeds to one prediction
#   --expand-seeds         instead run each seed as its own job
#   --ipsae-mode all|top   score every diffusion sample (default all),
#                          or only the top-ranked model
#   --ipsae-layout job|flat  one ipsae_scores subfolder per job (default job),
#                          or everything in a single directory
#   --protomers-a N        copies of each chain A entity (default 1), e.g. 6
#                          for a hexameric resistosome against each effector
#   --protomers-b N        copies of each chain B entity (default 1)
#   --extra-chain PATH[:N] a constant chain present in every job, optionally
#                          with a copy count. Repeatable. Does NOT multiply
#                          the job count.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

CONTROLLER="${SCRIPT_DIR}/AF3_controller.sh"

CHAIN_A=""; CHAIN_B=""; OUTPUT_DIR=""; BATCH=""; SEEDS="1"
EXPAND=false; DRY=false; START_CHUNK=1
EXTRA_CHAINS=()
[[ -n "$AF3_EXTRA_CHAINS" ]] && read -r -a EXTRA_CHAINS <<< "$AF3_EXTRA_CHAINS"

while [[ $# -gt 0 ]]; do
    case $1 in
        --chain-a)      CHAIN_A="$2"; shift 2 ;;
        --chain-b)      CHAIN_B="$2"; shift 2 ;;
        --output)       OUTPUT_DIR="$2"; shift 2 ;;
        --batch)        BATCH="$2"; shift 2 ;;
        --seeds)        SEEDS="$2"; shift 2 ;;
        --expand-seeds) EXPAND=true; shift ;;
        --ipsae-mode)   AF3_IPSAE_MODE="$2"; shift 2 ;;
        --ipsae-layout) AF3_IPSAE_LAYOUT="$2"; shift 2 ;;
        --protomers-a)  AF3_PROTOMERS_A="$2"; shift 2 ;;
        --protomers-b)  AF3_PROTOMERS_B="$2"; shift 2 ;;
        --extra-chain)  EXTRA_CHAINS+=("$2"); shift 2 ;;
        --start-chunk)  START_CHUNK="$2"; shift 2 ;;
        --dry-run)      DRY=true; shift ;;
        --help|-h)
            sed -n '3,19p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) af3_die "unknown option: $1" ;;
    esac
done

[[ -n "$CHAIN_A" && -n "$CHAIN_B" && -n "$OUTPUT_DIR" ]] \
    || af3_die "--chain-a, --chain-b and --output are required"
[[ -f "$CONTROLLER" ]] || af3_die "controller not found: $CONTROLLER"
[[ -f "$AF3_MERGE_SCRIPT" ]] || af3_die "merge script not found: $AF3_MERGE_SCRIPT"

# Fail early and clearly rather than letting the merge script reject the flag
# mid-array, after the manifest has already been written.
if [[ $AF3_PROTOMERS_A -gt 1 || $AF3_PROTOMERS_B -gt 1 || ${#EXTRA_CHAINS[@]} -gt 0 ]]; then
    if ! grep -q -- '--protomers-a' "$AF3_MERGE_SCRIPT"; then
        af3_die "$(basename "$AF3_MERGE_SCRIPT") does not support --protomers-a/--extra-chain.
       Copy merge_af3_multimer_v7.py into $(dirname "$AF3_MERGE_SCRIPT"),
       or set AF3_MERGE_SCRIPT to its path."
    fi
fi
af3_env_check || exit 1

CHAIN_A=$(af3_abspath "$CHAIN_A")
CHAIN_B=$(af3_abspath "$CHAIN_B")
mkdir -p "$OUTPUT_DIR"; OUTPUT_DIR=$(af3_abspath "$OUTPUT_DIR")
[[ -z "$BATCH" ]] && BATCH="$(basename "$OUTPUT_DIR")"

# Counted recursively, matching merge_af3_multimer_v6.py's sorted rglob:
# chain dirs hold one data-pipeline output folder per protein.
N_A=$(af3_count_chain_json "$CHAIN_A")
N_B=$(af3_count_chain_json "$CHAIN_B")
if [[ $N_A -eq 0 ]]; then
    echo "Contents of $CHAIN_A:" >&2; ls -la "$CHAIN_A" >&2
    af3_die "no JSON files found under $CHAIN_A (searched recursively)"
fi
if [[ $N_B -eq 0 ]]; then
    echo "Contents of $CHAIN_B:" >&2; ls -la "$CHAIN_B" >&2
    af3_die "no JSON files found under $CHAIN_B (searched recursively)"
fi

[[ "$AF3_PROTOMERS_A" =~ ^[0-9]+$ && $AF3_PROTOMERS_A -ge 1 ]] \
    || af3_die "--protomers-a must be a positive integer (got '$AF3_PROTOMERS_A')"
[[ "$AF3_PROTOMERS_B" =~ ^[0-9]+$ && $AF3_PROTOMERS_B -ge 1 ]] \
    || af3_die "--protomers-b must be a positive integer (got '$AF3_PROTOMERS_B')"

# Resolve extra chains to absolute paths now: the job scripts run on compute
# nodes with a different working directory.
# Emit the stoichiometry flags ONLY when they are non-default. At 1:1 with no
# extras the command line is exactly what it was before this feature existed,
# so an older merge script that lacks these flags still works.
STOICH_ARGS=()
[[ $AF3_PROTOMERS_A -gt 1 ]] && STOICH_ARGS+=(--protomers-a "$AF3_PROTOMERS_A")
[[ $AF3_PROTOMERS_B -gt 1 ]] && STOICH_ARGS+=(--protomers-b "$AF3_PROTOMERS_B")
EXTRA_ABS=()
for spec in ${EXTRA_CHAINS+"${EXTRA_CHAINS[@]}"}; do
    ec_path="${spec%%:*}"; ec_count=""
    [[ "$spec" == *:* ]] && ec_count="${spec##*:}"
    [[ -e "$ec_path" ]] || af3_die "--extra-chain not found: $ec_path"
    ec_abs=$(cd "$(dirname "$ec_path")" && pwd)/$(basename "$ec_path")
    if [[ -n "$ec_count" ]]; then
        [[ "$ec_count" =~ ^[0-9]+$ && $ec_count -ge 1 ]] \
            || af3_die "--extra-chain copy count must be a positive integer: $spec"
        ec_abs="${ec_abs}:${ec_count}"
    fi
    EXTRA_ABS+=("$ec_abs")
    STOICH_ARGS+=(--extra-chain "$ec_abs")
done

N_SEEDS=$(wc -w <<< "$SEEDS")
TOTAL=$((N_A * N_B))
$EXPAND && TOTAL=$((TOTAL * N_SEEDS))

LOG_DIR=$(af3_new_log_dir "screen" "$BATCH")

# ── Generate the manifest ────────────────────────────────────────────────────
MANIFEST="${OUTPUT_DIR}/manifest.tsv"
GEN=(python3 "$AF3_MERGE_SCRIPT" "$CHAIN_A" "$CHAIN_B"
     --list-combinations --batch "$BATCH" --output-naming both)
# shellcheck disable=SC2206
[[ -n "$SEEDS" ]] && GEN+=(--seeds $SEEDS)
$EXPAND && GEN+=(--expand-seeds)
[[ ${#STOICH_ARGS[@]} -gt 0 ]] && GEN+=("${STOICH_ARGS[@]}")

"${GEN[@]}" > "$MANIFEST"
MANIFEST_ROWS=$(af3_manifest_total "$OUTPUT_DIR")

# ── Remember settings for status / resume ────────────────────────────────────
cat > "${OUTPUT_DIR}/${AF3_CONF_NAME}" <<EOF
CHAIN_A="$CHAIN_A"
CHAIN_B="$CHAIN_B"
BATCH="$BATCH"
SEEDS="$SEEDS"
EXPAND="$EXPAND"
IPSAE_MODE="$AF3_IPSAE_MODE"
IPSAE_LAYOUT="$AF3_IPSAE_LAYOUT"
PROTOMERS_A="$AF3_PROTOMERS_A"
PROTOMERS_B="$AF3_PROTOMERS_B"
EXTRA_CHAINS="${EXTRA_ABS[*]-}"
LOG_DIR="$LOG_DIR"
SIF="$AF3_SIF"
CREATED="$(date -Iseconds)"
EOF

echo "==============================================================================="
echo "AF3 screen: $BATCH"
echo "==============================================================================="
echo "Chain A:    $CHAIN_A ($N_A inputs)"
af3_list_chain_json "$CHAIN_A" 5
[[ $N_A -gt 5 ]] && echo "  ... and $((N_A - 5)) more"
echo "Chain B:    $CHAIN_B ($N_B inputs)"
af3_list_chain_json "$CHAIN_B" 5
[[ $N_B -gt 5 ]] && echo "  ... and $((N_B - 5)) more"
echo "Seeds:      $SEEDS$($EXPAND && echo ' (expanded into separate jobs)')"
CHAINS_PER_JOB=$((AF3_PROTOMERS_A + AF3_PROTOMERS_B))
echo "Protomers:  A x$AF3_PROTOMERS_A, B x$AF3_PROTOMERS_B"
if [[ ${#EXTRA_ABS[@]} -gt 0 ]]; then
    echo "Extra:      constant in every job"
    for e in "${EXTRA_ABS[@]}"; do
        ec="${e##*:}"; [[ "$e" == *:* ]] || ec=1
        echo "              $(basename "${e%%:*}") x$ec"
        CHAINS_PER_JOB=$((CHAINS_PER_JOB + ec))
    done
fi
echo "Chains/job: ~$CHAINS_PER_JOB (per entity in each input)"
if [[ $CHAINS_PER_JOB -gt 8 ]]; then
    echo ""
    echo "NOTE: AF3 memory scales roughly with the SQUARE of total tokens."
    echo "      $CHAINS_PER_JOB chains is a large complex — check one job fits in"
    echo "      GPU memory before launching the whole screen."
fi
echo "Total jobs: $TOTAL"
echo "Manifest:   $MANIFEST ($MANIFEST_ROWS rows)"
echo "Output:     $OUTPUT_DIR"
echo "Container:  $AF3_SIF ($(af3_version))"
echo "ipSAE mode: $AF3_IPSAE_MODE (layout: $AF3_IPSAE_LAYOUT)"
echo "Logs:       $LOG_DIR"
echo ""

if [[ $MANIFEST_ROWS -ne $TOTAL ]]; then
    echo "NOTE: manifest rows ($MANIFEST_ROWS) != expected jobs ($TOTAL)."
    echo "      Check --seeds / --expand-seeds before continuing."
    echo ""
fi

export AF3_IPSAE_MODE AF3_IPSAE_LAYOUT
CTRL=(
    sbatch
    --partition="$AF3_CPU_PARTITION"
    --job-name="${BATCH}_ctrl"
    --output="${LOG_DIR}/controller.log"
    "$CONTROLLER"
    --script-dir "$AF3_SCRIPT_DIR"
    --manifest "$MANIFEST"
    --chain-a "$CHAIN_A"
    --chain-b "$CHAIN_B"
    --output "$OUTPUT_DIR"
    --batch "$BATCH"
    --start-chunk "$START_CHUNK"
    --log-dir "$LOG_DIR"
)
[[ ${#STOICH_ARGS[@]} -gt 0 ]] && CTRL+=("${STOICH_ARGS[@]}")
# shellcheck disable=SC2206
CTRL+=(--seeds $SEEDS)
$EXPAND && CTRL+=(--expand-seeds)

if $DRY; then
    echo "[dry-run] would submit controller:"
    printf '  %s\n' "${CTRL[*]}"
    echo ""
    echo "The manifest was still written — inspect it with:"
    echo "  head -5 $MANIFEST"
    exit 0
fi

echo "Submitting controller: $("${CTRL[@]}")"
echo ""
echo "Track with:    bash AF3_status.sh --output $OUTPUT_DIR"
echo "Controller log: ${LOG_DIR}/controller.log"
echo "Failed tasks:  bash AF3_logs.sh failed $(basename "$LOG_DIR")"
