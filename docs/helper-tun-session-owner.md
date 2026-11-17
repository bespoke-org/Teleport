# Helper TUN session ownership

The helper's `main.swift` constructs one `XrayTunController`. Its value copies
share one reference-type `HelperTUNSessionExecutor`, supervisor and leak guard.
There is no second app intent runtime and no wire/persistent format change.

## App → helper → result contract

Rechecked against develop `4d935c8572d7d3c2f0fd6c7d3a6f0230d8d40e02`:

- PR #84 (`7d79e4449ab1460f59e722a8a2d273db083aa30d`, stacked on
  `refactor/session-lifecycle-foundation`) owns latest **application intent**,
  desire generation, recovery and provider replacement. It finishes provider IO
  before rereading intent. These are not helper execution generations.
- `PrivilegedXrayRuntimeManager` creates the wire session UUID and retains it for
  rollback/stop. `PrivilegedHelperClient` validates response correlation and uses
  query-status after indeterminate transport outcomes. No new retry is introduced.
- `HelperCommandDispatcher` still owns authorization-independent request
  admission, ledger/replay/conflict detection, `executionTail` and admitted-session
  failure correlation. Authorization remains in the XPC endpoint. Failed
  mutations remain correlated so a matching stop can recover. The executor does
  not return its private generation over IPC or override dispatcher correlation.
- `HelperTUNSessionExecutor` owns **local resource effects**, run generation and
  exit ingress. A synchronous start/stop waits for its private serial queue;
  supervisor callbacks only enqueue `(sessionID, generation, pid)`. Status reads
  a short-lock immutable snapshot, never synchronously enters the effects queue.
- PR #55 (`7fe7f6fe38f1835d07f46027cac18e725fe8a0fb`) adds proxy preference
  commands to the dispatcher. Its proxy transaction/recovery semantics and the
  dispatcher are untouched here.
- PR #77 (`0ec15498674758e907ddafac3d43f4699b759881`) changes persistent guard,
  endpoint resolution and guard status in the controller. This is a real merge
  hotspot: when integrating, preserve its `isLeakGuardEngaged` field in **both**
  snapshot and restart-fallback status paths. Do not move guard policy into this
  executor. No unfinished PR is an implementation prerequisite or merged here.

## Model and invariants

```
no observation (fresh helper) --start--> starting(token) --> running(token)
                                  error |                     |
                                        v                     | stop / exit / replacement
                                   stopping(token) <----------+
                                        |
                       success ---------+-------- failure
                          |                          |
                        idle                 cleanupFailed(token)
                                                     |
                                                 stop / start
                                                     |
                                                stopping(token)
```

A token is the wire session UUID plus a fresh UUID generation, not a PID and not
an app intent revision. The generation is deliberately process-local. Reusing a
PID or session UUID cannot authorize an earlier exit. Supervisor watches also
have their own UUID, so an old source handler cannot consume a rearmed watch of
the same PID. Cancelling a source does not revoke a callback already delivered.

The only teardown recipe cancels the watch, prepares the root directory,
terminates the managed and legacy process, then executes the existing stop
script. Manual stop, replacement, failed start and unexpected exit use that same
recipe. An exit is validated again on the serial queue against token and PID.
After success the context is dropped; duplicate stop/exit does not run it again.
After failure the original recipe/token/interfaces stay retained; another stop
retries it. A new start must finish that recipe before writing a new config. A
failed attempt to replace A with B can still leave cleanup context A, while the
dispatcher correlates the failed request to B: stop(B) deliberately retries the
retained A context instead of trusting B's cleanup arguments.

No `NSLock` is held during IO. Exit ingress holds one mailbox and at most one
scheduled drain; an event flood during blocked IO cannot grow a task queue.
Snapshot reads are also safe from inside an effect. Effects must not synchronously
call start/stop on their own owner; production effects never do this.

Before the first owned operation, status and stop retain existing process/config
recovery for a helper restart. A start with no validated PID preserves the old
successful response but status falls back to existing process evidence rather
than inventing a watched process. After known cleanup, idle has no stale disk
fallback. `cleanupFailed` projects as the existing wire `.failed` with a bounded,
constant summary; no raw shell failure is published. Dispatcher failures retain
their existing presentation precedence. There is no new wire phase or session ID.

## Preserved effects and deliberate limits

Start still sets the dump marker, captures diagnostics, writes the config,
terminates managed then legacy Xray, runs the same start script with the same
validated fields/IPv6 inventory and arms the supervisor. Cleanup runs before a
replacement's first mutation, rather than racing it. Cleanup captures validated
values and resource drivers, not the controller or owner (no retain cycle).

The shell builders, ManagedXrayProcess, routing/DNS/proxy policy, guard arm/disarm,
app lifecycle and automatic retry/timeout policy are unchanged. Existing shell
suppressed errors and destination-only route deletes are not converted into an
ownership journal. Successful cleanup means the existing drivers returned
success, not atomic routing restoration. A stuck shell can still stall mutations
but not snapshot status. External route changes and helper crashes remain beyond
this process-local ownership model. No claims of durable tokens, full #42, #7,
#47, #53 or #81 resolution.

## Verification contracts

`HelperTUNSessionExecutorTests` uses fake effects and semaphores, not live network
or timing sleeps: happy path; stale exit before/after replacement; old exit during
B start; cleanup A already blocked while B requests start; manual stop/duplicate
exit; reused PID/session UUID; early exit during start; wrong PID/generation;
failure of every modeled start/cleanup stage; failed rollback retention; cleanup
retry/start refusal; restart fallback; nil PID; max concurrent effects = 1.
Native-only cases exercise the real facade/status and dispatcher ledger replay
while effects are blocked. Existing `HelperCommandDispatchTests`,
`XrayTunRuntimeInterfacesTests` and `SplitTunnelingTests` retain their protocol,
file-evidence and script characterization coverage. `XraySessionSupervisorTests`
uses only its own short-lived children, including same-PID rewatch and reaped
process fallback.

The old concrete controller had no injected shell/process boundary. The old
boundary witness test deterministically demonstrates the source ordering
(check A, replace with B, continue cleanup A) in an explicitly labeled model.
It is NOT a red run of the old production controller and NOT a reproduced live
network failure. The architecture is justified by the explicit invariant, not by
claiming that this model is production execution.

On Linux only the portable executor suite is executed in isolated Swift Docker
with networking disabled. Native build/XCTest must be checked through the existing
macOS 15 arm64 / macOS 26 arm64 and x86_64 PR CI. No Linux result is a macOS
route/DNS/helper-install test. Full `just test` belongs to CI; local native use is
limited to `just test-case <relevant class>` per AGENTS.md.

Remaining manual acceptance (separate authorized macOS test host): reconnect
while that host's fixture Xray exits, then network-change/sleep-wake; confirm an
old cleanup cannot tear down a new run. Never use a user's installed Teleport,
proxy/routes/DNS/PF or helper installation as an experiment.
