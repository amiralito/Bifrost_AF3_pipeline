#!/bin/bash
#SBATCH --job-name=AF3_data
#SBATCH --cpus-per-task=8
#SBATCH --mem=80G
#SBATCH --time=24:00:00

# NOTE: --output/--error are deliberately NOT set here. The submitting script
# creates the run log directory and passes an explicit --output, so stdout and
# stderr land in one file per task. SLURM does not create missing log
# directories: a stale path here means the task dies with no log at all.

set -euo pipefail
TASK_START=$(date +%s)

#===============================================================================
# AF3 Data Pipeline — array job (MSA generation, no GPU)
#===============================================================================
# Called by ./af3 msa — do not run directly.
#
# CHANGES vs the pre-3.0.4 version:
#   - container, models and databases come from af3_env.sh (one place to edit)
#   - --force_output_dir stops AF3 creating timestamp-suffixed duplicate dirs
#     when a task is requeued onto a dirty scratch dir
#   - scratch cleanup moved to a trap so it runs on failure too
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
INPUT_DIR=""
OUTPUT_DIR=""
ARRAY_OFFSET=""
LOG_DIR=""
JACKHMMER_CPU=8
NHMMER_CPU=8

while [[ $# -gt 0 ]]; do
    case $1 in
        --input)         INPUT_DIR="$2"; shift 2 ;;
        --output)        OUTPUT_DIR="$2"; shift 2 ;;
        --array-offset)  ARRAY_OFFSET="$2"; shift 2 ;;
        --log-dir)       LOG_DIR="$2"; shift 2 ;;
        --script-dir)    shift 2 ;;   # consumed by the bootstrap above
        --jackhmmer-cpu) JACKHMMER_CPU="$2"; shift 2 ;;
        --nhmmer-cpu)    NHMMER_CPU="$2"; shift 2 ;;
        *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$INPUT_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "ERROR: --input and --output are required"
    exit 1
fi
[[ -d "$INPUT_DIR" ]] || { echo "ERROR: Input directory not found: $INPUT_DIR"; exit 1; }
af3_env_check || exit 1

# ── Task index ───────────────────────────────────────────────────────────────
TASK_ID=${SLURM_ARRAY_TASK_ID:-0}
JOB_ID=${SLURM_ARRAY_JOB_ID:-$$}
[[ -n "$ARRAY_OFFSET" ]] && TASK_ID=$((TASK_ID + ARRAY_OFFSET))

