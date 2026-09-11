# Handoff: fix/72 a round asks every enabled engine

## Context

Neureni issue #72, found by the layered-context experiment on 2026-09-10. Four of ten runs on
the default two-engine configuration failed outright, and every one failed identically: the
planner put all four queries of the round on DuckDuckGo, DuckDuckGo bot-checked all four, so
every engine that had been attempted had failed and the round was declared unavailable.
**Yandex was enabled, healthy, and never asked.**

A 40% run failure rate, on the configuration the host is required to use.

This is neureni#41 in a different guise. #41 fixed "one gated engine fails the round while
others answered". This is "one gated engine fails the round while another was never asked".

## Two defects, one symptom

**The planner was free to put a whole round on one engine.** `campaign_search.eex` asks it to
cover the available platforms and nothing enforced that. `ensure_social_coverage/3` already
guaranteed LinkedIn and X a query each when enabled, so the idea existed; it was scoped to two
engines that ship switched off.

**`:search_unavailable` checked attempted engines, not enabled ones.** `docs/library.md` said
unavailable means every enabled engine failed. The code failed the round when every *attempted*
engine failed, which is a much weaker condition and is the one that fired.

## What changed

`Neuron.Search.balance/2` gives every enabled engine at least one query in the round. Queries
are **re-targeted, never added**, so the round stays inside `searches_per_round`, and only the
most crowded engine gives one up, so the planner's per-platform tailoring survives wherever it
can. A round that cannot cover an engine without uncovering another is left alone.

It runs **after** truncation in `stage(:plan_search, ...)`. Balanced before truncation, the
coverage queries are exactly the ones the budget drops, and the round asks one engine again.

`orchestrate/2` now declares a round unavailable only when every enabled engine was attempted
and failed. An enabled engine nobody asked leaves the round degraded, so the pipeline plans
another round instead of failing the run.

`ensure_social_coverage/3` is removed. `balance/2` covers every enabled engine, LinkedIn and X
included when they are switched on, and does it without growing the round, which the old
function did.

## Tests

Five cases, three of them proven load-bearing by reverting the fix and watching them fail:

- **two engines, one bot-checked, and the round succeeds on the other**, the acceptance case,
  built from the exact shape that failed four live runs
- an enabled engine nobody asked is not evidence that search is unavailable
- `balance/2` gives every enabled engine a query without growing the round or reordering
  queries
- it leaves a round that already covers every engine alone
- it never strips an engine bare to cover another

Full suite: 110 passed, 3 excluded. `mix format --check-formatted` clean.

## Not covered

This makes a round survive a walled engine. It does not make DuckDuckGo less likely to bot
check, which on Browser Use cloud addresses it does intermittently and Google does every time.
Residential proxies or a local browser provider (`neuron-02`) are the answer to that, and
neither is in scope here.
