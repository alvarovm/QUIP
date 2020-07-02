#!/bin/bash

set -e

if [ -z $QUIP_ROOT ]; then
   echo "$0: Need QUIP_ROOT defined"
   exit 1
fi
if [ -z $QUIP_ARCH ]; then
   echo "$0: Need QUIP_ARCH defined"
   exit 1
fi

TEST=test_quip.sh

mydir=`dirname $0`
bindir=$mydir/../build/$QUIP_ARCH

if [ ! -x $bindir/quip ]; then
   (cd $QUIP_ROOT && make Programs) || exit 2
fi

cat<<EOF > ${TEST}.in.xyz
8
Lattice="5.428835          0.000000          0.000000          0.000000          5.428835          0.000000          0.000000          0.000000          5.428835" Properties=species:S:1:pos:R:3
  Si      0.1000000      0.0000000      0.0000000
  Si      2.7144176      2.6144176      0.0000000
  Si      2.7144176      0.0000000      2.7144176
  Si      0.0000000      2.7144176      2.7144176
  Si      1.3572088      1.3572088      1.3572088
  Si      4.0716264      4.0716264      1.3572088
  Si      4.0716264      1.3572088      4.0716264
  Si      1.3572088      4.0716264      4.0716264
EOF

error=0
echo -n "$0: "
${MPIRUN} $bindir/quip atoms_filename=${TEST}.in.xyz E F V init_args='{IP SW}' test param_filename=$QUIP_ROOT/share/Parameters/ip.parms.SW.xml | grep 'test is OK' || error=1

rm -f ${TEST}.*
exit $error
