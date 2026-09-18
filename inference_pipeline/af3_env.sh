#!/bin/bash
#===============================================================================
# af3_env.sh — central configuration for the AF3 pipeline
#===============================================================================
# Sourced by every job script. This is the ONLY place the container path,
# weights, databases and partitions are defined. To test a different image:
#
#   AF3_SIF=/opt/apps/af3/containers/af3.sif ./af3 screen ...
#
# Every value below can be overridden from the environment, which is what
# makes A/B testing old vs new containers a one-variable change.
#===============================================================================

# ── Container ────────────────────────────────────────────────────────────────
AF3_SIF="${AF3_SIF:-/af3data/containers/af3_3.0.4.sif}"

# ── Weights and databases (all external to the container) ────────────────────
AF3_MODEL_DIR="${AF3_MODEL_DIR:-/opt/apps/af3/models}"
AF3_DB_DIR="${AF3_DB_DIR:-/dev/shm/public_databases}"
AF3_PDB_DIR="${AF3_PDB_DIR:-/mnt/databases/v3.0/uncompressed/mmcif_files}"

# ── Partitions ───────────────────────────────────────────────────────────────
# Override AF3_GPU_PARTITION during an a2-ultra stockout if a fallback
# GPU partition exists, e.g. AF3_GPU_PARTITION=infa2 ./af3 screen ...
AF3_CPU_PARTITION="${AF3_CPU_PARTITION:-datac3}"
AF3_GPU_PARTITION="${AF3_GPU_PARTITION:-infa2u}"

# ── Logs ─────────────────────────────────────────────────────────────────────
# One directory per run: $AF3_LOG_ROOT/<kind>_<batch>_<timestamp>/
#   submit.log / controller.log   what was submitted, and the chunk loop
#   tasks/<arrayjob>_<task>.log   one file per task (stdout AND stderr)
#   tasks.tsv                     one summary row per task — grep this first
#
# Deliberately NOT under $HOME: home is small and a full filesystem makes
# SLURM fail tasks with no log at all, which is impossible to diagnose.
AF3_LOG_ROOT="${AF3_LOG_ROOT:-/af3data/af3_logs}"

# ── Where these scripts live ─────────────────────────────────────────────────
AF3_SCRIPT_DIR="${AF3_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# Exported so batch jobs can find af3_env.sh: SLURM runs the batch script from
# /var/spool/slurmd/job<id>/, where BASH_SOURCE is useless.
export AF3_SCRIPT_DIR

# Prefer v7 (adds --protomers-a/-b and --extra-chain) but fall back to v6, so
# the pipeline works whether or not the newer merge script has been copied
# over. v7 is a strict superset: with no new flags its output is byte-identical
# to v6's, including the manifest.
if [[ -z "${AF3_MERGE_SCRIPT:-}" ]]; then
    for _cand in merge_af3_multimer_v7.py merge_af3_multimer_v6.py; do
        if [[ -f "${AF3_SCRIPT_DIR}/${_cand}" ]]; then
            AF3_MERGE_SCRIPT="${AF3_SCRIPT_DIR}/${_cand}"
            break
        fi
    done
    # Nothing found: keep the v6 path so the error message names a real file.
    AF3_MERGE_SCRIPT="${AF3_MERGE_SCRIPT:-${AF3_SCRIPT_DIR}/merge_af3_multimer_v6.py}"
fi
AF3_IPSAE_SCRIPT="${AF3_IPSAE_SCRIPT:-${AF3_SCRIPT_DIR}/ipsae.py}"

# ── ipSAE scoring scope ──────────────────────────────────────────────────────
#   all  score every diffusion sample (seed-<S>_sample-<N>/), default
#   top  score only the top-ranked model at the top level (old behaviour)
# AF3 writes num_seeds x num_diffusion_samples models (5 samples per seed by
# default), so "all" produces 5x the ipSAE rows per job for one seed.
AF3_IPSAE_MODE="${AF3_IPSAE_MODE:-all}"

# ── Stoichiometry ────────────────────────────────────────────────────────────
# Copies of each chain in every complex. 1/1 reproduces the pairwise screen.
# Copies use AF3's native id-list syntax, so the MSA is searched once per
# entity no matter the copy number — but tokens, and therefore memory, scale
# with the total chain count.
AF3_PROTOMERS_A="${AF3_PROTOMERS_A:-1}"
AF3_PROTOMERS_B="${AF3_PROTOMERS_B:-1}"

# Constant chains added to EVERY job, space-separated, each PATH[:N].
# These do not multiply the job count.
AF3_EXTRA_CHAINS="${AF3_EXTRA_CHAINS:-}"

