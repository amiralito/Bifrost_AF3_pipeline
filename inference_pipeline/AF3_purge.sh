#!/bin/bash
#SBATCH --job-name=purge
#SBATCH --partition=datac3
#SBATCH --cpus-per-task=8
#SBATCH --mem=4G
#SBATCH --time=12:00:00

#===============================================================================
# AF3_purge.sh — delete large directories in the background, fast
#===============================================================================
# rm -rf on NFS/Filestore is round-trip bound: one unlink RPC per file, issued
# serially. This script instead
#   1. renames the target out of the way (instant, same filesystem), so you get
#      the name back immediately and nothing new lands in a directory that is
#      being deleted;
#   2. unlinks files in parallel with xargs -P;
#   3. removes the empty directory skeleton depth-first.
#
# Typical speedup on Filestore is large, but it is still I/O bound — millions
# of files take a while. That is what the batch job is for.
#
# USAGE — dry run first (this is the default):
#   sbatch AF3_purge.sh --path ~/slurm_logs
#   bash   AF3_purge.sh --path ~/slurm_logs            # counts, then exits
#
# To actually delete, add --yes:
#   sbatch AF3_purge.sh --path ~/slurm_logs --yes
#
# Runs on the CPU partition (datac3). SLURM directives cannot read shell
# variables, so the partition is hardcoded above rather than taken from
# af3_env.sh. Override at submit time without editing the file:
#   sbatch --partition=<other> AF3_purge.sh --path <dir> --yes
#
# Job output goes to slurm-<jobid>.out in the directory you submit from,
# since this script is standalone and does not use the AF3 run-log layout.
#
# Options:
#   --path <dir>     directory to delete (repeatable)
#   --yes            actually delete; without this it only counts
#   --jobs <n>       parallel unlink workers (default: cpus-per-task)
#   --keep-root      empty the directory but keep the directory itself
#   --no-rename      delete in place instead of renaming first
#                    (use when the parent is not writable)
#
# SAFETY: refuses /, $HOME, /af3data, /opt, /mnt and other roots; refuses
# anything that is not a directory; refuses symlinks; requires --yes.
#===============================================================================

set -uo pipefail

PATHS=()
CONFIRM=false
KEEP_ROOT=false
RENAME=true
JOBS="${SLURM_CPUS_PER_TASK:-8}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --path)       PATHS+=("$2"); shift 2 ;;
        --yes|-y)     CONFIRM=true; shift ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --keep-root)  KEEP_ROOT=true; shift ;;
        --no-rename)  RENAME=false; shift ;;
        --help|-h)    sed -n '7,47p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ ${#PATHS[@]} -eq 0 ]] && { echo "ERROR: --path is required" >&2; exit 1; }

# ── Refuse to delete anything structurally important ─────────────────────────
PROTECTED=(
    / /home /root /usr /var /etc /opt /mnt /tmp /boot /dev /proc /sys
    "$HOME" /af3data /af3data/containers "${AF3_LOG_ROOT:-/af3data/af3_logs}"
)

validate() {
    local p="$1" real parent

    [[ -e "$p" ]] || { echo "  SKIP (does not exist): $p" >&2; return 1; }
    if [[ -L "$p" ]]; then
        echo "  REFUSE (symlink — delete the target explicitly): $p" >&2
        return 1
    fi
    [[ -d "$p" ]] || { echo "  REFUSE (not a directory): $p" >&2; return 1; }

    real=$(readlink -f "$p") || { echo "  REFUSE (cannot resolve): $p" >&2; return 1; }

    for prot in "${PROTECTED[@]}"; do
        if [[ "$real" == "$(readlink -f "$prot" 2>/dev/null)" ]]; then
            echo "  REFUSE (protected path): $real" >&2
            return 1
        fi
    done

    # Depth guard: /a/b is 2 components. Require at least 3 to avoid
    # top-level mistakes like /af3data or /home/user.
    local depth
    depth=$(awk -F/ '{c=0; for(i=1;i<=NF;i++) if($i!="") c++; print c}' <<< "$real")
    if [[ $depth -lt 3 ]]; then
        echo "  REFUSE (too close to filesystem root, depth $depth): $real" >&2
        return 1
    fi

    parent=$(dirname "$real")
    if $RENAME && [[ ! -w "$parent" ]]; then
        echo "  NOTE: parent not writable, will delete in place: $parent" >&2
        RENAME=false
    fi

    echo "$real"
    return 0
}

