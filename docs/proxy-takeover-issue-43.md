# Proxy takeover and recovery

Status: implemented with automated verification passing on macOS 27.0. Controlled
macOS helper installation, live preference commit/apply, and traffic verification remain
outstanding. See [the verification procedure](proxy-recovery.md).

Issue: https://github.com/bespoke-org/Teleport/issues/43

## Problem

`SystemProxyService` saves and changes HTTP, HTTPS, and SOCKS settings. It leaves
PAC and WPAD enabled, identifies services by name, and restores saved values even
when another application has since changed them. Its recovery file records the
original state but not the mutations Teleport actually performed.

The System Proxy provider, TUN provider, and `AppViewModel` also construct separate
service instances that operate on the same recovery file. Coordination must cover
all these callers, including deferred recovery and mode changes.

## Decisions from the design interview

- A conflicting external proxy change ends the connection with an explanation.
  Cleanup preserves the external change. An explicit user connection attempt is
  required before Teleport takes control again.
- System Proxy mode temporarily replaces bypass exceptions with loopback-only
  exceptions and disables exclusion of simple hostnames.
- TUN mode leaves bypass exceptions and simple-hostname exclusion untouched.
- A newly eligible network service or a change of network location ends the
  connection with an explanation and requires an explicit reconnect. Teleport
  does not automatically take over the newly eligible services.
- Both modes use the approved privileged helper for locked proxy preference
  updates and recovery. Administrator approval is needed for installation or a
  changed build; ordinary reconnects must not prompt. System Proxy's Xray process
  remains unprivileged.
- System Proxy split routing is a separate change. Its current Xray configuration
  sends all traffic received by its local proxies through the selected connection.
  Changing macOS bypass exceptions does not enable split routing.

## Takeover policy

Snapshot before the first mutation, keyed by `SCNetworkServiceGetServiceID`.
Keep the name for display only. Initially cover enabled services in the current
network location, consistent with the existing takeover scope. A disconnected
physical interface is not by itself a missing network service.

| Setting | System Proxy mode | TUN mode |
| --- | --- | --- |
| HTTP / HTTPS / SOCKS | Enable and point at Teleport's local endpoints | Disable flags; retain endpoints and other metadata |
| PAC | Disable; retain URL and other configuration | Disable; retain URL and other configuration |
| WPAD | Disable | Disable |
| Bypass exceptions | Replace with loopback-only exceptions | Leave untouched |
| Exclude simple hostnames | Disable | Leave untouched |
| Other proxy dictionary keys | Leave untouched | Leave untouched |

Loopback coverage means localhost, IPv4 loopback addresses, and IPv6 loopback.
Verify the macOS representation and matching behavior in platform checks; do not
include broad local-network exceptions such as `*.local` or private subnets.

Retain the existing refusal to take over enabled authenticated manual proxies in
either mode. Also reject a System Proxy takeover if overwriting a disabled proxy's
credential-bearing configuration cannot be shown to preserve it. Never read,
serialize, or promise to restore passwords. Toggling a flag is not evidence that
credential restoration works.

## Recovery records and conflict policy

Use a versioned journal with a session generation, stable service ID, display
name, mode, original values, expected Teleport values, and per-operation progress.
Preserve absent keys separately from explicit zero, false, or empty values.
Record intent durably before changing preferences; record verified results after.
If journal persistence fails, stop before the next settings mutation.

Record recovery writes as operations too. An interrupted operation must retain
both its prior state and intended next state, including whether it was taking over
or restoring. Recovery can recognize a completed write even if the process died
before recording verification. A multi-command writer must journal each possible
intermediate state before producing it; an unrecognized state is never assumed
to belong to Teleport.

Compare settings in coherent groups: each manual proxy's endpoint, enable state,
and authentication metadata; PAC's URL/configuration and enable state; WPAD;
and bypass exceptions plus simple-hostname exclusion. Track read dependencies
separately from fields Teleport writes. For example, changing a PAC URL while its
flag is suspended must prevent restoring the old enable state onto that new URL.

