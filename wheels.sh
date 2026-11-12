#!/usr/bin/env bash
# wheels.sh <python-hf-c5-release.zip>
# Cross-builds Moonraker's C-extension wheels (Pillow, streaming-form-data) for
# that python-hf bundle, so printers install them instead of compiling.
# Output: out/wheels-<python version>/*.whl (+ SHA256SUMS). See README.md.
set -euo pipefail

BUNDLE_ZIP=$(realpath "${1:?usage: wheels.sh <python-hf-c5-release.zip>}")
REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/.cache/ingenic-hf-python}
DL=$WORK/downloads
PREFIX=/usr/data/python-hf
PILLOW_VER=${PILLOW_VER:-12.3.0}
SFD_VER=${SFD_VER:-2.1.0}
J=${J:-$(nproc)}

log() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$DL"

# ------------------------------------------------------------ toolchain
R6=$WORK/tc-r6
if [ ! -x "$R6/bin/mips-xburst2-linux-gnu-gcc" ]; then
    [ -f "$DL/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2" ] || die "run build.sh c5 once to download the r6 toolchain"
    log "unpacking the r6.0.0 toolchain"
    rm -rf "$R6" "$R6.tmp" && mkdir -p "$R6.tmp"
    tar -xjf "$DL/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2" -C "$R6.tmp" --strip-components=1
    mv "$R6.tmp" "$R6"
fi
T=$R6/bin/mips-xburst2-linux-gnu-

# ---------------------------------------------------- the target bundle
B=$WORK/wheels
rm -rf "$B/stage" "$B/rel" && mkdir -p "$B/stage" "$B/rel"
python3 -m zipfile -e "$BUNDLE_ZIP" "$B/rel"
(cd "$B/rel" && { [ ! -f python-hf-c5.tar.gz.sha256 ] || sha256sum -c python-hf-c5.tar.gz.sha256 >/dev/null; }) ||
    die "python-hf-c5.tar.gz is damaged"
tar -xzf "$B/rel/python-hf-c5.tar.gz" -C "$B/stage"
P=$B/stage/python-hf
SYSCFG=$(ls "$P"/lib/python3.*/_sysconfigdata__*.py | head -1)
PYMM=$(basename "$(dirname "$SYSCFG")"); PYMM=${PYMM#python}
PYVER=$(sed -n 's/^python: \([0-9.]*\).*/\1/p' "$B/rel/BUILDINFO-c5")
[ -n "$PYVER" ] || die "no Python version in BUILDINFO-c5"
log "target Python $PYVER"

# ------------------------------------------- host Python, same version
HOSTPY=$WORK/hostpy-$PYVER/bin/python$PYMM
if ! "$HOSTPY" -c 'import ssl, zlib' 2>/dev/null || [ "$("$HOSTPY" -c 'print(1)' 2>/dev/null)" != 1 ]; then
    log "host Python $PYVER"
    rm -rf "$WORK/hostpy-$PYVER"
    [ -f "$DL/Python-$PYVER.tar.xz" ] ||
        curl -fsSL -o "$DL/Python-$PYVER.tar.xz" "https://www.python.org/ftp/python/$PYVER/Python-$PYVER.tar.xz"
    rm -rf "$WORK/hostpy-src-$PYVER" && mkdir -p "$WORK/hostpy-src-$PYVER"
    tar -xJf "$DL/Python-$PYVER.tar.xz" -C "$WORK/hostpy-src-$PYVER" --strip-components=1
    (cd "$WORK/hostpy-src-$PYVER" && ./configure --prefix="$WORK/hostpy-$PYVER" --without-ensurepip >/dev/null &&
        make -j"$J" >build.log 2>&1 && make install >install.log 2>&1) || die "host Python build failed"
fi

# ------------------------------------- build tools and sources (pinned)
TOOLS=$B/tools
rm -rf "$TOOLS" && mkdir -p "$TOOLS"
rm -rf "$B/dl-tools" "$B/dl-src"
python3 -m pip download -q --no-deps --only-binary :all: --python-version "$PYMM" --platform any \
    -d "$B/dl-tools" pip setuptools wheel cython pybind11
for whl in "$B"/dl-tools/*.whl; do python3 -m zipfile -e "$whl" "$TOOLS"; done
mkdir -p "$B/dl-src"
for spec in "pillow $PILLOW_VER" "streaming-form-data $SFD_VER"; do
    set -- $spec
    url=$(curl -fsSL "https://pypi.org/pypi/$1/$2/json" |
        python3 -c 'import json,sys; print(next(u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"] == "sdist"))')
    curl -fsSL -o "$B/dl-src/${url##*/}" "$url" || die "cannot download $1 $2"
done

# The host Python, told it is the target: its _sysconfigdata, paths in the stage
mkdir -p "$B/xsys"
sed "s#$PREFIX#$P#g" "$SYSCFG" >"$B/xsys/$(basename "$SYSCFG")"
XPY=(env _PYTHON_HOST_PLATFORM=linux-mips
    _PYTHON_SYSCONFIGDATA_NAME="$(basename "$SYSCFG" .py)"
    PYTHONPATH="$B/xsys:$TOOLS"
    CC="${T}gcc -march=xburst2" AR="${T}ar" LDSHARED="${T}gcc -shared -fPIC -L$P/lib -Wl,-rpath,$PREFIX/lib"
    CFLAGS="-O2 -I$P/include" LDFLAGS="-L$P/lib" SKIP_CYTHON=1
    PKG_CONFIG_LIBDIR="$B/no-pkgconfig" PKG_CONFIG_PATH= "$HOSTPY")

OUT=$REPO/out/wheels-$PYVER
rm -rf "$OUT" && mkdir -p "$OUT"
for sdist in "$B"/dl-src/*.tar.gz; do
    log "$(basename "$sdist")"
    "${XPY[@]}" -m pip wheel -q --no-deps --no-build-isolation --no-cache-dir -w "$OUT" \
        -C platform-guessing=disable -C xcb=disable "$sdist" >"$B/$(basename "$sdist" .tar.gz).log" 2>&1 ||
        die "build failed, see $B/$(basename "$sdist" .tar.gz).log"
done

# Every extension must be hard-float MIPS for this Python
for whl in "$OUT"/*.whl; do
    rm -rf "$B/check" && mkdir -p "$B/check" && python3 -m zipfile -e "$whl" "$B/check"
    for so in $(find "$B/check" -name '*.so'); do
        "${T}readelf" -A "$so" | grep -q 'Hard float' || die "not hard-float: $(basename "$whl") ${so#$B/check/}"
        case "$so" in *".cpython-${PYMM/./}-mipsel-linux-gnu.so") ;; *) die "wrong ABI suffix: $so" ;; esac
    done
done
(cd "$OUT" && sha256sum *.whl >SHA256SUMS)
log "wheels in $OUT"; ls -la "$OUT"
