# Handoff: fix/41 a login gate is a skipped engine

## Context

Neureni issue #41, `neuron-11`. One Reddit query hit a login gate and the whole run failed
with `{:search_unavailable, [one reason]}` after 314 seconds and five billed browser
sessions, with LinkedIn and X disabled and no profile ID, which is the configuration the
host is required to run. It contradicted Neuron's own documentation twice: a login gate is
an engine failure, and the remaining engines carry the round.

## What was already fixed, and where

The condition itself landed in #43, because that branch could not meet its own acceptance
without it. Once bot walls became visible, the old rule would have failed every round on a
walled Google while Yandex was answering. `orchestrate/2` now treats a round as unavailable
only when no engine answered at all, and an engine that answered with nothing still carried
the round. That is declared in #43's PR and repeated here so the history is not misleading.

## What this branch adds

The half of #41 that is about the host being able to tell what happened.

- `Neuron.Search.wall_reason/1` returns `{kind, reason}` rather than a bare sentence, with
  `kind` one of `:login_gate`, `:consent_wall`, `:bot_check`. A host can now say which
  happened instead of only that something did.
- Every failure entry carries `kind`. Page errors are `:page_failed`, harvest errors are
  `:harvest_failed`, so the whole failure list is classified rather than half of it.
- The campaign result's failures carry `engine` as well, so the list names each engine in a
  form that is read rather than parsed out of a string. The existing `query` field keeps its
  `"engine: query"` prefix, so nothing already reading it changes.
- `:search_unavailable` carries that same classified list, one entry per failed engine.
- `docs/library.md` states the rule the host renders from: a completed run with non-empty
  `result.failures` is a degraded round, a failed run with `{:search_unavailable, failures}`
  is an unavailable search, and both carry the same entry shape.

## Tests

- **a login gate on one engine leaves the other two to carry the round**, the acceptance
  case: three engines, one gated, the round returns `{:ok, merged, failures}`, both engines
  that answered are credited on the merged result, and the gated one appears once with
  `kind: :login_gate`.
- errors only when every engine failed, and names each one: two engines, one gated and one
  bot-walled, the round fails and the reason list carries both engines with their kinds.

Full suite: 79 passed, 3 excluded. `mix format --check-formatted` clean.

## Reddit

The issue asks for Reddit's status to be decided. It was already decided before this branch,
in commit `892566b`: `Neuron.Search.Reddit` is out of the default engine list and its
moduledoc records why, that cloud datacenter IPs are redirected to a login wall. Nothing
here changes that, and nothing here tries to get past it.

## Note on non-determinism

The issue records that the original failure was intermittent, one run failing where another
with the same engine list got much further. That is consistent with what the #43 diagnostic
measured: whether a given engine serves results or a wall varies per request from the same
cloud IPs. DuckDuckGo was walled on one query in six in the acceptance run and on four of
four an hour earlier. The fix does not make walls rarer. It makes them survivable, which is
the part that was wrong.
