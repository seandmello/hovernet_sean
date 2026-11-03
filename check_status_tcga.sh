#!/bin/bash
# Progress of HoVer-Net WSI inference on the selected TCGA slides.
#   bash check_status_tcga.sh [TCGA-BRCA ...]

COHORTS=${@:-TCGA-BLCA TCGA-BRCA TCGA-GBM TCGA-HNSC TCGA-KIRC TCGA-LUAD TCGA-OV TCGA-UCEC}
N_SLIDES=${N_SLIDES:-150}
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
TODO_DIR=/cluster/projects/kumargroup/sean/hovernet/todo
cd "$(dirname "$0")"

printf "%-10s %6s %9s %6s %8s\n" cohort done selected left crashes
for c in $COHORTS; do
    selected="$TODO_DIR/${c}_selected${N_SLIDES}.txt"
    total=$(cat "$selected" 2>/dev/null | wc -l)
    done_n=0
    if [ -s "$selected" ]; then
        while read -r slide; do
            [ -e "$OUT_ROOT/$c/json/$(basename "$slide" .svs).json" ] && done_n=$((done_n + 1))
        done < "$selected"
    fi
    crashes=$(cat logs/hovernet_${c}_*.err 2>/dev/null | grep -c Crash)
    printf "%-10s %6d %9d %6d %8d\n" $c $done_n $total $((total - done_n)) $crashes
done

echo
echo "== jobs"
squeue -u $USER -o "%.18i %.20j %.3t %.10M %.12L %R" | grep -E "JOBID|hovernet_TCGA"

echo
echo "== empty or tiny JSONs (likely broken)"
find "$OUT_ROOT"/TCGA-*/json -name '*.json' -size -10k 2>/dev/null | head
