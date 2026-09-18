#!/bin/bash

#SBATCH --job-name=AF3_array
#SBATCH -o /hpc-home/toghani/slurm.logs/slurm.%j.out
#SBATCH -e /hpc-home/toghani/slurm.logs/slurm.%j.err
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=amirali.toghani@tsl.ac.uk
#SBATCH --array=0-0   # will be overridden dynamically
#SBATCH --partition=tsl-gpu
#SBATCH -c 8
#SBATCH --gres=gpu:1
#SBATCH --mem=120G

# =============================================================================
# ipSAE + output configuration
# =============================================================================
RUN_IPSAE=true                 # set to false to skip ipSAE scoring
IPSAE_MODE=all                 # all = every seed-*_sample-*/ model (GCloud default)
                               # top = only the top-level <job>_model.cif
IPSAE_PAE=10                   # PAE cutoff passed to ipsae.py
IPSAE_DIST=10                  # distance cutoff passed to ipsae.py
REMOVE_DIR_AFTER_TAR=true      # keep only the .tar.gz (set false to keep the folder too)

# ipsae.py lives alongside the pipeline scripts.
SCRIPT_DIR="/tsl/scratch/toghani/AF3/scripts/AF3_default_new"
IPSAE_SCRIPT="${SCRIPT_DIR}/ipsae.py"

AF3_BIN="/tsl/software/testing/alphafold/3.0.2/x86_64/bin/run_alphafold.py"

# Interpreter for ipsae.py. Leave empty to auto-detect one that can import
# numpy (this is the usual reason ipSAE silently "does nothing": the plain
# python3 on a tsl-gpu node has no numpy). Override with AF3_PYTHON=... if
# you want to pin it.
IPSAE_PYTHON="${AF3_PYTHON:-}"

# -----------------------------
# Check input arguments
# -----------------------------
if [ -z "$1" ]; then
    echo "ERROR: You must provide the input directory containing JSON files."
    exit 1
fi

if [ -z "$2" ]; then
    echo "ERROR: You must provide an output directory."
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

# -----------------------------
# Collect all JSON files
# -----------------------------
JSON_FILES=($(find "$INPUT_DIR" -type f -iname "*.json" | sort))

