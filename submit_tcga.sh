#!/bin/bash
# Submit HoVer-Net WSI inference on a fixed sample of N_SLIDES (default 150)
# slides per TCGA cohort.
#
# The sample is drawn once per cohort and saved to
#   $TODO_DIR/<COHORT>_selected<N>.txt
# so reruns (e.g. after timeouts) keep working on the same slides. Selection:
#   - diagnostic FFPE slides (-DX in the name) before frozen sections (-TS/-BS)
#   - one slide per patient first, then extra slides of the same patients
#     only if the cohort has too few patients
#   - random order with a fixed seed (SEED, default 42)
# Delete the _selected file to draw a new sample.
#
# Only selected slides without an output JSON are submitted, split into job
# arrays of ~SLIDES_PER_TASK slides per GPU task (see run_wsi_cptac.sh).
# Output: /cluster/projects/kumargroup/sean/hovernet/output/<COHORT>/{json,thumb,mask}
#
# usage: bash submit_tcga.sh                        (default 8 cohorts)
#        bash submit_tcga.sh TCGA-BRCA TCGA-LUAD    (only these)
#        N_SLIDES=200 SLIDES_PER_TASK=5 MAX_PARALLEL=20 bash submit_tcga.sh
#        DRY_RUN=1 bash submit_tcga.sh              (select + report, no sbatch)
#        FORCE=1 bash submit_tcga.sh                (submit even if jobs are queued)

COHORTS=${@:-TCGA-BLCA TCGA-BRCA TCGA-GBM TCGA-HNSC TCGA-KIRC TCGA-LUAD TCGA-OV TCGA-UCEC}
N_SLIDES=${N_SLIDES:-150}
SEED=${SEED:-42}
SLIDES_PER_TASK=${SLIDES_PER_TASK:-10}
TCGA_ROOT=/cluster/projects/kumargroup/hayden/data/TCGA
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
TODO_DIR=/cluster/projects/kumargroup/sean/hovernet/todo

cd "$(dirname "$0")"
mkdir -p logs "$TODO_DIR"
for c in $COHORTS; do
    src="$TCGA_ROOT/$c/slides/raw"
    selected="$TODO_DIR/${c}_selected${N_SLIDES}.txt"

    if [ ! -s "$selected" ]; then
        # slides may sit directly in raw/ or in per-file (GDC UUID) subfolders
        find -L "$src" -type f -name '*.svs' 2>/dev/null | sort \
            | shuf --random-source=<(yes "$SEED") \
            | awk -v n="$N_SLIDES" '
                {
                    f = $0; sub(/.*\//, "", f)
                    pid = substr(f, 1, 12)              # TCGA-XX-XXXX
                    if (f ~ /-DX/) dx[++nd] = $0; else other[++no] = $0
                    pidof[$0] = pid
                }
                function pick(path) { if (k < n && !(path in used)) { used[path]; seen[pidof[path]]; print path; k++ } }
                END {
                    for (i = 1; i <= nd; i++) if (!(pidof[dx[i]] in seen)) pick(dx[i])
                    for (i = 1; i <= no; i++) if (!(pidof[other[i]] in seen)) pick(other[i])
                    for (i = 1; i <= nd; i++) pick(dx[i])
                    for (i = 1; i <= no; i++) pick(other[i])
                }' > "$selected"
        n_all=$(find -L "$src" -type f -name '*.svs' 2>/dev/null | wc -l)
        n_dx=$(grep -c -- '-DX' "$selected")
        n_pat=$(sed 's#.*/##' "$selected" | cut -c1-12 | sort -u | wc -l)
        echo "$c: selected $(wc -l < "$selected") of $n_all slides ($n_dx DX, $n_pat patients) -> $selected"
        if [ ! -s "$selected" ]; then
            echo "$c: no .svs found under $src" >&2
            rm -f "$selected"
            continue
        fi
    fi

    # queued/running tasks would be handed the same slides again
    if [ -z "$FORCE" ] && squeue -h -u "$USER" -n "hovernet_$c" 2>/dev/null | grep -q .; then
        echo "$c: hovernet_$c already queued/running, skipping (FORCE=1 to override)"
        continue
    fi

    todo="$TODO_DIR/${c}_$(date +%Y%m%d_%H%M%S).txt"
    : > "$todo"
    while read -r slide; do
        name=$(basename "$slide" .svs)
        [ -e "$OUT_ROOT/$c/json/$name.json" ] || echo "$slide" >> "$todo"
    done < "$selected"
    left=$(wc -l < "$todo")
    if [ "$left" -eq 0 ]; then
        echo "$c: done"
        rm -f "$todo"
        continue
    fi

    tasks=$(( (left + SLIDES_PER_TASK - 1) / SLIDES_PER_TASK ))
    array=0-$((tasks - 1))${MAX_PARALLEL:+%$MAX_PARALLEL}
    echo -n "$c: $left slides left -> $tasks tasks: "
    if [ -n "$DRY_RUN" ]; then
        echo "(dry run) sbatch --array=$array --job-name=hovernet_$c run_wsi_cptac.sh $c"
        rm -f "$todo"
        continue
    fi
    SLIDE_LIST="$todo" sbatch --array=$array --job-name=hovernet_$c run_wsi_cptac.sh $c
done
