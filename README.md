# ingenic-hf-python

Python 3.13 with everything Klippy needs, and Kalico's `c_helper.so`, built
for Ingenic XBurst2 printers with Ingenic's own MIPS toolchains:

| Target | Printer | glibc | Toolchain |
| --- | --- | --- | --- |
| `k1` | Creality K1 / K1 SE (SimpleAF Kalico) | 2.29 | Ingenic 5.0.2 GCC 7.2 `mips-gcc720-glibc229` |
| `c5` | FlashForge Creator 5 | 2.33 | Ingenic r6.0.0 GCC 12.1 |

The bundle contains Python 3.13.9 with pip (`ensurepip`), greenlet 3.3.2,
cffi 2.0.0, jinja2, markupsafe, pyserial, pycparser, numpy 2.2.2 and
`c_helper.so`. It also has its own shared libraries with headers: zlib,
libffi, OpenSSL 3.0, SQLite, bzip2, xz, libsodium and libjpeg. That gives the
standard library `ssl`, `hashlib`, `sqlite3`, `bz2` and `lzma`, and gives
pip-built modules (Pillow for Moonraker, for example) something hard-float
to link against. It's
hard-float (O32, FP64, nan2008), like the printers' own system libraries, and
links against the printer's glibc, so nothing from glibc is bundled. It
installs to `/usr/data/python-hf`.

## Build

On a Debian/Ubuntu x86_64 machine (WSL works):

```sh
sudo apt install build-essential curl git file xz-utils bzip2 python3
git clone https://github.com/FlashForge-C5-Modding-Group/build-python-13.git && cd build-python-13
./build.sh k1        # or: ./build.sh c5
```

That one command:
1. downloads both toolchains and every source (all pinned with SHA-256 in
   `sources.txt`) into `~/.cache/ingenic-hf-python`;
2. clones Kalico (`pellcorp/kalico` branch `aug2026` for `k1`);
3. builds a host Python 3.13, then zlib, libffi, CPython, greenlet, cffi,
   numpy and `c_helper.so` for the printer;
4. checks that every symbol in the bundle resolves against the printer's
   glibc;
5. runs the tests under QEMU against an x86 build of the same code;
6. writes `out/python-hf-k1.tar.gz` (about 13 MB) with its `.sha256` and a
   `BUILDINFO-k1` file.

The first build takes a while (two toolchains, about 450 MB, plus a host
Python). Rebuilds reuse what's done; delete `~/.cache/ingenic-hf-python/k1`
for a clean target build.

`c_helper.so` has to match the printer's Kalico sources. Build from the
printer's exact commit: `KALICO_REF=<commit> ./build.sh k1`, or use an existing
checkout with `KALICO_DIR=/path/to/kalico`. Other options: `--no-test` skips
the QEMU tests; `WORK=` moves the cache.

## Try it on a K1

```sh
scp out/python-hf-k1.tar.gz printer/k1-run-hf.sh root@<printer>:/usr/data/
ssh root@<printer>
cd /usr/data && gunzip -c python-hf-k1.tar.gz | tar -xf -
sh /usr/data/k1-run-hf.sh
```

`k1-run-hf.sh` stops `S55klipper_service` and starts Klippy the same way, but
on `/usr/data/python-hf/bin/python3.13`. It runs from a copy of `klippy/` with
the bundle's `c_helper.so`, so the Kalico tree isn't changed. It refuses to run
while printing. To go back: `/etc/init.d/S55klipper_service restart`, or
reboot.

Tested on a K1 SE with SimpleAF Kalico `2de10b68`: all three MCUs
configured, "Printer is ready"; `c_helper.so` and numpy results identical to
x86. Klippy used 38 MB of RAM versus 31.5 MB on Creality's Python 3.8, with
140 MB still free.

## Compiling on the printer (c_helper.so, pip)

Kalico rebuilds `c_helper.so` with `gcc` whenever its chelper sources change,
for example after an update, and pip compiles C extensions. Entware's gcc
and libraries are soft-float, so the bundle's `cc/` folder turns that gcc
into a hard-float compiler for this Python:
- `cc/bin/gcc` runs Entware's gcc (`/opt/bin/gcc`, or `ENTWARE_GCC`) with
  `-mhard-float -mfp64 -mnan=2008`;
