#!/bin/bash
#SBATCH --job-name=AF3_controller
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=7-00:00:00

# --output is passed by AF3_screen_submit.sh (controller.log in the run dir).

set -euo pipefail

#===============================================================================
# AF3 Controller — manifest driven
#===============================================================================
# Submitted by ./af3 screen — do not run directly.
#
# Replaces BOTH AF3_inference_controller.sh and
# AF3_inference_controller_manifest.sh. The manifest-based logic is a superset:
# a full screen produces a contiguous 0..N-1 manifest, which collapses to a
# single range, so the two code paths were doing the same thing.
#
# Reads job numbers from the manifest, collapses them into contiguous ranges,
# splits ranges larger than MaxArraySize, and submits one array job per chunk,
# waiting for each before submitting the next so the queue never exceeds
# MaxSubmitJobs.
#===============================================================================

# ── Locate af3_env.sh ────────────────────────────────────────────────────────
# SLURM copies the batch script to /var/spool/slurmd/job<id>/ before running
# it, so ${BASH_SOURCE[0]} does NOT point at the script directory. Resolve in
# priority order: --script-dir argument, exported AF3_SCRIPT_DIR, the submit
# directory, then BASH_SOURCE (for running this script directly).
_af3_dir=""
for ((_i = 1; _i <= $#; _i++)); do
    if [[ "${!_i}" == "--script-dir" ]]; then
        _j=$((_i + 1)); _af3_dir="${!_j}"; break
    fi
done
for _cand in "$_af3_dir" "${AF3_SCRIPT_DIR:-}" "${SLURM_SUBMIT_DIR:-}" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
    if [[ -n "$_cand" && -f "${_cand}/af3_env.sh" ]]; then
        AF3_SCRIPT_DIR="$_cand"; break
    fi
done
if [[ ! -f "${AF3_SCRIPT_DIR:-}/af3_env.sh" ]]; then
    echo "ERROR: cannot locate af3_env.sh." >&2
    echo "  Pass --script-dir /path/to/inference_scripts, or export AF3_SCRIPT_DIR." >&2
    exit 1
fi
export AF3_SCRIPT_DIR
# shellcheck source=af3_env.sh
source "${AF3_SCRIPT_DIR}/af3_env.sh"

JOB_SCRIPT="${AF3_SCRIPT_DIR}/AF3_inference_pipeline_job.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
MAX_CHUNK_SIZE=1001
CHECK_INTERVAL=30
SEEDS="1"
OUTPUT_NAMING="both"
START_CHUNK=1
END_CHUNK=""

MANIFEST_FILE=""; CHAIN_A_DIR=""; CHAIN_B_DIR=""; OUTPUT_DIR=""; BATCH_NAME=""
LOG_DIR=""
PROTOMERS_A=1; PROTOMERS_B=1; EXTRA_CHAINS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --manifest)     MANIFEST_FILE="$2"; shift 2 ;;
        --chain-a)      CHAIN_A_DIR="$2"; shift 2 ;;
        --chain-b)      CHAIN_B_DIR="$2"; shift 2 ;;
        --output)       OUTPUT_DIR="$2"; shift 2 ;;
        --batch)        BATCH_NAME="$2"; shift 2 ;;
        --log-dir)      LOG_DIR="$2"; shift 2 ;;
        --script-dir)   shift 2 ;;   # consumed by the bootstrap above
        --protomers-a)  PROTOMERS_A="$2"; shift 2 ;;
        --protomers-b)  PROTOMERS_B="$2"; shift 2 ;;
        --extra-chain)  EXTRA_CHAINS+=("$2"); shift 2 ;;
        --start-chunk)  START_CHUNK="$2"; shift 2 ;;
        --end-chunk)    END_CHUNK="$2"; shift 2 ;;
        --expand-seeds) EXPAND_SEEDS=1; shift ;;
        --seeds)
            SEEDS=""
            shift
            while [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; do
                SEEDS="$SEEDS $1"; shift
            done
            SEEDS="${SEEDS# }"
            ;;
        *) echo "ERROR: Unknown option: $1"; exit 1 ;;
    esac
done
EXPAND_SEEDS="${EXPAND_SEEDS:-0}"

for req in MANIFEST_FILE CHAIN_A_DIR CHAIN_B_DIR OUTPUT_DIR BATCH_NAME; do
    [[ -n "${!req}" ]] || { echo "ERROR: --${req,,} is required" | tr '_' '-'; exit 1; }
done
[[ -f "$MANIFEST_FILE" ]] || { echo "ERROR: Manifest not found: $MANIFEST_FILE"; exit 1; }
[[ -f "$JOB_SCRIPT" ]] || { echo "ERROR: Job script not found: $JOB_SCRIPT"; exit 1; }
af3_env_check || exit 1

