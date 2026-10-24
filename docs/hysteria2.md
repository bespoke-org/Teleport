# Hysteria 2 support

Teleport imports standalone Hysteria 2 profiles from Xray JSON subscriptions and
`hysteria2://` or `hy2://` links, including Base64 subscription lists. The bundled
Xray **26.10.21**, revision **1b1647c**, supplies both the proxy protocol and the
QUIC transport. Hysteria 1 is rejected. No additional executable is required.

The representative configuration in
`scripts/fixtures/subscriptions/hysteria2.json` is synthetic. It is not a capture
of any provider's subscription. A separate import check against the private
Liberty sample imported all four Hysteria profiles. Connectivity to those
servers still needs live verification.

## Supported configuration

- Outbound `protocol: hysteria`, `settings.version: 2`, `address`, and `port`.
- `streamSettings.network: hysteria` and `security: tls` are required.
- `hysteriaSettings.version: 2`, `auth`, and `udpIdleTimeout`. Zero or omission
  uses the core default; an explicit timeout must be 2–600 seconds.
- TLS `serverName`, `alpn` containing `h3`, and `pinnedPeerCertSha256`. Omitted
  SNI defaults to the original server hostname, even when VPN mode replaces the
  dial address with a protected numeric IP. Omitted ALPN defaults to `h3`.
- TLS `fingerprint` presets `chrome`, `firefox`, `safari`, `ios`, `android`,
  `edge`, `360`, `qq`, `random`, `randomized`, `randomizednoalpn`, and `unsafe`.
  The field is validated and preserved. Hysteria uses Go TLS and QUIC's Chrome
  parroting; this field does not select the TCP uTLS ClientHello for QUIC.
- One `finalmask.udp` Salamander mask with a password. `packetSize` enables
  Xray's Gecko variant and is retained as an integer range up to 2048 bytes.
- One `finalmask.udp` mask with `type: udphop`, `mode: intervalremote`,
  `remotePorts`, and an optional `interval`. It changes the destination port
  within the advertised list, including on the first packet. The base outbound
  port may differ from all hopping ports. With Salamander or Gecko, the
  `udphop` mask must be last in the array so obfuscation wraps the hopping socket.
  Other hopping modes, remote IP hopping, duplicate masks, and reversed mask
  ordering are rejected explicitly.
- `finalmask.quicParams`: congestion control `reno`, `bbr`, `brutal`, or
  `force-brutal`; `bbrProfile`; `brutalUp` and `brutalDown`;
  stream and connection receive windows; `maxIdleTimeout`;
  `keepAlivePeriod`; `disablePathMTUDiscovery`; and `maxIncomingStreams`.

Bandwidth values use the bundled core's string format, such as `20 mbps`.
Nonzero rates must be at least 65536 bytes/second after the core's conversion.
`force-brutal` requires nonzero upload bandwidth. Hopping ports accept a port or
comma-separated list of ports/ranges; hopping intervals must be at least five
seconds; an omitted interval uses the core default of 30 seconds. Receive
windows must be at least 16384; maximum idle timeout is 4–120 seconds; keepalive
is 2–60 seconds; maximum incoming streams is at least eight.
Zero timeout/window values select the core defaults.

Xray 26.10.21 enables Chrome QUIC parroting by default. Its QUIC library overrides
the idle timeout, initial receive windows and incoming stream counts to match
Chrome. Teleport preserves these fields, but their effective values are subject
to that core behavior. The restart integration check allows up to 60 seconds
for the previous QUIC session to expire.

Unknown fields and unsupported combinations are rejected with a reason. This
includes protocol chaining, balancers, multiple proxy outbounds, alternate
transports, other masks, server-side masquerade options, ECH, unrecognized TLS
fingerprint values, and QUIC debug logging. Legacy `up`, `down`, `congestion`, or `udphop`
inside `hysteriaSettings` are rejected. Bandwidth and congestion belong under
`finalmask.quicParams`; port hopping belongs in `finalmask.udp`. Provider
listeners, DNS, and ordinary routing rules are not executed; Teleport generates
its own runtime configuration.

**Insecure TLS is unsupported by this bundled core.** `insecure=1` and
`allowInsecure: true` fail import with an explanation. Use a certificate trusted
by the system or a certificate SHA-256 pin. Explicit false is accepted. Pins
are validated as 32-byte hex values, with optional OpenSSL-style colons; Xray
JSON may specify multiple pins separated by commas.

## Persistence, refresh and sharing

The first development build stored port hopping as `finalmask.quicParams.udpHop`.
Xray 26.10.21 silently ignores that obsolete field. Teleport still accepts it
for compatibility, translates it into the supported UDP mask, and writes only
the new schema. Supplying both forms is rejected as ambiguous. Saved source
identities are normalized during refresh so migration retains UUIDs, custom
names, saved dates, health metadata, and selection.

The connection model stores typed Hysteria parameters. Its `rawLink` contains
canonical JSON with all supported connection settings, so startup reparsing
and configuration editing cannot discard fields that have no URI equivalent.
This data stays in the existing Keychain snapshot. New fields are optional on
decode, so existing VLESS, Trojan and WireGuard snapshots remain readable.

The Hysteria subscription identity uses canonical connection settings without
the display name. JSON whitespace/key order and a provider's name change do not
replace the saved UUID, selection, saved date, health metadata or custom name.
Changing connection parameters produces a different identity, consistent with
the existing subscription model. Identical profiles share one identity.

Standard links support authentication, endpoint, IPv6, multi-port authorities,
SNI, a single `pinSHA256`, and Salamander or Gecko `obfs`/`obfs-password`.
Gecko links use the upstream default packet-size range of 512–1200 bytes.
Credentials and names are percent-decoded once.

