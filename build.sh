#!/bin/bash
# Hard-float Python 3.13 + Klippy's dependencies + Kalico's c_helper.so for
# Ingenic XBurst2 printers, built with Ingenic's own toolchains.
#
#   ./build.sh k1        Creality K1 / K1 SE (glibc 2.29), Kalico from pellcorp/kalico
#   ./build.sh c5        FlashForge Creator 5 (glibc 2.33), Kalico from FlashForge-C5-Modding-Group/kalico
#   ./build.sh k1 --no-test    skip the QEMU tests
#
# Environment: WORK (cache/build dir, default ~/.cache/ingenic-hf-python),
# PY_FAST=0 (shared libpython, no PGO/LTO, as before; see README.md),
# KALICO_DIR (use this Kalico checkout), KALICO_REPO / KALICO_REF (what to
# clone; use the printer's exact commit so c_helper.so matches its sources).
# Output: out/python-hf-<target>.tar.gz (+ .sha256, BUILDINFO). See README.md.
set -euo pipefail

TARGET=${1:-}
RUN_TESTS=1
[ "${2:-}" = --no-test ] && RUN_TESTS=0
REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/.cache/ingenic-hf-python}
DL=$WORK/downloads
OUTDIR=$REPO/out
PREFIX=/usr/data/python-hf
PYVER=3.13.9
NUMPY_VER=2.2.2
J=${J:-$(nproc)}
PY_FAST=${PY_FAST:-1}

log() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
meson_list() { local s= a; for a in "$@"; do s="$s${s:+, }'$a'"; done; echo "$s"; }

case "$TARGET" in
k1)
    KALICO_REPO=${KALICO_REPO:-https://github.com/pellcorp/kalico.git}
    KALICO_REF=${KALICO_REF:-aug2026}
    ;;
c5)
    KALICO_REPO=${KALICO_REPO:-https://github.com/FlashForge-C5-Modding-Group/kalico.git}
    KALICO_REF=${KALICO_REF:-something}
    ;;
*) sed -n '2,15p' "$0"; exit 1 ;;
esac

# ---------------------------------------------------------------- 0. host
for cmd in curl git make gcc g++ python3 file tar xz bzip2 sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing host tool: $cmd (see README.md)"
done
mkdir -p "$DL" "$OUTDIR"

# ----------------------------------------------- 1. downloads (sha256-checked)
fetch() {  # fetch FILE: download from sources.txt and verify
    local line url sum
    line=$(grep -E "^$1 " "$REPO/sources.txt") || die "$1 not in sources.txt"
    sum=$(echo "$line" | awk '{print $2}'); url=$(echo "$line" | awk '{print $3}')
    if [ ! -f "$DL/$1" ] || ! echo "$sum  $DL/$1" | sha256sum -c --status; then
        log "downloading $1"
        curl -fL --retry 3 -o "$DL/$1.part" "$url" || die "download failed: $url"
        mv "$DL/$1.part" "$DL/$1"
    fi
    echo "$sum  $DL/$1" | sha256sum -c --status || die "checksum mismatch: $1"
}
for f in $(grep -v '^#' "$REPO/sources.txt" | awk 'NF {print $1}'); do
    case "$f" in mips-gcc720-glibc229.tar.gz) [ "$TARGET" = k1 ] || continue ;; esac
    fetch "$f"
done
SRC=$DL

# ------------------------------------------------------------ 2. toolchains
# The r6.0.0 toolchain (GCC 12.1, glibc 2.33) builds everything for the C5.
# The K1 needs glibc 2.29: Ingenic's GCC 7.2 toolchain builds most of it, and
# numpy (needs GCC >= 8.4) and greenlet (C++20) use a copy of GCC 12 pointed
# at the glibc 2.29 sysroot.
R6=$WORK/tc-r6
if [ ! -x "$R6/bin/mips-xburst2-linux-gnu-gcc" ]; then
    log "unpacking the r6.0.0 toolchain"
    rm -rf "$R6" "$R6.tmp" && mkdir -p "$R6.tmp"
    tar -xjf "$DL/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2" -C "$R6.tmp" --strip-components=1
    mv "$R6.tmp" "$R6"   # only a complete unpack counts