# Must match merge_af3_multimer_v6.py's sorted rglob exactly: NUM_B is the
# divisor for task_id -> (index_a, index_b), so a wrong count mis-pairs chains.
NUM_B=$(af3_count_chain_json "$CHAIN_B_DIR")
[[ $NUM_B -eq 0 ]] && { echo "ERROR: no JSON files found under $CHAIN_B_DIR"; exit 1; }

NUM_SEEDS=$(wc -w <<< "$SEEDS")
IPSAE_OUTPUT="${OUTPUT_DIR}/ipsae_scores"

# If run by hand without --log-dir, make one so task logs still have a home.
if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR=$(af3_new_log_dir "screen" "$BATCH_NAME")
    echo "NOTE: no --log-dir given; created $LOG_DIR"
fi
mkdir -p "${LOG_DIR}/tasks"

# ── Banner ───────────────────────────────────────────────────────────────────
echo "==============================================================================="
echo "AF3 Controller"
echo "==============================================================================="
echo "Controller job:   ${SLURM_JOB_ID:-interactive}"
echo "Started:          $(date)"
echo "Manifest:         $MANIFEST_FILE"
echo "Chain A:          $CHAIN_A_DIR"
echo "Chain B:          $CHAIN_B_DIR (num_B=$NUM_B)"
echo "Output:           $OUTPUT_DIR"
echo "Batch:            $BATCH_NAME"
echo "Seeds:            $SEEDS (n=$NUM_SEEDS, expand=$EXPAND_SEEDS)"
echo "GPU partition:    $AF3_GPU_PARTITION"
echo "ipSAE mode:       $AF3_IPSAE_MODE (layout: $AF3_IPSAE_LAYOUT)"
echo "Protomers:        A x$PROTOMERS_A, B x$PROTOMERS_B${EXTRA_CHAINS[*]+ (+${#EXTRA_CHAINS[@]} extra)}"
echo "Logs:             $LOG_DIR"
af3_env_banner
echo ""

# ── Collapse manifest job numbers into contiguous ranges ─────────────────────
# Column 2 is job_number in both the 5-column and 6-column (seed) layouts.
JOB_NUMBERS=$(tail -n +2 "$MANIFEST_FILE" | cut -f2 | grep -E '^[0-9]+$' | sort -n | uniq)
TOTAL_JOBS=$(wc -l <<< "$JOB_NUMBERS")
echo "Jobs in manifest: $TOTAL_JOBS"

CHUNKS_FILE=$(mktemp)
FINAL_CHUNKS_FILE=$(mktemp)
trap 'rm -f "$CHUNKS_FILE" "$FINAL_CHUNKS_FILE"' EXIT

prev=""; range_start=""
while read -r num; do
    if [[ -z "$prev" ]]; then
        range_start="$num"
    elif [[ $num -ne $((prev + 1)) ]]; then
        echo "$range_start $prev" >> "$CHUNKS_FILE"
        range_start="$num"
    fi
    prev="$num"
done <<< "$JOB_NUMBERS"
[[ -n "$range_start" ]] && echo "$range_start $prev" >> "$CHUNKS_FILE"

# Split any range larger than MaxArraySize
while read -r start end; do
    if [[ $((end - start + 1)) -le $MAX_CHUNK_SIZE ]]; then
        echo "$start $end" >> "$FINAL_CHUNKS_FILE"
    else
        current=$start
        while [[ $current -le $end ]]; do
            chunk_end=$((current + MAX_CHUNK_SIZE - 1))
            [[ $chunk_end -gt $end ]] && chunk_end=$end
            echo "$current $chunk_end" >> "$FINAL_CHUNKS_FILE"
            current=$((chunk_end + 1))
        done
    fi
done < "$CHUNKS_FILE"

TOTAL_CHUNKS=$(wc -l < "$FINAL_CHUNKS_FILE")
[[ -z "$END_CHUNK" ]] && END_CHUNK=$TOTAL_CHUNKS
echo "Chunks:           $TOTAL_CHUNKS (processing $START_CHUNK..$END_CHUNK)"
echo ""
echo "First 5 chunks:"
head -5 "$FINAL_CHUNKS_FILE" | while read -r s e; do
    echo "  jobs $s-$e ($((e - s + 1)))"
done
[[ $TOTAL_CHUNKS -gt 5 ]] && echo "  ..."
echo ""

# ── Wait helper ──────────────────────────────────────────────────────────────
wait_for_job() {
    local job_id=$1 chunk_num=$2 chunk_size=$3 remaining completed failed
    while true; do
        remaining=$(squeue -j "$job_id" -h 2>/dev/null | wc -l)
        if [[ $remaining -eq 0 ]]; then
            completed=$(sacct -j "$job_id" --format=State -n 2>/dev/null | grep -c "COMPLETED" || true)
            failed=$(sacct -j "$job_id" --format=State -n 2>/dev/null | grep -cE "FAILED|NODE_FAIL|TIMEOUT|CANCELLED" || true)
            printf "\r  Chunk %d finished: %s completed, %s failed          \n" \
                "$chunk_num" "${completed:-0}" "${failed:-0}"
            return 0
        fi
        printf "\r  Chunk %d: %d/%d still queued or running...   " "$chunk_num" "$remaining" "$chunk_size"
        sleep $CHECK_INTERVAL
    done
}