- it uses glibc's headers, crt files, `libc_nonshared.a` and libgcc from the
  Ingenic toolchain, and the bundle's own headers and libraries;
- it links against the printer's `/lib` glibc and loader, never Entware's,
  with an rpath to the bundle's `lib`.

The bundle's sysconfig names `cc/bin/gcc` as `CC`/`LDSHARED`, so pip uses it
without any setup. For Kalico, put `cc/bin` first in Klippy's `PATH`. On a
Creator 5 it builds a `c_helper.so` with identical output in about 50 s. C++
extensions aren't covered.

## Speed build (default)

Klippy's own Python is the main CPU load on these SoCs, so CPython is built
for speed (`PY_FAST=1`, the default; `PY_FAST=0` builds it as before):
- **Static libpython** (`--disable-shared`): on 32-bit MIPS every call
  inside a shared library goes through the GOT and `$t9`. Linked into the
  executable, the interpreter calls directly. Extension modules (greenlet, cffi,
  numpy, the stdlib's, pip-built ones) take the C API from `python3.13`, which
  exports it; there is no `libpython3.13.so` in the bundle.
- **PGO + LTO** (`--enable-optimizations --with-lto`): the instrumented build
  runs CPython's `--pgo` test set under QEMU (`RUNSHAREDLIB` points at
  `qemu-mipsel-static`), and the final build is optimized from that profile.
  This makes the CPython step take much longer.
- **`-march=xburst2`** (Creator 5 only): Ingenic's GCC 12 knows the core. It
  is the same ISA as the default `mips32r2` (FP64, no MSA), with XBurst2
  instruction scheduling. The K1's GCC 7.2 build is unchanged. The `cc/`
  wrapper drops `-march`/`-mtune` from sysconfig's flags, since Entware's gcc
  may not know them.

Measure on the printer before switching: `printer/c5-bench.sh` times the
installed `/usr/data/python-hf` against an unpacked new bundle (Klippy batch
mode on bursts of short moves, plus plain-Python workloads like Klippy's). It
installs and restarts nothing and refuses to run while printing.

```sh
mkdir -p /usr/data/python-hf-new
gunzip -c python-hf-c5.tar.gz | tar -xf - -C /usr/data/python-hf-new --strip-components=1
sh c5-bench.sh /usr/data/python-hf-new     # copy printer/c5-bench* next to it
```

## How the K1 build works

GCC 7.2 builds most of it. numpy 2.2.2 needs GCC 8.4 or newer, and greenlet
3.3.2 needs C++20, so those two use the r6.0.0 GCC 12 pointed at the glibc
2.29 sysroot, from a copy adjusted for 2.29:
- its fixincluded `pthread.h` (from glibc 2.33) is removed;
- libstdc++'s glibc 2.30+ clocklock calls are turned off in `c++config.h`;
- the C++ runtime is linked statically;
- glibc 2.32's `__libc_single_threaded` is defined as 0 inside each C++
  module, so libstdc++ stays on its thread-safe paths.

`tests/check-symbols.sh` checks the result symbol by symbol, not only by
version tag. A symbol missing from the old glibc can end up unversioned, so a
version-tag check would miss it.

## Tests

`tests/run.sh` (run by `build.sh`) uses `qemu-mipsel-static -cpu P5600`, with
the toolchain sysroot standing in for the printer's `/lib`. If QEMU isn't
installed, it fetches Debian/Ubuntu's `qemu-user-static` without root.
- **imports:** everything Klippy imports.
- **`chelper_test.py`:** drives `c_helper.so` through cffi the way Klippy
  does (corexy steppers, the 13-double `trapq_append`, input shaper, pressure
  advance, `trapq_extract_old`). Every value must match an x86 build of the
  same Kalico sources bit for bit. It also stress-tests threads (errno from
  background threads, overflowing `ldexp`, cffi double calls).
- **`numpy_test.py`:** runs Kalico's input shaper fit on a synthetic
  recording, and the results must match x86 numpy 2.2.2.

QEMU doesn't catch everything (some bugs only show on real hardware), so try
it on a printer before relying on it.
