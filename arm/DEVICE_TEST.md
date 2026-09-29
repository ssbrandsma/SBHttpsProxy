# First Squeezebox Radio test

The ARM artifacts have passed the native integration suite under QEMU's
ARM926 model. That is not a substitute for this hardware test.

## Inspect the Radio

Run these commands over SSH and save the output:

```sh
uname -a
cat /proc/cpuinfo
cat /proc/version
ls -l /lib/ld* /lib/libc* /lib/libpthread* 2>/dev/null
cat /proc/meminfo
```

The probe is static, so missing `file`, `readelf`, and `ldd` on the Radio do
not prevent testing it.

## Copy and run the probe

From PowerShell, replacing the address:

```powershell
scp -O -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 .\build\arm\device-test\sbproxy-arm-probe root@RADIO_IP:/tmp/
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 root@RADIO_IP "chmod 755 /tmp/sbproxy-arm-probe && /tmp/sbproxy-arm-probe"
```

Expected first lines:

```text
SBHttpsProxy ARM probe
sizeof(void*) = 4
ARM target = ARMv5
float ABI = soft
```

## Copy and run sbproxy

```powershell
scp -O -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 .\build\arm\device-test\sbproxy root@RADIO_IP:/tmp/
scp -O -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 .\build\arm\device-test\cacert.pem root@RADIO_IP:/tmp/
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 root@RADIO_IP
```

These options are needed because current OpenSSH releases disable the Radio's
legacy SSH algorithms by default. `scp -O` selects the legacy SCP protocol
implemented by its firmware.

On the Radio:

```sh
chmod 755 /tmp/sbproxy
/tmp/sbproxy --listen 127.0.0.1:8765 --ca-bundle /tmp/cacert.pem >/tmp/sbproxy.log 2>&1 &
echo $! >/tmp/sbproxy.pid
sleep 2
wget -qO- http://127.0.0.1:8765/health
cat /tmp/sbproxy.log
```

If the firmware's `wget` lacks `-O-`, use:

```sh
wget -q -O /tmp/health.txt http://127.0.0.1:8765/health
cat /tmp/health.txt
```

Then prove DNS, TCP, SNI, certificate validation, and HTTPS with:

```sh
wget -q -O /tmp/example.html http://127.0.0.1:8765/https/example.com/
head /tmp/example.html
cat /tmp/sbproxy.log
```

Confirm the listener is loopback-only when `netstat` is available:

```sh
netstat -ltn 2>/dev/null | grep 8765
```

Stop and clean up:

```sh
kill `cat /tmp/sbproxy.pid`
rm -f /tmp/sbproxy.pid /tmp/sbproxy.log /tmp/health.txt /tmp/example.html
```

Do not install the Jive applet until the probe, `/health`, and generic HTTPS
test all succeed on the Radio.