# ── Submit chunks sequentially ───────────────────────────────────────────────
START_TIME=$(date +%s)
PROGRESS_FILE="${OUTPUT_DIR}/.controller_progress"
CHUNK_NUM=0

while read -r RANGE_START RANGE_END; do
    CHUNK_NUM=$((CHUNK_NUM + 1))
    [[ $CHUNK_NUM -lt $START_CHUNK ]] && continue
    [[ $CHUNK_NUM -gt $END_CHUNK ]] && break

    CHUNK_SIZE=$((RANGE_END - RANGE_START + 1))
    ELAPSED=$(($(date +%s) - START_TIME))

    echo ""
    printf "[%dh %02dm] ══ Chunk %d/%d: jobs %d-%d (%d) ══\n" \
        $((ELAPSED / 3600)) $(((ELAPSED % 3600) / 60)) \
        "$CHUNK_NUM" "$TOTAL_CHUNKS" "$RANGE_START" "$RANGE_END" "$CHUNK_SIZE"

    SBATCH_CMD=(
        sbatch
        --array="0-$((CHUNK_SIZE - 1))"
        --partition="$AF3_GPU_PARTITION"
        --job-name="$BATCH_NAME"
        --output="${LOG_DIR}/tasks/%A_%a.log"
        "$JOB_SCRIPT"
        --script-dir "$AF3_SCRIPT_DIR"
        --chain-a "$CHAIN_A_DIR"
        --chain-b "$CHAIN_B_DIR"
        --output "$OUTPUT_DIR"
        --num-b "$NUM_B"
        --output-naming "$OUTPUT_NAMING"
        --merge-script "$AF3_MERGE_SCRIPT"
        --array-offset "$RANGE_START"
        --log-dir "$LOG_DIR"
    )
    # Only forward stoichiometry when non-default, so the job script in turn
    # calls the merge script with the same command line it always used.
    [[ $PROTOMERS_A -gt 1 ]] && SBATCH_CMD+=(--protomers-a "$PROTOMERS_A")
    [[ $PROTOMERS_B -gt 1 ]] && SBATCH_CMD+=(--protomers-b "$PROTOMERS_B")
    for _ec in ${EXTRA_CHAINS+"${EXTRA_CHAINS[@]}"}; do
        SBATCH_CMD+=(--extra-chain "$_ec")
    done
    SBATCH_CMD+=(--seeds)
    for seed in $SEEDS; do SBATCH_CMD+=("$seed"); done
    [[ $EXPAND_SEEDS -eq 1 && $NUM_SEEDS -gt 1 ]] && SBATCH_CMD+=(--num-seeds "$NUM_SEEDS")
    [[ -f "$AF3_IPSAE_SCRIPT" ]] && SBATCH_CMD+=(--ipsae-script "$AF3_IPSAE_SCRIPT" --ipsae-output "$IPSAE_OUTPUT" --ipsae-mode "$AF3_IPSAE_MODE" --ipsae-layout "$AF3_IPSAE_LAYOUT")

    JOB_OUTPUT=$("${SBATCH_CMD[@]}" 2>&1) || {
        echo "  ERROR: submission failed: $JOB_OUTPUT"
        echo "  Retrying in 60s..."
        sleep 60
        JOB_OUTPUT=$("${SBATCH_CMD[@]}" 2>&1) || {
            echo "  FATAL: submission failed again."
            echo "  Resume with: bash AF3_screen_submit.sh ... --start-chunk $CHUNK_NUM"
            exit 1
        }
    }

    JOB_ID=$(grep -oE '[0-9]+' <<< "$JOB_OUTPUT" | tail -1)
    echo "  Submitted job $JOB_ID"
    echo "$CHUNK_NUM $JOB_ID $(date +%s)" >> "$PROGRESS_FILE"

    wait_for_job "$JOB_ID" "$CHUNK_NUM" "$CHUNK_SIZE"
    sleep 5
done < "$FINAL_CHUNKS_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
TOTAL_TIME=$(($(date +%s) - START_TIME))
echo ""
echo "==============================================================================="
echo "Controller complete"
echo "  Chunks processed: $((END_CHUNK - START_CHUNK + 1))"
printf "  Total time:       %dh %02dm\n" $((TOTAL_TIME / 3600)) $(((TOTAL_TIME % 3600) / 60))
echo "  Finished:         $(date)"
echo ""
echo "  Check progress:   bash AF3_status.sh --output $OUTPUT_DIR"
echo "  Logs:             $LOG_DIR"
echo "  Failed tasks:     bash AF3_logs.sh failed $(basename "$LOG_DIR")"
echo "==============================================================================="