fi
BASE=$WORK/$TARGET
mkdir -p "$BASE"
case "$TARGET" in
c5)
    T=$R6/bin/mips-xburst2-linux-gnu-
    HOST=mips-xburst2-linux-gnu
    SYSROOT=$R6/sysroot
    SYSLIBS="$SYSROOT/lib"
    NP_T=$T; NP_FLAGS=(); NP_LINK=(-ldl -lpthread)
    # Same ISA (mips32r2, FP64), XBurst2 instruction scheduling
    ARCH_FLAGS=(-march=xburst2)
    ;;
k1)
    TC=$WORK/tc-glibc229
    if [ ! -x "$TC/bin/mips-linux-gnu-gcc" ]; then
        log "unpacking the glibc 2.29 toolchain"
        rm -rf "$TC" "$TC.tmp" && mkdir -p "$TC.tmp"
        tar -xzf "$DL/mips-gcc720-glibc229.tar.gz" -C "$TC.tmp" --strip-components=1
        mv "$TC.tmp" "$TC"
    fi
    T=$TC/bin/mips-linux-gnu-
    HOST=mips-linux-gnu
    SYSROOT=$TC/mips-linux-gnu/libc
    SYSLIBS="$SYSROOT/lib $SYSROOT/usr/lib"
    # GCC 12 adjusted for glibc 2.29: drop its fixincluded (glibc 2.33)
    # pthread.h, and turn off libstdc++'s glibc 2.30+ clocklock calls.
    GCC12=$WORK/gcc12-glibc229
    if [ ! -x "$GCC12/bin/mips-xburst2-linux-gnu-gcc" ]; then
        rm -rf "$GCC12" "$GCC12.tmp" && cp -a "$R6" "$GCC12.tmp"
        rm -f "$GCC12.tmp"/lib/gcc/mips-xburst2-linux-gnu/12.1.0/include-fixed/pthread.h
        find "$GCC12.tmp" -name c++config.h -path '*bits/*' -exec sed -i -E \
            's@^#define (_GLIBCXX_USE_PTHREAD_(MUTEX_CLOCKLOCK|COND_CLOCKWAIT|RWLOCK_CLOCKLOCK)) 1@/* glibc 2.29 lacks \1 */@' {} +
        mv "$GCC12.tmp" "$GCC12"
    fi
    NP_T=$GCC12/bin/mips-xburst2-linux-gnu-
    # GCC 12's static libstdc++ reads glibc 2.32's __libc_single_threaded;
    # 0 ("may be multi-threaded") keeps it on its thread-safe paths.
    printf 'char __libc_single_threaded __attribute__((visibility("hidden"))) = 0;\n' \
        >"$BASE/glibc229-compat.c"
    "${NP_T}gcc" "--sysroot=$SYSROOT" -O2 -fPIC -c "$BASE/glibc229-compat.c" -o "$BASE/glibc229-compat.o"
    NP_FLAGS=("--sysroot=$SYSROOT")
    NP_LINK=("--sysroot=$SYSROOT" -static-libstdc++ -static-libgcc "$BASE/glibc229-compat.o" -ldl -lpthread)
    ARCH_FLAGS=()
    ;;
esac
W=$BASE/work
STAGE=$BASE/stage
P=$STAGE$PREFIX
mkdir -p "$W" "$STAGE"

# ------------------------------------------------------------- 3. Kalico
if [ -n "${KALICO_DIR:-}" ]; then
    KALICO=$KALICO_DIR
else
    KALICO=$BASE/kalico
    if [ ! -d "$KALICO/.git" ]; then
        log "cloning $KALICO_REPO"
        git clone -q "$KALICO_REPO" "$KALICO"
    fi
    git -C "$KALICO" fetch -q origin
    git -C "$KALICO" checkout -q "$KALICO_REF" 2>/dev/null ||
        git -C "$KALICO" checkout -q "origin/$KALICO_REF"
    git -C "$KALICO" merge -q --ff-only "origin/$KALICO_REF" 2>/dev/null || true
