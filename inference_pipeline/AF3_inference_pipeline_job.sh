#!/bin/bash
#SBATCH --job-name=alphafold3_inference
#SBATCH --time=01:00:00
#SBATCH --mem=160G
#SBATCH --cpus-per-task=12
#SBATCH --gres=gpu:1

# NOTE: --output/--error are deliberately NOT set here. The controller creates
# the run log directory and passes an explicit --output, so stdout and stderr
# land in one file per task. SLURM does not create missing log directories --
# the old `job_%j/out.txt` path required a directory per job that nothing ever
# created, so tasks could die with no log at all.

set -euo pipefail
TASK_START=$(date +%s)

#===============================================================================
# AF3 Inference — array job
#===============================================================================
# Called by AF3_controller.sh — do not run directly.
#
# Task index -> chain pair:
#   standard:        index_a = TASK_ID / num_B,  index_b = TASK_ID % num_B
#   seed expansion:  pair_id = TASK_ID / num_seeds, seed_idx = TASK_ID % num_seeds
#
# CHANGES vs the pre-3.0.4 version:
#   - container, models and databases come from af3_env.sh
#   - FIXED: AF_EXIT_CODE was unreachable. Under `set -e` a failing apptainer
#     run killed the script before the assignment, so the failure branch never
#     ran and scratch leaked. Now wrapped in set +e / set -e.
#   - --force_output_dir: no timestamp-suffixed duplicate dirs on requeue
#   - AF3 output dir resolved with a glob fallback instead of assuming the
#     name survives sanitised_name() unchanged
#   - cleanup moved to a trap so it runs on every exit path
#   - partition comes from AF3_GPU_PARTITION via the controller's sbatch call
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

# ── Parse arguments ──────────────────────────────────────────────────────────
CHAIN_A_DIR=""; CHAIN_B_DIR=""; OUTPUT_DIR=""; NUM_B=""
NUM_SEEDS=""; OUTPUT_NAMING="both"; MERGE_SCRIPT=""; SEEDS=""
IPSAE_SCRIPT=""; IPSAE_OUTPUT_DIR=""; ARRAY_OFFSET=""; LOG_DIR=""
PROTOMERS_A=1; PROTOMERS_B=1; EXTRA_CHAINS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --chain-a)        CHAIN_A_DIR="$2"; shift 2 ;;
        --chain-b)        CHAIN_B_DIR="$2"; shift 2 ;;
        --output)         OUTPUT_DIR="$2"; shift 2 ;;
        --num-b)          NUM_B="$2"; shift 2 ;;
        --num-seeds)      NUM_SEEDS="$2"; shift 2 ;;
        --output-naming)  OUTPUT_NAMING="$2"; shift 2 ;;
        --merge-script)   MERGE_SCRIPT="$2"; shift 2 ;;
        --ipsae-script)   IPSAE_SCRIPT="$2"; shift 2 ;;
        --ipsae-output)   IPSAE_OUTPUT_DIR="$2"; shift 2 ;;
        --ipsae-mode)     AF3_IPSAE_MODE="$2"; shift 2 ;;
        --ipsae-layout)   AF3_IPSAE_LAYOUT="$2"; shift 2 ;;
        --array-offset)   ARRAY_OFFSET="$2"; shift 2 ;;
        --log-dir)        LOG_DIR="$2"; shift 2 ;;
        --protomers-a)    PROTOMERS_A="$2"; shift 2 ;;
        --protomers-b)    PROTOMERS_B="$2"; shift 2 ;;
        --extra-chain)    EXTRA_CHAINS+=("$2"); shift 2 ;;
        --script-dir)     shift 2 ;;   # consumed by the bootstrap above
        --seeds)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SEEDS="$SEEDS $1"; shift
            done
            SEEDS="${SEEDS# }"
            ;;
        *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$CHAIN_A_DIR" || -z "$CHAIN_B_DIR" || -z "$OUTPUT_DIR" || -z "$NUM_B" ]]; then
    echo "ERROR: Required: --chain-a, --chain-b, --output, --num-b"
    exit 1
