#!/bin/bash
# check-symbols.sh BUNDLE_PREFIX SYSROOT NM
# Every non-weak undefined dynamic symbol in the bundle must be defined by the
# target's glibc (the toolchain sysroot) or by the bundle itself. Version tags
# alone aren't enough: a symbol the old glibc lacks can end up unversioned.
# A glibc symbol referenced without a version fails too: it binds to the
# oldest version (sem_getvalue@GLIBC_2.0 when libpthread isn't linked).
set -euo pipefail
B=$1 SYSROOT=$2 NM=$3
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
elfs=$(find "$B" -type f \( -name '*.so*' -o -path '*/bin/*' \) -exec sh -c 'file "$1" | grep -q ELF && echo "$1"' _ {} \;)
# (Some sysroot .so files are linker scripts; nm failing on them is fine.)
for f in "$SYSROOT"/lib/*.so* "$SYSROOT"/usr/lib/*.so*; do
    [ -f "$f" ] && "$NM" -D --defined-only "$f" 2>/dev/null || true
done | awk '{print $NF}' | sed 's/@.*//' | sort -u >"$tmp/glibc"
for f in $elfs; do
    "$NM" -D --defined-only "$f" 2>/dev/null || true
done | awk '{print $NF}' | sed 's/@.*//' | sort -u >"$tmp/bundle"
sort -u "$tmp/glibc" "$tmp/bundle" >"$tmp/defined"
comm -23 "$tmp/glibc" "$tmp/bundle" >"$tmp/glibc-only"
bad=0
for f in $elfs; do
    { "$NM" -D --undefined-only "$f" 2>/dev/null || true; } | awk '$1 == "U" {print $2}' >"$tmp/raw"
    sed 's/@.*//' "$tmp/raw" | sort -u >"$tmp/undef"
    missing=$(comm -23 "$tmp/undef" "$tmp/defined")
    if [ -n "$missing" ]; then
        echo "UNRESOLVED in ${f#$B/}: $(echo $missing)"
        bad=1
    fi
    grep -v '@' "$tmp/raw" | sort -u >"$tmp/unversioned" || true
    unversioned=$(comm -12 "$tmp/unversioned" "$tmp/glibc-only")
    if [ -n "$unversioned" ]; then
        echo "UNVERSIONED glibc symbols in ${f#$B/} (missing -l?): $(echo $unversioned)"
        bad=1
    fi
done
[ "$bad" = 0 ] && echo "== symbols: everything resolves against the target glibc and the bundle"
exit $bad
