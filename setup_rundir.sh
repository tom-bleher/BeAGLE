#!/bin/bash
# Prepare a BeAGLE run directory outside the source tree.
# FLUKA 4 opens nuclear.bin and its other data tables by relative path, so they are linked here;
# BeAGLE's own .dat files are found through $BEAGLESYS.
#   bash ~/src/BeAGLE/setup_rundir.sh <dir>
#   cd <dir> && source ./env.sh && $BEAGLESYS/BeAGLE < input.inp > logfile   (inside eic-shell; plain "source env.sh" is a no-op there)
set -euo pipefail
B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPS=$HOME/src/beagle-deps
FLUPRO=${FLUPRO:-$DEPS/fluka}
D=${1:?usage: setup_rundir.sh <dir>}
mkdir -p "$D/outForPythiaMode"
D=$(cd "$D" && pwd)
for f in "$FLUPRO"/data/*; do ln -sfn "$f" "$D/"; done
cat > "$D/env.sh" <<EOF
export BEAGLESYS=$B
export LHAPATH=$DEPS/lhapdf5/share/lhapdf/PDFsets
export FLUPRO=$FLUPRO
EOF
echo "run directory ready: $D (cd there and 'source ./env.sh' before running)"
