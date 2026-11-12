#!/bin/bash
# Progress of HoVer-Net WSI inference on the selected TCGA slides.
#   bash check_status_tcga.sh [TCGA-BRCA ...]
#   N_SLIDES=all bash check_status_tcga.sh    (match the N_SLIDES / REQUIRE_LW
#                                              used with submit_tcga.sh)

COHORTS=${@:-TCGA-BLCA TCGA-BRCA TCGA-GBM TCGA-HNSC TCGA-KIRC TCGA-LUAD TCGA-OV TCGA-UCEC}
N_SLIDES=${N_SLIDES:-150}
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
TODO_DIR=/cluster/projects/kumargroup/sean/hovernet/todo
cd "$(dirname "$0")"

printf "%-10s %6s %9s %6s %8s %8s %4s %4s  %s\n" cohort done selected left crashes done/24h run pend ETA
for c in $COHORTS; do
    selected="$TODO_DIR/${c}${REQUIRE_LW:+_lw}_selected${N_SLIDES}.txt"
    total=$(cat "$selected" 2>/dev/null | wc -l)
    done_n=0
    recent=0
    if [ -s "$selected" ]; then
        while read -r slide; do
            json="$OUT_ROOT/$c/json/$(basename "$slide" .svs).json"
            if [ -e "$json" ]; then
                done_n=$((done_n + 1))
                [ -n "$(find "$json" -mmin -1440)" ] && recent=$((recent + 1))
            fi
        done < "$selected"
    fi
    left=$((total - done_n))
    crashes=$(cat logs/hovernet_${c}_*.err 2>/dev/null | grep -c Crash)
    running=$(squeue -h -u "$USER" -n "hovernet_$c" -t R 2>/dev/null | wc -l)
    pending=$(squeue -h -u "$USER" -n "hovernet_$c" -t PD -r 2>/dev/null | wc -l)
    if [ "$left" -eq 0 ]; then eta=done
    elif [ "$recent" -gt 0 ]; then eta=$(awk -v l=$left -v r=$recent 'BEGIN { printf "%.1fd", l / r }')
    else eta=-; fi
    printf "%-10s %6d %9d %6d %8d %8d %4d %4d  %s\n" $c $done_n $total $left $crashes $recent $running $pending $eta
done

echo
echo "ETA = left / slides finished in the last 24h, at the current number of GPUs"
echo
echo "== why pending"
squeue -h -u $USER -t PD -o "%j %R" | grep hovernet_TCGA | sort | uniq -c

echo
echo "== empty or tiny JSONs (likely broken)"
find "$OUT_ROOT"/TCGA-*/json -name '*.json' -size -10k 2>/dev/null | head