# ── ipSAE output layout ──────────────────────────────────────────────────────
#   job   ipsae_scores/<job_name>/...  one folder per job (default)
#   flat  ipsae_scores/...             everything in one directory
# Model filenames are unique either way; "job" just groups them.
AF3_IPSAE_LAYOUT="${AF3_IPSAE_LAYOUT:-job}"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Verify the container and weights are reachable. Databases live on the
# compute nodes (/dev/shm) so they are deliberately not checked here.
af3_env_check() {
    local fail=0
    if [[ ! -f "$AF3_SIF" ]]; then
        echo "ERROR: container not found: $AF3_SIF" >&2
        fail=1
    fi
    if [[ ! -d "$AF3_MODEL_DIR" ]]; then
        echo "ERROR: model directory not found: $AF3_MODEL_DIR" >&2
        fail=1
    fi
    return $fail
}

# Report the AlphaFold version inside the configured container.
af3_version() {
    apptainer exec "$AF3_SIF" python3 -c \
        "import importlib.metadata as m; print(m.version('alphafold3'))" 2>/dev/null \
        || echo "unknown"
}

# Print the resolved configuration (used by every script's banner).
af3_env_banner() {
    echo "Container:        $AF3_SIF"
    echo "Model dir:        $AF3_MODEL_DIR"
    echo "DB dir:           $AF3_DB_DIR"
    echo "PDB mmCIF dir:    $AF3_PDB_DIR"
}

#===============================================================================
# Shared helpers (used by the submit / status / resume scripts)
#===============================================================================

AF3_CONF_NAME=".af3_screen.conf"

af3_die() { echo "ERROR: $*" >&2; exit 1; }

af3_abspath() { (cd "$1" 2>/dev/null && pwd) || af3_die "directory not found: $1"; }

# Number of data rows in a screen's manifest.
af3_manifest_total() { echo $(( $(wc -l < "$1/manifest.tsv") - 1 )); }

# How many manifest rows have no archive on disk yet.
#   $1 = screen output dir
#   $2 = optional path to write the missing rows to (header preserved)
# Echoes the missing count.
#
# Naming note: with a single non-expanded seed the merge script appends
# _seed<N> to the archive name while the manifest row does not, so both forms
# are accepted here.
af3_count_missing() {
    local out_dir="$1" missing_file="${2:-}" manifest="$1/manifest.tsv"
    local n_missing=0 name

    [[ -f "$manifest" ]] || af3_die "no manifest.tsv in $out_dir — is this a screen output dir?"
    [[ -n "$missing_file" ]] && head -1 "$manifest" > "$missing_file"

    while IFS= read -r line; do
        name=$(awk -F'\t' '{print $NF}' <<< "$line")
        [[ -z "$name" ]] && continue
        if compgen -G "${out_dir}/${name}.tar.gz" > /dev/null \
        || compgen -G "${out_dir}/${name}_seed*.tar.gz" > /dev/null; then
            continue
        fi
        n_missing=$((n_missing + 1))
        [[ -n "$missing_file" ]] && printf '%s\n' "$line" >> "$missing_file"
    done < <(tail -n +2 "$manifest")

    echo "$n_missing"
}

# Count the JSON inputs in a chain directory EXACTLY as merge_af3_multimer_v6.py
# does (sorted rglob, recursive, follows symlinked dirs). Chain directories
# normally hold one data-pipeline output folder per protein, each containing a
# <name>_data.json, so a flat -maxdepth 1 count returns zero. Reimplementing
# this in bash risks disagreeing with the merge script's indexing, which would
# silently mis-pair chains.
af3_count_chain_json() {
    python3 -c '
import sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.is_file():
    print(1 if p.suffix.lower() == ".json" else 0)
elif p.is_dir():
    print(len(sorted(p.rglob("*.json"))))
else:
    print(0)
' "$1"
}

# First N chain inputs, relative to the chain dir — for submission previews.
af3_list_chain_json() {
    python3 -c '
import sys, pathlib
p, n = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for f in sorted(p.rglob("*.json"))[:n]:
    print(" ", f.relative_to(p))
' "$1" "${2:-5}"
}

# Create and echo a fresh run-log directory.
#   $1 = kind (msa|screen)   $2 = batch name
af3_new_log_dir() {
    local kind="$1" batch="$2" dir
    dir="${AF3_LOG_ROOT}/${kind}_${batch}_$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${dir}/tasks" || af3_die "cannot create log dir: $dir"
    echo "$dir"
}

# Append one row to a run's tasks.tsv, safe across concurrent array tasks.
#   $1 = log dir, $2 = task id, $3 = state, $4 = exit code,
#   $5 = elapsed seconds, $6 = name/detail
af3_log_task() {
    local dir="$1" f="$1/tasks.tsv"
    [[ -d "$dir" ]] || return 0
    [[ -f "$f" ]] || echo -e "task_id\tstate\texit_code\telapsed_s\tdetail" > "$f"
    (
        flock -x 200
        echo -e "${2}\t${3}\t${4}\t${5}\t${6}" >> "$f"
    ) 200>"${f}.lock"
}
