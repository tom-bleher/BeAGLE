#!/bin/bash
# Build BeAGLE in ~/src/BeAGLE inside eic-shell (gfortran 14). Dependencies live in ~/src/beagle-deps.
#   Stage 1 (no FLUKA needed): PYTHIA/RADGEN/PyQM libraries, RAPGAP 3.302 libraries,
#                              CERNLIB stand-in (nanocernlib), LHAPDF 5.9.1 + CTEQ6L1/EPS09 grids.
#   Stage 2 (needs FLUKA):     DPMJET + BeAGLE linked against CERN FLUKA 4 ($FLUPRO, default beagle-deps/fluka)
# FLUKA must be downloaded by hand (fluka.cern, registration): fluka_4-*.x86-Linux-gfor9_amd64.deb, then
#   dpkg-deb -x <deb> tmp && mv tmp/usr/local/fluka ~/src/beagle-deps/fluka
# Run as:  printf '%s\n' "bash ~/src/BeAGLE/build_local.sh" | ~/eic/eic-shell
# Then create a run directory with:  bash ~/src/BeAGLE/setup_rundir.sh <dir>
set -euo pipefail
B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPS=$HOME/src/beagle-deps
FFLAGS="-c -g -m64 -O2 -fno-inline -fno-automatic -fno-align-commons -std=legacy -fallow-argument-mismatch -w"
cd "$B"
mkdir -p obj/PYTHIA-6.4.28 obj/PyQM obj/dpmjet obj/radgen-6.4.28

echo "== stage 1: PYTHIA 6.4.28, RADGEN, PyQM (rebuilt with this compiler)"
make -B -j8 obj/libpythia6.a obj/libradgen.a obj/libpyqm.a CXXFLAGS="$FFLAGS" > build_stage1.log 2>&1

if [ ! -f RAPGAP-3.302/lib/librapgap33.a ]; then
  echo "== stage 1: RAPGAP 3.302"
  mkdir -p "$DEPS/pythia6/lib"
  ln -sf "$B/obj/libpythia6.a" "$DEPS/pythia6/lib/libpythia6.a"
  cd "$DEPS"
  [ -f rapgap-3.302.tar.gz ] || curl -sSfL -o rapgap-3.302.tar.gz "https://rapgap.hepforge.org/downloads/?f=rapgap-3.302.tar.gz"
  [ -d rapgap-3.302 ] || tar xzf rapgap-3.302.tar.gz
  cd rapgap-3.302
  # README: RAPGAP ships the Pythia 6.4.13 pydata.f; use the 6.4.28 one
  cp "$B/PYTHIA-6.4.28/pydata.f" src/rapgap/pydata.f 2>/dev/null || true
  F77=gfortran FC=gfortran FFLAGS="-O2 -std=legacy -fallow-argument-mismatch -w -fno-automatic" ./configure --prefix="$DEPS/rapgap-install" \
     --with-pythia6="$DEPS/pythia6" --with-lhapdf=/opt/local --disable-shared > "$B/build_rapgap.log" 2>&1
  # only the static libraries are needed; the example executables (e.g. rapgap_hepmc) may fail to link
  make -k -j8 >> "$B/build_rapgap.log" 2>&1 || echo "  (RAPGAP example programs failed to link; libraries checked below)"
  cd "$B"
  for l in libar4.a libbases.a librapgap33.a; do
    f=$(find "$DEPS/rapgap-3.302" -name "$l" | head -1)
    [ -n "$f" ] || { echo "RAPGAP did not produce $l (see build_rapgap.log)"; exit 1; }
    cp "$f" RAPGAP-3.302/lib/
  done
  ar d RAPGAP-3.302/lib/librapgap33.a sfecfe.o 2>/dev/null || true   # README: clashes with FLUKA's sfecfe
fi
# h1qcdfit.o carries a copy of PFTOPDG identical to LHAPDF 5's; let LHAPDF's definition win
objcopy --weaken-symbol=pftopdg_ RAPGAP-3.302/lib/librapgap33.a

# CERNLIB stand-in for the old -lmathlib -lkernlib -lpacklib (RAPGAP needs e.g. DGAUSS, RANLUX).
# PDFLIB is deliberately NOT linked: its PDFSET/STRUCTM would shadow LHAPDF's.
if [ ! -f "$DEPS/cernlib/lib/libnanocernlib_mathlib.a" ]; then
  echo "== stage 1: nanocernlib"
  rm -rf "$DEPS/nanocernlib-src"
  git clone -q https://github.com/sly2j/nanocernlib "$DEPS/nanocernlib-src"
  git -C "$DEPS/nanocernlib-src" checkout -q 55a2f9a4ebea3d2339f54082c20a50d5c9aa842d
  cmake -S "$DEPS/nanocernlib-src" -B "$DEPS/nanocernlib-src/build" -DCMAKE_INSTALL_PREFIX="$DEPS/cernlib" \
    -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_Fortran_COMPILER=gfortran \
    -DCMAKE_Fortran_FLAGS="-std=legacy -fallow-argument-mismatch -w" \
    -DCMAKE_C_FLAGS="-Df2cFortran -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion" \
    > "$B/build_cernlib.log" 2>&1
  cmake --build "$DEPS/nanocernlib-src/build" -j8 >> "$B/build_cernlib.log" 2>&1
  cmake --install "$DEPS/nanocernlib-src/build" >> "$B/build_cernlib.log" 2>&1
