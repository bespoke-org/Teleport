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

Before installing TUN routes, Teleport resolves every member and pins its dial
address to a protected physical route. A member that cannot be resolved fails
the connection attempt. Health checks open temporary leak-guard exemptions for
all members. If the helper's shared address budget is full, the check reports an
unknown result and releases any exemptions already opened.

The fixtures in `teleportTests/fixtures/subscriptions/balanced-*.json` use
synthetic credentials and reserved example domains. Tests check import,
refresh, sharing, sealed storage, member routes and generated configurations
with the bundled Xray's `run -test` command. Configuration validation does not
prove reachability through an operator's whitelist; that needs a connection
test on the affected network.
