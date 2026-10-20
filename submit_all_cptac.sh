#!/bin/bash
# Submit HoVer-Net WSI inference for every CPTAC cohort.
# Only slides without an output JSON are submitted; the list of remaining
# slides is fixed at submit time and split evenly across one job array per
# cohort, sized so each GPU task gets about SLIDES_PER_TASK slides.
# Rerun this after jobs time out to pick up whatever is left.
#
# usage: bash submit_all_cptac.sh                   (~10 slides per GPU task)
#        SLIDES_PER_TASK=5 bash submit_all_cptac.sh (more tasks in parallel)
#        MAX_PARALLEL=20 bash submit_all_cptac.sh   (cap running tasks per cohort)
#        bash submit_all_cptac.sh GBM LUAD          (only these cohorts)
#        FORCE=1 bash submit_all_cptac.sh           (submit even if jobs are queued)

COHORTS=${@:-CCRCC GBM HNSCC LSCC LUAD PDA UCEC}
SLIDES_PER_TASK=${SLIDES_PER_TASK:-10}
CPTAC_ROOT=/cluster/projects/kumargroup/hayden/data/CPTAC
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
TODO_DIR=/cluster/projects/kumargroup/sean/hovernet/todo

cd "$(dirname "$0")"
mkdir -p logs "$TODO_DIR"
for c in $COHORTS; do
    # queued/running tasks would be handed the same slides again
    if [ -z "$FORCE" ] && squeue -h -u "$USER" -n "hovernet_$c" | grep -q .; then
        echo "$c: hovernet_$c already queued/running, skipping (FORCE=1 to override)"
        continue
    fi

    src=$(ls -d "$CPTAC_ROOT"/CPTAC-$c/slides/raw_v*/$c 2>/dev/null | sort -V | tail -1)
    todo="$TODO_DIR/${c}_$(date +%Y%m%d_%H%M%S).txt"
    : > "$todo"
    for slide in "$src"/*.svs; do
        name=$(basename "$slide" .svs)
        [ -e "$OUT_ROOT/$c/json/$name.json" ] || echo "$slide" >> "$todo"
    done
    left=$(wc -l < "$todo")
    if [ "$left" -eq 0 ]; then
        echo "$c: done"
        rm -f "$todo"
        continue
    fi

    tasks=$(( (left + SLIDES_PER_TASK - 1) / SLIDES_PER_TASK ))
    array=0-$((tasks - 1))${MAX_PARALLEL:+%$MAX_PARALLEL}
    echo -n "$c: $left slides left -> $tasks tasks: "
    SLIDE_LIST="$todo" sbatch --array=$array --job-name=hovernet_$c run_wsi_cptac.sh $c
done
