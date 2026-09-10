# Handoff: fix/44 close Browser Use sessions

## Context

Neureni issue #44. A Browser Use session is a billed remote resource. Neuron closed one
only on paths that reached an `after` block, so anything that skipped `after` left a cloud
browser running until the provider's own timeout expired.

## The leak, precisely

`Neuron.Browser.BrowserUse.open_session/1` calls `Process.unlink(pid)`, so nothing tied the
remote browser's lifetime to the process that opened it. Three paths skipped cleanup:

1. **Owner killed.** An Oban cancellation, a Lifeline rescue, or a brutal supervisor kill
   terminates the worker without running `after`.
2. **A linked task exiting.** `Neuron.Browser.Fleet.fetch_pages/3` runs one `Task.async` per
   slot. `run_slot` rescues exceptions, but an exit (a CDP `GenServer.call` timeout, for
   example) is not an exception: it propagates to the fleet caller and kills it, so
   `with_fleet`'s `after close(fleet)` never runs.
3. **Cleanup order.** `close_session/1` called `Pinocchio.Session.release(pid)` before
   `Pinocchio.Providers.BrowserUse.stop/1`. Releasing an already dead connection process
   exits, and the remote stop, the only call that ends the billing, was never reached.

## What changed

- `Neuron.Browser.Sessions`, a supervised GenServer that owns cleanup. Every session opened
  is registered against the process that opened it and is stopped when that owner goes down
  for any reason, when the caller closes it explicitly, or when the process terminates with
  the application. It traps exits and stops every registered session in `terminate/2`, with
  a 30 second shutdown budget.
- `Neuron.Browser.BrowserUse.stop_session/1` runs the remote stop first and unconditionally,
  then releases the local connection process only if it is still alive. Losing the local
  process can no longer skip the billed resource.
- `Neuron.Browser.BrowserUse.close_session/1` now routes through `Sessions`, so a session is
  stopped exactly once whether the caller reaches its cleanup or dies first.
- `Neuron.Browser.BrowserUse.list_sessions/1`, `stale_sessions/3` and `sweep/1`.
- `mix neuron.browser.sweep [ttl_seconds]`, the operator backstop.
- `:neuron, :browser, :browser_use, session_ttl_seconds`, default 3600.

The sweep task runs on `app.config`, not `app.start`. A leaked session has to be reclaimable
when the application itself will not boot, which is not hypothetical: on this machine
`app.start` currently fails on the embedding model path in Neureni issue #38.

## Tests

`test/neuron_browser_sessions_test.exs`, four cases:

- a task that raises still leaves zero open sessions (the acceptance case)
- a killed owner stops its session
- an explicit close stops the session once and drops its registration, and the owner
  outliving it does not stop it a second time
- the sweep selects only sessions still running past the TTL, never ones already stopped

Full suite: 69 passed, 3 excluded. `mix format --check-formatted` clean.

## Sweep run

Run against the live account on 2026-09-10 at 10:57 PDT.

```
$ mix neuron.browser.sweep
No sessions older than the TTL are still running.
```

**It closed zero sessions.** That is the honest result and not a claim that nothing ever
leaked. Confirmed against the provider directly: 325 browsers on the key, all with status
`stopped`, and zero still running at any age. The spike's sessions from earlier today had
already been reclaimed by Browser Use's own one hour `timeoutAt`. The sweep is the backstop
for the window before that timeout, which is where the billing actually accrues.

## Provider note

The spike handoff records that `/api/v4/browsers` ignores `limit` and returns only the ten
most recent rows. The parameter it honours is `pageSize`; `limit` is ignored. The listing
here pages with `pageSize=100` and `pageNumber`, and reads `totalItems` to know when to
stop, so it sees the whole account rather than a truncated window. Worth carrying back to
Neureni issue #40, whose cost workaround reads the same endpoint.

## Not covered

- Sessions opened by a caller that supplies its own `:handles` to the fleet are the caller's
  to close. Test fixtures do this; production code does not.
- The sweep is account wide, not organization scoped. Scoping waits on `neuron-04`.