The common URI extensions `mport`, `alpn`, and `fp` map to hopping ports, TLS
ALPN, and TLS fingerprint. They go through the same validation as JSON settings.
`mport` preserves the base port in the authority; conflicting authority and
query port lists are rejected. ECH and link bandwidth parameters
`upmbps`/`downmbps` receive specific unsupported-setting errors. Use Xray JSON
to configure bandwidth explicitly. Other unknown URI parameters are rejected
because silently discarding connection settings could change how a profile
connects. The URI specification permits third-party extensions but does not
require recipients to interpret or ignore them.

If a profile includes QUIC tuning, a single-port hopping mask, an explicit hopping interval, a base port
different from its first hopping port, a TLS fingerprint, nondefault Gecko packet
sizes, a custom UDP idle timeout, multiple certificate pins, or extra ALPN
values, the share popover explains that a standard link cannot preserve it.
It offers **Copy configuration** and disables QR export. The copied standalone
Xray JSON can be imported back into Teleport. Basic profiles offer standard
links and QR codes.

## DNS in VPN mode

The default remote resolver is `https://1.1.1.1/dns-query`. Xray forwards those
queries through the proxy using HTTP/2 over TCP, even when the original device
query arrived over UDP. Disabling a server's application UDP relay therefore
does not inherently break the default DNS path. Hysteria's underlying QUIC
transport still requires UDP connectivity. Custom UDP resolvers and other
application UDP traffic require server relay support; the bundled client does
not report the server's UDP-disabled handshake flag to Teleport.

## Automated verification

Run from the repository root:

```sh
just test-script hysteria
just test-script subscription-support
just test-script persistence
just test-hysteria-integration
```

`just test-script hysteria` runs `fetch-xray`, so both Hysteria recipes work on a
fresh checkout without first building the app. The download is checked against
the bundled core's SHA-256 pin.

The Hysteria checks exercise real subscription decoding, plain/Base64 links,
strict rejection and sanitized diagnostics, rename/refresh identity, snapshot
and startup round trips, share export, both config writers, and bundled
`xray run -test` validation. Persistence checks include an isolated Keychain
round trip. They require access to the login Keychain.

The integration script starts disposable local TCP/UDP echo services and a
Hysteria server, then imports a synthetic subscription through Teleport's real
parser and writer. It checks SOCKS TCP, HTTP CONNECT, SOCKS UDP, server restart
recovery, and listener cleanup, with and without Salamander. Additional UDP
relays simulate provider port forwarding to the same Hysteria server. These
checks prove that the base port stays unused when a different sole hopping
port is configured, and that traffic changes destination port after an explicit
five-second interval while TCP, HTTP, and UDP continue working. They cover plain
TLS, Salamander, Gecko, migration from the obsolete hopping field, and a Gecko
URI with the `mport`/`alpn`/`fp` extensions. Run only
these checks after `just test-script hysteria` with:

```sh
python3 scripts/test_hysteria_integration.py /tmp/teleport-test-hysteria --hopping-only
```

The script creates a temporary self-signed certificate and pins it in the client. All listeners
use loopback; temporary processes and files are removed. It requires Python 3
and OpenSSL, but no root access and no changes to macOS networking.

## Live macOS verification

The local test does not prove provider interoperability, actual system proxy
installation, privileged TUN routing, provider-side port hopping, or network-change recovery.
Before closing the issue, use privately supplied profiles on a signed build:

1. Inspect the sample's outbound/transport version and field names privately.
   Import each standalone Hysteria profile. Check imported/skipped counts and
   settings against the original without putting credentials in logs or tickets.
2. Rename one connection, refresh the subscription, restart the app, and verify
   the name, selection, UUID and extended settings survive. Import an entirely
   unsupported response and verify saved entries remain intact.
3. In System Proxy mode, connect and send an HTTPS request through the HTTP
   listener and UDP traffic through a SOCKS5 UDP-capable client. Verify the
   response reaches the expected remote endpoint. Check health probing, then
   disconnect and confirm proxy restoration and process/listener cleanup.
4. In VPN mode, verify the physical host route and interface binding for every
   Hysteria server, including a Hysteria connection selected by a split-tunnel
   rule. Check TCP, DNS, and non-443 UDP traffic, IPv4 and IPv6 where available,
   and large transfers. Application UDP/443 remains blocked by Teleport's
   existing policy; the Hysteria transport's own QUIC traffic must still work.
5. Exercise any advertised hopping range for multiple intervals and Gecko
   obfuscation if present. Verify certificate/authentication failures do not
   result in a usable connection or expose secrets.
6. Switch uplinks and sleep/wake while connected; check reconnect and leak
   guard behavior. Disconnect and quit; confirm removal of TUN routes, DNS
   state, leak-guard state and Xray processes.

Core contracts used for this implementation:

- [Pinned outbound schema](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/hysteria.go)
- [Pinned transport schema](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/transport_method.go)
- [Pinned QUIC, hopping and obfuscation schema](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/transport_finalmask.go)
- [Pinned TLS schema](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/transport_security.go)
- [Hysteria 2 URI specification](https://hy2.io/docs/developers/URI-Scheme/)
- [Gecko defaults](https://hy2.io/docs/advanced/Full-Client-Config/#obfuscation)
- [Pinned DNS-over-HTTPS transport](https://github.com/XTLS/Xray-core/blob/1b1647c/app/dns/nameserver_doh.go)
- [Pinned hopping implementation](https://github.com/XTLS/Xray-core/blob/1b1647c/transport/internet/finalmask/udphop/conn.go)
- [Pinned mask ordering](https://github.com/XTLS/Xray-core/blob/1b1647c/transport/internet/finalmask/finalmask.go)
