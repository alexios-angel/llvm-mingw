#!/bin/sh
#
# Copyright (c) 2026 Alexios Angel
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# One-box driver for the std-embed toolchain matrix (8 cores / 32 GB /
# 256 GB devbox, Ubuntu 24.04). Produces, in order, into $OUT:
#
#   llvm-mingw-$TAG-ucrt-ubuntu-24.04-x86_64.tar.xz    Linux-hosted cross
#   llvm-mingw-$TAG-ucrt-ubuntu-24.04-aarch64.tar.xz   Linux/aarch64-hosted
#   llvm-mingw-$TAG-ucrt-{i686,x86_64,armv7,aarch64}.zip  Windows-hosted
#
# Every toolchain targets all five archs (i686/x86_64/armv7/aarch64/
# arm64ec) with the full feature set (lldb+python on Windows hosts,
# clang-tools-extra, all runtimes, sanitizers, openmp, cfguard), built
# from the std-embed clang/LLVM branch with std::fetch backed by real
# libcurl on every host (see build-curl.sh). macOS-universal and msys2
# hosts remain buildable with the upstream scripts but need real
# Apple/Windows hardware - not covered here.
#
# Compilers: stage A bootstraps with the distro clang+lld (fast at
# building LLVM); the Windows-hosted stages compile with the freshly
# built std-embed clang via the native toolchain's wrappers; the
# aarch64 host stage uses the distro cross gcc (upstream path).
#
# Modes: default plain Release (~20-24 h total). --pgo runs the
# upstream stage1/profile/thinlto-pgo pipeline first (~32-40 h total).
# Expect ~90-110 GB peak disk with the default per-stage cleanup.
# OOM relief valve if ThinLTO/PGO links thrash 32 GB:
#   LLVM_CMAKEFLAGS="-DLLVM_PARALLEL_LINK_JOBS=2" ./build-everything.sh --pgo
set -e

TAG="$(TZ=UTC date +%Y%m%d)-stdembed"
OUT="$(pwd)/dist"
HOSTS="i686 x86_64 armv7 aarch64"
CURL_ARGS=
KEEP_BUILDS=
PGO=
THINLTO=
SKIP_NATIVE=
SKIP_AARCH64=
SKIP_WINDOWS=
WINE_SMOKE=

while [ $# -gt 0 ]; do
    case "$1" in
    --pgo)
        PGO=1
        ;;
    --thinlto)
        THINLTO=1
        ;;
    --archs=*)
        TOOLCHAIN_ARCHS="$(echo ${1#*=} | tr , ' ')"
        export TOOLCHAIN_ARCHS
        ;;
    --hosts=*)
        HOSTS="$(echo ${1#*=} | tr , ' ')"
        ;;
    --skip-native)
        SKIP_NATIVE=1
        ;;
    --skip-cross-aarch64)
        SKIP_AARCH64=1
        ;;
    --skip-windows)
        SKIP_WINDOWS=1
        ;;
    --disable-curl)
        CURL_ARGS="--disable-curl"
        ;;
    --keep-builds)
        KEEP_BUILDS=1
        ;;
    --wine-smoke)
        WINE_SMOKE=1
        ;;
    --out=*)
        OUT="${1#*=}"
        ;;
    *)
        echo Unrecognized parameter $1
        exit 1
        ;;
    esac
    shift
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# ---- dependencies (idempotent apt guard) -----------------------------------
# The devbox image is project-agnostic; each project converges its own deps.
APT_DEPS="build-essential git cmake ninja-build ccache python3 \
    libcurl4-openssl-dev g++-aarch64-linux-gnu zip unzip bzip2 file \
    libtool automake autoconf autoconf-archive libltdl-dev swig \
    pkg-config gettext autopoint xz-utils curl clang lld"
[ -z "$WINE_SMOKE" ] || APT_DEPS="$APT_DEPS wine64"
missing=""
for p in $APT_DEPS; do
    dpkg -s $p >/dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
fi

# ---- global build environment ----------------------------------------------
if command -v ccache >/dev/null; then
    export COMPILER_LAUNCHER=ccache
fi
# Re-resolve the std-embed branch head on every run; each artifact's
# versions.txt records the exact sha (reproduce with LLVM_VERSION=<sha>).
export SYNC=1
# Reproducible archive mtimes, pinned to this fork's HEAD commit date.
BUILD_DATE="$(git log -1 --pretty=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

