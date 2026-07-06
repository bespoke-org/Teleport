## Context

Teleport's VPN mode runs Xray with a TUN inbound through the privileged helper and installs split default IPv4 routes so all traffic enters the tunnel; the only existing exceptions are host routes for the proxy server itself and resolved DNS servers, added directly by the helper's shell scripts (see `TeleportPrivilegedHelper/main.swift`). `XrayConfigurationWriter.makeTunnelPayload` already builds a `routing.rules` array with two block rules (NetBIOS/mDNS ports, multicast) ahead of a catch-all `outboundTag: proxy` rule.

Research into comparable clients showed two relevant precedents:
- Xray-core's own routing module supports `domain` and `ip` match fields on `type: field` rules with an arbitrary `outboundTag`, which is exactly the mechanism needed here — no changes to the helper, TUN inbound, or route table are required.
- macOS has no supported per-app VPN routing API for unmanaged (non-MDM) apps since Big Sur, so true per-app split tunneling is out of scope; rule-based Xray/sing-box clients (Surge, Shadowrocket, ClashX) instead expose an ordered list of destination-match rules with a per-rule action, which is the UI precedent this design follows.

The user's explicit priority for this change is that editing the match-rule list must be low-friction — fast to add a rule, hard to enter an invalid one, and easy to see what's currently bypassing the tunnel.

## Goals / Non-Goals

**Goals:**
- Persist an ordered list of split-tunnel rules (domain or IP/CIDR), each with its own action (direct/proxy/block), per-rule enable state, and an overall feature toggle.
- Apply per-rule actions in VPN tunnel mode only; System Proxy mode is unaffected.
- Make rule entry fast and hard to get wrong: inline type detection, inline validation, no modal dialogs for the common add/edit/remove path.
- Let the user check whether a given domain/IP would match a saved rule — and which one, and with what action — without connecting VPN or reading logs.
- Apply rule changes to an already-connected VPN session without a manual disconnect/reconnect.

