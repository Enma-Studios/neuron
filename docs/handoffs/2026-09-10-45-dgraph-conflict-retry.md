# Handoff: fix/45 retry Dgraph transaction aborts

## Context

Neureni issue #45, found in the acceptance run for #43 on 2026-09-10.

Six of that campaign's ingestion children failed outright with gRPC status 10, `ABORTED`,
carrying Dgraph's own message: `Transaction has been aborted. Please retry`. Nothing retried.
The parent recorded each as a failure and continued, so the run survived, but the evidence
those six children had already gathered was thrown away.

This is not an exceptional condition. Neuron dispatches a batch of ingestion children at once
and they routinely upsert overlapping organizations, sources and claims. An abort is the
database saying two writers touched the same entity and the loser should try again, not that
the write was wrong.

## What changed

`Neuron.Graph.with_conflict_retry/2` wraps a mutation and retries while Dgraph aborts it.

All three write paths use it, not only the one the failure surfaced through: `upsert/2`,
`insert_once/2` and `replace/3` each call `Dlex.mutate` and each had the same gap. Patching
only `upsert/2` would have left two siblings broken in exactly the same way.

- **Bounded.** Five attempts by default, backoff doubling from 50 ms with jitter and a cap of
  800 ms. A genuinely contended entity gives up rather than holding a stage open.
  `graph_conflict_attempts` and `graph_conflict_backoff_ms` are per-run options.
- **Aborts only.** Anything else is returned on the first attempt, unchanged. A schema
  violation retried five times is five times the same wrong answer.
- **Counted when it loses.** A conflict that exhausts its retries is recorded against the run
  and surfaces as `usage.total.graph_conflicts` in `get_run/1`, aggregating a campaign's
  ingestion children into the parent, which is where the losses actually happen. A conflict
  the retry absorbs cost time, not data, and is not counted.

`conflict?/1` matches structurally on gRPC status 10 where the shape is known and on Dgraph's
own wording otherwise, so a change in the client's error struct cannot silently turn every
abort back into a permanent failure.

## Tests

`test/neuron_graph_conflict_test.exs`, eight cases, using the exact error shape the #43
acceptance run produced:

- a transient abort succeeds on retry, asserted by consuming a queue of results so the retry
  is proven rather than assumed
- an abort that exhausts its retries is returned and counted against the run
- a conflict the retry absorbs is not counted as a loss
- a non-abort error is returned on the first attempt and nothing retries
- a campaign counts the conflicts its ingestion children exhausted, per stage and in total
- `conflict?/1` recognises an abort by status and by wording, and does not treat other
  failures as retryable
- exhausting the default attempts is not open-ended

Full suite: 104 passed, 3 excluded. `mix format --check-formatted` clean.

## Not in scope

Reducing the collisions themselves, by batching or ordering writes so children do not contend
for the same entities, is a different question and a larger one. This is about not throwing
away evidence when one happens, and about a run that lost some saying so.