fi
[ -f "$KALICO/klippy/chelper/__init__.py" ] || die "no Kalico checkout at $KALICO"

# ------------------------------------------------- 4. host Python $PYVER
HOSTPY=$WORK/hostpy/bin/python3.13
if [ ! -x "$HOSTPY" ]; then
    log "host Python $PYVER (needed to cross-build CPython)"
    rm -rf "$WORK/hostpy-src" && mkdir -p "$WORK/hostpy-src"
    tar -xJf "$SRC/Python-$PYVER.tar.xz" -C "$WORK/hostpy-src" --strip-components=1
    (cd "$WORK/hostpy-src" && ./configure --prefix="$WORK/hostpy" --without-ensurepip >/dev/null &&
        make -j"$J" >build.log 2>&1 && make install >install.log 2>&1) || die "host Python build failed"
fi

CROSS_ENV=(CC="${T}gcc" CXX="${T}g++" AR="${T}ar" RANLIB="${T}ranlib"
    READELF="${T}readelf" STRIP="${T}strip")

# ------------------------------------------------------- 5. zlib, libffi
if [ ! -f "$P/lib/libz.so" ]; then
    log zlib
    rm -rf "$W/zlib" && mkdir -p "$W/zlib"
    tar -xzf "$SRC/zlib-1.3.1.tar.gz" -C "$W/zlib" --strip-components=1
    (cd "$W/zlib" && env "${CROSS_ENV[@]}" ./configure --prefix="$PREFIX" --shared >/dev/null &&
        make -j"$J" >build.log 2>&1 && make install DESTDIR="$STAGE" >install.log 2>&1)
fi
if [ ! -f "$P/lib/libffi.so" ]; then
    log libffi
    rm -rf "$W/libffi" && mkdir -p "$W/libffi"
    tar -xzf "$SRC/libffi-3.4.7.tar.gz" -C "$W/libffi" --strip-components=1
    (cd "$W/libffi" && env "${CROSS_ENV[@]}" ./configure --host="$HOST" --prefix="$PREFIX" \
        --disable-static --disable-docs >/dev/null &&
        make -j"$J" >build.log 2>&1 && make install DESTDIR="$STAGE" >install.log 2>&1)
fi

# ------------------------- 5b. libraries for the stdlib and pip-built modules
# Shared, with headers, in the bundle: Entware's are soft-float, so anything
# pip compiles on the printer links against these.
autotools_lib() {  # autotools_lib NAME TARBALL MARKER [configure args]
    local name=$1 tarball=$2 marker=$3; shift 3
    [ -e "$P/lib/$marker" ] && return 0
    log "$name"
    rm -rf "$W/$name" && mkdir -p "$W/$name"
    tar -xzf "$SRC/$tarball" -C "$W/$name" --strip-components=1
    (cd "$W/$name" && env "${CROSS_ENV[@]}" ./configure --host="$HOST" --prefix="$PREFIX" \
        --disable-static "$@" >configure.log 2>&1 &&
        make -j"$J" >build.log 2>&1 && make install DESTDIR="$STAGE" >install.log 2>&1) ||
        die "$name build failed, see $W/$name/*.log"
}
if [ ! -e "$P/lib/libssl.so" ]; then
    log openssl
    rm -rf "$W/openssl" && mkdir -p "$W/openssl"
    tar -xzf "$SRC/openssl-3.0.22.tar.gz" -C "$W/openssl" --strip-components=1
    (cd "$W/openssl" && ./Configure linux-generic32 --cross-compile-prefix="$T" \
        --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib shared no-tests \
        -latomic "-Wl,-rpath,$PREFIX/lib" >configure.log 2>&1 &&
        make -j"$J" >build.log 2>&1 &&
        make install_sw install_ssldirs DESTDIR="$STAGE" >install.log 2>&1) ||
        die "openssl build failed, see $W/openssl/*.log"
fi
autotools_lib sqlite sqlite-autoconf-3540100.tar.gz libsqlite3.so
autotools_lib xz xz-5.8.4.tar.gz liblzma.so --disable-xz --disable-xzdec --disable-lzmadec \
    --disable-lzmainfo --disable-lzma-links --disable-scripts --disable-doc --disable-nls
