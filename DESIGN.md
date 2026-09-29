# SBHttpsProxy design and research

Status: native Linux implementation validated; ARM/device work remains

## Scope

This project will contain two independently useful components:

* `sbproxy`, a small native C HTTP listener that binds only to
  `127.0.0.1:8765` and translates `/https/<authority>/<path>` into an
  upstream HTTPS request.
* `HTTPSProxy`, a thin Jive service applet that owns the helper lifecycle and
  exposes `proxyUrl(url)` and `isAvailable()` to other applets.

There will be no Qobuz, Spotify, audio, cache, registration, session, or URL
ID logic in either component. StandaloneRadio integration is deliberately a
later, separate change.

## Repository findings

### SBStandalone

* Runtime Lua files are under `applet/StandaloneRadio`.
* The package builder deliberately places files at ZIP archive root. An
  enclosing `StandaloneRadio/` directory would install incorrectly.
* The applet targets SqueezePlay `baby` (Radio) and `fab4` (Touch), minimum
  target 7.7.
* Existing asynchronous external-process work uses `jive.net.Process`.
* Existing playback code already forwards HTTP response headers to native
  playback and handles ICY metadata through SqueezePlay's native stream
  support; the proxy must therefore preserve those headers.

### SBSpotifyConnect

`SpotifyService.lua` is the closest lifecycle example. It uses:

* an applet-owned runtime directory;
* PID files and `/proc/<pid>/cmdline` validation;
* a fixed loopback port;
* shell-launched background helpers;
* cleanup/restart methods and a status file;
* a service object loaded during applet registration.

That pattern is useful, but HTTPSProxy should remain smaller: health is the
authoritative status check, and no persistent JSON state is needed for the
proxy.

## Proposed runtime design

`sbproxy` will use a small worker-per-connection model. The accept loop will
listen on IPv4 loopback only and cap active workers (at least four). Each
worker will parse one request, use libcurl synchronously with a bounded write
buffer, and write directly to the local socket. Blocking writes provide
backpressure without an unbounded queue; a failed local write cancels the
libcurl transfer promptly.

The listener will support GET, HEAD, `/health`, request-header forwarding for
end-to-end headers, redirects, Range requests, and response-header forwarding.
Hop-by-hop headers will be excluded in both directions. libcurl's decoded body
will be sent without `Transfer-Encoding: chunked`; responses without a known
length will be streamed until the local connection closes.

The target URL is reconstructed literally from the request target after the
`/https/` prefix. Parsing must preserve query ordering and percent escapes.
The initial implementation will use IPv4 upstream resolution where practical
because the SqueezeOS environment is old; this does not relax TLS hostname
verification.

TLS verification remains enabled. The CA bundle path will be a command-line
option with an installation-relative default. Redirects remain inside the
same local request and have a finite limit. Upstream private/loopback address
blocking is deferred until compatibility testing establishes whether it harms
legitimate radio/CDN use; the listener itself is never LAN-accessible.

## Applet service design

The applet will determine its installed directory, locate `bin/sbproxy` and
`certs/cacert.pem`, and maintain a private runtime/PID/log location. Startup
will first check `http://127.0.0.1:8765/health`; if unhealthy, it will start
one helper, wait briefly, and check health again. PID and command-line checks
will prevent duplicate launches and stale PID reuse. A helper crash makes
`isAvailable()` false; the next start/use may retry.

The public service surface will be intentionally tiny:

```lua
proxyUrl(url)       -- HTTP unchanged; HTTPS mapped to localhost
isAvailable()       -- health-backed boolean
getVersion()        -- optional health/version value
```

The service will be optional for consumers. No existing applet will be made
dependent on HTTPSProxy during the first implementation.

## Build and test plan

Development will provide a native Linux build first, then an ARMv5TE build.
 The published SqueezeOS build instructions identify the legacy toolchain as
 GCC 4.2.2 with glibc 2.6.1 and an `arm-926ejs-linux-gnueabi` target. This is
 consistent with the Radio's ARM926EJ-S CPU, but that SDK/sysroot is not
 present in either local repository. The exact SDK must therefore be located
 or supplied before claiming a reproducible cross-build. The intended native stack is C + libcurl + wolfSSL,
with HTTP/HTTPS-only libcurl features and a mostly static target binary.

Tests will use a local HTTPS fixture and cover health, GET/HEAD, query and
percent-encoding preservation, redirects, Range/206, status propagation,
certificate rejection, failures, disconnects, bounded streaming, concurrency,
chunked upstream responses, ICY headers, and Lua URL transformation.

## Risks and decisions to validate

1. **Toolchain availability:** no ARM926/SqueezeOS SDK or libcurl/wolfSSL
   build inputs were found in either source repository. Cross-compilation is
   blocked until the SDK/sysroot is located or supplied.
2. **TLS compatibility:** wolfSSL must be configured for the target libc and
   TLS versions without pulling in unsupported runtime dependencies.
3. **Jive HTTP API:** health polling must use an API available on stock 7.7;
   the applet should fall back to the simplest proven mechanism if the exact
   async HTTP convenience API is absent.
4. **Multiple workers:** a small fixed worker cap is preferred over an
   asynchronous redesign, but stack/RAM cost must be measured on hardware.
5. **URL syntax:** the proxy URL format intentionally treats everything after
   `/https/` as the original authority/path/query; malformed or non-HTTPS
   targets receive local 4xx responses.

## Milestones

1. This design/research document.
2. Native listener and `/health`.
3. HTTPS streaming, headers, redirects, Range, and errors.
4. Automated local tests.
5. ARMv5 build once the toolchain is verified.
6. HTTPSProxy service applet and package.
7. Device deployment/test instructions and real-device proof.
8. Optional minimal StandaloneRadio integration in a separate change.
