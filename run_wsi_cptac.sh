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
#        sbatch --array=0-7 run_wsi_cptac.sh LUAD

set -e

CANCER_TYPE=${1:?usage: sbatch run_wsi_cptac.sh <CANCER_TYPE>}

SLIDE_ROOT=/cluster/projects/kumargroup/hayden/data/CPTAC/CPTAC-${CANCER_TYPE}/slides/raw_v1/${CANCER_TYPE}
WORK_ROOT=/cluster/projects/kumargroup/sean/hovernet
MODEL_PATH=${WORK_ROOT}/pannuke.tar
OUTPUT_DIR=${WORK_ROOT}/output/${CANCER_TYPE}

TASK_ID=${SLURM_ARRAY_TASK_ID:-0}
NR_TASKS=${SLURM_ARRAY_TASK_COUNT:-1}
SHARD_DIR=${WORK_ROOT}/shards/${CANCER_TYPE}_${TASK_ID}
CACHE_DIR=${WORK_ROOT}/cache/${CANCER_TYPE}_${TASK_ID}

# -------------------------
# Environment setup
# -------------------------
source ~/miniforge3/etc/profile.d/conda.sh
conda activate hovernet_new
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib

cd $SLURM_SUBMIT_DIR
mkdir -p logs "$OUTPUT_DIR"/json "$OUTPUT_DIR"/thumb "$OUTPUT_DIR"/mask

# -------------------------
# Build this task's shard: symlinks to every NR_TASKS-th .svs
# -------------------------
rm -rf "$SHARD_DIR" && mkdir -p "$SHARD_DIR"
i=0
for slide in $(ls "$SLIDE_ROOT"/*.svs | sort); do
    if [ $((i % NR_TASKS)) -eq "$TASK_ID" ]; then
        ln -s "$slide" "$SHARD_DIR/"
    fi
    i=$((i + 1))
done
echo "[$CANCER_TYPE task $TASK_ID/$NR_TASKS] $(ls "$SHARD_DIR" | wc -l) of $i slides -> $OUTPUT_DIR"

echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
nvidia-smi --query-gpu=name,memory.total --format=csv
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
    --batch_size=64 \
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