autotools_lib libsodium libsodium-1.0.20.tar.gz libsodium.so
autotools_lib jpeg jpegsrc.v9f.tar.gz libjpeg.so
if [ ! -e "$P/lib/libbz2.so" ]; then
    log bzip2
    rm -rf "$W/bzip2" && mkdir -p "$W/bzip2"
    tar -xzf "$SRC/bzip2-1.0.8.tar.gz" -C "$W/bzip2" --strip-components=1
    (cd "$W/bzip2" && make -f Makefile-libbz2_so CC="${T}gcc" >build.log 2>&1) ||
        die "bzip2 build failed, see $W/bzip2/build.log"
    cp "$W/bzip2/libbz2.so.1.0.8" "$P/lib/"
    ln -sf libbz2.so.1.0.8 "$P/lib/libbz2.so.1.0"
    ln -sf libbz2.so.1.0.8 "$P/lib/libbz2.so.1"
    ln -sf libbz2.so.1.0.8 "$P/lib/libbz2.so"
    cp "$W/bzip2/bzlib.h" "$P/include/"
fi

# ------------------------------------------------------------- 6. CPython
if ! ls "$P"/lib/python3.13/lib-dynload/_ssl.*.so >/dev/null 2>&1; then
    log "CPython $PYVER"
    rm -rf "$W/python" && mkdir -p "$W/python"
    tar -xJf "$SRC/Python-$PYVER.tar.xz" -C "$W/python" --strip-components=1
    cat >"$W/python/config.site" <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
