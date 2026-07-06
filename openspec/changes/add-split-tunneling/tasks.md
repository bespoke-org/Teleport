## 1. Data model and persistence

- [x] 1.1 Add `SplitTunnelRule` (`id`, `value`, `kind: .domain | .ip`, `action: .direct | .proxy | .block`, `isEnabled`) to `TeleportModels.swift`.
- [x] 1.2 Add `splitTunnelRules: [SplitTunnelRule]` (default `[]`) and `isSplitTunnelEnabled: Bool` (default `false`) to `AppSnapshot`, with legacy-decode defaults for snapshots that predate this change.
- [x] 1.3 Persist and restore split-tunnel state through `ConfigurationStore` alongside the rest of `AppSnapshot`.

## 2. Rule classification, validation, and shared matcher

- [x] 2.1 Implement input classification: valid IPv4/IPv6 literal or CIDR → `.ip`; hostname-shaped value (optionally prefixed `full:`) → `.domain`; otherwise reject with an inline error. Do not offer a raw regex/`regexp:` match kind.
- [x] 2.2 Reject and surface invalid values at entry time so no invalid rule is ever persisted.
- [x] 2.3 Implement a single shared first-match-wins matcher function (given saved rules in order and a candidate domain/IP, return the matching rule or nil) used by both routing-rule generation (3.1) and the rule tester (5.3), so the two can never disagree.

## 3. Xray routing generation

- [x] 3.1 Extend `XrayConfigurationWriter.makeTunnelPayload` to accept enabled split-tunnel rules and emit one `type: field` routing rule per saved rule, in saved order, with `outboundTag` mapped from each rule's `action` (`direct`/`proxy`/`block`), inserted after existing block rules and before the catch-all `proxy` rule.
- [x] 3.2 Leave `makePayload` (System Proxy mode) unchanged.
- [x] 3.3 Preserve existing DNS/multicast block-rule behavior and ordering.

## 4. Live apply to an active VPN session

- [x] 4.1 In `AppViewModel`, regenerate the tunnel config and restart the managed Xray process via the existing helper `start` path when the enabled rule list or the split-tunnel toggle changes while VPN mode is connected.
- [x] 4.2 Ensure rule changes while disconnected are simply persisted and take effect on next connect, with no forced restart.

## 5. Settings UI

- [x] 5.1 Add a split-tunneling section to Settings with an overall enable toggle and a short caption explaining the destination-based (not per-app) scope and the macOS platform limitation.
- [x] 5.2 Build a reorderable rule list (`.onMove`, swipe-to-delete, per-row enable toggle, per-row action picker showing direct/proxy/block) showing each rule's value and detected kind.
- [x] 5.3 Build a single-field add-rule row with inline domain/IP classification, an action picker, and inline validation error display, requiring no modal dialog or type picker for the common path.
- [x] 5.4 Build a live rule tester control: a text field where, as the user types a domain/IP, the UI shows the matching rule (value + action) or "no match — default proxy behavior" using the shared matcher from 2.3.
- [x] 5.5 Reflect the saved state immediately when reopening Settings, matching existing settings-view restore behavior.

## 6. Verification

- [x] 6.1 Add `scripts/verify_split_tunneling.swift` covering: rule classification (valid/invalid domain and IP/CIDR inputs), the shared matcher's first-match-wins behavior including overlapping rules, generated routing-rule shape/ordering/action-mapping consistency with the shared matcher, legacy snapshot decode defaults, and toggle-disabled behavior (no routing rules emitted).
- [x] 6.2 Add a `verify-split-tunneling` recipe to `justfile` and include it in the `verify` recipe.
- [x] 6.3 Run the project verification/build commands and confirm the change is ready to apply.
