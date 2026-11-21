# Helper TUN session ownership

The helper's `main.swift` constructs one `XrayTunController`. Its value copies
share one reference-type `HelperTUNSessionExecutor`, supervisor and leak guard.
There is no second app intent runtime and no wire/persistent format change.

## App → helper → result contract

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
                           script error |                     |
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
terminates the managed and legacy process, then executes the stop script.
The executor arms route rollback immediately before invoking the start script.
A preparation failure returns without running route cleanup. After a fresh
helper launch, a follow-up stop checks for persisted tunnel state or a validated
legacy process before adopting a cleanup recipe. An exit is validated again on the serial queue against token and PID.
After success the context is dropped; duplicate stop/exit does not run it again.
After failure the original recipe/token/interfaces stay retained; another stop
retries it. A new start must finish that recipe before writing a new config. A
failed attempt to replace A with B can still leave cleanup context A, while the
dispatcher correlates the failed request to B: stop(B) deliberately retries the
retained A context instead of trusting B's cleanup arguments.

The supervisor consumes each watch once. Its callback enqueues an exit on the
same queue as start and stop. Status reads a snapshot under a short lock, even
while the queue is waiting for shell I/O.

Before the first owned operation, status and stop retain existing process/config
recovery for a helper restart. A start with no validated PID preserves the old
successful response but status falls back to existing process evidence rather
than inventing a watched process. After known cleanup, idle has no stale disk
fallback. `cleanupFailed` projects as the existing wire `.failed` with a bounded,
constant summary and retained interface information. The dispatcher preserves
this status after a failed command. Reconnect, explicit stop and app cleanup
can retry using the helper's correlated session ID. Reconnect also checks for
other VPN interfaces before retrying.

A stop treats absent routes as already removed, reports route deletion errors
and checks that the Teleport DNS resolver key is gone. The helper retains its
cleanup context and persistent config on failure. Destination-only deletes
remain a limitation until the helper journals the exact routes it installed.

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

App recovery tests use scripted helper replies. The stop-script regression
uses fixture route and DNS commands to exercise failed deletion and retry.

Remaining manual acceptance (separate authorized macOS test host): reconnect
while that host's fixture Xray exits, then network-change/sleep-wake; confirm an
old cleanup cannot tear down a new run. Never use a user's installed Teleport,
proxy/routes/DNS/PF or helper installation as an experiment.