fi
MERGE_SCRIPT="${MERGE_SCRIPT:-$AF3_MERGE_SCRIPT}"
[[ -f "$MERGE_SCRIPT" ]] || { echo "ERROR: Merge script not found: $MERGE_SCRIPT"; exit 1; }
af3_env_check || exit 1

# ── Task index -> chain pair ─────────────────────────────────────────────────
TASK_ID=${SLURM_ARRAY_TASK_ID:-0}
JOB_ID=${SLURM_ARRAY_JOB_ID:-$$}
[[ -n "$ARRAY_OFFSET" ]] && TASK_ID=$((TASK_ID + ARRAY_OFFSET))

if [[ -n "$NUM_SEEDS" && "$NUM_SEEDS" -gt 1 ]]; then
    PAIR_ID=$((TASK_ID / NUM_SEEDS))
    SEED_INDEX=$((TASK_ID % NUM_SEEDS))
    INDEX_A=$((PAIR_ID / NUM_B))
    INDEX_B=$((PAIR_ID % NUM_B))
    read -r -a SEEDS_ARRAY <<< "$SEEDS"
    CURRENT_SEED="${SEEDS_ARRAY[$SEED_INDEX]}"
else
    INDEX_A=$((TASK_ID / NUM_B))
    INDEX_B=$((TASK_ID % NUM_B))
    CURRENT_SEED=""
fi

# ── Scratch + temp JSON, cleaned up on any exit ──────────────────────────────
LOCAL_SCRATCH="/tmp/af3_scratch_${JOB_ID}_${TASK_ID}"
TEMP_JSON="/tmp/af3_${JOB_ID}_${TASK_ID}.json"
mkdir -p "$LOCAL_SCRATCH"
trap 'rm -rf "$LOCAL_SCRATCH" "$TEMP_JSON"' EXIT

