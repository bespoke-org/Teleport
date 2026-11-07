# Composite Xray profiles

Teleport can import a subscription entry containing several proxy outbounds as
one portal. Xray selects its member server using the entry's balancer and
`burstObservatory` checks. A group keeps its fallback server, selection strategy,
probe settings and explicit cost weights.

The supported shape is one catch-all balancer with up to 64 independently
supported VLESS, Trojan or Hysteria 2 outbounds. Strategies are `leastLoad`,
`leastPing`, `random` and `roundRobin`. Selectors use Xray's prefix matching;
costs use substring matching. Literal regular-expression cost matches are also
accepted. Other regexes and automatic weights are rejected.

Each group gets separate runtime tags, including when split routing selects
several groups in one TUN session. Xray has one burst observer per process, so
groups sharing a session must have identical probe settings. Otherwise Teleport
reports an error instead of replacing one group's settings with another's.

Teleport still owns listeners, DNS and direct/block routing. Provider rules
that choose individual proxy members, outbound chaining, ordinary `observatory`
profiles, and direct observatory connectivity probes are not supported.

## Transport settings

XHTTP JSON profiles preserve validated `extra` options for padding, XMux,
upload method and placement, session/sequence fields and buffering. Legacy
`sessionKey` and `sessionPlacement` map to `sessionIDKey` and
`sessionIDPlacement`. `downloadSettings` and unknown options are rejected.

VLESS and Trojan profiles can explicitly enable Mux with concurrency and XUDP
settings. Mux with VLESS flow or Hysteria is rejected. Teleport does not enable
Mux on ordinary connections by default.

Groups, XHTTP extras and Mux settings are saved and shared as Xray JSON. Renaming,
refreshing and restarting preserve them. Duplicate filtering compares the whole
profile without its display name, so two names for the same group count as one
portal when filtering is enabled.

## TUN and health checks

Before installing TUN routes, Teleport resolves every member and pins each usable
dial address to a protected physical route. Members that cannot resolve or have
no route on the current uplink are excluded from that session, with a warning in
the log. The saved profile stays intact and all members are reconsidered on the
next connection. When `fallbackTag` is omitted, the first proxy member is the
preferred fallback, even if it is outside the selector. If the preferred fallback
is unavailable, a reachable selected member becomes the session's fallback. If
neither a selected member nor the preferred fallback is reachable, the connection
fails. Standalone portals still require a reachable endpoint. Health checks open
temporary leak-guard exemptions for
all members. If the helper's shared address budget is full, the check reports an
unknown result and releases any exemptions already opened.

The fixtures in `teleportTests/fixtures/subscriptions/balanced-*.json` use
synthetic credentials and reserved example domains. Tests check import,
refresh, sharing, sealed storage, member routes and generated configurations
with the bundled Xray's `run -test` command. Configuration validation does not
prove reachability through an operator's whitelist; that needs a connection
test on the affected network.

## Connection diagnostics

Connection errors distinguish an empty DNS result, a missing route, and an
IPv6-only DNS answer with no usable route. An empty DNS answer is not enough to
claim that a server is IPv6-only. A group with no reachable eligible member
reports a group failure, with counts of DNS, IPv6-route and other route failures.
Only selected members and the configured fallback contribute to those counts.
Known local failures have specific portal status labels while keeping the check
state unknown; they do not claim that the remote server is down.

## Local failover integration tests

Run `just test-case XrayGroupIntegrationTests` to test the bundled Xray with
configs produced by Teleport's real subscription parser and configuration writer.
The tests exercise `leastLoad` and `leastPing` using two loopback VLESS servers:
traffic starts through A, switches to B after A stops, fails while both are down,
and recovers through B while fallback A remains down. The outage spans a full
observer cycle. A separate HTTP destination detects any unintended direct
requests, including observer probes. The tests also stop the client and reap all
child processes. No external server, subscription credentials or network changes
are required.

These checks exercise the local proxy and balancer. They do not create a TUN or
prove privileged route/firewall/DNS cleanup, IPv6 uplink connectivity, continuity
of existing TCP streams, or reachability through an operator's whitelist. Those
still need tests on the affected network. Reconnect ordering and cancellation
are covered separately by `PrivilegedHelperClientTests` with a simulated helper.