if [ ${#JSON_FILES[@]} -eq 0 ]; then
    echo "ERROR: No JSON files found in $INPUT_DIR"
    exit 1
fi

# -----------------------------
# Select JSON file for this array task
# -----------------------------
TARGET_JSON=${JSON_FILES[$SLURM_ARRAY_TASK_ID]}

echo "Task $SLURM_ARRAY_TASK_ID: Running AlphaFold on $TARGET_JSON"

# -----------------------------
# Run AlphaFold
# -----------------------------
# --force_output_dir keeps AF3 from creating a timestamped duplicate directory
# when the target already exists (supported since 3.0.2). Drop it if you would
# rather have reruns land in a fresh <name>_YYYYMMDD_HHMMSS folder.
"$AF3_BIN" --json_path="$TARGET_JSON" \
    --model_dir=/tsl/industry/bioinformatics/af3weights \
    --db_dir=/nbi/Reference-Data/AlphaFold/db-v3.0.0 \
    --small_bfd_database_path=/nbi/Reference-Data/AlphaFold/db-v2.3.2/small_bfd/bfd-first_non_consensus_sequences.fasta \
    --mgnify_database_path=/nbi/Reference-Data/AlphaFold/db-v2.3.2/mgnify/mgy_clusters_2022_05.fa \
    --force_output_dir \
    --output_dir="${OUTPUT_DIR}"

AF3_EXIT=$?

# Only continue if AlphaFold succeeded, so we never score/compress a broken run.
if [ $AF3_EXIT -ne 0 ]; then
    echo "AlphaFold exited with code $AF3_EXIT for $TARGET_JSON — skipping ipSAE + compression."
    exit $AF3_EXIT
fi

# -----------------------------
# Locate this task's output directory
# -----------------------------
# AF3 appends fold_input.sanitised_name() to --output_dir. IMPORTANT: 3.0.1
# lowercased that name, 3.0.2+ PRESERVES CASE — the old script's lowercasing
# meant TASK_OUT was never found for any job name containing capitals, and the
# whole ipSAE + compression block was skipped with a warning. We now generate
# both candidates and fall back to a glob.
read -r SUBDIR_CASE SUBDIR_LOWER < <(python3 -c '
import json, string, sys
name = json.load(open(sys.argv[1]))["name"]
spaceless = name.replace(" ", "_")
keep_case = set(string.ascii_letters + string.digits + "_-.")
keep_low  = set(string.ascii_lowercase + string.digits + "_-.")
print("".join(c for c in spaceless if c in keep_case),
      "".join(c for c in spaceless.lower() if c in keep_low))
' "$TARGET_JSON")

TASK_OUT=""
for cand in "$SUBDIR_CASE" "$SUBDIR_LOWER"; do
    [ -n "$cand" ] && [ -d "${OUTPUT_DIR}/${cand}" ] && { TASK_OUT="${OUTPUT_DIR}/${cand}"; break; }
done
if [ -z "$TASK_OUT" ]; then
    # Last resort: newest dir whose name starts with the sanitised name
    # (covers AF3's <name>_YYYYMMDD_HHMMSS duplicate-output behaviour).
    TASK_OUT=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -iname "${SUBDIR_CASE}*" -printf '%T@ %p\n' 2>/dev/null \
               | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [ -z "$TASK_OUT" ] || [ ! -d "$TASK_OUT" ]; then
    echo "WARNING: no output dir for '$SUBDIR_CASE' under $OUTPUT_DIR — skipping ipSAE + compression."
    exit 0
fi

SUBDIR=$(basename "$TASK_OUT")
echo "Output directory: $TASK_OUT"

# =============================================================================
# ipSAE scoring   (must run BEFORE compression)
# =============================================================================
# Mirrors the GCloud pipeline:
#   * IPSAE_MODE=all scores EVERY diffusion sample (seed-<S>_sample-<N>/model.cif).
#     The top-level <job>_model.cif is a byte-duplicate of the best sample, so it
#     is skipped; <job>_ranking_scores.csv is copied across instead so you can
#     tell which sample was ranked best.
#   * Results are collected one folder per job:
#       <output>/ipsae_scores/<job_name>/seed-1_sample-0_10_10.txt
#                                        seed-1_sample-0_10_10_byres.txt
#                                        seed-1_sample-0_10_10.pml
#                                        <job>_ranking_scores.csv
#     i.e. downstream aggregation globs ipsae_scores/*/*_10_10.txt
#   * ipSAE is non-fatal: anything that goes wrong here still lets the
#     prediction compress and the job exit 0. Failures are logged to
#     <output>/ipsae_failed.tsv.
# =============================================================================
if [ "$RUN_IPSAE" = true ]; then
    echo "───────────────────────────── ipSAE scoring ─────────────────────────────"
    IPSAE_DEST="${OUTPUT_DIR}/ipsae_scores/${SUBDIR}"
    IPSAE_FAILED_FILE="${OUTPUT_DIR}/ipsae_failed.tsv"

    log_ipsae_failure() {
        [ -f "$IPSAE_FAILED_FILE" ] || echo -e "job_num\toutput_name\treason" > "$IPSAE_FAILED_FILE"
        ( flock -x 200; echo -e "${SLURM_ARRAY_TASK_ID}\t${SUBDIR}\t$1" >> "$IPSAE_FAILED_FILE" ) \
            200>"${IPSAE_FAILED_FILE}.lock"
    }

    # --- pick an interpreter that can actually import numpy --------------------
    if [ -z "$IPSAE_PYTHON" ]; then
        CANDIDATES=()
        # AF3's own interpreter, taken from run_alphafold.py's shebang and from
        # the bin/ dir next to it — these definitely have numpy.
        if [ -f "$AF3_BIN" ]; then
            SB=$(head -1 "$AF3_BIN" | sed -e 's/^#!//' -e 's/^[[:space:]]*//')
            case "$SB" in
                */env\ *) CANDIDATES+=("$(echo "$SB" | awk '{print $2}')") ;;
                /*)       CANDIDATES+=("$(echo "$SB" | awk '{print $1}')") ;;
            esac
            CANDIDATES+=("$(dirname "$AF3_BIN")/python3" "$(dirname "$AF3_BIN")/python")
        fi
        CANDIDATES+=("python3" "python")
        for c in "${CANDIDATES[@]}"; do
            [ -n "$c" ] || continue
            command -v "$c" >/dev/null 2>&1 || continue
            if "$c" -c 'import numpy' >/dev/null 2>&1; then IPSAE_PYTHON="$c"; break; fi
        done
    fi

    if [ ! -f "$IPSAE_SCRIPT" ]; then
        echo "  SKIP: ipsae.py not found at $IPSAE_SCRIPT"
        log_ipsae_failure "no_ipsae_script"
    elif [ -z "$IPSAE_PYTHON" ]; then
        echo "  SKIP: no interpreter with numpy found (tried: ${CANDIDATES[*]})."
        echo "        Set AF3_PYTHON=/path/to/python before sbatch, or load a python module."
        log_ipsae_failure "no_numpy_python"
    else
        mkdir -p "$IPSAE_DEST"
        P2=$(printf '%02d' "$IPSAE_PAE"); D2=$(printf '%02d' "$IPSAE_DIST")

        # --- build the list of (confidences.json, model.cif, tag) triples ------
        CONFS=(); CIFS=(); TAGS=(); SOURCE="seed/sample models"
        if [ "$IPSAE_MODE" = all ]; then
            for MD in "$TASK_OUT"/seed-*_sample-*/; do
                [ -d "$MD" ] || continue
                if [ -f "${MD}model.cif" ] && [ -f "${MD}confidences.json" ]; then
                    CIFS+=("${MD}model.cif")
                    CONFS+=("${MD}confidences.json")
                    TAGS+=("$(basename "${MD%/}")")
                fi
            done
        fi
        if [ ${#CIFS[@]} -eq 0 ]; then
            # top mode, or no per-sample dirs: score the top-level model.
            SOURCE="top-level model"
            TOP_CIF=$(find "$TASK_OUT" -maxdepth 1 -name "*_model.cif" -type f | head -1)
            TOP_CONF=$(find "$TASK_OUT" -maxdepth 1 -name "*_confidences.json" ! -name "*summary*" -type f | head -1)
            if [ -n "$TOP_CIF" ] && [ -n "$TOP_CONF" ]; then
                CIFS+=("$TOP_CIF"); CONFS+=("$TOP_CONF")
                TAGS+=("$(basename "$TOP_CIF" .cif)")
            fi
        fi

        echo "  Interpreter:     $IPSAE_PYTHON"
        echo "  Complex:         $SUBDIR"
        echo "  Mode:            $IPSAE_MODE ($SOURCE)"
        echo "  Models to score: ${#CIFS[@]}"
        echo "  Destination:     $IPSAE_DEST"

        if [ ${#CIFS[@]} -eq 0 ]; then
            echo "  WARNING: no model files found under $TASK_OUT — nothing to score."
            log_ipsae_failure "no_models"
        else
            N_OK=0; N_FILES=0
            for i in "${!CIFS[@]}"; do
                MD=$(dirname "${CIFS[$i]}")
                STEM=$(basename "${CIFS[$i]}" .cif)
                TAG="${TAGS[$i]}"

                if "$IPSAE_PYTHON" "$IPSAE_SCRIPT" "${CONFS[$i]}" "${CIFS[$i]}" "$IPSAE_PAE" "$IPSAE_DIST"; then
                    N_OK=$((N_OK + 1))
                else
                    echo "  WARNING: ipSAE failed on ${CIFS[$i]}"
                    log_ipsae_failure "ipsae_error"
                    continue
                fi

                # ipsae.py writes <model_stem>_<pae>_<dist>{.txt,_byres.txt,.pml}
                # next to the structure. Collect them into the per-job folder,
                # prefixed with seed-<S>_sample-<N> so samples don't collide.
                shopt -s nullglob
                for f in "${MD}/${STEM}"*"_${P2}_${D2}"*; do
                    base=$(basename "$f")
                    suffix="${base#${STEM}}"                 # e.g. _10_10.txt
                    if [ "$TAG" = "$STEM" ]; then
                        dest="${IPSAE_DEST}/${base}"         # top-level model
                    else
                        dest="${IPSAE_DEST}/${TAG}${suffix}" # seed-1_sample-0_10_10.txt
                    fi
                    cp -f "$f" "$dest" && N_FILES=$((N_FILES + 1))
                done
                shopt -u nullglob
            done

            # Ranking table identifies which sample the top-level model is.
            for rk in "$TASK_OUT"/*_ranking_scores.csv "$TASK_OUT"/ranking_scores.csv; do
                [ -f "$rk" ] && cp -f "$rk" "$IPSAE_DEST/"
            done

            echo "  ipSAE succeeded on $N_OK / ${#CIFS[@]} model(s); copied $N_FILES file(s) to ipsae_scores/${SUBDIR}/"
            if [ "$N_OK" -eq 0 ]; then
                echo "  WARNING: ipSAE produced nothing — check the traceback above."
            elif [ "$N_FILES" -eq 0 ]; then
                echo "  WARNING: ipsae.py exited 0 but wrote no *_${P2}_${D2}* files where expected."
                log_ipsae_failure "no_output_files"
            fi
        fi
    fi
fi

# -----------------------------
# Compress this task's output into a single .tar.gz
# -----------------------------
echo "Compressing $TASK_OUT into a single archive"
ARCHIVE="${OUTPUT_DIR}/${SUBDIR}.tar.gz"

# One archive of this task's own directory (concurrency-safe: only $SUBDIR is
# read, never the shared parent). pigz for multi-core, gzip fallback.
if command -v pigz >/dev/null 2>&1; then
    tar -cf - -C "${OUTPUT_DIR}" "${SUBDIR}" | pigz -p "${SLURM_CPUS_PER_TASK:-8}" > "$ARCHIVE"
    TAR_EXIT=${PIPESTATUS[0]}; GZ_EXIT=${PIPESTATUS[1]}
else
    tar -czf "$ARCHIVE" -C "${OUTPUT_DIR}" "${SUBDIR}"
    TAR_EXIT=$?; GZ_EXIT=0
fi

if [ $TAR_EXIT -ne 0 ] || [ $GZ_EXIT -ne 0 ] || [ ! -s "$ARCHIVE" ]; then
    echo "ERROR: archiving failed (tar=$TAR_EXIT gzip=$GZ_EXIT) — leaving '$TASK_OUT' intact."
    rm -f "$ARCHIVE"
    exit 1
fi

# Verify the archive is readable before deleting the only copy of the data.
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    echo "ERROR: archive '$ARCHIVE' failed integrity check — leaving '$TASK_OUT' intact."
    exit 1
fi

if [ "$REMOVE_DIR_AFTER_TAR" = true ]; then
    rm -rf "$TASK_OUT"
    echo "Done: created $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)); removed original directory"
else
    echo "Done: created $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)); kept original directory"
fi