NATIVE="$(pwd)/install/llvm-mingw-native"
STAGE1="$(pwd)/install/llvm-mingw-stage1"
DISTRO=ubuntu-$(. /etc/lsb-release 2>/dev/null && echo $DISTRIB_RELEASE || echo unknown)

LTO_PGO_ARGS=
[ -z "$THINLTO" ] || LTO_PGO_ARGS="--thinlto"
[ -z "$PGO" ] || LTO_PGO_ARGS="--thinlto --pgo"

record_versions() {
    # Upstream's store-version.sh only echoes env vars; record the truly
    # resolved shas instead so every artifact is reproducible.
    v="$1/versions.txt"
    echo "std-embed llvm-mingw toolchain $TAG" > "$v"
    echo "LLVM_REPOSITORY=${LLVM_REPOSITORY:-https://github.com/alexios-angel/llvm-project.git}" >> "$v"
    echo "LLVM_VERSION=${LLVM_VERSION:-std-embed}" >> "$v"
    [ ! -d llvm-project ] || echo "LLVM_COMMIT=$(git -C llvm-project rev-parse HEAD)" >> "$v"
    [ ! -d mingw-w64 ] || echo "MINGW_W64_COMMIT=$(git -C mingw-w64 rev-parse HEAD)" >> "$v"
    echo "LLVM_MINGW_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)" >> "$v"
    sed -n 's/^: ${CURL_VERSION:=\(.*\)}/CURL_VERSION=\1/p' build-curl.sh >> "$v"
}

package_tar() {
    # $1 = prefix dir, $2 = archive basename
    dir="$(dirname "$1")"
    base="$(basename "$1")"
    (cd "$dir" && mv "$base" "$2" && \
     tar -Jcf "$OUT/$2.tar.xz" --format=ustar --numeric-owner \
         --owner=0 --group=0 --sort=name --mtime="$BUILD_DATE" "$2" && \
     mv "$2" "$base")
    echo "packaged $OUT/$2.tar.xz"
}

package_zip() {
    dir="$(dirname "$1")"
    base="$(basename "$1")"
    (cd "$dir" && mv "$base" "$2" && \
     rm -f "$OUT/$2.zip" && zip -9rq "$OUT/$2.zip" "$2" && \
     mv "$2" "$base")
    echo "packaged $OUT/$2.zip"
}

# The curl code rides inside libclang-cpp (LLVMHTTP is non-component and
# linked via clangAST), so probe there first. Match HTTPClient.cpp's own
# curl-path string: the "libcurl/x.y.z" banner lives in curl's version.o,
# which nothing references in a static link, so it never appears.
assert_curl_linked() {
    p="$1"
    shift
    for pat in "$@"; do
        for f in "$p"/$pat; do
            [ -e "$f" ] || continue
            if llvm-strings "$f" 2>/dev/null | grep -q curl_easy_perform; then
                return 0
            fi
        done
    done
    echo "ERROR: no curl code baked into $p" 1>&2
    exit 1
}

# std::embed / std::fetch smoke against the embed repo's examples: the
# features are COMPILE-TIME, so cross-compiling a Windows .exe on this
# Linux box exercises them end to end (network included). The .exes
# land in $OUT for a later native run on a real Windows machine.
smoke_std_embed() {
    P="$1"
    EMBED_DIR="${EMBED_DIR:-$HOME/projects/embed}"
    if [ ! -d "$EMBED_DIR/examples/std/basic/source" ]; then
        echo "WARNING: embed repo not found at $EMBED_DIR - skipping std::embed/std::fetch smokes" 1>&2
        return 0
    fi
    CXX="$P/bin/x86_64-w64-mingw32-clang++"
    src="$EMBED_DIR/examples/std/basic/source"
    "$CXX" -std=c++2d -Wno-c++2d-extensions -I "$EMBED_DIR/include" \
        --embed-dir="$src" "$src/local_file.c++" -o "$OUT/std-embed-smoke.exe"
    echo "SMOKE PASS: std::embed (compile-time asserts held; PE emitted)"
    if [ -z "$CURL_ARGS" ]; then
        fsrc="$EMBED_DIR/examples/std/fetch/source"
        "$CXX" -std=c++2d -I "$EMBED_DIR/include" \
            --fetch-allow=https://example.com/ \
            --fetch-allow='https://example.com/**' \
            "$fsrc/fetch_url.c++" -o "$OUT/std-fetch-smoke.exe"
        echo "SMOKE PASS: std::fetch positive (curl linked and live)"
        # Negative: without --fetch-allow the compile MUST fail.
        if "$CXX" -std=c++2d -I "$EMBED_DIR/include" "$fsrc/fetch_url.c++" \
            -o "$OUT/std-fetch-denied.exe" 2>/dev/null; then
            echo "SMOKE FAIL: std::fetch compiled without --fetch-allow" 1>&2
            exit 1
        fi
        rm -f "$OUT/std-fetch-denied.exe"
        echo "SMOKE PASS: std::fetch negative (denied without --fetch-allow)"
    fi
}

