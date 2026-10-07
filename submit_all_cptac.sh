#!/bin/bash
# Submit HoVer-Net WSI inference for every CPTAC cohort.
# Finished slides are skipped, so rerun this after jobs time out.
#
# usage: bash submit_all_cptac.sh            (10 GPUs per cohort)
#        ARRAY=0-19 bash submit_all_cptac.sh
#        bash submit_all_cptac.sh GBM LUAD    (only these cohorts)

COHORTS=${@:-CCRCC GBM HNSCC LSCC LUAD PDA UCEC}
ARRAY=${ARRAY:-0-9}

cd "$(dirname "$0")"
mkdir -p logs
for c in $COHORTS; do
    echo -n "$c: "
    sbatch --array=$ARRAY --job-name=hovernet_$c run_wsi_cptac.sh $c
done
