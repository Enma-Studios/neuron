# Handoff: fix/73 an ingested assertion carries its source edge

## Context

Neureni issue #73, found by the layered-context experiment on 2026-09-10. Across ten campaign
runs, **0 of 319 assertions had `sources` populated**, so a claim in the graph could not be
traced to the document it came from.

The experiment set out to measure evidence verbatim as "does this excerpt appear in the source
this assertion cites" and had to weaken it to "does it appear in any document this run
ingested". The weaker check passed at 100% in every run that produced claims, so the model was
not paraphrasing, but nothing in the graph let anyone verify that per claim.

## Diagnosis: a write bug, no migration needed

Checked before changing anything:

- `sources: [uid] @reverse .` is declared in the Dgraph migrations and appears on the
  `Assertion` type in `Neuron.Graph.Schema.definition/0`. The predicate is present and indexed.
- **`Neuron.Research` already writes it.** Its assertion nodes carry `"sources" => source_refs`.
- **`Neuron.Knowledge.ingest/4` does not.** That is the path every campaign uses. It wrote
  `"url"` as a plain string and `"documents" => [snapshot]`, and never set `sources`.

So the schema was right, one writer was right, and the other writer had simply omitted the
edge. No migration is needed and none was invented.

## Fix

One line in `ingest/4`: `"sources" => [%{"uid" => id("source", canonical_url(document.url))}]`.
The Source node already has that stable identity, `ingest/4` already has `document.url` in
hand, and `Neuron.CampaignPipeline` already links leads to sources this exact way.

User assertions from `assert_fact/2` stay exempt. They have no source document, and giving
them a fabricated one would be worse than having none.

## Tests

In `test/neuron_dgraph_integration_test.exs`, which is where this can be asserted honestly,
since the claim is about what reaches Dgraph:

- **the count of observed assertions with no source edge is zero after ingestion**
- the edge points at the document the claim was actually read from, checked by following
  `sources { url }` back to the ingested URL

Both are scoped to the test's own nonce URL rather than to the whole database, so they assert
something about the code under test and not about whatever else is in a shared instance. That
scoping matters: an unscoped version passed for the wrong reason against leftover data.

**Confirmed load-bearing.** Reverting the one-line fix makes the orphan assertion fail, naming
the exact assertion it found:

```
observed assertions with no source edge: [%{"predicate" => "name", "uid" => "0x4e2a",
  "url" => "https://buyer-2280f5bb-....example/team"}]
```

Integration suite 2 passed against Dgraph v25.4.1. Default suite 110 passed, 3 excluded.
`mix format --check-formatted` clean.

## Now possible, not done here

The evidence verbatim check can be tightened from "appears in any document this run ingested"
to "appears in the document this assertion cites". That check lives in the layered-context
experiment's harness on another branch, and tightening it belongs with whoever picks that up.
