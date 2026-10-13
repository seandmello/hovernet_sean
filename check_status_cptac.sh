#!/bin/bash
# Progress of HoVer-Net WSI inference for each CPTAC cohort.
# Run on a compute node if the login node can't see the output folder:
#   srun -p all --time=0:15:00 bash check_status_cptac.sh

COHORTS=${@:-CCRCC GBM HNSCC LSCC LUAD PDA UCEC}
CPTAC_ROOT=/cluster/projects/kumargroup/hayden/data/CPTAC
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
cd "$(dirname "$0")"

printf "%-6s %7s %7s %7s %8s %s\n" cohort done total left crashes slide_dir
for c in $COHORTS; do
    src=$(ls -d "$CPTAC_ROOT"/CPTAC-$c/slides/raw_v*/$c 2>/dev/null | sort -V | tail -1)
    total=$(ls "$src"/*.svs 2>/dev/null | wc -l)
    done_n=$(ls "$OUT_ROOT/$c/json" 2>/dev/null | wc -l)
    crashes=$(cat logs/hovernet_${c}_*.err 2>/dev/null | grep -c Crash)
    printf "%-6s %7d %7d %7d %8d %s\n" $c $done_n $total $((total - done_n)) $crashes "${src:-NOT FOUND}"
done

echo
echo "== jobs"
squeue -u $USER -o "%.18i %.20j %.3t %.10M %.12L %R" | grep -E "JOBID|hovernet"

echo
echo "== empty or tiny JSONs (likely broken)"
find "$OUT_ROOT"/*/json -name '*.json' -size -10k 2>/dev/null | head
