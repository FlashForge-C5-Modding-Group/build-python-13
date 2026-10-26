#!/bin/bash
# run.sh TARGET BUNDLE SYSROOT KALICO WORK HOSTPY
# Runs the bundle under QEMU (the toolchain sysroot stands in for the
# printer's /lib) and compares it with an x86 build of the same code:
#  - imports of everything Klippy needs
#  - chelper_test.py: c_helper.so through cffi, values must be bit-identical,
#    plus a thread stress test (errno/TLS from background threads)
#  - numpy_test.py: Kalico's input shaper fit, results must be identical
set -euo pipefail
TARGET=$1 BUNDLE=$2 SYSROOT=$3 KALICO=$4 WORK=$5 HOSTPY=$6
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
DL=$WORK/downloads
K=$KALICO/klippy
fail() { echo "TEST FAILED: $*" >&2; exit 1; }

# QEMU user mode: the system's, or Debian/Ubuntu's static build without root.
QEMU=$(command -v qemu-mipsel-static || command -v qemu-mipsel || true)
if [ -z "$QEMU" ]; then
    Q=$WORK/qemu
    if [ ! -x "$Q/usr/bin/qemu-mipsel-static" ]; then
        command -v apt-get >/dev/null || fail "install qemu-user-static (qemu-mipsel-static) or run with --no-test"
        mkdir -p "$Q" && (cd "$Q" && apt-get download qemu-user-static >/dev/null && dpkg-deb -x qemu-user-static_*.deb . && rm -f ./*.deb)
    fi
    QEMU=$Q/usr/bin/qemu-mipsel-static
fi
echo "== tests (QEMU: $QEMU)"

QROOT=$WORK/$TARGET/qroot
rm -rf "$QROOT" && mkdir -p "$QROOT/usr/data"
cp -a "$SYSROOT"/. "$QROOT"/
tar -xzf "$BUNDLE" -C "$QROOT/usr/data"
B=$QROOT/usr/data/python-hf
# Under QEMU, glibc's check that an RPATH directory exists misses the -L
# prefix, so once the first library isn't found there it drops the bundle's
# lib/ (a static python3.13 looks there for libc first). Give it the host path.
RUN=("$QEMU" -cpu P5600 -L "$QROOT" -E LD_LIBRARY_PATH="$B/lib" "$B/bin/python3.13")

"${RUN[@]}" -c 'import sys,zlib,ctypes,ssl,hashlib,sqlite3,bz2,lzma,ensurepip,greenlet,cffi,jinja2,markupsafe,serial,numpy,_cffi_backend; ctypes.CDLL("libsodium.so.26"); import multiprocessing; lk = multiprocessing.Lock(); lk.acquire(); lk.release(); print("imports ok:", sys.version.split()[0], ssl.OPENSSL_VERSION, "sqlite", sqlite3.sqlite_version, "greenlet", greenlet.__version__, "cffi", cffi.__version__, "numpy", numpy.__version__)' ||
    fail "imports"

# x86 reference: the host Python 3.13 + x86 wheels + c_helper.so from the same sources
REF=$WORK/hostref
if [ ! -d "$REF/site/numpy" ]; then
    rm -rf "$REF" && mkdir -p "$REF/site"
    for whl in "$DL"/numpy-*-cp313-*x86_64*.whl "$DL"/cffi-*-cp313-*x86_64*.whl "$DL"/pycparser-*.whl; do
        python3 -m zipfile -e "$whl" "$REF/site"
    done
fi
SOURCES=$(cd "$K/chelper" && "$HOSTPY" -c 'import re;s=open("__init__.py").read();print(" ".join(re.findall(r"\"(\w+\.c)\"",s.split("SOURCE_FILES")[1].split("]")[0])))')
(cd "$K/chelper" && gcc -Wall -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
    -o "$REF/c_helper.so" $SOURCES)
HREF=(env PYTHONPATH="$REF/site" "$HOSTPY")

OUT=$WORK/$TARGET/test-results
mkdir -p "$OUT"
"${HREF[@]}" "$HERE/chelper_test.py" "$K" "$REF/c_helper.so" >"$OUT/chelper-x86.txt" 2>&1 || fail "x86 chelper reference: $(tail -1 "$OUT/chelper-x86.txt")"
"${RUN[@]}" "$HERE/chelper_test.py" "$K" "$B/chelper/c_helper.so" >"$OUT/chelper-mips.txt" 2>&1 || fail "chelper: $(tail -1 "$OUT/chelper-mips.txt")"
grep -q "^THREADS ok" "$OUT/chelper-mips.txt" || fail "chelper threads: $(grep ^THREADS "$OUT/chelper-mips.txt")"
[ "$(grep ^VALUES "$OUT/chelper-x86.txt")" = "$(grep ^VALUES "$OUT/chelper-mips.txt")" ] || fail "chelper values differ from x86 (see $OUT)"
echo "chelper: $(grep ^VALUES "$OUT/chelper-mips.txt" | wc -w) values identical to x86, threads ok"

"${HREF[@]}" "$HERE/numpy_test.py" "$K" >"$OUT/numpy-x86.txt" 2>&1 || fail "x86 numpy reference: $(tail -1 "$OUT/numpy-x86.txt")"
"${RUN[@]}" "$HERE/numpy_test.py" "$K" >"$OUT/numpy-mips.txt" 2>&1 || fail "numpy: $(tail -1 "$OUT/numpy-mips.txt")"
diff <(grep -E '^(PSD|SHAPER|BEST|LINALG)' "$OUT/numpy-x86.txt") <(grep -E '^(PSD|SHAPER|BEST|LINALG)' "$OUT/numpy-mips.txt") >/dev/null ||
    fail "numpy results differ from x86 (see $OUT)"
echo "numpy: input shaper fit identical to x86 ($(grep ^BEST "$OUT/numpy-mips.txt"))"
echo "== all tests passed"
