# ARMv5 / SqueezeOS build

The first compatibility artifact is a statically linked musl probe built for
ARMv5TE soft-float. It intentionally has no dependency on the Radio's old
glibc or dynamic loader.

The selected development toolchain is Bootlin's
`armv5-eabi--musl--stable-2020.02-2` toolchain (GCC 8.4.0). This older musl
toolchain avoids the 32-bit `time64` transition in musl 1.2 while providing a
reproducible ARM EABI compiler. Production proxy compatibility still requires
execution on a real Radio.

Build flags:

```
-static -Os -march=armv5te -mtune=arm926ej-s -mfloat-abi=soft
```

The static-musl strategy is preferred for the first test because it avoids
depending on SqueezeOS's glibc 2.11.1 and loader. DNS in the eventual static
proxy is performed by musl's resolver directly; it does not depend on glibc
NSS modules. The kernel compatibility floor must be confirmed on hardware.

## Expected target ABI

* ARM926EJ-S / ARMv5TEJ, little-endian, 32-bit ARM state.
* ARM EABI5 with software floating point; never `gnueabihf`/armhf.
* Linux 2.6.26-era kernel and pthread support already used by SqueezePlay.
* The tested Radio reports glibc 2.11.1 and `/lib/ld-linux.so.3`; the static
  artifacts do not depend on either.
* The selected binaries have no ELF interpreter or shared-library dependency.
* Static musl performs DNS itself using `/etc/resolv.conf`; this avoids target
  glibc NSS modules, but resolver and kernel behavior still require hardware
  confirmation.

## Reproducible build

Run in WSL/Linux:

```sh
sh arm/fetch-dependencies.sh
sh arm/build-arm.sh
```

Components:

* Bootlin ARMv5 EABI musl stable 2020.02-2, GCC 8.4.0.
* wolfSSL 5.8.2 static, curl compatibility, TLS 1.2 and TLS 1.3 enabled.
* curl 8.18.0 static with wolfSSL; HTTP/HTTPS are the required protocols.

The resulting files are `build/arm/sbproxy-arm-probe` and
`build/arm/sbproxy`. Both are static EABI5 soft-float executables. The proxy
passes the native 14-test HTTPS integration suite under `qemu-arm -cpu
arm926`.

Run that suite explicitly with:

```sh
SBPROXY_BINARY="$PWD/build/arm/sbproxy" \
SBPROXY_RUNNER="sh $PWD/arm/qemu-arm926.sh" \
python3 tests/integration_test.py
```

## Physical Radio result

Tested on a Logitech MX25 Baby Board / Squeezebox Radio with ARM926EJ-S
revision 4, Linux 2.6.26.8-rt16, and 62 MB RAM:

* ARM probe: passed and identified ARMv5 soft-float correctly.
* `/health`: passed; reported curl 8.18.0 and wolfSSL 5.8.2.
* Listener: confirmed as `127.0.0.1:8765` only.
* Generic HTTPS: `https://example.com/` succeeded through the proxy, proving
  target DNS, TCP, SNI, CA validation, TLS, and response streaming.
* Idle RSS: about 220 KiB; RSS after the first HTTPS request: about 924 KiB.

Audio playback and Jive applet lifecycle remain separate device milestones.
