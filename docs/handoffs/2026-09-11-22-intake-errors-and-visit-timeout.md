# Handoff: intake step errors and the navigation timeout

Neureni#22. Two defects, both in Neuron.

## 1. Every step of intake reported as a URL problem

`intake_answers/3` ran the whole chain in one `with` and had a single
`{:error, _reason} when is_binary(url)` clause underneath it. Any failure anywhere in that
chain, on a site that answered 200, came back as `:url_unavailable`.

`scrape_answers/2` made it worse by collapsing seven steps into one `{:error, reason}` before
that clause ever saw it: browser fetch, HTML extraction, snapshot normalization, document save,
prompt render, model call and JSON decode. A model timeout read as a URL problem.

**And the answers were thrown away.** The `:url_unavailable` branch returned `questions()`,
the whole set of eight, with the caller's answers in `partial`. That is the reported symptom:
answer all eight, get the identical eight back. The docstring already said what should have
happened, "use supplied answers first; if a URL is present, scrape it to fill missing
answers", but the code made a successful scrape a precondition for using answers that were
already complete.

Fixed in two parts:

- **Each step names itself.** `step/2` tags every stage, so a failure is `{:normalize, reason}`
  or `{:model, reason}`. Only `:fetch` means the URL was the problem.
- **A scrape failure no longer discards answers.** Intake normalizes what it was given; if that
  is enough, it returns a campaign. If it is not, it asks only for what is still missing and
  attaches `scrape_error` so the host can see why enrichment failed. `:url_unavailable` is
  gone.

## 2. A navigation wait that exited instead of returning

`Pinocchio.Browser.visit_and_wait/3` discards the timeout it is given. `expect_navigation/2`
ignores its options entirely (`_opts \\ []`) and `await/1` hardcodes 30 seconds:

```elixir
def await(%Pinocchio.Expectation{session: %Session{pid: pid}, ref: ref}),
  do: Pinocchio.Connection.await(Session.connection(pid), ref, 30_000)
```

`Connection.await/3` is `GenServer.call(pid, {:await, ref}, timeout)`, which **exits** on
timeout. An exit is not an exception, so the `with` could not match it and the `rescue` in
`fetch_with_open_session` never saw it. A slow page killed the caller instead of failing the
fetch, and a page the fleet allowed 120 seconds was cut off at 30.

Neuron already had what it needed. `Neuron.Browser.Fleet.CDP.wait_ready/4` takes the timeout it
is given and returns `{:error, :page_not_ready}`. `BrowserUse.navigate/3` now uses it, at
`BrowserUse.timeout/1`: the caller's, then the fleet's, then a minute. The `try` gained a
`catch` so any remaining exit becomes `{:error, {:browser_use_timeout, _}}`.

`wait_ready/4` gained two things: a `nil` URL now means settle-only rather than ready
immediately, because a direct fetch accepts wherever a redirect landed, and a browser module
argument so the poll is testable without a browser.

## Why the third visit hangs: not answered, and now tried properly

**Addendum, 2026-09-11 evening.** The URL was supplied afterwards: `https://nyx-labs.org/`, in
the intake scrape, with the host's profile unset. It still does not reproduce.

The site is not the cause. It answers 200 in 1.3 seconds with 12,833 bytes, no redirects, a
plain static document with `last-modified` from August.

Seven conditions, 31 navigations, 20 browser sessions, $0.1056:

| condition | URL | profile | result |
| --- | --- | --- | --- |
| three separate `fetch/2` | rewind.com | set | 15.7s, 8.7s, 6.8s, all ok |
| four consecutive `visit_and_wait/3`, one session | rewind.com | set | 3.1s, 1.4s, 1.4s, 1.3s, all ok |
| three separate `fetch/2` | **nyx-labs.org** | **unset** | 5.3s, 5.5s, 5.1s, all ok |
| three `visit_and_wait/3`, one session, the old path | **nyx-labs.org** | **unset** | 5.2s, 0.3s, 0.4s, all ok |
| three `navigate/3`, one session, the new path | **nyx-labs.org** | **unset** | 2.2s, 0.7s, 0.8s, all ok |
| **three real `Campaign.intake/2` passes**, with Dgraph and the model | **nyx-labs.org** | **unset** | 22.6s, 16.3s, 28.1s, all scraped, `scrape_error: nil` |
| five concurrent sessions, three visits each | **nyx-labs.org** | **unset** | 15 visits, slowest 5.0s, all ok |

The third visit was specifically checked in every sequential condition, including against the
unfixed `Pinocchio.Browser.visit_and_wait/3` rather than only the replacement. Nothing came
near the 30 second wait, let alone past it.

**So the trigger is not the URL, not the missing profile, not session reuse, not repetition,
and not concurrent session pressure.** What is left is something about that particular run:
provider-side state on the day, a transient network condition, or an account-level limit that
was being hit then and is not now. The report is dated 2026-09-11 and this was run the same
evening, which narrows it further without settling it.

This is recorded so nobody pays to run it again. If it recurs, the thing to capture is the
Browser Use session id and the `[:neuron, :browser, :session]` telemetry for the run, because
the provider's own record of that session is the one piece of evidence this reproduction
cannot manufacture.

The fix stands on its own either way, and is what makes a recurrence survivable rather than
fatal: whatever hangs is now `{:error, :page_not_ready}` at the caller's timeout instead of an
exit at a hardcoded 30 seconds that no `with` could match and no `rescue` could see.

## Why the third visit hangs: the original attempt

**I could not reproduce the hang**, and I am not going to assert a cause I did not observe.
Against `rewind.com/about/` with the profile set:

- three separate `Neuron.Browser.fetch/2` calls: 15.7s, 8.7s, 6.8s, all `{:ok, _}`
- four consecutive `visit_and_wait/3` calls on **one** session: 3.1s, 1.4s, 1.4s, 1.3s, all fine

So session reuse on its own does not do it, and neither does repeated navigation to the same
URL, nor a URL that redirects. What remains is site-specific or provider-specific: a page that
never settles, or a profile whose browser context is still held by the previous session.

The fix does not depend on knowing which. Whatever causes a navigation to hang, it is now a
tagged error at the caller's timeout instead of an exit at a hardcoded 30 seconds. **If the
repro names a URL, give it to me and I will find the cause itself.**

## Tests

`test/neuron_intake_errors_test.exs`, six cases:

- **eight answers and a URL that will not parse still produce a campaign**, the repro
- eight answers and an unreachable URL still produce a campaign
- a step after the fetch is not reported as a URL problem
- a fetch failure names the fetch, and asks only for the unanswered questions rather than all
  eight
- no URL at all is unchanged
- incomplete answers and no URL ask for what is missing, with no `scrape_error`

`test/neuron_browser_navigate_test.exs`, five:

- the navigation budget is the caller's, then the fleet's, then a minute
- a page that never settles is a tagged error, not an exit, and honours its timeout
- a settled page is ready, and a redirect elsewhere is still accepted
- a fleet tab still has to be reading its own page
- **the repro's sequence completes with a profile**, gated on `:integration`, three navigations
  on one session and three separate fetches. Run live: 5 passed in 33 seconds. It fails loudly
  rather than skipping when either variable is unset

Full suite 156 passed, 5 excluded.
