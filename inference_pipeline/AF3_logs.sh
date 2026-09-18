#!/bin/bash
#===============================================================================
# AF3_logs.sh — find, read and clean up AF3 run logs
#===============================================================================
# Logs live one directory per run under $AF3_LOG_ROOT:
#
#   <kind>_<batch>_<timestamp>/
#     submit.log | controller.log    what was submitted / the chunk loop
#     tasks.tsv                      one row per task: id, state, exit, seconds
#     tasks/<arrayjob>_<task>.log    full stdout+stderr for one task
#
# Usage:
#   bash AF3_logs.sh list                     runs, newest first
#   bash AF3_logs.sh summary <run>            pass/fail counts for one run
#   bash AF3_logs.sh failed  <run>            failed tasks and their exit codes
#   bash AF3_logs.sh show    <run> <task_id>  full log for one task
#   bash AF3_logs.sh tail    <run>            follow the controller/submit log
#   bash AF3_logs.sh prune   --older-than <N days> [--yes]
#
# <run> may be the directory name or a unique fragment of it.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

[[ -d "$AF3_LOG_ROOT" ]] || af3_die "no log root at $AF3_LOG_ROOT (nothing run yet?)"

# Resolve a run fragment to exactly one directory.
resolve_run() {
    local frag="$1" matches
    [[ -d "${AF3_LOG_ROOT}/${frag}" ]] && { echo "${AF3_LOG_ROOT}/${frag}"; return; }
    mapfile -t matches < <(find "$AF3_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -name "*${frag}*" | sort)
    case ${#matches[@]} in
        0) af3_die "no run matching '$frag' in $AF3_LOG_ROOT" ;;
        1) echo "${matches[0]}" ;;
        *) echo "Multiple runs match '$frag':" >&2
           printf '  %s\n' "${matches[@]##*/}" >&2
           exit 1 ;;
    esac
}

cmd_list() {
    printf '%-46s %8s %8s %6s %s\n' RUN TASKS FAILED SIZE MODIFIED
    while IFS= read -r d; do
        local_tsv="${d}/tasks.tsv"
        n=0; f=0
        if [[ -f "$local_tsv" ]]; then
            n=$(( $(wc -l < "$local_tsv") - 1 ))
            f=$(awk -F'\t' 'NR>1 && $2=="FAIL"' "$local_tsv" | wc -l)
        fi
        printf '%-46s %8s %8s %6s %s\n' \
            "$(basename "$d")" "$n" "$f" \
            "$(du -sh "$d" 2>/dev/null | cut -f1)" \
            "$(date -r "$d" '+%Y-%m-%d %H:%M')"
    done < <(find "$AF3_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
}

cmd_summary() {
    local run; run=$(resolve_run "$1")
    echo "Run:  $run"
    [[ -f "${run}/submit.log" ]] && { echo "---"; cat "${run}/submit.log"; echo "---"; }
    local tsv="${run}/tasks.tsv"
    if [[ ! -f "$tsv" ]]; then
        echo "No tasks.tsv yet — nothing has finished."
        echo "Task logs present: $(find "${run}/tasks" -type f -name '*.log' 2>/dev/null | wc -l)"
        return 0
    fi
    awk -F'\t' 'NR>1 {n++; if($2=="FAIL") f++; s+=$4}
        END {printf "Tasks:    %d\nFailed:   %d\nOK:       %d\nMean time: %.0f s\n",
             n, f+0, n-(f+0), (n? s/n : 0)}' "$tsv"
}

cmd_failed() {
    local run; run=$(resolve_run "$1")
    local tsv="${run}/tasks.tsv"
    [[ -f "$tsv" ]] || af3_die "no tasks.tsv in $run"
    local n; n=$(awk -F'\t' 'NR>1 && $2=="FAIL"' "$tsv" | wc -l)
    if [[ $n -eq 0 ]]; then echo "No failed tasks recorded in $(basename "$run")."; return 0; fi
    echo "Failed tasks in $(basename "$run"): $n"
    echo ""
    printf '%-10s %-10s %-10s %s\n' TASK EXIT ELAPSED DETAIL
    awk -F'\t' 'NR>1 && $2=="FAIL" {printf "%-10s %-10s %-10s %s\n", $1, $3, $4, $5}' "$tsv"
    echo ""
    echo "Read one with:  bash AF3_logs.sh show $(basename "$run") <TASK>"
    echo ""
    echo "NOTE: tasks killed by SLURM (OOM, timeout, node failure) never reach"
    echo "      the summary step and so are absent here. Cross-check with:"
    echo "        sacct -j <jobid> --format=JobID,State,ExitCode,Reason,MaxRSS"
}

cmd_show() {
    local run task; run=$(resolve_run "$1"); task="$2"
    local hit
    hit=$(grep -rl "^Task ID:  *${task}\b\|Inference — Task ${task}$\|Data Pipeline — Task ${task}$" \
          "${run}/tasks" 2>/dev/null | head -1 || true)
    if [[ -z "$hit" ]]; then
        hit=$(find "${run}/tasks" -name "*_${task}.log" -type f | head -1 || true)
    fi
    [[ -n "$hit" ]] || af3_die "no log found for task $task in $(basename "$run")"
    echo "── $hit ──"
    cat "$hit"
}

cmd_tail() {
    local run; run=$(resolve_run "$1")
    local f="${run}/controller.log"
    [[ -f "$f" ]] || f="${run}/submit.log"
    [[ -f "$f" ]] || af3_die "no controller.log or submit.log in $(basename "$run")"
    tail -f "$f"
}

cmd_prune() {
    local days="" assume_yes=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --older-than) days="$2"; shift 2 ;;
            --yes|-y)     assume_yes=true; shift ;;
            *) af3_die "unknown option: $1" ;;
        esac
    done
    [[ -n "$days" ]] || af3_die "--older-than <days> is required"

    mapfile -t victims < <(find "$AF3_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" | sort)
    if [[ ${#victims[@]} -eq 0 ]]; then
        echo "Nothing older than ${days} days in $AF3_LOG_ROOT"
        return 0
    fi

    echo "Runs older than ${days} days:"
    for v in "${victims[@]}"; do
        printf '  %-46s %s\n' "$(basename "$v")" "$(du -sh "$v" 2>/dev/null | cut -f1)"
    done
    echo ""
    echo "Total: $(du -shc "${victims[@]}" 2>/dev/null | tail -1 | cut -f1)"

    if ! $assume_yes; then
        echo ""
        echo "Dry run. Re-run with --yes to delete."
        return 0
    fi
    rm -rf "${victims[@]}"
    echo "Deleted ${#victims[@]} run(s)."
}

[[ $# -eq 0 ]] && { sed -n '3,25p' "$0" | sed 's/^# \?//'; exit 1; }
SUB="$1"; shift
case "$SUB" in
    list)      cmd_list "$@" ;;
    summary)   [[ $# -ge 1 ]] || af3_die "usage: summary <run>"; cmd_summary "$1" ;;
    failed)    [[ $# -ge 1 ]] || af3_die "usage: failed <run>"; cmd_failed "$1" ;;
    show)      [[ $# -ge 2 ]] || af3_die "usage: show <run> <task_id>"; cmd_show "$1" "$2" ;;
    tail)      [[ $# -ge 1 ]] || af3_die "usage: tail <run>"; cmd_tail "$1" ;;
    prune)     cmd_prune "$@" ;;
    --help|-h) sed -n '3,25p' "$0" | sed 's/^# \?//' ;;
    *) af3_die "unknown subcommand: $SUB" ;;
esac
