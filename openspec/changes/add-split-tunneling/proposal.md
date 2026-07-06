## Why

VPN mode currently routes all IPv4 traffic through the selected server with split default routes (`0.0.0.0/1`, `128.0.0.0/1`). Users have asked for a way to keep specific destinations off the remote proxy — for example local network services, banking sites with proxy-hostile fraud detection, or bandwidth-heavy domains that don't need to be tunneled. macOS offers no supported way to do this per-application outside of an MDM-managed configuration profile, so this change scopes split tunneling to destination-based rules (domain and IP/CIDR) evaluated inside Xray's own routing engine, matching how other Xray/sing-box-based clients (Shadowrocket, Surge, ClashX) implement the same feature.

## What Changes

- Add a persisted, ordered list of split-tunnel rules, each matching a domain or IP/CIDR value and each carrying its own action (`direct`, `proxy`, or `block`) applied during VPN mode.
- Add a per-app toggle to enable or disable split tunneling without discarding the saved rule list.
- Generate Xray tunnel routing rules from the saved list, inserted before the existing catch-all proxy rule, preserving current DNS/multicast block rules.
- Add a Settings UI for managing split-tunnel rules, designed around fast, low-friction rule entry and editing (inline type detection, inline validation, per-rule action picker, drag-to-reorder, per-rule enable toggle) since matching-rule usability is the primary success criterion for this change.
- Add a rule tester in the same UI: the user types a domain or IP and immediately sees which saved rule (if any) would match it and what action it resolves to, without connecting VPN or reading logs.
- Apply rule-list or enabled-flag changes to an active VPN session by regenerating the tunnel config and restarting the managed Xray process, without requiring the user to manually disconnect and reconnect.
- Deliberately do not expose raw regex matching in the UI; only deterministic match kinds (domain with automatic subdomain inclusion, `full:`-prefixed exact host, IP/CIDR) are offered, so a rule's effect is predictable by reading it rather than needing to test it against traffic.

## Capabilities

### New Capabilities
- `split-tunneling`: Destination-based (domain/IP/CIDR) rules, each with its own routing action (direct/proxy/block), with persisted per-rule ordering, enablement, and an interactive rule tester.

### Modified Capabilities
- `bundled-xray-runtime`: VPN tunnel configuration generation includes routing rules derived from saved split-tunnel rules ahead of the default proxy rule.
- `settings-window`: Adds a split-tunneling management surface to the Settings window.

## Impact

- `TeleportModels.swift` — new `SplitTunnelRule` model and `AppSnapshot` fields.
- `ConfigurationStore` — persistence and legacy-decode defaults for split-tunnel state.
- `XrayConfigurationWriter` — tunnel routing-rule generation from saved split-tunnel rules.
- `AppViewModel` — rule CRUD, live-apply to an active VPN session.
- `Views/Settings` — new split-tunneling settings view.
- `scripts/` and `justfile` — new verification script for rule-to-routing-rule generation.
