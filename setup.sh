#!/bin/bash

. path.sh

echo Setting up symlinks
ln -sfn ../../wsj/s5/steps steps
ln -sfn ../../wsj/s5/utils utils
ln -sfn ../../callhome_diarization/v1/diarization diarization
ln -sfn ../../sre08/v1/sid/ sid
cd local
ln -sfn $KALDI_ROOT/egs/aishell/v1/local/produce_trials.py  product_trials.py
ln -sfn $KALDI_ROOT/egs/aishell/v1/local/split_data_enroll_eval.py  split_data_enroll_eval.py
cd ../

echo "Make logs dir"
mkdir -p logs
mkdir -p data
mkdir -p exp
mkdir -p mfcc

echo Done
