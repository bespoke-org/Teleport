# Shadowsocks

Teleport supports native Shadowsocks TCP and UDP through the bundled Xray
v26.10.21 in System Proxy and TUN modes. Import an `ss://` link or an Xray JSON
profile in Settings > Connections. Plain and base64 subscription lists accept
the same links, and JSON subscriptions accept Shadowsocks outbounds.

## Supported methods and credentials

- `aes-128-gcm`, `aes-256-gcm`
- `chacha20-ietf-poly1305`, `xchacha20-ietf-poly1305`
- `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`,
  `2022-blake3-chacha20-poly1305`

Xray's `chacha20-poly1305`, `xchacha20-poly1305` and `aead_*` aliases for the
older AEAD methods are normalized to the names above. Older AEAD methods take
a nonempty password. AEAD-2022 takes standard padded base64 keys: 16 decoded
bytes for AES-128, 32 for AES-256 and ChaCha20. AES supports colon-separated
key chains; ChaCha20 requires a single key. Raw, non-base64 2022 keys are not
accepted, even though Xray has a fallback for them.

SIP002 links accept base64/base64url `method:password` userinfo for older AEAD
methods, or separately percent-encoded method and password. AEAD-2022 requires
the percent-encoded form. Legacy links encoding the complete
`method:password@host:port` authority are accepted for older AEAD methods.
IPv6 addresses use brackets. Export uses canonical SIP002 links, retaining the
password and visible name. Never post real links in issues or logs.

## Xray JSON and scope

Both flat `settings` with `address`, `port`, `method`, `password` and the older
`settings.servers` array with exactly one endpoint are accepted. `email` and
`level` are validated as source-client metadata, then omitted. Transport may be
absent or native `tcp`/`raw` with `security: "none"`; these aliases normalize to
TCP. Empty socket options and an explicit TCP header of `none` are accepted.
The connection remains encrypted by Shadowsocks itself.

Plugins, stream ciphers, `none` encryption, transport wrappers such as
WebSocket/TLS, TCP header obfuscation, custom socket options, FinalMask and
enabled Mux are rejected with import errors. Link options other than an empty
`plugin` are rejected. SIP008 subscription JSON, Outline-specific options, and
ShadowsocksR are outside this support.

Supported Shadowsocks outbounds can also be members of Teleport's existing
composite profiles or targets of split routing. Teleport continues to generate
its own inbounds, DNS and routing. Equivalent URI encodings and JSON endpoint
shapes have the same subscription identity, excluding the provider's display
name. Distinct ciphers or passwords remain distinct entries. A refreshed name
therefore preserves selection and the user's custom name.

## Verification

Run the targeted checks:

```sh
just test-case ShadowsocksTests
just test-case SubscriptionSupportTests
just test-case PersistenceTests
just test-case CoreTests
```

`ShadowsocksTests` covers credential encoding, invalid input, import shapes,
subscription identity, rename/export, and saved-model compatibility. Its
loopback lab runs the generated System Proxy and TUN configurations through
`xray run -test`. All seven methods then carry TCP and UDP through local Xray
Shadowsocks servers, with client restart and child-process cleanup checks.
The server redirects a TEST-NET destination to a local echo service, so a
direct connection cannot satisfy the test.

For the TUN traffic check, the lab keeps the generated proxy outbound and its
interface binding but substitutes a local SOCKS inbound. This does not exercise
a real utun or change the host's proxy, routes, DNS or privileged helper.

Before claiming interoperability with a provider, use a private representative
profile and check both modes on a working server:

1. Import, rename, export/reimport, refresh the subscription, and restart the app.
   Confirm credentials, selection and names survive.
2. In System Proxy mode, verify HTTPS through the HTTP/SOCKS listener and UDP
   through SOCKS5 UDP ASSOCIATE with a server that supports UDP relay.
3. In TUN mode, verify HTTPS, DNS and UDP traffic, including split routes to a
   second connection. Confirm the server endpoint bypasses the utun.
4. Disconnect/reconnect, sleep/wake and change uplinks. After stopping, confirm
   Teleport's listeners, helper session, routes and resolver state are removed.

The checked-in fixture uses synthetic credentials. No private provider sample
is included, and loopback checks alone do not establish provider interoperability.

References: [Xray's pinned config parser](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/shadowsocks.go),
[SIP002](https://shadowsocks.org/doc/sip002.html),
[SIP022](https://shadowsocks.org/doc/sip022.html).