For each group on cleanup:

- If the live state matches Teleport's verified state, or the intended state of a
  durably recorded interrupted takeover write, restore only the fields Teleport
  changed, merging into the current dictionary.
- If it already matches the original state, mark it restored without writing.
- If it differs from both, preserve the whole externally changed group and mark
  it relinquished. Do not retry an old value later or infer the other app's intent.
- If the service cannot be accessed or the write fails, retain that unresolved
  record for recovery. Successfully restored groups must not be replayed.

Do not restore a complete stale proxy dictionary. Unrelated keys and groups remain
as they are. A changed field whose value coincidentally equals Teleport's value
cannot be attributed to a writer; document this limit of value-based ownership.

Keep unavailable-service records across relaunch and subsequent sessions. A
renamed service is recovered by ID; a new service reusing an old name never inherits
its record. Preserve records for missing IDs rather than guessing that deletion
is permanent. New takeovers must not treat a deferred journal as evidence that
newly encountered services have already been snapshotted.

Journal writes must be atomic and private to the user. Avoid logging PAC URLs,
credentials, or complete proxy dictionaries in conflict messages.

## Live conflict handling

Observe proxy preference and network-service changes, then verify current state
through the same serialized coordinator that performs mutations. Use a bounded
periodic check as a fallback and recheck before declaring a connection ready.
Notifications request a reread; they do not by themselves prove a conflict.

Ignore notifications caused by Teleport's own verified mutations. Ignore changes
to settings the active mode neither controls nor depends on, including bypass
values in TUN mode. Fence callbacks by session generation so a late notification
cannot tear down a replacement session.

On a confirmed conflict, serialize teardown through the provider operation queue,
restore the groups still owned by Teleport, and publish a specific failure through
`ConnectionState`. Identify the service and setting group, explain that an external
change was preserved, and include any cleanup failure. Do not report this as an
Xray crash or claim cleanup succeeded when it did not.

Clear pending automatic reconnect intent and fence already queued wake/uplink
reconnect work. A later path notification must not silently undo the user's or
another application's change. Normal TUN teardown and leak-guard release still
apply; a proxy conflict does not introduce a permanent traffic block.

Service renames only update display information. Ordinary link loss on already
known services retains the existing network recovery behavior.

When a newly eligible service appears or the network location changes, end the
connection with an explanation and require an explicit reconnect in either mode.
This includes an existing but previously disabled service becoming eligible.
Preserve settings on newly eligible services; clean up previously owned settings
by stable ID using the same conflict policy. Clear and fence automatic reconnect
work just as for a proxy conflict. On explicit reconnect, take a fresh inventory
and snapshot the eligible services before changing them.

## Architecture and implementation gates

Keep this in the app-side proxy subsystem. Inject one coordinator into both mode
backends and deferred recovery. Put inventory, preference writes, observation, and
journal storage behind testable interfaces. Keep proxy-specific details below the
provider API; use typed backend failure reporting for supervision.

Prefer a SystemConfiguration transaction that locks preferences, reads fresh
configuration by stable ID, compares ownership, merges only owned fields, commits,
applies, and verifies the result. The installed SDK documents separate commit and
apply operations; a committed change whose apply fails is a recoverable partial
operation, not an untouched system.

The approved helper performs the privileged transaction. The app keeps the
journal and sends an expected inventory plus an allowlisted patch over authenticated
XPC. The helper rechecks the affected groups and service scope under the preferences
lock. A mismatch rejects the whole patch and requires explicit reconnect.

The helper serializes reads with pending writes. Each read returns a one-time
transaction ID that invalidates earlier IDs. This ensures recovery cannot discard
a journal ahead of an in-flight write or be followed by a delayed old write.
A lost write reply is reconciled from a fresh helper read, never blindly replayed.

### Permission feasibility result

