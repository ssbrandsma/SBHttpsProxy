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

## Deploy an updated proxy to the Radio

The current device deployment is a standalone localhost service in `/tmp`;
the HTTPSProxy Jive applet is not installed yet. Because `/tmp` is a RAM
filesystem, both files and the process disappear at reboot. This is suitable
for native helper testing, but it is not a persistent installation.

Current OpenSSH clients need the Radio's legacy algorithms, and `scp -O` is
needed for its legacy SCP server. In PowerShell, calculate local hashes and
copy both the helper and current CA bundle:

```powershell
Get-FileHash -Algorithm MD5 .\build\arm\sbproxy, .\certs\cacert.pem

scp -O `
    -o PreferredAuthentications=password `
    -o PubkeyAuthentication=no `
    -o KexAlgorithms=+diffie-hellman-group1-sha1 `
    -o HostKeyAlgorithms=+ssh-rsa `
    -o Ciphers=+aes128-cbc `
    -o MACs=+hmac-sha1 `
    .\build\arm\sbproxy .\certs\cacert.pem `
    root@RADIO_IP:/tmp/

ssh -o PreferredAuthentications=password `
    -o PubkeyAuthentication=no `
    -o KexAlgorithms=+diffie-hellman-group1-sha1 `
    -o HostKeyAlgorithms=+ssh-rsa `
    -o Ciphers=+aes128-cbc `
    -o MACs=+hmac-sha1 `
    root@RADIO_IP
```

On the Radio, compare `md5sum` with the two local values before starting the
files. This SqueezeOS image has `md5sum`, but not `cksum` or `sha256sum`.

```sh
set -e
md5sum /tmp/sbproxy /tmp/cacert.pem
chmod 755 /tmp/sbproxy

if test -s /tmp/sbproxy.pid; then
    kill `cat /tmp/sbproxy.pid` 2>/dev/null || true
fi
killall sbproxy 2>/dev/null || true
rm -f /tmp/sbproxy.pid /tmp/sbproxy.log
```

Start the localhost service, record its PID, and verify health, loopback-only
binding, and a real HTTPS request:

```sh
/tmp/sbproxy --listen 127.0.0.1:8765 \
    --ca-bundle /tmp/cacert.pem \
    >/tmp/sbproxy.log 2>&1 &
echo $! >/tmp/sbproxy.pid
sleep 2

wget -q -O /tmp/health.txt http://127.0.0.1:8765/health
cat /tmp/health.txt
netstat -ltn 2>/dev/null | grep '127.0.0.1:8765'
wget -q -O /tmp/example.html \
    http://127.0.0.1:8765/https/example.com/
grep 'Example Domain' /tmp/example.html
cat /tmp/sbproxy.pid
ps | grep '[s]bproxy'
tail -n 80 /tmp/sbproxy.log
```

The service is now available to local clients at `127.0.0.1:8765`. Response
scratch files can be removed without stopping it:

```sh
rm -f /tmp/health.txt /tmp/example.html
```

Stop the standalone service with:

```sh
kill `cat /tmp/sbproxy.pid` 2>/dev/null || true
rm -f /tmp/sbproxy.pid
```

Once the Jive applet is packaged and installed, it will instead own a
persistent helper beneath its applet directory and supervise the process using
`/tmp/httpsproxy.pid` and `/tmp/httpsproxy.log`.
