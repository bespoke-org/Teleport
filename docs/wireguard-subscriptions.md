# WireGuard subscriptions

Subscriptions accept one `wireguard://` link per line in plain UTF-8 text, or the
entire list encoded as base64. A list can mix WireGuard with VLESS, Trojan and
Hysteria 2 links.

Links use the same parser and validation as standalone imports. Supported settings
include private, public and preshared keys, interface addresses, allowed IPs, DNS,
MTU, reserved bytes, keepalive and a display name in the URL fragment.

## Unsupported forms

WireGuard `[Interface]` configuration files, `wg://` links and WireGuard Xray JSON
profiles are skipped with an explanation. Import configuration files separately
as standalone connections. Invalid links are skipped without including keys or
provider values in the status message.

## Refresh and duplicate filtering

An unchanged link retains its saved identity, custom name, selection and health
history across refreshes, including when the list switches between plain text and
base64. Changing the link itself creates a new subscription entry.

Duplicate filtering keeps profiles with different keys or peer/resolver settings,
even when they share an endpoint. Names alone do not distinguish duplicates.