On this Mac, an ordinary app cannot lock system network preferences without
administrator authorization. The direct authorization design was tested and then
replaced because the network right's administrator credential timeout is 30 seconds,
causing repeated prompts. Root helper transactions preserve locking without relying
on short-lived app credentials. Both modes install/check the existing helper;
protocol revision 11 and helper version 13 require older installations to update.

All recovery entry points use the same coordinator. A second app process must
either be excluded from takeover or participate in an interprocess journal lock;
an in-process serial queue alone does not protect the file from another process.

## Upgrade recovery

Read the current unversioned snapshot format without discarding or overwriting it.
It lacks stable IDs, mode, and a verified last-write record. In particular, an
off proxy cannot prove that Teleport suspended it rather than another app.

Do not manufacture ownership or recover onto a service solely because its name
matches. Preserve ambiguous legacy records, surface a recovery explanation, and
prevent a new takeover from overwriting those records. Document the manual recovery
procedure. Already-restored entries can be retired only when identity and state
can be established. Corrupt or unsupported journals must remain available for
diagnosis and must not be replaced by an empty snapshot.

## Implementation tasks

- [x] Implement the approved helper-backed writer with preference locking,
      commit/apply, and read-back verification.
- [ ] Verify helper installation, prompt-free reconnects, and live commit/apply in a controlled
      macOS environment using the documented procedure.
- [x] Add stable service inventory, typed proxy values, and a versioned journal
      with safe handling of legacy and corrupt records.
- [x] Implement serialized takeover and conditional recovery for both modes,
      including partial writes, missing services, and retained old records.
- [x] Share the coordinator across provider creation, mode changes, and deferred
      recovery; establish exclusive journal ownership across processes.
- [x] Add conflict observation, typed provider failure reporting, and suppression
      of queued automatic reconnects after a conflict or newly eligible service /
      network-location change.
- [x] Add isolated tests and a controlled macOS verification procedure.
- [x] Update README behavior and recovery documentation, including the distinction
      between System Proxy bypass handling and TUN-only split routing.

## Verification

Completed: 23 `SystemProxyServiceTests`, 27 `ConnectionProviderTests`, 5
`UplinkReconciliationTests`, 37 `SplitTunnelingTests`, and 8
`AppViewModelGeodataTests`, all passing. The CFNetwork dictionary test confirms
loopback exception matching and the need to remove `ExcludeSimpleHostnames`,
rather than setting it to zero, on macOS 27.0. Tests used isolated preference
adapters and storage; they did not change the machine's network configuration.

Add `SystemProxyServiceTests` with fake inventory, preferences, notifications, and
storage. Tests must never modify the developer's real proxy preferences or recovery
file. Cover manual, disabled-manual, authenticated, PAC, WPAD, mixed configurations,
bypass lists, missing keys, unknown dictionary keys, and both modes.

Exercise connect, failed start at every mutation boundary, cancellation, TUN
suspension, mode switch, disconnect, and crash/relaunch. Include failure between
intent persistence and write, after write but before verification, after commit but
before apply, and during recovery journal updates.

Cover rename, temporary disappearance, disabled services, name reuse with a new ID,
new service/location during a session, partial restore, legacy/corrupt journals,
and repeated recovery. Newly eligible services and location changes must cause
teardown without writing to the new services or automatically reconnecting.
Explicit reconnect must snapshot their current settings. Competing edits must
survive cleanup and later retries.
Unrelated edits and TUN bypass changes must not cause a conflict. Test self-generated
notifications, delayed callbacks, and edits during start and recovery.

Extend `ConnectionProviderTests` for conflict teardown and error reporting, and
`UplinkReconciliationTests` or the relevant view-model tests for suppression of
automatic reconnect after a conflict. Run only affected classes using
`just test-case <Class>`.

Use a controlled macOS test environment to verify actual preference writes,
authorization, loopback matching, PAC/WPAD behavior in an application honoring
system proxies, authenticated-proxy refusal, crash recovery, and competing GUI
changes. Explicit SOCKS requests alone do not exercise system proxy selection.
Unit tests cannot establish those platform behaviors. Record the OS version and
results before declaring issue #43 complete.
