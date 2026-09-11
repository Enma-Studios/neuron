# Handoff: get_run/1 is read-only

## Context

`get_run/1` reconciled as a side effect. Reading a run could transition it to `failed` and
write an event, so a host dashboard polling a live run was mutating the thing it was watching.
A read that writes is not a read, and a poller cannot be asked to avoid looking.

## What changed

`get_run/1` reads. It never writes.

`reconcile_run/1` reconciles and then returns **the same snapshot** `get_run/1` returns, so a
caller that wants the old behaviour substitutes one for the other and nothing else changes. It
was already public; it previously returned an internal FSM machine struct, which nothing
documented consumed.

Reconciliation still has to happen or a run whose Oban job was discarded sits in `processing`
with nobody working on it. Three callers do it deliberately now:

- `await_run/2`, because waiting is not reading. Without it, awaiting an abandoned run would
  spin to its timeout rather than returning the failure.
- `resume_run/1`, which was already reconciling and is a write by definition.
- `Neuron.CampaignPipeline.stage(:collect, ...)`, which waits on ingestion children. This one
  matters: a discarded child would otherwise leave the stage snoozing against it until the
  campaign's budget ran out.

`list_runs/0`, `get_agent/1` and `Neuron.Ingestion.get/1` all became read-only by going through
`get_run/1`, which is what they should have been.

## Tests

Two, in `test/neuron_pipeline_test.exs`:

- the existing recovery test now asserts the **order**: a discarded job leaves `get_run/1`
  reporting `:planning` with no error and the row untouched, `reconcile_run/1` is what fails
  the run, and resumption still works from there
- a new test reads five times and asserts the machine's state, version and `updated_at` are all
  unchanged, then asserts `await_run/2` still notices the abandoned job and returns the failure
  rather than spinning to its timeout

Full suite 146 passed, 4 excluded.

## For the host

`docs/library.md` and `docs/operations.md` both say it now. The thing a host needs to decide is
who calls `reconcile_run/1`, because polling no longer does it for them: on a schedule, or on a
run that has not advanced for longer than its longest legitimate stage. Reading is free;
noticing an abandoned worker is a deliberate act.
