INPUT=$1
OUTPUT=$2

sbatch \
  --array=0-$(($(find "$INPUT" -type f -iname "*.json" | wc -l)-1)) \
  /tsl/scratch/toghani/AF3/scripts/AF3_default_new/AF3_array_job.sh "$INPUT" "$OUTPUT"