# Handoff: a candidate with no name or employer must not crash selection

## Context

Found by the layered-context experiment's first trial sweep on 2026-09-10, in `v0.2.1` code
rather than in the experiment. A campaign run failed after ingesting 47 claims from 7
organizations, all of that work discarded:

```
** (ArgumentError) argument error
    (neuron 0.2.1) lib/neuron/selection.ex:119: Neuron.Selection.score/4
    (neuron 0.2.1) lib/neuron/selection.ex:53: Neuron.Selection.candidates/2
```

## Cause

`neuron-12` split "does this person match the campaign" from "can we reach them", and in doing
so moved the check out of `if valid do` and into `cond do not matched ->`.

`matched` is a `&&` chain. It returns `nil`, not `false`, whenever it short-circuits on a
missing value: a candidate with no `name` claim, or no observed `employer` claim. `if` accepts
`nil` happily. `not` demands a strict boolean and raises on anything else.

The unit tests did not catch it because every fixture record carried a name and an employer, so
the chain always ran to its final boolean. `require_contact_channel: false` makes it far more
likely in practice: candidates that used to be filtered out before reaching the scoring branch
now reach it.

## Fix

`!matched` instead of `not matched`. One character, at the one place the refactor introduced
the strictness.

## Test

`a candidate missing a name or an employment claim is not a match, and does not crash`, over
both a nameless and an unemployed record, under `require_contact_channel` both true and false.

Confirmed to catch the defect: reverting the fix makes the test fail with the same
`ArgumentError` the live run produced, and restoring it makes it pass. Full suite 105 passed,
3 excluded.

## Provenance

Cherry-picked from `experiment/layered-context`, where it was made so the experiment could
compare two arms that both finish. It belongs on `main` on its own merits and is here without
anything else from that branch.
