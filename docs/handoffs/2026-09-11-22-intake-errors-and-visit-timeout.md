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

## Why the third visit hangs: not answered

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
