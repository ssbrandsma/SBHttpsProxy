#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

TOOLCHAIN="$ROOT/build/toolchains/armv5-eabi--musl--stable-2020.02-2"
TARGET=arm-buildroot-linux-musleabi

CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
SIZE="$TOOLCHAIN/bin/$TARGET-size"

CMAKE="$ROOT/build/toolchains/cmake-3.31.8-linux-x86_64/bin/cmake"

PREFIX="$ROOT/build/arm-mini/prefix"

WOLFSSL_SOURCE="$ROOT/build/vendor-arm/wolfssl-5.8.2-stable"
CURL_SOURCE="$ROOT/build/vendor/curl-8.18.0"

WOLFSSL_BUILD="$ROOT/build/arm-mini/wolfssl-build"
CURL_BUILD="$ROOT/build/arm-mini/curl-build"

OUTPUT="$ROOT/build/arm-mini/sbproxy"

COMMON_FLAGS="-Os -marm -march=armv5te -mtune=arm926ej-s -mfloat-abi=soft -ffunction-sections -fdata-sections"
WOLFSSL_FLAGS="$COMMON_FLAGS -DWOLFSSL_NO_ASN_STRICT"

echo "== sbproxy ARMv5 mini build =="
echo

mkdir -p "$ROOT/build/arm-mini"

rm -rf \
    "$WOLFSSL_BUILD" \
    "$CURL_BUILD" \
    "$PREFIX"

mkdir -p "$WOLFSSL_BUILD"
mkdir -p "$CURL_BUILD"


# ---------------------------------------------------------------------------
# wolfSSL
#
# Keep TLS 1.2 + TLS 1.3 for this first mini build.
#
# We deliberately do NOT aggressively disable crypto algorithms yet.
# First establish a smaller known-good baseline by reducing libcurl.
# ---------------------------------------------------------------------------

echo "== Building wolfSSL =="

"$CMAKE" \
    -S "$WOLFSSL_SOURCE" \
    -B "$WOLFSSL_BUILD" \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="$WOLFSSL_FLAGS" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DWOLFSSL_ALT_CERT_CHAINS:BOOL=ON \
    -DWOLFSSL_CURL:BOOL=ON \
    -DWOLFSSL_TLS13:BOOL=OFF \
    -DWOLFSSL_DTLS:BOOL=OFF \
    -DWOLFSSL_EXAMPLES:BOOL=OFF \
    -DWOLFSSL_CRYPT_TESTS:BOOL=OFF

"$CMAKE" --build "$WOLFSSL_BUILD" -j2
"$CMAKE" --install "$WOLFSSL_BUILD"


# ---------------------------------------------------------------------------
# curl
#
# sbproxy only needs:
#
#   HTTP
#   HTTPS
#   GET / HEAD
#   redirects
#   headers
#   IPv4/DNS
#
# Everything else is disabled where curl's configure script allows it.
# ---------------------------------------------------------------------------

echo
echo "== Building minimal curl =="

cd "$CURL_BUILD"

CC="$CC" \
AR="$AR" \
RANLIB="$RANLIB" \
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
CPPFLAGS="-I$PREFIX/include" \
LDFLAGS="-L$PREFIX/lib" \
CFLAGS="$COMMON_FLAGS" \
LIBS="-lwolfssl -lpthread" \
"$CURL_SOURCE/configure" \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    \
    --disable-shared \
    --enable-static \
    \
    --with-wolfssl="$PREFIX" \
    --without-openssl \
    \
    --enable-http \
    \
    --disable-dict \
    --disable-file \
    --disable-ftp \
    --disable-gopher \
    --disable-imap \
    --disable-ipfs \
    --disable-ldap \
    --disable-ldaps \
    --disable-mqtt \
    --disable-pop3 \
    --disable-rtsp \
    --disable-smb \
    --disable-smtp \
    --disable-telnet \
    --disable-tftp \
    --disable-websockets \
    \
    --without-libpsl \
    --without-libidn2 \
    --without-zlib \
    --without-brotli \
    --without-zstd \
    --without-nghttp2 \
    --without-ngtcp2 \
    --without-nghttp3 \
    --without-libssh2 \
    \
    --disable-manual \
    --disable-docs \
    --disable-threaded-resolver \
    --disable-alt-svc \
    --disable-hsts \
    \
    --disable-cookies \
    --disable-doh \
    --disable-form-api \
    --disable-mime \
    --disable-netrc \
    --disable-progress-meter \
    --disable-proxy \
    \
    --disable-basic-auth \
    --disable-bearer-auth \
    --disable-digest-auth \
    --disable-kerberos-auth \
    --disable-negotiate-auth \
    --disable-aws \
    --disable-ntlm \
    --disable-tls-srp

make -j2
make install


# ---------------------------------------------------------------------------
# sbproxy
# ---------------------------------------------------------------------------

echo
echo "== Linking sbproxy =="

"$CC" \
    -static \
    $COMMON_FLAGS \
    -Wl,--gc-sections \
    -pthread \
    -I"$PREFIX/include" \
    "$ROOT/native/sbproxy.c" \
    "$PREFIX/lib/libcurl.a" \
    "$PREFIX/lib/libwolfssl.a" \
    -o "$OUTPUT.unstripped"


# ---------------------------------------------------------------------------
# Show unstripped size before stripping.
# ---------------------------------------------------------------------------

echo
echo "== Unstripped ELF size =="

ls -lh "$OUTPUT.unstripped"

if [ -x "$SIZE" ]; then
    "$SIZE" "$OUTPUT.unstripped" || true
fi


# ---------------------------------------------------------------------------
# Strip final executable.
# ---------------------------------------------------------------------------

cp "$OUTPUT.unstripped" "$OUTPUT"

"$STRIP" \
    --strip-all \
    "$OUTPUT"


echo
echo "== Final stripped binary =="

ls -lh "$OUTPUT"

if [ -x "$SIZE" ]; then
    "$SIZE" "$OUTPUT" || true
fi


# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

echo
echo "== ELF information =="

file "$OUTPUT" || true

echo
echo "== Dynamic dependencies =="

if command -v readelf >/dev/null 2>&1; then
    readelf -l "$OUTPUT" | grep INTERP || echo "No ELF interpreter (static)"
    readelf -d "$OUTPUT" 2>/dev/null | grep NEEDED || echo "No shared-library dependencies"
fi


echo
echo "Build complete:"
echo
echo "  $OUTPUT"
echo
echo "Reference:"
echo "  $ROOT/build/arm/sbproxy"
echo
echo "Compare with:"
echo
echo "  ls -lh \\"
echo "    $ROOT/build/arm/sbproxy \\"
echo "    $OUTPUT"
