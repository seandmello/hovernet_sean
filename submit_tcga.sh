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
#        N_SLIDES=all bash submit_tcga.sh           (every candidate slide, no sampling)
#        REQUIRE_LW=1 bash submit_tcga.sh           (only slides that have a harm10
#            local-window map, i.e. the DX slides the protein maps were made from;
#            searches all of $TCGA_ROOT/<COHORT>/slides, or SLIDE_SEARCH="dir1 dir2";
#            sample file <COHORT>_lw_selected<N>.txt; cohorts without maps are skipped)

COHORTS=${@:-TCGA-BLCA TCGA-BRCA TCGA-GBM TCGA-HNSC TCGA-KIRC TCGA-LUAD TCGA-OV TCGA-UCEC}
N_SLIDES=${N_SLIDES:-150}
SEED=${SEED:-42}
SLIDES_PER_TASK=${SLIDES_PER_TASK:-10}
TCGA_ROOT=/cluster/projects/kumargroup/hayden/data/TCGA
OUT_ROOT=/cluster/projects/kumargroup/sean/hovernet/output
TODO_DIR=/cluster/projects/kumargroup/sean/hovernet/todo

cd "$(dirname "$0")"
mkdir -p logs "$TODO_DIR"

# fail here, not in every array task, if the job's conda env is broken
if [ -z "$DRY_RUN" ]; then
    source ~/miniforge3/etc/profile.d/conda.sh
    if ! conda run -n "${CONDA_ENV:-hovernet}" python -c "import cv2, torch, openslide, scipy, skimage" ; then
        echo "conda env '${CONDA_ENV:-hovernet}' is missing packages (see error above); not submitting" >&2
        exit 1
    fi
fi

LW_BASE=/cluster/projects/kumargroup/sean/results/05-inference
lw_dir_for () {  # TCGA cohort -> local-window windows/ dir (harm10 bfep r1.5)
    local ct
    case "$1" in
        TCGA-KIRC) ct=CCRCC ;; TCGA-HNSC) ct=HNSCC ;; TCGA-LUSC) ct=LSCC ;; TCGA-PAAD) ct=PDA ;;
        *) ct=${1#TCGA-} ;;
    esac
    echo "$LW_BASE/${ct,,}_spatial_neighbourhoods/harm10_bfep_r1.5/local_window/${ct}_TCGA/windows"
}

list_slides () {  # $1 = cohort; all candidate .svs paths, one per line
    if [ -n "$REQUIRE_LW" ]; then
        local lw; lw=$(lw_dir_for "$1")
        # slides may sit in per-file (GDC UUID) subfolders anywhere under slides/
        find -L ${SLIDE_SEARCH:-$TCGA_ROOT/$1/slides} -type f -name '*.svs' 2>/dev/null \
            | awk -v lw="$lw" 'BEGIN { while ((("ls " lw) | getline f) > 0) { sub(/\.npz$/, "", f); want[f] } }
                               { f = $0; sub(/.*\//, "", f); sub(/\.svs$/, "", f); if ((f in want) && !(f in seen)) { seen[f]; print } }'
    else
        find -L "$TCGA_ROOT/$1/slides/raw" -type f -name '*.svs' 2>/dev/null
    fi
}

for c in $COHORTS; do
    selected="$TODO_DIR/${c}${REQUIRE_LW:+_lw}_selected${N_SLIDES}.txt"
    if [ -n "$REQUIRE_LW" ] && [ ! -d "$(lw_dir_for "$c")" ]; then
        echo "$c: no local-window maps ($(lw_dir_for "$c")), skipping"
        continue
    fi

    if [ ! -s "$selected" ]; then
        list_slides "$c" | sort \
            | shuf --random-source=<(yes "$SEED" 2>/dev/null) \
            | awk -v n="$([ "$N_SLIDES" = all ] && echo 1000000000 || echo "$N_SLIDES")" '
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
        n_all=$(list_slides "$c" | wc -l)
        n_dx=$(grep -c -- '-DX' "$selected")
        n_pat=$(sed 's#.*/##' "$selected" | cut -c1-12 | sort -u | wc -l)
        echo "$c: selected $(wc -l < "$selected") of $n_all slides ($n_dx DX, $n_pat patients) -> $selected"
        if [ ! -s "$selected" ]; then
            echo "$c: no .svs found${REQUIRE_LW:+ that match a local-window map}" >&2
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