**Non-Goals:**
- Per-application split tunneling (no supported unmanaged macOS API; see Context).
- GeoIP/geosite rule-set support or imported rule-set files (Surge/Shadowrocket-style); may be a later change once the basic rule list ships.
- Split tunneling for System Proxy mode (apps that don't honor the system proxy are already outside its scope by design).

## Decisions

### Represent rules as a single ordered list with a per-rule action, not a global include/exclude mode
Each `SplitTunnelRule` has `id`, `value` (raw domain or IP/CIDR string), `kind` (`.domain` or `.ip`), `action` (`.direct`, `.proxy`, or `.block`), and `isEnabled`. There is no global mode switch; each rule independently declares what should happen to matching traffic, and unmatched traffic keeps the connection's default behavior (proxy).

This mirrors Shadowrocket/Surge/ClashX's rule-engine model rather than NordVPN/ExpressVPN's two-mode (include/exclude) app picker, which doesn't map cleanly to destination-based matching and forces a global framing ("only these bypass" vs. "only these tunnel") onto what is naturally a per-destination decision. A per-rule action is also a strict superset of the include/exclude framing: an "include mode" is just every rule set to `.proxy` with a global default of `.direct`, so nothing is foreclosed by choosing this model now — a global default-action setting can be layered on top later without a data-model change.

**Alternatives considered:**
- Global include/exclude mode with implicit per-rule action: rejected — adds a mode the user has to reason about, and doesn't allow mixing "force through proxy" and "force direct" and "block" rules in the same list, which per-rule action supports for free.
- Implicit bypass-only action (no `action` field): rejected per discussion — user wants the flexibility to force specific traffic through the proxy or block it outright, not just bypass, and the added field is a small, well-understood control (segmented picker), not a new mode.

### Domain matching uses Xray's `domain` field with automatic subdomain inclusion; no raw regex in the UI
A domain rule value like `example.com` generates a routing-rule `domain` entry using Xray's `domain:` prefix semantics (matches `example.com` and all subdomains), which is the behavior users expect from a single typed-in domain. Users who want exact-host-only matching can prefix a value with `full:` (passed through as-is); this is an escape hatch, not the primary flow. Xray also supports a `regexp:` domain form, but this design deliberately does not expose it as a selectable match kind: regex rules are exactly the case called out in discussion as hard to reason about — a user cannot look at a regex and be confident whether it matches without testing it against real traffic, which undermines the goal of predictable, low-friction rule editing. Only deterministic kinds (domain-with-subdomains, `full:` exact host, IP/CIDR) are supported as first-class input.

**Alternatives considered:**
- Exact-match only by default: rejected, would silently fail to bypass `www.example.com` when the user typed `example.com`, which is the single most common mistake this design tries to prevent.
- Exposing a full match-type picker including `regexp:`/keyword (Surge-style): rejected — regex rules are unpredictable to read and were the specific pain point raised in design discussion; the rule tester (see below) is aimed at closing exactly this gap for the kinds we do support, not at making regex safe to expose.

### Inline, single-field rule entry with automatic domain/IP detection
The add-rule row is a single text field plus an enable toggle and delete button — no "choose type" step. On commit, the input is classified: valid IPv4/IPv6 literal or CIDR → `.ip`; otherwise, if it passes a hostname-shape check → `.domain`; otherwise the row shows an inline error and does not save. This removes an entire decision (and UI control) from the common path.

**Alternatives considered:**
- Explicit segmented control for domain vs. IP: rejected, redundant information the input itself already encodes, and adds a click to every rule entered.
- Deferred/blocking validation via a save button and modal alert: rejected; inline validation next to the field (as Shadowrocket/Surge do) lets users fix mistakes without losing context or the rest of the list.

### Live rule tester alongside the rule list
The Settings UI includes a always-visible tester control: the user types a domain or IP, and the UI evaluates it against the saved rule list using the same ordered first-match logic Xray will use, then shows either "no rule matches — uses default proxy behavior" or the matching rule's value and action, live as the user types (debounced, no submit button). This runs entirely client-side against the persisted rule list — it does not require an active VPN connection, Xray, or the helper.

This is the direct answer to the recurring pain point raised in discussion: not being able to tell whether a given matcher actually applies to a given input. Making this a first-class, always-visible control (not a hidden debug feature) turns "does this rule work" from a question answered by trial-and-error/log reading into an immediate, visible fact.

**Alternatives considered:**
- Surface matching only via connection logs after the fact: rejected — this is the status quo pain point being solved, not a fix for it.
- A separate "test" button/modal instead of live-as-you-type: rejected — adds a step for a check the user will want to run repeatedly and quickly while iterating on rules.

### Reorderable list with drag handles, but order only matters for overlapping rules
Rules render as a `List` with `.onMove` drag-to-reorder, an enable `Toggle`, the value, and a delete swipe action — consistent with the existing Connections settings list patterns. Because domain and IP rules are matched independently and non-overlapping in the overwhelming common case, reordering is an escape hatch for power users (e.g., a broad domain rule followed by a more specific override), not something most users will ever touch. The list still shows rules in evaluation order and documents that first match wins, so behavior isn't surprising when someone does add overlapping rules.

**Alternatives considered:**
- No manual reordering, sorted alphabetically: rejected, silently breaks overlapping-rule precedence with no way to control it.
- Priority number field per rule: rejected, more UI and mental overhead than drag-to-reorder for the same outcome.

### Rule changes apply live to a connected VPN session
When the enabled rule list changes while VPN mode is connected, `AppViewModel` regenerates the tunnel config via `XrayConfigurationWriter` and asks `PrivilegedXrayRuntimeManager` to restart the managed Xray process in place (same helper `start` command, which already tears down and relaunches Xray) rather than requiring the user to toggle VPN off and on.

This directly addresses the split-tunneling UX complaint found in research: several consumer VPN clients require a manual reconnect before exclusions take effect, which users experience as the feature "not working."

**Alternatives considered:**
- Require manual disconnect/reconnect after rule changes: rejected as the most-cited usability complaint in existing split-tunneling implementations.
- Hot-reload Xray's routing config without a process restart: Xray has no supported in-place routing-config reload via the existing helper protocol; a full managed-process restart reuses code paths that already exist and are exercised by connect/disconnect today.

### Routing rules generated only for VPN tunnel mode, inserted before the proxy catch-all, in saved order
`XrayConfigurationWriter.makeTunnelPayload` gains a parameter for the enabled split-tunnel rules; each rule becomes its own `type: field` routing rule with its `kind` (`domain`/`ip`) and its `action` mapped to `outboundTag` (`direct` → `direct`, `proxy` → `proxy`, `block` → `block`, reusing the existing `block` outbound already defined for NetBIOS/multicast). Rules are emitted in saved list order — preserving first-match-wins semantics for overlapping rules — inserted after the existing block rules and before the final `outboundTag: proxy` catch-all. `makePayload` (System Proxy mode) is unchanged.

**Alternatives considered:**
- Also support split tunneling in System Proxy mode: rejected as out of scope — apps opting into the system proxy can already choose not to use it, making destination-based bypass redundant there.

## Risks / Trade-offs

- **[Users expect per-app split tunneling, not per-destination]** → Document the limitation directly in the Settings UI (short explanatory caption) and in the README, referencing the macOS platform constraint.
- **[Live rule changes restart the Xray process, causing a brief connectivity blip]** → Acceptable trade-off versus a manual reconnect requirement; the existing connect path already tolerates short Xray restarts and the helper's readiness wait covers it.
- **[Malformed CIDR/domain values silently drop a rule at config-generation time]** → Inline validation at entry time (see Decisions) prevents this from ever reaching persisted state; add a verify-script test asserting invalid values are rejected before save, not filtered later.
- **[Users assume broad domain rules also match matching IP literals reached directly]** → Out of scope; document that domain rules match SNI/Host, not resolved IPs, consistent with Xray's `AsIs` domain strategy already in use.
- **[Rule tester's client-side evaluation drifts from Xray's actual matching behavior]** → Implement the tester's matcher as the same shared Swift logic used to build the routing-rule payload (not a reimplementation), so the tester is provably consistent with what gets generated; cover with a verify-script test that feeds the same inputs through both paths.

## Migration Plan

1. Add `SplitTunnelRule` and `AppSnapshot.splitTunnelRules` / `isSplitTunnelEnabled` with legacy decode defaults (`[]`, `false`).
2. Extend `XrayConfigurationWriter.makeTunnelPayload` to accept and render enabled rules as routing rules.
3. Wire `ConfigurationStore` persistence and `AppViewModel` CRUD plus live-apply-on-change behavior.
4. Build the Settings UI per the Decisions above.
5. Add `scripts/verify_split_tunneling.swift` and a `just verify-split-tunneling` recipe; include it in `just verify`.
6. Release without state migration; older builds ignore the new persisted fields, matching the pattern used for `filterDuplicateImports`.

## Open Questions

- None currently; scope is deliberately limited to destination-based rules for this change, with per-app split tunneling and rule-set import explicitly deferred.