echo "==============================================================================="
echo "AF3 Inference — Task $TASK_ID"
echo "==============================================================================="
echo "Job ID:           ${JOB_ID}_${TASK_ID}"
echo "Index A / B:      $INDEX_A / $INDEX_B  (num_B=$NUM_B)"
echo "Protomers:        A x$PROTOMERS_A, B x$PROTOMERS_B"
[[ ${#EXTRA_CHAINS[@]} -gt 0 ]] && echo "Extra chains:     ${EXTRA_CHAINS[*]}"
echo "Chain A dir:      $CHAIN_A_DIR"
echo "Chain B dir:      $CHAIN_B_DIR"
echo "Output dir:       $OUTPUT_DIR"
if [[ -n "$CURRENT_SEED" ]]; then
    echo "Seed (expanded):  $CURRENT_SEED"
elif [[ -n "$SEEDS" ]]; then
    echo "Seeds:            $SEEDS"
fi
af3_env_banner
echo "==============================================================================="
echo ""

# ── Build the merged input JSON ──────────────────────────────────────────────
echo "Generating merged input JSON: $TEMP_JSON"

MERGE_CMD=(
    python3 "$MERGE_SCRIPT" "$CHAIN_A_DIR" "$CHAIN_B_DIR"
    --index-a "$INDEX_A" --index-b "$INDEX_B"
    --output-file "$TEMP_JSON" --job-number "$TASK_ID" --quiet
)
# Only pass stoichiometry when non-default: at 1:1 with no extras the merge
# command is identical to the pre-feature one, so an older merge script works.
[[ $PROTOMERS_A -gt 1 ]] && MERGE_CMD+=(--protomers-a "$PROTOMERS_A")
[[ $PROTOMERS_B -gt 1 ]] && MERGE_CMD+=(--protomers-b "$PROTOMERS_B")
for _ec in ${EXTRA_CHAINS+"${EXTRA_CHAINS[@]}"}; do
    MERGE_CMD+=(--extra-chain "$_ec")
done
if [[ -n "$CURRENT_SEED" ]]; then
    MERGE_CMD+=(--seeds "$CURRENT_SEED")
elif [[ -n "$SEEDS" ]]; then
    # shellcheck disable=SC2206
    MERGE_CMD+=(--seeds $SEEDS)
fi

MERGE_OUTPUT=$("${MERGE_CMD[@]}")
CHAIN_A_NAME=$(echo "$MERGE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['chain_A'])")
CHAIN_B_NAME=$(echo "$MERGE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['chain_B'])")
OUTPUT_NAME=$(echo "$MERGE_OUTPUT"  | python3 -c "import sys,json; print(json.load(sys.stdin)['output_name'])")

echo "Processing:  $CHAIN_A_NAME + $CHAIN_B_NAME"
echo "Output name: $OUTPUT_NAME"
[[ -f "$TEMP_JSON" ]] || { echo "ERROR: Failed to create merged JSON"; exit 1; }
echo ""

# ── Run AlphaFold 3 inference ────────────────────────────────────────────────
echo "── Running AlphaFold 3 inference ────────────────────────────────────────────"

# set +e so the exit code is captured. Without this, `set -e` aborts the script
# here on any AF3 failure and the cleanup/report below never runs.
set +e
apptainer run --nv \
    --bind "$CHAIN_A_DIR" \
    --bind "$CHAIN_B_DIR" \
    --bind "$OUTPUT_DIR" \
    --bind "$AF3_MODEL_DIR" \
    --bind "$LOCAL_SCRATCH" \
    "$AF3_SIF" python3 /app/alphafold/run_alphafold.py \
    --json_path="$TEMP_JSON" \
    --model_dir="$AF3_MODEL_DIR" \
    --db_dir="$AF3_DB_DIR" \
    --pdb_database_path="$AF3_PDB_DIR" \
    --run_data_pipeline=false \
    --run_inference=true \
    --force_output_dir \
    --output_dir="$LOCAL_SCRATCH"
AF_EXIT_CODE=$?
set -e

# ── Locate AF3's output directory ────────────────────────────────────────────
# AF3 appends sanitised_name(OUTPUT_NAME) to --output_dir. For names made of
# [A-Za-z0-9_-.] on 3.0.2+ that equals OUTPUT_NAME, but fall back to a glob so
# an unexpected character (or an older, lowercasing image) can't silently
# produce a "successful" job with no archive.
AF3_LOCAL_OUTPUT="${LOCAL_SCRATCH}/${OUTPUT_NAME}"
if [[ $AF_EXIT_CODE -eq 0 && ! -d "$AF3_LOCAL_OUTPUT" ]]; then
    mapfile -t _af3_dirs < <(find "$LOCAL_SCRATCH" -mindepth 1 -maxdepth 1 -type d)
    if [[ ${#_af3_dirs[@]} -eq 1 ]]; then
        AF3_LOCAL_OUTPUT="${_af3_dirs[0]}"
        echo "NOTE: resolved AF3 output dir by glob: $(basename "$AF3_LOCAL_OUTPUT")"
        echo "      (expected '${OUTPUT_NAME}' — name was altered by sanitised_name)"
    else
        echo "ERROR: cannot resolve AF3 output directory in $LOCAL_SCRATCH"
        ls -la "$LOCAL_SCRATCH" || true
        AF_EXIT_CODE=1
    fi
fi

# ── ipSAE scoring ────────────────────────────────────────────────────────────
# AF3 3.0.x output layout:
#   <out>/<job>_model.cif                       top-ranked model (a COPY of the
#   <out>/<job>_confidences.json                best-scoring sample below)
#   <out>/<job>_ranking_scores.csv              seed,sample,ranking_score
#   <out>/seed-<S>_sample-<N>/<job>_seed-<S>_sample-<N>_model.cif
#   <out>/seed-<S>_sample-<N>/<job>_seed-<S>_sample-<N>_confidences.json
#
# mode=all scores every sample directory. The top-level model is deliberately
# NOT scored in that mode — it duplicates whichever sample ranked best, and
# ranking_scores.csv (copied into the ipSAE dir) identifies which one that is.
IPSAE_SCRIPT="${IPSAE_SCRIPT:-}"
IPSAE_ROOT="${IPSAE_OUTPUT_DIR:-${OUTPUT_DIR}/ipsae_scores}"
# One folder per job by default: ipsae_scores/<job_name>/
if [[ "$AF3_IPSAE_LAYOUT" == "flat" ]]; then
    IPSAE_DEST="$IPSAE_ROOT"
else
    IPSAE_DEST="${IPSAE_ROOT}/${OUTPUT_NAME}"
fi
IPSAE_EXIT_CODE=0
IPSAE_N_OK=0
IPSAE_N_FAIL=0

log_ipsae_failure() {
    local model_id="$1" reason="$2"
    local f="${OUTPUT_DIR}/ipsae_failed.tsv"
    [[ -f "$f" ]] || echo -e "job_num\toutput_name\tmodel\tchain_a\tchain_b\texit_code" > "$f"
    (
        flock -x 200
        echo -e "${TASK_ID}\t${OUTPUT_NAME}\t${model_id}\t${CHAIN_A_NAME}\t${CHAIN_B_NAME}\t${reason}" >> "$f"
    ) 200>"${f}.lock"
}

# Score one model. $1 = .cif path, $2 = model id for logging.
run_ipsae_on() {
    local cif="$1" model_id="$2" conf model_dir stem rc
    model_dir=$(dirname "$cif")
    conf=$(find "$model_dir" -maxdepth 1 -name "*_confidences.json" ! -name "*summary*" -type f | head -1)

    if [[ -z "$conf" ]]; then
        echo "  [$model_id] no confidences.json — skipped"
        log_ipsae_failure "$model_id" "no_json"
        IPSAE_N_FAIL=$((IPSAE_N_FAIL + 1))
        return 0
    fi

    set +e
    apptainer exec \
        --bind "$IPSAE_SCRIPT_DIR" \
        --bind "$AF3_LOCAL_OUTPUT" \
        --bind "$IPSAE_ROOT" \
        "$AF3_SIF" \
        python3 "$IPSAE_SCRIPT" "$conf" "$cif" 10 10
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        stem=$(basename "$cif" .cif)
        for ext in ".txt" "_byres.txt" ".pml"; do
            [[ -f "${model_dir}/${stem}_10_10${ext}" ]] \
                && mv "${model_dir}/${stem}_10_10${ext}" "$IPSAE_DEST/"
        done
        IPSAE_N_OK=$((IPSAE_N_OK + 1))
        echo "  [$model_id] ok"
    else
        echo "  [$model_id] FAILED (exit $rc)"
        log_ipsae_failure "$model_id" "$rc"
        IPSAE_N_FAIL=$((IPSAE_N_FAIL + 1))
    fi
    return 0
}

if [[ $AF_EXIT_CODE -eq 0 && -n "$IPSAE_SCRIPT" && -f "$IPSAE_SCRIPT" ]]; then
    echo ""
    echo "── Running ipSAE (mode: $AF3_IPSAE_MODE, layout: $AF3_IPSAE_LAYOUT) ─────"
    echo "  Destination: $IPSAE_DEST"
    mkdir -p "$IPSAE_DEST"
    IPSAE_SCRIPT_DIR=$(dirname "$IPSAE_SCRIPT")

    declare -a MODEL_CIFS=()
    if [[ "$AF3_IPSAE_MODE" == "top" ]]; then
        mapfile -t MODEL_CIFS < <(find "$AF3_LOCAL_OUTPUT" -maxdepth 1 -name "*_model.cif" -type f | sort)
    else
        # every seed-<S>_sample-<N> directory, in seed then sample order
        mapfile -t MODEL_CIFS < <(find "$AF3_LOCAL_OUTPUT" -mindepth 2 -maxdepth 2 \
            -path "*/seed-*_sample-*/*_model.cif" -type f | sort -V)
    fi

    if [[ ${#MODEL_CIFS[@]} -eq 0 ]]; then
        echo "WARNING: no model .cif files found in $AF3_LOCAL_OUTPUT (mode=$AF3_IPSAE_MODE)"
        log_ipsae_failure "-" "no_cif"
    else
        echo "  Models to score: ${#MODEL_CIFS[@]}"
        for cif in "${MODEL_CIFS[@]}"; do
            if [[ "$AF3_IPSAE_MODE" == "top" ]]; then
                run_ipsae_on "$cif" "top"
            else
                run_ipsae_on "$cif" "$(basename "$(dirname "$cif")")"
            fi
        done

        # Copy the ranking table so the top model is identifiable downstream
        RANKING_CSV=$(find "$AF3_LOCAL_OUTPUT" -maxdepth 1 -name "*_ranking_scores.csv" -type f | head -1)
        [[ -n "$RANKING_CSV" ]] && cp "$RANKING_CSV" "$IPSAE_DEST/"

        echo "  ipSAE done: $IPSAE_N_OK ok, $IPSAE_N_FAIL failed"
        [[ $IPSAE_N_OK -eq 0 ]] && IPSAE_EXIT_CODE=1
    fi
fi

# ── Compress and transfer ────────────────────────────────────────────────────
if [[ $AF_EXIT_CODE -eq 0 && -d "$AF3_LOCAL_OUTPUT" ]]; then
    echo ""
    echo "── Compressing and transferring ─────────────────────────────────────────"
    mkdir -p "$OUTPUT_DIR"

    ARCHIVE_BASENAME=$(basename "$AF3_LOCAL_OUTPUT")
    ARCHIVE_NAME="${ARCHIVE_BASENAME}.tar.gz"

    cd "$LOCAL_SCRATCH"
    if tar -czf "$ARCHIVE_NAME" "$ARCHIVE_BASENAME"; then
        echo "  Archive size: $(du -h "$ARCHIVE_NAME" | cut -f1)"
        if mv "${LOCAL_SCRATCH}/${ARCHIVE_NAME}" "$OUTPUT_DIR/"; then
            echo "  Transferred: $OUTPUT_DIR/$ARCHIVE_NAME"
        else
            echo "  ERROR: transfer failed"
            AF_EXIT_CODE=1
        fi
    else
        echo "  ERROR: compression failed"
        AF_EXIT_CODE=1
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==============================================================================="
if [[ $AF_EXIT_CODE -eq 0 ]]; then
    echo "Job completed successfully"
    echo "  Archive: $OUTPUT_DIR/${ARCHIVE_NAME:-unresolved}"
    [[ -n "$IPSAE_SCRIPT" ]] && echo "  ipSAE:   ${IPSAE_DEST:-n/a}/ ($IPSAE_N_OK scored, $IPSAE_N_FAIL failed)"
else
    echo "Job FAILED with exit code: $AF_EXIT_CODE"
fi
echo "Finished at: $(date)"
echo "==============================================================================="

af3_log_task "$LOG_DIR" "$TASK_ID" \
    "$([[ $AF_EXIT_CODE -eq 0 ]] && echo OK || echo FAIL)" \
    "$AF_EXIT_CODE" "$(( $(date +%s) - TASK_START ))" \
    "${OUTPUT_NAME:-?} ipsae=${IPSAE_N_OK:-0}/$(( ${IPSAE_N_OK:-0} + ${IPSAE_N_FAIL:-0} ))"

exit $AF_EXIT_CODE
