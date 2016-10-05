#!/bin/bash

if [ $# -eq 0 ]; then
  gpu_id=0
else
  gpu_id=$1
fi

CUDA_VISIBLE_DEVICES=$gpu_id th main.lua \
  -expID hg-32-lr-1e-3-bs-64 \
  -nEpochs 30 \
  -batchSize 64 \
  -weightFocal 1 \
  -LR 1e-3 \
  -netType hg-32