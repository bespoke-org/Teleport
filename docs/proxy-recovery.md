# Proxy recovery and verification

Teleport saves the original and intended proxy settings before changing them. The
recovery file is `~/Library/Application Support/teleport/system-proxy-snapshot.json`,
written atomically with mode 0600. It does not contain proxy passwords. PAC URLs,
scripts, and proxy usernames can still be sensitive; do not publish this file.

## Authorization

Both connection modes use Teleport's privileged helper for proxy preference
transactions. Administrator approval installs the helper and approves the app and
helper build. A changed build can need approval again. Ordinary connects,
reconnects, disconnects, and recovery use the approved helper without requesting
short-lived network authorization in the app.

Recovery also checks helper installation. If it is missing or outdated, macOS may
ask to install or update it. Canceling leaves the recovery record intact. A declined
recovery request is not repeated on every network notification; retry explicitly
by disconnecting or connecting again.

System Proxy's Xray process still runs as the current user. The helper receives
only typed proxy requests through authenticated XPC, with no shell command or
caller-selected file path. It compares the affected proxy groups under the
preferences lock, merges only the requested fields, commits, applies, and verifies.
Recovery reads run behind pending writes. Each read also invalidates previous
transaction IDs, so a delayed old write cannot reapply settings after recovery.

## What is restored

HTTP, HTTPS, SOCKS, PAC, WPAD, and bypass settings are compared in coherent groups.
For example, a PAC URL and its enabled flag belong to one group. If another app
changes the suspended PAC URL, Teleport preserves that group instead of enabling
PAC on the new URL using the old flag. Unknown preference keys are left alone.

System Proxy temporarily uses `localhost`, `127.0.0.0/8`, and `::1` bypass
exceptions. It removes `ExcludeSimpleHostnames` to disable that behavior; on the
tested macOS version, CFNetwork treats even a zero-valued key as enabled. Recovery
restores the exact previous value or absence. TUN does not change either bypass
setting.

An external change to a controlled group ends the connection. Teleport restores
other groups that still match its writes, relinquishes the externally changed
group, and does not replay it on a later recovery. A newly eligible service or a
change of network location also ends the connection without changing the new
services. Reconnect explicitly to take over the current services.

Preference notifications trigger checks; the provider also checks every two
seconds. Detection is not instantaneous and does not prevent traffic from using an
external configuration before teardown. Values identical to Teleport's writes
cannot be attributed to a different writer. These are limits of value comparison,
not guarantees about which application owns a setting.

Recovery uses stable service IDs across all saved services, including disconnected
or disabled services, when their preferences are accessible. Missing IDs remain
in the journal. A new service with an old name never inherits its recovery record.
Another Teleport process cannot take over or recover while the current process
holds the journal lock.

## An older or unreadable recovery file

Old snapshots contain service names but no stable IDs or record of what Teleport
last wrote. Teleport preserves them and refuses to guess which current settings it
owns. Corrupt and unsupported files are also preserved.

1. Quit Teleport. Keep a private backup of the recovery file.
2. In System Settings > Network, review each relevant service's proxy settings.
   For an old snapshot, use its saved names and original HTTP/HTTPS/SOCKS values
   as reference, but verify which service each name now identifies. Old snapshots
   do not record PAC, WPAD, or bypass settings. Do not infer those values from them.
3. Restore the desired settings manually, including any required credentials from
   your own records. If the file is unreadable, consult your network administrator
   or your known working configuration; Teleport cannot reconstruct it.
4. Once all services are reconciled, move the recovery file to a private backup
   location outside the Teleport directory. Do not remove the lock file while an
   app instance is running. Relaunch Teleport and connect explicitly.

For a current journal with a temporarily missing service, prefer bringing the
service back and retrying recovery. Keep its record until that service is restored
or you have independently reconciled its settings.

## Automated checks

Run `just test-case SystemProxyServiceTests` and
`just test-case ConnectionProviderTests`. The proxy tests use fake preferences and
isolated storage; the CFNetwork bypass test evaluates supplied dictionaries and
does not send traffic or alter system settings. The provider tests cover conflict
notifications, polling, cleanup failures, and the explicit-reconnect requirement.

## Controlled macOS verification

Use a disposable macOS account or VM with a known working network configuration.
Record the OS version and original service IDs/settings before testing. Never
replace a real user's proxy settings just to run this checklist.

- Connect and disconnect both modes with manual proxies, PAC, WPAD, and mixed
  settings. Check preferences and an application that honors system proxies.
  Explicit SOCKS requests alone do not verify PAC/WPAD precedence.
- Accept and cancel helper installation on first connect and on recovery with a
  missing or outdated helper. Confirm the app remains responsive, recovery records
  survive cancellation, and retry works. With the approved helper installed, wait
  more than 30 seconds between connects/reconnects/disconnects and confirm there
  are no further password prompts in either mode.
- Verify loopback bypass, non-loopback local addresses, and simple hostnames using
  real requests. Confirm the previous exceptions and hostname flag return.
- Confirm enabled authenticated proxies are rejected before changing settings.
  Also check a disabled authenticated configuration in each mode. Do not infer
  password preservation from a successful connection.
- Terminate the app after takeover, then relaunch. Restore the original values;
  also test a TUN helper session that survives the app process.
- Change a controlled proxy group in System Settings while connected. Verify
  teardown, a useful error, preservation of the external change, and no automatic
  reconnect after wake or network notifications. Change an unrelated setting and
  TUN bypass exceptions; those changes should survive without a proxy conflict.
- Rename a service, disconnect its interface, remove/reintroduce an adapter, and
  switch locations. Verify retained records and the explicit-reconnect policy for
  newly eligible services. Check that a new ID reusing an old name is untouched.
- Start a second app instance and verify it cannot take over, recover, or stop a
  TUN session owned by the first instance.

Interactive helper installation, real preference commit/apply, application traffic, and
helper survival require this controlled verification. Passing unit tests alone
does not establish these behaviors on every supported macOS version.