fi
ln -sf libnanocernlib_mathlib.a "$DEPS/cernlib/lib/libmathlib.a"
ln -sf libnanocernlib_packlib.a "$DEPS/cernlib/lib/libkernlib.a"   # nanocernlib folds kernlib into packlib
ln -sf libnanocernlib_packlib.a "$DEPS/cernlib/lib/libpacklib.a"

# LHAPDF 5.9.1: the README's tested series. Provides the LHAGLUE numbering (MSTP(51)=10042 -> cteq6ll.LHpdf)
# and STRUCTA/SETLHAPARM with EPS09, which LHAPDF 6 does not have.
LHA=$DEPS/lhapdf5
if [ ! -f "$LHA/lib/libLHAPDF.a" ]; then
  echo "== stage 1: LHAPDF 5.9.1"
  mkdir -p "$DEPS/lhapdf5-src" && cd "$DEPS/lhapdf5-src"
  [ -f lhapdf-5.9.1.tar.gz ] || curl -sSfL -o lhapdf-5.9.1.tar.gz "https://lhapdf.hepforge.org/downloads/?f=old/lhapdf-5.9.1.tar.gz"
  [ -d lhapdf-5.9.1 ] || tar xzf lhapdf-5.9.1.tar.gz
  cd lhapdf-5.9.1
  F77=gfortran FC=gfortran CC=gcc CXX=g++ FFLAGS="-O2 -std=legacy -fallow-argument-mismatch -fno-automatic -w" \
    FCFLAGS="-O2 -std=legacy -fallow-argument-mismatch -fno-automatic -w" CXXFLAGS="-O2 -std=c++11 -w" \
    ./configure --prefix="$LHA" --disable-pyext --disable-octave --disable-doxygen > "$B/build_lhapdf5.log" 2>&1
  make -j8 >> "$B/build_lhapdf5.log" 2>&1
  make install >> "$B/build_lhapdf5.log" 2>&1
  cd "$B"
fi
mkdir -p "$LHA/share/lhapdf/PDFsets"
if [ ! -f "$LHA/share/lhapdf/PDFsets/cteq6ll.LHpdf" ]; then
  echo "== stage 1: CTEQ6L1 and EPS09 grids"
  for f in cteq6ll.LHpdf \
           $(for a in 4 6 9 12 16 27 40 56 64 108 115 117 184 195 197 208 238; do echo EPS09LOR_$a.LHgrid; done) \
           $(for a in 4 6 9 12 16 20 27 40 56 64 84 108 115 117 131 184 195 197 208 238; do echo EPS09NLOR_$a.LHgrid; done); do
    curl -sSfL -o "$LHA/share/lhapdf/PDFsets/$f" "https://lhapdf.hepforge.org/downloads/?f=pdfsets/5.9.1/$f"
  done
fi
echo "stage 1 done: $(ls obj/*.a RAPGAP-3.302/lib/*.a | xargs -n1 basename | tr '\n' ' ')"

FLUPRO=${FLUPRO:-$DEPS/fluka}
if [ ! -f "$FLUPRO/lib/libfluka.a" ]; then
  echo "stage 2 skipped: set FLUPRO to a CERN FLUKA 4 installation (with lib/libfluka.a and include/) and rerun"
  exit 0
fi
# BeAGLE includes FLUKA commons as INCLUDE '(DIMPAR)' etc. (FLUKA 2011 flukapro/ layout);
# FLUKA 4 ships them as include/dimpar.inc, so provide the old names as symlinks.
if [ ! -d "$FLUPRO/flukapro" ]; then
  mkdir "$FLUPRO/flukapro"
  for f in "$FLUPRO"/include/*.inc; do
    n=$(basename "$f" .inc)
    ln -s "../include/$n.inc" "$FLUPRO/flukapro/(${n^^})"
  done
fi
echo "== stage 2: DPMJET + BeAGLE against FLUKA $(cat "$FLUPRO/Version.tag" 2>/dev/null) in $FLUPRO"
rm -f BeAGLE
make -j8 all CXXFLAGS="$FFLAGS -I$FLUPRO/flukapro" FLUKA="$FLUPRO" \
  LIB1="-L$DEPS/cernlib/lib -lmathlib -lkernlib -lpacklib -ldl -lm" \
  LIB2="-L$FLUPRO/lib -lfluka" \
  LIB3="$LHA/lib/libLHAPDF.a -lstdc++ -Wl,--no-relax" > build_stage2.log 2>&1   # large commons: GOTPCREL can't be relaxed
ls -la BeAGLE
echo "BeAGLE built. Make a run directory with: bash $B/setup_rundir.sh <dir>"
