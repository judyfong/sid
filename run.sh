#! /bin/bash
# Author: Judy Fong - Reykjavik University
# 
#SBATCH --nodelist=terra
#SBATCH --output=logs/run_%J.out

stage=0

experiment=1
num_jobs=60

gunnardir=data/t2-initialdata/
traindir=data/test$experiment
data_dir=data/test$experiment
mfccdir=${data_dir}/mfccs/
nnet_dir=nnet_dir
exp_cmn_dir=exp/test$experiment/cmvn
data_cmn_dir=${data_dir}/cmvn
xvectors_dir=exp/test$experiment/xvectors
segmented_dir=${data_dir}
vaddir=${data_dir}/vad

threshold=0.3

t2_trials=$data_cmn_dir/core-core.lst

mkdir -p $data_cmn_dir
mkdir -p $exp_cmn_dir

. ./cmd.sh
. ./path.sh
set -e

. utils/parse_options.sh


if [ $stage -le 0 ]; then
    echo -e "Preparing t2_selection data"
    #train dir has wav.scp, short utterances
    for name in wav.scp utt2spk; do
      cp $gunnardir/$name $traindir/
    done
    srun utils/utt2spk_to_spk2utt.pl $traindir/utt2spk > $traindir/spk2utt

    #use fix_data_dir.sh
    utils/fix_data_dir.sh $traindir
    utils/validate_data_dir.sh --no-feats --no-text $traindir
fi
if [ $stage -le 1 ]; then
    echo -e "\nMake mfccs"
    mkdir -p exp/make_mfcc
    mkdir -p $mfccdir
    cp $data_dir/spk2utt exp/make_mfcc/spk2utt
    cp $data_dir/wav.scp exp/make_mfcc/wav.scp

    steps/make_mfcc.sh --mfcc-config conf/mfcc.conf --nj ${num_jobs} \
     --cmd "$train_cmd" --write-utt2num-frames true \
     --write-utt2dur false \
     $data_dir exp/make_mfcc $mfccdir

    #use fix_data_dir.sh
    utils/fix_data_dir.sh $traindir
    utils/validate_data_dir.sh --no-feats --no-text $traindir

    sid/compute_vad_decision.sh --nj ${num_jobs} --cmd "$train_cmd" \
        $data_dir exp/make_vad $vaddir
    utils/fix_data_dir.sh $data_dir
fi
if [ $stage -le 2 ]; then
    echo -e "\nPerform Cepstral mean and variance normalization(CMVN)"
    # TODO: is this needed?
    local/nnet3/xvector/prepare_feats.sh --nj ${num_jobs} --cmd \
     "$train_cmd" $data_dir $data_cmn_dir $exp_cmn_dir

    if [ -f $data_dir/vad.scp ]; then
      cp $data_dir/vad.scp $data_cmn_dir
    fi

    utils/fix_data_dir.sh $data_cmn_dir
fi

if [ $stage -le 3 ]; then
    #split the test to enroll and eval
    mkdir -p $data_cmn_dir/enroll $data_cmn_dir/eval
    cp $data_cmn_dir/{spk2utt,feats.scp,vad.scp} $data_cmn_dir/enroll
    cp $data_cmn_dir/{spk2utt,feats.scp,vad.scp} $data_cmn_dir/eval
    local/split_data_enroll_eval.py $data_cmn_dir/utt2spk  $data_cmn_dir/enroll/utt2spk $data_cmn_dir/eval/utt2spk
    t2_trials=$data_cmn_dir/core-core.lst
    local/produce_trials.py $data_cmn_dir/eval/utt2spk $t2_trials
    utils/fix_data_dir.sh $data_cmn_dir/enroll
    utils/fix_data_dir.sh $data_cmn_dir/eval
fi

if [ $stage -le 4 ]; then
    echo -e "\nExtract Embeddings/X-Vectors"
    mkdir -p $xvectors_dir

    # NOTE each speaker can be split into at most 1 job
    # so jobs(nj) needs to be <= num_speakers
    sid/nnet3/xvector/extract_xvectors.sh --cmd \
      "$train_cmd --mem 5G" --nj ${num_jobs} \
      $nnet_dir/xvector_nnet_1a \
      $data_cmn_dir $xvectors_dir
fi

if [ $stage -eq 5 ]; then
    echo -e "\nScore x-vectors with PLDA to check similarity"
    mkdir -p $xvectors_dir/plda_scores
    # TODO: Compute PLDA scores for t2_selection like sitw/v2

    # Compute PLDA scores for SITW dev core-core trials
    $train_cmd $xvectors_dir/plda_scores/log/t2_selection_scoring.log \
      ivector-plda-scoring --normalize-length=true \
      --num-utts=ark:$xvectors_dir/num_utts.ark \
      "ivector-copy-plda --smoothing=0.0 $nnet_dir/xvector_nnet_1a/xvectors_ruvdi2/plda - |" \
      "ark:ivector-mean ark:$data_cmn_dir/enroll/spk2utt scp:$xvectors_dir/xvector.scp ark:- | ivector-subtract-global-mean $nnet_dir/xvector_nnet_1a/xvectors_ruvdi2/mean.vec ark:- ark:- | transform-vec $nnet_dir/xvector_nnet_1a/xvectors_ruvdi2/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
      "ark:ivector-subtract-global-mean $nnet_dir/xvector_nnet_1a/xvectors_ruvdi2/mean.vec scp:$xvectors_dir/xvector.scp ark:- | transform-vec $nnet_dir/xvector_nnet_1a/xvectors_ruvdi2/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
      "cat '$t2_trials_core' | cut -d\  --fields=1,2 |" $xvectors_dir/plda_scores/t2_trials_core_scores || exit 1;
  
    # SITW Dev Core:
    # EER: 3.003%
    # minDCF(p-target=0.01): 0.3119
    # minDCF(p-target=0.001): 0.4955
    eer=$(paste $t2_trials_core $xvectors_dir/plda_scores/t2_trials_core_scores | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
    mindcf1=`sid/compute_min_dcf.py --p-target 0.01 $xvectors_dir/plda_scores/t2_trials_core_scores $t2_trials_core 2> /dev/null`
    mindcf2=`sid/compute_min_dcf.py --p-target 0.001 $xvectors_dir/plda_scores/t2_trials_core_scores $t2_trials_core 2> /dev/null`
    echo "EER: $eer%"
    echo "minDCF(p-target=0.01): $mindcf1"
    echo "minDCF(p-target=0.001): $mindcf2"
fi

echo -e "\nThe run file has finished."