# ── Select this task's JSON ──────────────────────────────────────────────────
mapfile -t JSON_FILES < <(find "$INPUT_DIR" -type f -iname "*.json" | sort)
NUM_FILES=${#JSON_FILES[@]}
[[ $NUM_FILES -eq 0 ]] && { echo "ERROR: No JSON files found in $INPUT_DIR"; exit 1; }
if [[ $TASK_ID -ge $NUM_FILES ]]; then
    echo "ERROR: Task ID ($TASK_ID) exceeds number of JSON files ($NUM_FILES)"
    exit 1
fi

INPUT_JSON="${JSON_FILES[$TASK_ID]}"
JSON_NAME=$(basename "$INPUT_JSON" .json)

# ── Scratch (node-local SSD), cleaned up on any exit ─────────────────────────
LOCAL_SCRATCH="/tmp/af3_data_scratch_${JOB_ID}_${SLURM_ARRAY_TASK_ID:-0}"
mkdir -p "$LOCAL_SCRATCH"
trap 'rm -rf "$LOCAL_SCRATCH"' EXIT

# ── Banner ───────────────────────────────────────────────────────────────────
echo "==============================================================================="
echo "AF3 Data Pipeline — Task $TASK_ID"
echo "==============================================================================="
echo "Job ID:           $JOB_ID"
echo "Task ID:          $TASK_ID (SLURM: ${SLURM_ARRAY_TASK_ID:-0}, offset: ${ARRAY_OFFSET:-0})"
echo "Input JSON:       $INPUT_JSON"
echo "Output dir:       $OUTPUT_DIR"
echo "Local scratch:    $LOCAL_SCRATCH"
echo "Jackhmmer CPUs:   $JACKHMMER_CPU"
echo "Nhmmer CPUs:      $NHMMER_CPU"
af3_env_banner
echo "Started at:       $(date)"
echo ""

# ── Run AlphaFold 3 data pipeline ────────────────────────────────────────────
echo "── Running AlphaFold 3 data pipeline ────────────────────────────────────────"

# No --nv: the data pipeline is CPU only.
# set +e so a non-zero exit is captured rather than killing the script under -e.
set +e
apptainer run \
    --bind "$INPUT_DIR" \
    --bind "$LOCAL_SCRATCH" \
    --bind "$AF3_MODEL_DIR" \
    --bind "$AF3_PDB_DIR" \
    "$AF3_SIF" python3 /app/alphafold/run_alphafold.py \
    --json_path="$INPUT_JSON" \
    --model_dir="$AF3_MODEL_DIR" \
    --db_dir="$AF3_DB_DIR" \
    --pdb_database_path="$AF3_PDB_DIR" \
    --run_data_pipeline=true \
    --run_inference=false \
    --force_output_dir \
    --jackhmmer_n_cpu="$JACKHMMER_CPU" \
    --nhmmer_n_cpu="$NHMMER_CPU" \
    --output_dir="$LOCAL_SCRATCH"
AF_EXIT_CODE=$?
set -e

# ── Locate AF3's output directory ────────────────────────────────────────────
# AF3 appends sanitised_name() of the JSON `name` field to --output_dir, which
# need not match basename(INPUT_JSON). 3.0.2+ preserves casing; earlier
# versions lowercased. Globbing is correct under both.
AF3_LOCAL_OUTPUT=""
if [[ $AF_EXIT_CODE -eq 0 ]]; then
    mapfile -t _af3_dirs < <(find "$LOCAL_SCRATCH" -mindepth 1 -maxdepth 1 -type d)
    if [[ ${#_af3_dirs[@]} -eq 1 ]]; then
        AF3_LOCAL_OUTPUT="${_af3_dirs[0]}"
        echo "AF3 output directory: $(basename "$AF3_LOCAL_OUTPUT")"
    elif [[ ${#_af3_dirs[@]} -eq 0 ]]; then
        echo "ERROR: AF3 reported success but produced no output directory"
        AF_EXIT_CODE=1
    else
        echo "ERROR: Found multiple output directories in $LOCAL_SCRATCH (expected one):"
        printf '  %s\n' "${_af3_dirs[@]}"
        AF_EXIT_CODE=1
    fi
fi

# ── Transfer to final storage ────────────────────────────────────────────────
if [[ $AF_EXIT_CODE -eq 0 && -n "$AF3_LOCAL_OUTPUT" && -d "$AF3_LOCAL_OUTPUT" ]]; then
    echo ""
    echo "── Transferring output ──────────────────────────────────────────────────"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_BASENAME=$(basename "$AF3_LOCAL_OUTPUT")
    echo "  Output size: $(du -sh "$AF3_LOCAL_OUTPUT" | cut -f1)"

    if [[ -d "${OUTPUT_DIR}/${OUTPUT_BASENAME}" ]]; then
        echo "  Removing pre-existing ${OUTPUT_DIR}/${OUTPUT_BASENAME}"
        rm -rf "${OUTPUT_DIR}/${OUTPUT_BASENAME}"
    fi
    echo "  Transferring to: $OUTPUT_DIR/$OUTPUT_BASENAME"
    if mv "$AF3_LOCAL_OUTPUT" "$OUTPUT_DIR/"; then
        echo "  Transfer completed successfully"
    else
        echo "  ERROR: Transfer failed"
        AF_EXIT_CODE=1
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==============================================================================="
if [[ $AF_EXIT_CODE -eq 0 ]]; then
    echo "Job completed successfully"
    echo "  Output: $OUTPUT_DIR/$(basename "${AF3_LOCAL_OUTPUT:-unresolved}")/"
else
    echo "Job FAILED with exit code: $AF_EXIT_CODE"
fi
echo "Finished at: $(date)"
echo "==============================================================================="

af3_log_task "$LOG_DIR" "$TASK_ID" \
    "$([[ $AF_EXIT_CODE -eq 0 ]] && echo OK || echo FAIL)" \
    "$AF_EXIT_CODE" "$(( $(date +%s) - TASK_START ))" "$JSON_NAME"

exit $AF_EXIT_CODE