# ---- stage A: native linux-x86_64 toolchain --------------------------------
if [ -z "$SKIP_NATIVE" ]; then
    if [ -n "$PGO" ]; then
        # Upstream three-step pipeline; stage1 bootstraps with distro
        # clang+lld, the final compiler is ThinLTO+PGO optimized.
        ./build-all.sh "$STAGE1" "$NATIVE" --full-pgo --with-clang $CURL_ARGS
    else
        ./build-all.sh "$NATIVE" --with-clang $LTO_PGO_ARGS $CURL_ARGS
    fi
    record_versions "$NATIVE"
    ./test-libcxx-module.sh "$NATIVE"
    ./run-tests.sh "$NATIVE"
    smoke_std_embed "$NATIVE"
    package_tar "$NATIVE" llvm-mingw-$TAG-ucrt-$DISTRO-x86_64
fi

# The cross stages compile with the just-built std-embed clang (its
# wrappers shadow the distro tools) and reuse its llvm-tblgen; the
# native llvm build tree must therefore survive until the end.
export PATH="$NATIVE/bin:$PATH"

# ---- stage B: linux-aarch64 host -------------------------------------------
if [ -z "$SKIP_AARCH64" ]; then
    A64="$(pwd)/install/llvm-mingw-aarch64"
    if [ -z "$CURL_ARGS" ]; then
        ./build-curl.sh "$(pwd)/curl-prefix-aarch64-linux-gnu" --host=aarch64-linux-gnu
        A64_CURL="--enable-curl=$(pwd)/curl-prefix-aarch64-linux-gnu"
    else
        A64_CURL="--disable-curl"
    fi
    if [ -n "$PGO" ]; then
        ./build-all.sh "$NATIVE" "$A64" --no-runtimes --host=aarch64-linux-gnu \
            --thinlto --pgo $A64_CURL
    else
        ./build-all.sh "$A64" --no-runtimes --host=aarch64-linux-gnu \
            $LTO_PGO_ARGS $A64_CURL
    fi
    ./prepare-cross-toolchain-unix.sh "$NATIVE" "$A64"
    if [ -z "$CURL_ARGS" ]; then
        mkdir -p "$A64/share/curl"
        cp "$(pwd)/curl-prefix-aarch64-linux-gnu/share/curl/COPYING.txt" "$A64/share/curl/"
    fi
    if [ -z "$CURL_ARGS" ]; then
        assert_curl_linked "$A64" "lib/libclang-cpp.so*" "lib/libLLVM*.so*" "bin/clang-*"
    fi
    record_versions "$A64"
    package_tar "$A64" llvm-mingw-$TAG-ucrt-$DISTRO-aarch64
    if [ -z "$KEEP_BUILDS" ]; then
        rm -rf llvm-project/llvm/build-aarch64-linux-gnu*
    fi
fi

# ---- stage C: windows-hosted toolchains ------------------------------------
if [ -z "$SKIP_WINDOWS" ]; then
    for arch in $HOSTS; do
        P="$(pwd)/install/llvm-mingw-win-$arch"
        ./build-cross-tools.sh "$NATIVE" "$P" $arch \
            --with-python --with-busybox $LTO_PGO_ARGS $CURL_ARGS
        record_versions "$P"
        if [ -z "$CURL_ARGS" ]; then
            assert_curl_linked "$P" "bin/libclang-cpp*.dll" "bin/libLLVM*.dll" "bin/clang-*.exe"
        fi
        package_zip "$P" llvm-mingw-$TAG-ucrt-$arch
        if [ -z "$KEEP_BUILDS" ]; then
            rm -rf llvm-project/llvm/build-$arch-w64-mingw32*
            rm -rf lldb-mi/build-$arch-w64-mingw32* 2>/dev/null || true
        fi
    done
fi

echo
echo "All done. Artifacts in $OUT:"
ls -lh "$OUT"
