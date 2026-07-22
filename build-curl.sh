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

# Builds a minimal STATIC libcurl for linking into clang, backing
# std::fetch (__builtin_std_fetch) in the std-embed toolchain.
#
# For *-mingw32 hosts the TLS backend is Schannel: clang.exe uses the
# Windows certificate store at runtime, so no OpenSSL and no CA bundle
# ship with the toolchain. For *-linux* cross hosts (where no system
# libcurl for the target arch exists) a pinned static OpenSSL is built
# first, with CA paths defaulted to the Debian/Ubuntu locations
# (override at clang runtime with CURL_CA_BUNDLE if needed).
#
# HTTP/HTTPS only; every optional curl dependency is explicitly OFF so
# the result is deterministic regardless of what the build box has
# installed. curl is built with its CMake build system so the exported
# CURLConfig.cmake records the static link deps (ws2_32, crypt32,
# bcrypt, secur32... or the OpenSSL libs) and the CURL_STATICLIB
# define for the consumer. build-llvm.sh --enable-curl=<prefix> points
# find_package(CURL) here; nothing from the prefix is shipped - the
# static lib is folded into clang/libLLVM at link time.
#
# Native builds don't use this script; they link the system libcurl
# dev package (libcurl4-openssl-dev).

set -e

: ${CURL_VERSION:=8.21.0}
: ${CURL_SHA256:=d9b327997999045a24cda50f3983e69e51c516bd8be6ef9842fc7f99135e33bb}
: ${OPENSSL_VERSION:=3.5.7}
: ${OPENSSL_SHA256:=a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8}

unset HOST

while [ $# -gt 0 ]; do
    case "$1" in
    --host=*)
        HOST="${1#*=}"
        ;;
    *)
        PREFIX="$1"
        ;;
    esac
    shift
done
if [ -z "$PREFIX" ] || [ -z "$HOST" ]; then
    echo $0 --host=triple dest
    exit 1
fi

mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

: ${CORES:=$(nproc 2>/dev/null)}
: ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
: ${CORES:=4}

if command -v ninja >/dev/null; then
    CMAKE_GENERATOR="Ninja"
fi

download() {
    if command -v curl >/dev/null; then
        curl -LO "$1"
    else
        wget "$1"
    fi
}

check_sha256() {
    echo "$1  $2" | sha256sum -c - >/dev/null
}

ARCH="${HOST%%-*}"

case $HOST in
*-mingw32)
    # Schannel: the Windows certificate store, revocation checking and
    # all, with zero files to ship. ENABLE_UNICODE for correct
    # non-ASCII paths/proxies through the wide-char Windows APIs.
    TLS_FLAGS="-DCURL_USE_SCHANNEL=ON"
    EXTRA_FLAGS="-DENABLE_UNICODE=ON"
    TOOLCHAIN_FLAGS="\
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=$ARCH \
        -DCMAKE_C_COMPILER=$HOST-gcc \
        -DCMAKE_RC_COMPILER=$HOST-windres \
        -DCMAKE_FIND_ROOT_PATH=$(cd $(dirname $(command -v $HOST-gcc))/../$HOST && pwd) \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
    ;;
*-linux*)
    # No Schannel outside Windows: build a pinned static OpenSSL.
    case $ARCH in
    aarch64) OPENSSL_TARGET=linux-aarch64 ;;
    x86_64)  OPENSSL_TARGET=linux-x86_64 ;;
    *)
        echo "Unsupported linux cross arch $ARCH"
        exit 1
        ;;
    esac
    if [ ! -d openssl-$OPENSSL_VERSION ]; then
        if [ ! -e openssl-$OPENSSL_VERSION.tar.gz ]; then
            download https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz
        fi
        check_sha256 $OPENSSL_SHA256 openssl-$OPENSSL_VERSION.tar.gz
        tar -zxf openssl-$OPENSSL_VERSION.tar.gz
    fi
    cd openssl-$OPENSSL_VERSION
    [ -z "$CLEAN" ] || rm -rf build-$HOST
    mkdir -p build-$HOST
    cd build-$HOST
    # --openssldir=/etc/ssl matches the Debian/Ubuntu cert layout, so
    # the statically linked clang finds the host distro's trust store.
    ../Configure $OPENSSL_TARGET --cross-compile-prefix=$HOST- \
        --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
        no-shared no-tests no-apps no-docs
    make -j$CORES
    make install_sw
    cd ../..
    TLS_FLAGS="\
        -DCURL_USE_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR=$PREFIX \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
        -DCURL_CA_PATH=/etc/ssl/certs \
        -DCURL_CA_FALLBACK=ON"
    EXTRA_FLAGS=""
    TOOLCHAIN_FLAGS="\
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=$ARCH \
        -DCMAKE_C_COMPILER=$HOST-gcc"
    ;;
*)
    echo "Unrecognized host $HOST"
    exit 1
    ;;
esac

if [ ! -d curl-$CURL_VERSION ]; then
    if [ ! -e curl-$CURL_VERSION.tar.gz ]; then
        download https://curl.se/download/curl-$CURL_VERSION.tar.gz
    fi
    check_sha256 $CURL_SHA256 curl-$CURL_VERSION.tar.gz
    tar -zxf curl-$CURL_VERSION.tar.gz
fi

cd curl-$CURL_VERSION
[ -z "$CLEAN" ] || rm -rf build-$HOST
mkdir -p build-$HOST
cd build-$HOST
[ -n "$NO_RECONF" ] || rm -rf CMake*
cmake \
    ${CMAKE_GENERATOR+-G} "$CMAKE_GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    $TOOLCHAIN_FLAGS \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_LIBCURL_DOCS=OFF \
    -DBUILD_MISC_DOCS=OFF \
    -DENABLE_CURL_MANUAL=OFF \
    -DHTTP_ONLY=ON \
    -DCURL_ZLIB=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBSSH=OFF \
    -DCURL_USE_GSSAPI=OFF \
    -DUSE_NGHTTP2=OFF \
    -DUSE_LIBIDN2=OFF \
    $TLS_FLAGS \
    $EXTRA_FLAGS \
    ..
cmake --build . -j$CORES
cmake --install .
cd ../..

# The curl license rides along so consumers can ship it next to the
# binaries that contain curl code.
mkdir -p "$PREFIX/share/curl"
install -m644 curl-$CURL_VERSION/COPYING "$PREFIX/share/curl/COPYING.txt"
