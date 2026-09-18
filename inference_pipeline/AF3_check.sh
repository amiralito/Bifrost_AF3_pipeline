#!/bin/bash
#===============================================================================
# AF3_check.sh — verify the container, weights and helper scripts
#===============================================================================
# Usage:
#   bash AF3_check.sh
#
# Override any setting from the environment, e.g. to inspect the old image:
#   AF3_SIF=/opt/apps/af3/containers/af3.sif bash AF3_check.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=af3_env.sh
source "${SCRIPT_DIR}/af3_env.sh"

echo "==============================================================================="
echo "AF3 environment"
echo "==============================================================================="
echo "Container:  $AF3_SIF"
af3_env_check || exit 1
echo "Version:    $(af3_version)"
echo "Entrypoint: $(apptainer exec "$AF3_SIF" wc -l /app/alphafold/run_alphafold.py | awk '{print $1}') lines"
echo "Models:     $AF3_MODEL_DIR ($(find "$AF3_MODEL_DIR" -maxdepth 1 -type f | wc -l) files)"
echo "DB dir:     $AF3_DB_DIR (checked on compute nodes only)"
echo "PDB mmCIF:  $AF3_PDB_DIR"
echo "Merge:      $AF3_MERGE_SCRIPT $([[ -f $AF3_MERGE_SCRIPT ]] && echo OK || echo MISSING)"
echo "ipSAE:      $AF3_IPSAE_SCRIPT $([[ -f $AF3_IPSAE_SCRIPT ]] && echo OK || echo MISSING)"
echo "ipSAE mode: $AF3_IPSAE_MODE (layout: $AF3_IPSAE_LAYOUT)"
echo "Partitions: cpu=$AF3_CPU_PARTITION gpu=$AF3_GPU_PARTITION"
echo "==============================================================================="
