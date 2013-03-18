#!/bin/bash

# Copyright 2012-2013  Arnab Ghoshal
#                      Johns Hopkins University (authors: Daniel Povey, Sanjeev Khudanpur)

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
# WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
# MERCHANTABLITY OR NON-INFRINGEMENT.
# See the Apache 2 License for the specific language governing permissions and
# limitations under the License.


# Script for system combination using minimum Bayes risk decoding.
# This calls lattice-combine to create a union of lattices that have been 
# normalized by removing the total forward cost from them. The resulting lattice
# is used as input to lattice-mbr-decode. This should not be put in steps/ or 
# utils/ since the scores on the combined lattice must not be scaled.

# begin configuration section.
cmd=run.pl
beam=4 # prune the lattices prior to MBR decoding, for speed.
stage=0
cer=0
decode_mbr=true
lat_weights=
min_lmwt=7
max_lmwt=17
parallel_opts="-pe smp 3"
#end configuration section.

help_message="Usage: "$(basename $0)" [options] <data-dir> <graph-dir|lang-dir> <decode-dir1>[:lmwt-bias] <decode-dir2>[:lmwt-bias] [<decode-dir3>[:lmwt-bias] ... ] <out-dir>
     E.g. "$(basename $0)" data/test data/lang exp/tri1/decode exp/tri2/decode exp/tri3/decode exp/combine
     or:  "$(basename $0)" data/test data/lang exp/tri1/decode exp/tri2/decode:18 exp/tri3/decode:13 exp/combine
Options:
  --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes.
  --min-lmwt INT                  # minumum LM-weight for lattice rescoring 
  --max-lmwt INT                  # maximum LM-weight for lattice rescoring
  --lat-weights STR               # colon-separated string of lattice weights
  --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes.
  --stage (0|1|2)                 # (createCTM | filterCTM | runSclite).
  --parallel-opts <string>        # extra options to command for combination stage,
                                  # default '-pe smp 3'
  --cer (0|1)                     # compute CER in addition to WER
";

[ -f ./path.sh ] && . ./path.sh
. parse_options.sh || exit 1;


