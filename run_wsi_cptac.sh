#!/bin/bash
#SBATCH --job-name=hovernet_wsi
#SBATCH -p gpu
#SBATCH -A kumargroup_gpu
#SBATCH --output=logs/%x_%A_%a.out
#SBATCH --error=logs/%x_%A_%a.err
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --gres=gpu:1
#SBATCH --time=24:00:00
#SBATCH --array=0-3

# HoVer-Net (PanNuke) WSI inference on one CPTAC cancer type.
# Slides are split across array tasks; finished slides are skipped, so the
# same command can be resubmitted to continue after a timeout.
#
# usage: sbatch run_wsi_cptac.sh CCRCC
#        CONDA_ENV=myenv sbatch run_wsi_cptac.sh CCRCC   (default env: hovernet)
#        BATCH_SIZE=16 sbatch run_wsi_cptac.sh CCRCC     (default 32; lower on CUDA OOM)
#        sbatch --array=0-7 run_wsi_cptac.sh LUAD
#        SLIDE_LIST=todo.txt sbatch ... (only the .svs paths listed, one per line;
#                                        submit_all_cptac.sh writes this for you)

set -e

CANCER_TYPE=${1:?usage: sbatch run_wsi_cptac.sh <CANCER_TYPE>}

# slides live in .../CPTAC-<TYPE>/slides/raw_v<N>/<TYPE>; use the highest raw_v<N>
# found, or set SLIDE_ROOT=... to choose one explicitly
CPTAC_ROOT=/cluster/projects/kumargroup/hayden/data/CPTAC
# (not needed when SLIDE_LIST is given, e.g. TCGA via submit_tcga.sh)
if [ -n "$SLIDE_LIST" ]; then
    SLIDE_ROOT=${SLIDE_ROOT:-$SLIDE_LIST}
elif [ -z "$SLIDE_ROOT" ]; then
    SLIDE_ROOT=$(ls -d "$CPTAC_ROOT"/CPTAC-${CANCER_TYPE}/slides/raw_v*/${CANCER_TYPE} 2>/dev/null | sort -V | tail -1)
fi
if [ -z "$SLIDE_LIST" ] && { [ -z "$SLIDE_ROOT" ] || ! ls "$SLIDE_ROOT"/*.svs > /dev/null 2>&1; }; then
    echo "no .svs found for $CANCER_TYPE under $CPTAC_ROOT/CPTAC-${CANCER_TYPE}/slides/raw_v*/${CANCER_TYPE}" >&2
    exit 1
fi
WORK_ROOT=/cluster/projects/kumargroup/sean/hovernet
MODEL_PATH=${WORK_ROOT}/pannuke.tar
OUTPUT_DIR=${WORK_ROOT}/output/${CANCER_TYPE}

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}
NR_TASKS=${SLURM_ARRAY_TASK_COUNT:-1}
SHARD_DIR=${WORK_ROOT}/shards/${CANCER_TYPE}_${SLURM_ARRAY_JOB_ID:-local}_${TASK_ID}
# cache is I/O heavy (~15-30 GB per 40x slide); prefer node-local disk.
# override with e.g. CACHE_ROOT=/tmp sbatch run_wsi_cptac.sh CCRCC
CACHE_ROOT=${CACHE_ROOT:-${SLURM_TMPDIR:-${WORK_ROOT}/cache}}
CACHE_DIR=${CACHE_ROOT}/hovernet_${CANCER_TYPE}_${SLURM_JOB_ID:-local}_${TASK_ID}

# -------------------------
# Environment setup
# -------------------------
source ~/miniforge3/etc/profile.d/conda.sh
conda activate ${CONDA_ENV:-hovernet}
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

cd $SLURM_SUBMIT_DIR
mkdir -p logs "$OUTPUT_DIR"/json "$OUTPUT_DIR"/thumb "$OUTPUT_DIR"/mask

# -------------------------
# Build this task's shard: symlinks to every NR_TASKS-th .svs
# (from SLIDE_LIST if given, so all tasks shard the same fixed list)
# -------------------------
rm -rf "$SHARD_DIR" && mkdir -p "$SHARD_DIR"
if [ -n "$SLIDE_LIST" ]; then
    SLIDES=$(sort "$SLIDE_LIST")
else
    SLIDES=$(ls "$SLIDE_ROOT"/*.svs | sort)
fi
i=0
for slide in $SLIDES; do
    if [ $((i % NR_TASKS)) -eq "$TASK_ID" ]; then
        ln -s "$slide" "$SHARD_DIR/"
    fi
    i=$((i + 1))
done
echo "[$CANCER_TYPE task $TASK_ID/$NR_TASKS] $(ls "$SHARD_DIR" | wc -l) of $i slides in $SLIDE_ROOT -> $OUTPUT_DIR"

echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "cache: $CACHE_DIR"; df -h "$CACHE_ROOT" | tail -1
nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv
python -c "import torch; print('torch', torch.__version__, 'cuda available:', torch.cuda.is_available())"

# -------------------------
# Run inference (PanNuke was trained at 40x)
# -------------------------
python run_infer.py \
    --gpu=${CUDA_VISIBLE_DEVICES:-0} \
    --nr_types=6 \
    --type_info_path=type_info.json \
    --model_path=$MODEL_PATH \
    --model_mode=fast \
    --batch_size=${BATCH_SIZE:-32} \
    --nr_inference_workers=8 \
    --nr_post_proc_workers=16 \
    wsi \
    --input_dir=$SHARD_DIR \
    --output_dir=$OUTPUT_DIR \
    --cache_path=$CACHE_DIR \
    --proc_mag=40 \
    --save_thumb \
    --save_mask

rm -rf "$SHARD_DIR" "$CACHE_DIR"
