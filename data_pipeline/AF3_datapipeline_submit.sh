#!/bin/bash
#===============================================================================
# AF3_datapipeline_submit.sh — submit the AF3 data pipeline (MSA generation)
#===============================================================================
# Runs the data pipeline over a directory of JSON files, chunking automatically
# around SLURM's MaxArraySize.
#
# Usage:
#   bash AF3_datapipeline_submit.sh --input <json_dir> --output <dir> \
#        [--batch NAME] [--jackhmmer-cpu N] [--nhmmer-cpu N] [--dry-run]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

JOB_SCRIPT="${SCRIPT_DIR}/AF3_datapipeline_job.sh"

INPUT_DIR=""; OUTPUT_DIR=""; BATCH="af3_data"; JACK=8; NH=8; DRY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --input)         INPUT_DIR="$2"; shift 2 ;;
        --output)        OUTPUT_DIR="$2"; shift 2 ;;
        --batch)         BATCH="$2"; shift 2 ;;
        --jackhmmer-cpu) JACK="$2"; shift 2 ;;
        --nhmmer-cpu)    NH="$2"; shift 2 ;;
        --dry-run)       DRY=true; shift ;;
        --help|-h)
            sed -n '3,14p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) af3_die "unknown option: $1" ;;
    esac
done

[[ -n "$INPUT_DIR" && -n "$OUTPUT_DIR" ]] || af3_die "--input and --output are required"
[[ -f "$JOB_SCRIPT" ]] || af3_die "job script not found: $JOB_SCRIPT"
af3_env_check || exit 1

INPUT_DIR=$(af3_abspath "$INPUT_DIR")
mkdir -p "$OUTPUT_DIR"; OUTPUT_DIR=$(af3_abspath "$OUTPUT_DIR")

TOTAL=$(find "$INPUT_DIR" -type f -iname "*.json" | wc -l)
[[ $TOTAL -eq 0 ]] && af3_die "no JSON files in $INPUT_DIR"

LOG_DIR=$(af3_new_log_dir "msa" "$BATCH")

# `|| true` matters: under `set -o pipefail` a missing or failing scontrol
    # makes this pipeline non-zero and `set -e` kills the submit silently,
    # never reaching the fallback below.
MAX_ARRAY=$( { scontrol show config 2>/dev/null || true; } | awk '/MaxArraySize/ {print $3}')
[[ -z "$MAX_ARRAY" || "$MAX_ARRAY" == "0" ]] && MAX_ARRAY=1000

echo "==============================================================================="
echo "AF3 data pipeline (MSA)"
echo "==============================================================================="
echo "Input:      $INPUT_DIR"
echo "Output:     $OUTPUT_DIR"
echo "JSON files: $TOTAL"
echo "Partition:  $AF3_CPU_PARTITION"
echo "Container:  $AF3_SIF ($(af3_version))"
echo "Logs:       $LOG_DIR"
echo ""

{
  echo "submitted: $(date -Iseconds)"
  echo "input:     $INPUT_DIR"
  echo "output:    $OUTPUT_DIR"
  echo "container: $AF3_SIF"
  echo "files:     $TOTAL"
} > "${LOG_DIR}/submit.log"

START=0; CHUNK=0
while [[ $START -lt $TOTAL ]]; do
    END=$((START + MAX_ARRAY - 1))
    [[ $END -ge $TOTAL ]] && END=$((TOTAL - 1))
    SIZE=$((END - START + 1))
    CHUNK=$((CHUNK + 1))

    CMD=(
        sbatch
        --array="0-$((SIZE - 1))"
        --partition="$AF3_CPU_PARTITION"
        --job-name="$BATCH"
        --output="${LOG_DIR}/tasks/%A_%a.log"
        "$JOB_SCRIPT"
        --script-dir "$AF3_SCRIPT_DIR"
        --input "$INPUT_DIR"
        --output "$OUTPUT_DIR"
        --jackhmmer-cpu "$JACK"
        --nhmmer-cpu "$NH"
        --log-dir "$LOG_DIR"
    )
    [[ $START -gt 0 ]] && CMD+=(--array-offset "$START")

    if $DRY; then
        echo "[dry-run] chunk $CHUNK (jobs $START-$END): ${CMD[*]}"
    else
        echo "  chunk $CHUNK (jobs $START-$END): $("${CMD[@]}")"
    fi
    START=$((END + 1))
done

echo ""
if $DRY; then
    echo "Dry run — nothing submitted."
else
    echo "Monitor with:  squeue -u \$USER -n $BATCH"
    echo "Logs:          $LOG_DIR"
    echo "Failed tasks:  bash AF3_logs.sh failed $(basename "$LOG_DIR")"
fi