echo "==============================================================================="
echo "AF3 purge"
echo "==============================================================================="
echo "Started:   $(date)"
echo "Host:      $(hostname)"
echo "Workers:   $JOBS"
echo "Mode:      $($CONFIRM && echo 'DELETE' || echo 'dry run (add --yes to delete)')"
echo ""

# ── Validate everything before touching anything ─────────────────────────────
TARGETS=()
for p in "${PATHS[@]}"; do
    echo "Checking: $p"
    if real=$(validate "$p") && [[ -d "$real" ]]; then
        TARGETS+=("$real")
        echo "  OK: $real"
    fi
done

[[ ${#TARGETS[@]} -eq 0 ]] && { echo ""; echo "Nothing to do."; exit 1; }

# ── Report size ──────────────────────────────────────────────────────────────
echo ""
echo "── Contents ─────────────────────────────────────────────────────────────────"
TOTAL_FILES=0
for t in "${TARGETS[@]}"; do
    n=$(find "$t" -type f 2>/dev/null | wc -l)
    d=$(find "$t" -type d 2>/dev/null | wc -l)
    sz=$(du -sh "$t" 2>/dev/null | cut -f1)
    TOTAL_FILES=$((TOTAL_FILES + n))
    printf '  %-50s %8s files, %6s dirs, %6s\n' "$t" "$n" "$d" "$sz"
done
echo ""
echo "  Total files to unlink: $TOTAL_FILES"

if ! $CONFIRM; then
    echo ""
    echo "Dry run — nothing deleted."
    echo "Re-run with --yes to delete:"
    echo "  sbatch $0 $(printf -- '--path %q ' "${PATHS[@]}")--yes"
    exit 0
fi

# ── Delete ───────────────────────────────────────────────────────────────────
START=$(date +%s)
FAILED=0

for t in "${TARGETS[@]}"; do
    echo ""
    echo "── Purging $t ───────────────────────────────────────────────────────────"
    work="$t"

    # Rename first: instant on the same filesystem, frees the name immediately
    # and stops anything writing into a directory mid-deletion.
    if $RENAME && ! $KEEP_ROOT; then
        work="${t}.purging.$$"
        if mv "$t" "$work" 2>/dev/null; then
            echo "  Renamed to $(basename "$work") — original name is free now"
        else
            echo "  Rename failed, deleting in place"
            work="$t"
        fi
    fi

    # Parallel unlink. -print0/-0 handles any filename; -n 500 amortises exec
    # cost; -P runs several rm processes so unlink RPCs overlap.
    echo "  Unlinking files with $JOBS workers..."
    find "$work" -type f -print0 2>/dev/null \
        | xargs -0 -r -n 500 -P "$JOBS" rm -f 2>/dev/null
    find "$work" -type l -print0 2>/dev/null \
        | xargs -0 -r -n 500 -P "$JOBS" rm -f 2>/dev/null

    # Remove the directory skeleton depth-first (cheap once files are gone).
    echo "  Removing directory tree..."
    find "$work" -depth -type d -empty -delete 2>/dev/null

    # Anything left (odd file types, races) gets a conventional sweep.
    if [[ -e "$work" ]]; then
        rm -rf "$work" 2>/dev/null
    fi

    if [[ -e "$work" ]]; then
        echo "  WARNING: $work still exists — check permissions"
        FAILED=$((FAILED + 1))
    else
        echo "  Done"
    fi

    if $KEEP_ROOT; then
        mkdir -p "$t" && echo "  Recreated empty $t"
    fi
done

ELAPSED=$(($(date +%s) - START))
echo ""
echo "==============================================================================="
printf 'Purge finished in %dh %02dm %02ds\n' \
    $((ELAPSED / 3600)) $(((ELAPSED % 3600) / 60)) $((ELAPSED % 60))
[[ $TOTAL_FILES -gt 0 && $ELAPSED -gt 0 ]] \
    && echo "Throughput: ~$((TOTAL_FILES / ELAPSED)) files/s"
echo "Failures:   $FAILED"
echo "Finished:   $(date)"
echo "==============================================================================="

exit $FAILED