ac_cv_broken_sem_getvalue=no
py_cv_module__uuid=n/a
EOF
    PY_ENV=("${CROSS_ENV[@]}") PY_CONF=(--enable-shared)
    if [ "$PY_FAST" = 1 ]; then
        # Static libpython (no PIC call overhead in the interpreter), LTO, and
        # PGO trained by running the instrumented build under QEMU.
        QEMU=$(command -v qemu-mipsel-static || command -v qemu-mipsel || true)
        if [ -z "$QEMU" ]; then
            Q=$WORK/qemu
            if [ ! -x "$Q/usr/bin/qemu-mipsel-static" ]; then
                command -v apt-get >/dev/null || die "PGO needs qemu-user-static (qemu-mipsel-static), or PY_FAST=0"
                mkdir -p "$Q" && (cd "$Q" && apt-get download qemu-user-static >/dev/null &&
                    dpkg-deb -x qemu-user-static_*.deb . && rm -f ./*.deb)
            fi
            QEMU=$Q/usr/bin/qemu-mipsel-static
        fi
        PY_ENV+=(AR="${T}gcc-ar" RANLIB="${T}gcc-ranlib")
        PY_CONF=(--disable-shared --enable-optimizations --with-lto)
    fi
    # The Makefile runs the profile task as a native ./python, so for a cross
    # build: instrumented build, the task under QEMU (serially: QEMU can't
    # start MIPS subprocesses), then the profile-guided build.
    py_make() {
        if [ "$PY_FAST" = 1 ]; then
            make -j"$J" profile-gen-stamp &&
                { "$QEMU" -cpu P5600 -L "$SYSROOT" -E LD_LIBRARY_PATH="$P/lib" \
                    ./python -m test --pgo --timeout=900 >pgo-task.log 2>&1 || true; } &&
                ls Python/*.gcda >/dev/null 2>&1 &&
                make clean-retain-profile && touch profile-run-stamp
        fi &&
            make -j"$J"
    }
    (cd "$W/python" && env "${PY_ENV[@]}" CONFIG_SITE="$W/python/config.site" \
        CFLAGS="${ARCH_FLAGS[*]}" \
        CPPFLAGS="-I$P/include" LDFLAGS="-L$P/lib -Wl,-rpath,$PREFIX/lib" \
        LDSHARED="${T}gcc -shared -fPIC -lpthread -ldl" \
        LIBFFI_CFLAGS="-I$P/include" LIBFFI_LIBS="-L$P/lib -lffi" \
        ZLIB_CFLAGS="-I$P/include" ZLIB_LIBS="-L$P/lib -lz" \
        LIBSQLITE3_CFLAGS="-I$P/include" LIBSQLITE3_LIBS="-L$P/lib -lsqlite3" \
        BZIP2_CFLAGS="-I$P/include" BZIP2_LIBS="-L$P/lib -lbz2" \
        LIBLZMA_CFLAGS="-I$P/include" LIBLZMA_LIBS="-L$P/lib -llzma" \
        ./configure --host="$HOST" --build=x86_64-pc-linux-gnu --prefix="$PREFIX" \
        --with-openssl="$P" --with-openssl-rpath=no "${PY_CONF[@]}" --with-build-python="$HOSTPY" --without-ensurepip \
        --disable-test-modules >configure.log 2>&1 &&
        py_make >build.log 2>&1 && make install DESTDIR="$STAGE" >install.log 2>&1) ||
        die "CPython build failed, see $W/python/*.log"
fi

PYINC=$P/include/python3.13
SP=$P/lib/python3.13/site-packages
EXT=$(ls "$P"/lib/python3.13/lib-dynload/_struct.*.so | sed 's#.*/_struct##')
EXTFLAGS=(-O2 "${ARCH_FLAGS[@]}" -shared -fPIC "-I$PYINC" "-L$P/lib" "-Wl,-rpath,$PREFIX/lib")
# With a static libpython, extensions take the API from the python3.13 binary
[ "$PY_FAST" = 1 ] || EXTFLAGS+=(-lpython3.13)

# ------------------------------------------------------ 7. greenlet, cffi
log greenlet
rm -rf "$W/greenlet" && mkdir -p "$W/greenlet"
tar -xzf "$SRC"/greenlet-*.tar.gz -C "$W/greenlet" --strip-components=1
rm -rf "$SP/greenlet" && mkdir -p "$SP/greenlet"
(cd "$W/greenlet/src/greenlet" && find . -name '*.py' -not -path './tests/*' -exec cp --parents {} "$SP/greenlet/" \;)
"${NP_T}g++" "${NP_FLAGS[@]}" "${EXTFLAGS[@]}" "${NP_LINK[@]}" -I"$W/greenlet/src/greenlet" \
    -o "$SP/greenlet/_greenlet$EXT" "$W/greenlet/src/greenlet/greenlet.cpp"

log cffi
rm -rf "$W/cffi" && mkdir -p "$W/cffi"
tar -xzf "$SRC"/cffi-2.0.0.tar.gz -C "$W/cffi" --strip-components=1
rm -rf "$SP/cffi" && cp -r "$W/cffi/src/cffi" "$SP/cffi"
"${T}gcc" "${EXTFLAGS[@]}" -I"$P/include" -o "$SP/_cffi_backend$EXT" \
    "$W/cffi/src/c/_cffi_backend.c" -lffi -ldl -lpthread

# ------------------------------------------------- 8. pure-Python packages
log "pure Python packages"
for whl in jinja2-*.whl pyserial-*.whl pycparser-*.whl; do
    python3 -m zipfile -e "$SRC/$(cd "$SRC" && ls $whl)" "$SP"
done
rm -rf "$W/markupsafe" && mkdir -p "$W/markupsafe"
tar -xzf "$SRC"/markupsafe-*.tar.gz -C "$W/markupsafe" --strip-components=1
rm -rf "$SP/markupsafe" && mkdir -p "$SP/markupsafe"
cp "$W"/markupsafe/src/markupsafe/*.py "$SP/markupsafe/"   # optional C speedups left out
# dbus-fast: Moonraker's core dbus_manager imports it, though the printer has
# no D-Bus. Plain Python, with a dist-info so pip counts the requirement as met
# instead of building it on the printer.
rm -rf "$W/dbus-fast" "$SP/dbus_fast" "$SP"/dbus_fast-*.dist-info && mkdir -p "$W/dbus-fast"
tar -xzf "$SRC/dbus_fast-5.0.22.tar.gz" -C "$W/dbus-fast" --strip-components=1
(cd "$W/dbus-fast/src" && find dbus_fast \( -name '*.py' -o -name py.typed \) -exec cp --parents {} "$SP/" \;)
mkdir -p "$SP/dbus_fast-5.0.22.dist-info"
printf 'Metadata-Version: 2.1\nName: dbus-fast\nVersion: 5.0.22\n' >"$SP/dbus_fast-5.0.22.dist-info/METADATA"
: >"$SP/dbus_fast-5.0.22.dist-info/RECORD"

# -------------------------------------------------------------- 9. numpy
# numpy's bundled Meson runs the host Python with the target's
# _sysconfigdata (paths pointed at the stage). No BLAS/LAPACK, no SIMD.
if [ ! -d "$SP/numpy" ]; then
    log "numpy $NUMPY_VER"
    HB=$BASE/hostbuild
    rm -rf "$HB" && mkdir -p "$HB/site" "$HB/bin" "$HB/xsys"
    python3 -m zipfile -e "$SRC"/cython-*.whl "$HB/site"
    python3 -m zipfile -e "$SRC"/ninja-*.whl "$HB/site"
    chmod 755 "$HB"/site/ninja-*.data/scripts/ninja
    ln -sf "$(ls "$HB"/site/ninja-*.data/scripts/ninja)" "$HB/bin/ninja"
    printf '#!/bin/sh\nPYTHONPATH=%s exec python3 -m cython "$@"\n' "$HB/site" >"$HB/bin/cython"
    sed "s#$PREFIX#$P#g" "$P"/lib/python3.13/_sysconfigdata__linux_mipsel-linux-gnu.py \
        >"$HB/xsys/_sysconfigdata__linux_mipsel-linux-gnu.py"
    cat >"$HB/bin/xpython" <<EOF
#!/bin/sh
export _PYTHON_HOST_PLATFORM=linux-mips
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__linux_mipsel-linux-gnu
export PYTHONPATH=$HB/xsys
exec $HOSTPY "\$@"
EOF
    chmod 755 "$HB/bin/cython" "$HB/bin/xpython"
    cat >"$W/numpy-cross.txt" <<EOF
[binaries]
c = '${NP_T}gcc'
cpp = '${NP_T}g++'
ar = '${NP_T}ar'
strip = '${NP_T}strip'
python = '$HB/bin/xpython'
cython = '$HB/bin/cython'
[host_machine]
system = 'linux'
cpu_family = 'mips'
cpu = 'mips32r2'
endian = 'little'
[properties]
longdouble_format = 'IEEE_DOUBLE_LE'
needs_exe_wrapper = true
[built-in options]
c_args = [$(meson_list "${NP_FLAGS[@]}")]
cpp_args = [$(meson_list "${NP_FLAGS[@]}")]
c_link_args = [$(meson_list "${NP_LINK[@]}")]
cpp_link_args = [$(meson_list "${NP_LINK[@]}")]
EOF
    rm -rf "$W/numpy" "$W/numpy-dest" && mkdir -p "$W/numpy"
    tar -xzf "$SRC/numpy-$NUMPY_VER.tar.gz" -C "$W/numpy" --strip-components=1
    (cd "$W/numpy" && export PATH="$HB/bin:$PATH" &&
        python3 vendored-meson/meson/meson.py setup build . \
            --cross-file "$W/numpy-cross.txt" --prefix="$PREFIX" --buildtype=release \
            -Db_ndebug=if-release -Dallow-noblas=true -Dblas=none -Dlapack=none \
            -Dcpu-baseline=none -Dcpu-dispatch=none -Ddisable-highway=true \
            -Ddisable-svml=true -Db_asneeded=false >setup.log 2>&1 &&
        ninja -C build -j"$J" >build.log 2>&1 &&
        python3 vendored-meson/meson/meson.py install -C build \
            --destdir "$W/numpy-dest" >install.log 2>&1) || die "numpy build failed, see $W/numpy/*.log"
    cp -r "$(find "$W/numpy-dest" -type d -name numpy -path '*site-packages/numpy' | head -1)" "$SP/numpy"
    find "$SP/numpy" -type d -name tests -prune -exec rm -rf {} +
fi

# --------------------------------------------------------- 10. c_helper.so
KCOMMIT=$(git -C "$KALICO" rev-parse HEAD 2>/dev/null || echo unknown)
log "c_helper.so from Kalico ${KCOMMIT:0:8}"
CH=$KALICO/klippy/chelper
SOURCES=$(cd "$CH" && "$HOSTPY" -c 'import re;s=open("__init__.py").read();print(" ".join(re.findall(r"\"(\w+\.c)\"",s.split("SOURCE_FILES")[1].split("]")[0])))')
rm -rf "$P/chelper" && mkdir -p "$P/chelper"
(cd "$CH" && "${T}gcc" -Wall -O2 "${ARCH_FLAGS[@]}" -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
    -o "$P/chelper/c_helper.so" $SOURCES -lm -lpthread)
echo "$KCOMMIT" >"$P/chelper/kalico-commit"

# ------------------------------------------------- 10b. gcc kit, pip builds
# cc/bin/gcc runs the printer's Entware gcc (soft-float) as a hard-float
# compiler for this Python: Kalico rebuilds c_helper.so with it, and pip
# builds C extensions with it (the bundle's sysconfig names it as CC).
log "gcc kit"
rm -rf "$P/cc" && mkdir -p "$P/cc/bin" "$P/cc/lib"
cp -r "$SYSROOT/usr/include" "$P/cc/include"
# glibc's limits.h include_next's GCC's, which lives in include-fixed.
mkdir -p "$P/cc/include-fixed"
cp "$(dirname "$("${T}gcc" -print-libgcc-file-name)")"/include-fixed/{limits.h,syslimits.h} "$P/cc/include-fixed/"
LIBGCC_DIR=$(dirname "$("${T}gcc" -print-libgcc-file-name)")
cp "$LIBGCC_DIR"/{libgcc.a,crtbegin.o,crtend.o,crtbeginS.o,crtendS.o} "$P/cc/lib/"
CRT_DIR=$(dirname "$("${T}gcc" -print-file-name=crt1.o)")
cp "$CRT_DIR"/{crt1.o,crti.o,crtn.o,libc_nonshared.a} "$P/cc/lib/"
# -lpthread and such must find the printer's glibc, not Entware's.
for so in "$CRT_DIR"/lib{c,m,pthread,dl,rt,util,crypt,resolv}.so; do
    [ -e "$so" ] || continue
    target=$(ls "$SYSROOT"/lib/"$(basename "$so")".[0-9]* 2>/dev/null | head -1 || true)
    if [ -n "$target" ]; then ln -sf "/lib/$(basename "$target")" "$P/cc/lib/$(basename "$so")"; fi
done
INTERP=$("${T}readelf" -l "$P/bin/python3.13" | sed -n 's/.*interpreter: \(.*\)]/\1/p')
cat >"$P/cc/bin/gcc" <<EOF
#!/bin/sh
INTERP=$INTERP
EOF
cat >>"$P/cc/bin/gcc" <<'EOF'
K=$(cd "$(dirname "$0")/.." && pwd)
P=$(dirname "$K")
L=$K/lib
GCC=${ENTWARE_GCC:-/opt/bin/gcc}
link=1 shared=0
for a; do
    shift
    case $a in
        # sysconfig's CFLAGS carry the build's -march; Entware's gcc may not know it
        -march=*|-mtune=*) continue ;;
        -c|-S|-E|-M|-MM) link=0 ;;
        -shared) shared=1 ;;
    esac
    set -- "$@" "$a"
done
set -- -mabi=32 -mips32r2 -mhard-float -mfp64 -mnan=2008 -nostdinc \
    -isystem "$("$GCC" -print-file-name=include)" -isystem "$P/include" \
    -isystem "$K/include-fixed" -isystem "$K/include" "$@"
if [ $link = 1 ]; then
    if [ $shared = 1 ]; then
        set -- -nostdlib -nostartfiles "$L/crti.o" "$L/crtbeginS.o" "$@"
        end="$L/crtendS.o $L/crtn.o"
    else
        set -- -nostdlib -nostartfiles -Wl,-dynamic-linker,"$INTERP" \
            "$L/crt1.o" "$L/crti.o" "$L/crtbegin.o" "$@"
        end="$L/crtend.o $L/crtn.o"
    fi
    set -- "$@" -L"$P/lib" -L"$L" -Wl,-rpath,"$P/lib" \
        "$L/libgcc.a" -lpthread -lc "$L/libc_nonshared.a" -lm "$L/libgcc.a" $end
fi
exec "$GCC" "$@"
EOF
chmod 755 "$P/cc/bin/gcc"
# pip and setuptools build with sysconfig's CC/LDSHARED: point them at the
# wrapper (and Entware's binutils) instead of the cross toolchain.
for sc in "$P"/lib/python3.13/_sysconfigdata_*.py; do
    # gcc-ar/gcc-ranlib (the LTO build's) first, or the gcc rule turns them
    # into cc/bin/gcc-ar, which doesn't exist.
    sed -i -e "s|${T}gcc-ar|/opt/bin/ar|g" -e "s|${T}gcc-ranlib|/opt/bin/ranlib|g" \
        -e "s|${T}gcc|$PREFIX/cc/bin/gcc|g" -e "s|${T}g++|$PREFIX/cc/bin/gcc|g" \
        -e "s|${T}|/opt/bin/|g" -e "s|$P|$PREFIX|g" "$sc"
done
# CA certificates for ssl (Moonraker, pip): pip's own certifi bundle.
mkdir -p "$P/ssl"
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); open(sys.argv[2], "wb").write(z.read("pip/_vendor/certifi/cacert.pem"))' \
    "$(ls "$P"/lib/python3.13/ensurepip/_bundled/pip-*.whl)" "$P/ssl/cert.pem"

# ------------------------------------------------ 11. runtime libs, package
log "bundle"
for lib in libstdc++.so.6 libgcc_s.so.1 libatomic.so.1; do
    src=$(find $SYSLIBS -maxdepth 1 -name "$lib" 2>/dev/null | head -1)
    [ -n "$src" ] || die "missing $lib in $SYSLIBS"
    cp -L "$src" "$P/lib/$lib"
done
rm -rf "$P"/lib/python3.13/{idlelib,tkinter,turtledemo,test,config-3.13-*} \
    "$P"/lib/python3.13/lib2to3 "$P/share" "$P/lib/pkgconfig" "$P"/lib/*.a "$P"/lib/*.la \
    "$P"/cc/include/{drm,sound,rdma,scsi,video,xen,mtd}
find "$P" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$P" -type f \( -name '*.so*' -o -path '*/bin/*' \) -exec sh -c \
    'file "$1" | grep -q ELF && '"${T}"'strip --strip-unneeded "$1"' _ {} \;

"$REPO/tests/check-symbols.sh" "$P" "$SYSROOT" "${T}nm" || die "symbol check failed"

BUNDLE=python-hf-$TARGET.tar.gz
tar -czf "$OUTDIR/$BUNDLE" -C "$STAGE/usr/data" python-hf
(cd "$OUTDIR" && sha256sum "$BUNDLE" >"$BUNDLE.sha256")
cat >"$OUTDIR/BUILDINFO-$TARGET" <<EOF
target: $TARGET
python: $PYVER (prefix $PREFIX)$([ "$PY_FAST" = 1 ] && echo ", static libpython, PGO, LTO") ${ARCH_FLAGS[*]}
numpy: $NUMPY_VER, greenlet 3.3.2, cffi 2.0.0
kalico: $KALICO_REPO $KCOMMIT
toolchain: $("${T}gcc" --version | head -1)
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# --------------------------------------------------------------- 12. tests
if [ "$RUN_TESTS" = 1 ]; then
    "$REPO/tests/run.sh" "$TARGET" "$OUTDIR/$BUNDLE" "$SYSROOT" "$KALICO" "$WORK" "$HOSTPY" ||
        die "tests failed"
fi
log "done: $OUTDIR/$BUNDLE"
