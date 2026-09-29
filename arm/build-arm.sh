#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLCHAIN="$ROOT/build/toolchains/armv5-eabi--musl--stable-2020.02-2"
TARGET=arm-buildroot-linux-musleabi
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
CMAKE="$ROOT/build/toolchains/cmake-3.31.8-linux-x86_64/bin/cmake"
PREFIX="$ROOT/build/arm/prefix"
WOLFSSL_SOURCE="$ROOT/build/vendor-arm/wolfssl-5.8.2-stable"
CURL_SOURCE="$ROOT/build/vendor/curl-8.18.0"
COMMON_FLAGS="-Os -marm -march=armv5te -mtune=arm926ej-s -mfloat-abi=soft -ffunction-sections -fdata-sections"

mkdir -p "$ROOT/build/arm"

"$CC" -static $COMMON_FLAGS -s "$ROOT/arm/arm-probe.c" -o "$ROOT/build/arm/sbproxy-arm-probe"

rm -rf "$ROOT/build/arm/wolfssl-build" "$ROOT/build/arm/curl-build" "$PREFIX"
"$CMAKE" -S "$WOLFSSL_SOURCE" -B "$ROOT/build/arm/wolfssl-build" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="$COMMON_FLAGS" -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DWOLFSSL_CURL:BOOL=ON -DWOLFSSL_TLS13:BOOL=ON -DWOLFSSL_DTLS:BOOL=OFF \
    -DWOLFSSL_EXAMPLES:BOOL=OFF -DWOLFSSL_CRYPT_TESTS:BOOL=OFF
"$CMAKE" --build "$ROOT/build/arm/wolfssl-build" -j2
"$CMAKE" --install "$ROOT/build/arm/wolfssl-build"

mkdir -p "$ROOT/build/arm/curl-build"
cd "$ROOT/build/arm/curl-build"
CC="$CC" AR="$AR" RANLIB="$RANLIB" \
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
CFLAGS="$COMMON_FLAGS" LIBS="-lwolfssl -lpthread" \
"$CURL_SOURCE/configure" --host="$TARGET" --prefix="$PREFIX" \
    --disable-shared --enable-static --with-wolfssl="$PREFIX" --without-openssl \
    --enable-http --disable-ipfs --disable-websockets --disable-dict --disable-file --disable-ftp --disable-gopher \
    --disable-imap --disable-ldap --disable-ldaps --disable-mqtt --disable-pop3 \
    --disable-rtsp --disable-smb --disable-smtp --disable-telnet --disable-tftp \
    --without-libpsl --without-libidn2 --without-zlib --without-brotli \
    --without-zstd --without-nghttp2 --without-ngtcp2 --without-nghttp3 \
    --without-libssh2 --disable-manual --disable-docs --disable-threaded-resolver \
    --disable-alt-svc --disable-hsts
make -j2
make install

"$CC" -static $COMMON_FLAGS -Wl,--gc-sections -pthread \
    -I"$PREFIX/include" "$ROOT/native/sbproxy.c" \
    "$PREFIX/lib/libcurl.a" "$PREFIX/lib/libwolfssl.a" \
    -o "$ROOT/build/arm/sbproxy"
"$TOOLCHAIN/bin/$TARGET-strip" "$ROOT/build/arm/sbproxy"
