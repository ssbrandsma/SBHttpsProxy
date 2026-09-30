# SBHttpsProxy

SBHttpsProxy adds HTTPS support to older Logitech Squeezebox devices running
SqueezePlay/SqueezeOS. It is intended for service applets that can play an
HTTP stream but cannot themselves fetch an HTTPS stream.

It runs a small local proxy on `127.0.0.1:8765`:

```text
other Jive applet
  -> http://127.0.0.1:8765/https/example.com/path
  -> sbproxy
  -> https://example.com/path
```

The proxy is deliberately stateless. It does not know about stations, audio
providers, accounts, or playlists. It forwards ordinary HTTP request and
response data, including redirects, Range requests, ICY headers, and long
streaming responses.

## Why it is needed

The Squeezebox Radio and Touch use an old embedded SqueezePlay stack. Many
current radio and audio services now require HTTPS, while existing playback
paths in older applets commonly expect an HTTP URL. HTTPSProxy lets an applet
continue to hand a normal local HTTP URL to SqueezePlay while `sbproxy` makes
the upstream HTTPS connection.

The helper binds only to IPv4 loopback. It is not a LAN-facing proxy.

## Contents

`sbproxy` is a static ARMv5 helper built with libcurl and wolfSSL. The
`HTTPSProxy` Jive applet starts and stops that helper, performs a local health
check, and exposes a minimal service API to other applets.

The installed layout is:

```text
/usr/share/jive/applets/HTTPSProxy/
  HTTPSProxyApplet.lua
  HTTPSProxyMeta.lua
  HTTPSProxyService.lua
  bin/sbproxy
  certs/cacert.pem
```

Runtime state is kept in `/tmp/httpsproxy.pid` and `/tmp/httpsproxy.log`.

## Installing

Install `HTTPSProxy-<version>.zip` through the Squeezebox Applet Installer.
The package contains files at the ZIP root, as required by the installer.
Once installed, the service applet starts the helper automatically. The
release repository metadata is generated with:

```powershell
.\build\package.ps1
```

See [arm/README.md](arm/README.md) for manual Radio deployment, verification,
and rollback instructions.

## Using it from another applet

The service object provides three methods:

```lua
proxyUrl(url)       -- HTTPS becomes a local HTTP proxy URL; other URLs stay unchanged
isAvailable()       -- true after a successful local /health check
getVersion()        -- helper version from /health, or nil until available
```

Load the applet and obtain its service object defensively. HTTPSProxy should
remain optional for consumers: do not fail an applet merely because it is not
installed.

```lua
local function httpsProxyService()
    local applet = appletManager:loadApplet("HTTPSProxy")

    if applet and applet.service then
        return applet.service
    end

    return nil
end
```

Map an upstream URL immediately before passing it to the normal SqueezePlay
playback path:

```lua
local upstream = "https://playerservices.streamtheworld.com/" ..
                 "api/livestream-redirect/RADIO538.mp3"
local proxy = httpsProxyService()

if proxy then
    local playbackUrl = proxy:proxyUrl(upstream)
    -- Pass playbackUrl to the applet's existing HTTP/SqueezePlay player code.
else
    -- HTTPSProxy is not installed. Show a useful error or use an HTTP fallback.
end
```

`proxyUrl()` preserves the representation after `https://`; this matters for
signed URLs, repeated query parameters, and percent-encoded paths. For
example:

```lua
local localUrl = proxy:proxyUrl(
    "https://cdn.example.com/a%20file.flac?token=a%2Fb%2Bc&x=1&x=2"
)
-- http://127.0.0.1:8765/https/cdn.example.com/a%20file.flac?token=a%2Fb%2Bc&x=1&x=2
```

Plain HTTP URLs are returned unchanged, so an applet can use the same call for
both protocols:

```lua
local playbackUrl = proxy and proxy:proxyUrl(url) or url
```

### Checking readiness

The helper starts asynchronously. `isAvailable()` is false until the applet's
local health request succeeds, so a consumer should check it when readiness is
important:

```lua
local proxy = httpsProxyService()

if not proxy or not proxy:isAvailable() then
    -- The applet is absent, still starting, or its helper is unavailable.
    -- Retry later or report that HTTPS playback is temporarily unavailable.
    return
end

local version = proxy:getVersion()
local playbackUrl = proxy:proxyUrl("https://example.com/stream.mp3")
```

The health endpoint is also useful during device diagnosis:

```sh
wget -q -O - http://127.0.0.1:8765/health
tail -n 80 /tmp/httpsproxy.log
```

Expected health output includes the `sbproxy` version, libcurl version, TLS
backend, and `status: OK`.

## URL format and scope

The local request format is:

```text
http://127.0.0.1:8765/https/<host>[/path][?query]
```

It becomes:

```text
https://<host>[/path][?query]
```

Only `GET` and `HEAD` are supported. The helper follows redirects, forwards
end-to-end headers such as `Range` and ICY metadata, removes hop-by-hop
headers, and streams the response instead of buffering an entire audio file in
memory.

## Security note

Version 0.2.0 disables upstream certificate and hostname verification. This is
a compatibility workaround for a GoDaddy certificate chain served by
StreamTheWorld that wolfSSL 5.8.2 on the ARM target rejects. The connection is
still encrypted, but the upstream server is not authenticated; an attacker on
the network path could impersonate it. Use this release only on networks where
that trade-off is acceptable.

## Building

The ARMv5 release build requires the dependencies fetched by the project:

```sh
sh arm/fetch-dependencies.sh
sh arm/build-arm.sh
```

The output is `build/arm/sbproxy`. The release package can then be built with
the PowerShell command shown above. The canonical ARM build targets ARMv5TE,
ARM926EJ-S, soft-float SqueezeOS.

## Status

The 0.2.0 ARM helper has been tested on a Squeezebox Radio. It listens only on
`127.0.0.1:8765`; `/health` and Radio 538's StreamTheWorld HTTPS stream have
been verified on the device.
