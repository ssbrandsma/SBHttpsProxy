#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/build/toolchains" "$ROOT/build/vendor" "$ROOT/build/vendor-arm"

fetch() {
    url=$1
    output=$2
    test -f "$output" || curl -L --fail "$url" -o "$output"
}

fetch "https://toolchains.bootlin.com/downloads/releases/toolchains/armv5-eabi/tarballs/armv5-eabi--musl--stable-2020.02-2.tar.bz2" \
    "$ROOT/build/toolchains/armv5-musl.tar.bz2"
test -d "$ROOT/build/toolchains/armv5-eabi--musl--stable-2020.02-2" || \
    tar -xjf "$ROOT/build/toolchains/armv5-musl.tar.bz2" -C "$ROOT/build/toolchains"

fetch "https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-linux-x86_64.tar.gz" \
    "$ROOT/build/toolchains/cmake.tar.gz"
test -d "$ROOT/build/toolchains/cmake-3.31.8-linux-x86_64" || \
    tar -xzf "$ROOT/build/toolchains/cmake.tar.gz" -C "$ROOT/build/toolchains"

fetch "https://github.com/wolfSSL/wolfssl/archive/refs/tags/v5.8.2-stable.tar.gz" \
    "$ROOT/build/vendor-arm/wolfssl.tar.gz"
test -d "$ROOT/build/vendor-arm/wolfssl-5.8.2-stable" || \
    tar -xzf "$ROOT/build/vendor-arm/wolfssl.tar.gz" -C "$ROOT/build/vendor-arm"

fetch "https://curl.se/download/curl-8.18.0.tar.xz" "$ROOT/build/vendor/curl.tar.xz"
test -d "$ROOT/build/vendor/curl-8.18.0" || \
    tar -xJf "$ROOT/build/vendor/curl.tar.xz" -C "$ROOT/build/vendor"