if [ $# -lt 5 ]; then
  printf "$help_message\n";
  exit 1;
fi

data=$1
lang=$2
dir=${@: -1}  # last argument to the script
shift 2;
decode_dirs=( $@ )  # read the remaining arguments into an array
unset decode_dirs[${#decode_dirs[@]}-1]  # 'pop' the last argument which is odir
num_sys=${#decode_dirs[@]}  # number of systems to combine



for f in $lang/words.txt $lang/phones/word_boundary.int $data/stm; do
  [ ! -f $f ] && echo "$0: file $f does not exist" && exit 1;
done
ScoringProgram=$KALDI_ROOT/tools/sctk-2.4.0/bin/sclite
[ ! -f $ScoringProgram ] && echo "Cannot find scoring program at $ScoringProgram" && exit 1;



mkdir -p $dir/log

for i in `seq 0 $[num_sys-1]`; do
  decode_dir=${decode_dirs[$i]}
  offset=`echo $decode_dir | cut -d: -s -f2` # add this to the lm-weight.
  decode_dir=`echo $decode_dir | cut -d: -f1`
  [ -z "$offset" ] && offset=0
  
  model=$decode_dir/../final.mdl  # model one level up from decode dir
  for f in $model $decode_dir/lat.1.gz ; do
    [ ! -f $f ] && echo "$0: expecting file $f to exist" && exit 1;
  done
  if [ $i -eq 0 ]; then
    nj=`cat $decode_dir/num_jobs` || exit 1;
  else
    if [ $nj != `cat $decode_dir/num_jobs` ]; then
      echo "$0: number of decoding jobs mismatches, $nj versus `cat $decode_dir/num_jobs`" 
      exit 1;
    fi
  fi
  file_list=""
  # I want to get the files in the correct order so we can use ",s,cs" to avoid
  # memory blowup.  I first tried a pattern like file.{1,2,3,4}.gz, but if the
  # system default shell is not bash (e.g. dash, in debian) this will not work,
  # so we enumerate all the input files.  This tends to make the command lines
  # very long.
  for j in `seq $nj`; do file_list="$file_list $decode_dir/lat.$j.gz"; done

  lats[$i]="ark,s,cs:lattice-prune --beam=$beam --inv-acoustic-scale=\$[$offset+LMWT] \
 'ark:gunzip -c $file_list|' ark:- | \
 lattice-scale --inv-acoustic-scale=\$[$offset+LMWT] ark:- ark:- | \
 lattice-align-words $lang/phones/word_boundary.int $model ark:- ark:- |"
done

mkdir -p $dir/scoring/log

cat $data/text | sed 's:<NOISE>::g' | sed 's:<SPOKEN_NOISE>::g' \
  > $dir/scoring/test_filt.txt

if [ -z "$lat_weights" ]; then
  lat_weights=1.0
  for i in `seq $[$num_sys-1]`; do lat_weights="$lat_weights:1.0"; done
fi

if [ $stage -le 0 ]; then  
  $cmd $parallel_opts LMWT=$min_lmwt:$max_lmwt $dir/log/combine_lats.LMWT.log \
    mkdir -p $dir/score_LMWT/ '&&' \
    lattice-combine --lat-weights=$lat_weights "${lats[@]}" ark:- \| \
    lattice-to-ctm-conf --decode-mbr=true ark:- - \| \
    utils/int2sym.pl -f 5 $lang/words.txt  \| \
    utils/convert_ctm.pl $data/segments $data/reco2file_and_channel \
    '>' $dir/score_LMWT/$name.ctm || exit 1;
fi


if [ $stage -le 1 ]; then
# Remove some stuff we don't want to score, from the ctm.
  for x in $dir/score_*/$name.ctm; do
    cp $x $x.bkup1;
    cat $x.bkup1 | grep -v -E '\[NOISE|LAUGHTER|VOCALIZED-NOISE\]' | \
      grep -v -E '<UNK>|%HESITATION|\(\(\)\)' | \
      grep -v -E '<eps>' | \
      grep -v -E '<noise>' | \
      grep -v -E '<silence>' | \
      grep -v -E '<unk>' | \
      grep -v -E '<v-noise>' | \
      perl -e '@list = (); %list = ();
      while(<>) {
        chomp; 
        @col = split(" ", $_); 
        push(@list, $_);
        $key = "$col[0]" . " $col[1]"; 
        $list{$key} = 1;
      } 
      foreach(sort keys %list) {
        $key = $_;
        foreach(grep(/$key/, @list)) {
          print "$_\n";
        }
      }' > $x;
    cp $x $x.bkup2;
    y=${x%.ctm};
    cat $x.bkup2 | \
      perl -e '
      use Encode;
      while(<>) {
        chomp;
        @col = split(" ", $_);
        @col == 6 || die "Bad number of columns!";
        if ($col[4] =~ m/[\x80-\xff]{2}/) {
          $word = decode("UTF8", $col[4]);
          @char = split(//, $word);
          $start = $col[2];
          $dur = $col[3]/@char;
          $start -= $dur;
          foreach (@char) {
            $char = encode("UTF8", $_);
            $start += $dur;
            # printf "$col[0] $col[1] $start $dur $char\n"; 
            printf "%s %s %.2f %.2f %s %s\n", $col[0], $col[1], $start, $dur, $char, $col[5]; 
          }
        }
      }' > $y.char.ctm
    cp $y.char.ctm $y.char.ctm.bkup1
  done
fi

if [ $stage -le 2 ]; then
  $cmd LMWT=$min_lmwt:$max_lmwt $dir/scoring/log/score.LMWT.log \
    cp $data/stm $dir/score_LMWT/ '&&' cp $data/glm $dir/score_LMWT/ '&&'\
    $ScoringProgram -s -r $dir/score_LMWT/stm stm -h $dir/score_LMWT/${name}.ctm ctm -o all -o dtl;

  if [ $cer -eq 1 ]; then
    $cmd LMWT=$min_lmwt:$max_lmwt $dir/scoring/log/score.LMWT.char.log \
      cp $data/char.stm $dir/score_LMWT/'&&'\
      $ScoringProgram -s -r $dir/score_LMWT/char.stm stm -h $dir/score_LMWT/${name}.char.ctm ctm -o all -o dtl;
  fi
  
#  for x in $dir/score_*/*.ctm; do
#    mv $x.filt $x;
#    rm -f $x.filt*;
#  done

#  for x in $dir/score_*/*stm; do
#    mv $x.filt $x;
#    rm -f $x.filt*;
#  done
fi


exit 0
