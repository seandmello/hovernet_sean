#!/bin/bash
#SBATCH --job-name=methylcdm_patches
#SBATCH -p gpu
#SBATCH -A kumargroup_gpu
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --gres=gpu:4
#SBATCH --time=24:00:00

set -e

# -------------------------
# Environment setup
# -------------------------
source ~/miniforge3/etc/profile.d/conda.sh
conda activate hovernet_new

# CRITICAL: only use conda libs, not system + conda mix
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib

# -------------------------
# Move to project directory
# -------------------------
cd $SLURM_SUBMIT_DIR

# -------------------------
# Run script
# -------------------------
bash run_patches_pannuke.sh
