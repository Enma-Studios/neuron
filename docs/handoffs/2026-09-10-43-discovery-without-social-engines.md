# Handoff: fix/43 discovery without social engines

## Context

Neureni issue #43. With `linkedin`, `x` and `reddit` disabled, two complete campaign runs
ingested nothing at all: zero Organizations, Sources, Assertions, Persons and Snapshots, and
zero ingestion children, while 28 search stages fired and 10 browsers were billed. The
question the issue asks is whether discovery works on public engines alone, because that is
the only configuration the Neureni host runs.

**It does now.** It did not before, for four separate reasons, all of them found by running
it rather than reading it.

## The diagnostic

`scripts/discovery_diagnostic.exs` runs one round on DuckDuckGo, Google and Yandex against
the spike's intake answers, with no `BROWSER_USE_PROFILE_ID`, and logs per engine the raw
result count, the URLs returned, and every harvest decision with its reason. Two runs are
committed:

- `2026-09-10-43-diagnostic-before.md`, against the code as it was. Ingestion children: 0.
- `2026-09-10-43-diagnostic-after.md`, against the code in this branch. Ingestion children: 12.

## Four causes

**1. Bot walls were invisible, so a walled engine read as an engine that found nothing.**
`Neuron.Search.orchestrate/2` never called `engine.blocked?/1` or `engine.gated?/1`. Those
predicates are only reached from `web_all/2`, the research path, not from campaign
discovery. Google redirected every query to `google.com/sorry/index` and DuckDuckGo served
its anomaly modal, and both came back as ordinary transcripts with no results on them. The
harvest then honestly found nothing, and the round recorded no failure at all. The `before`
log shows `engine.blocked?(html): true` on three of four pages that the pipeline treated as
successes.

**2. The planner was prompted toward platforms that were switched off.**
`campaign_search.eex` said LinkedIn and X "MUST each receive at least one tailored search
every round" and "Prefer company websites, LinkedIn and X". With those engines disabled the
planner still wrote `site:linkedin.com/in` and `site:x.com` queries onto the keyword
engines, so in the `before` run the one engine that was working, Yandex, was aimed at X and
returned celebrity accounts and X help pages. The prompt now takes the available platform
list as authoritative and aims keyword engines at pages a buying company publishes itself.

**3. The harvest prompt preferred profile URLs that cannot be read without an account.**
`search_harvest.eex` led with "Prefer personal profile URLs (such as linkedin.com/in/...)".
A LinkedIn profile harvested by a host with no profile ID is ingested into an authwall and
yields no claims. Company team, about and contact pages now come first.

**4. Harvested URLs were the search engine's own redirect wrappers.**
This one only became visible once the first three were fixed. Transcript links come from the
rendered DOM, so DuckDuckGo results arrive as `duckduckgo.com/l/?uddg=...`. The per-engine
`parse/1` functions unwrap these, but the transcript path never calls `parse/1`. The single
URL the fixed round first produced was a `duckduckgo.com` wrapper: ingesting it would have
fetched DuckDuckGo, recorded DuckDuckGo as the Organization, and attributed the prospect's
claims to the search engine.

## What changed

- `Neuron.Search.wall_reason/1`. One place that decides whether a page is a login gate, a
  consent wall or a bot check. Reads the final URL, and the engine's own markers off the
  document. A wall is recorded as a skipped engine with its reason. Nothing is ever done to
  get past one.
- `Neuron.Browser.Scripting` returns the whole document only when it is under 32KB. A wall
  page is tiny and a rendered results page is not, so the markers travel back without ever
  shipping a real page whole.
- `Neuron.Search.Engine.unwrap/1`, applied to transcript links in `Neuron.Search.Agent`.
- `Neuron.Search.orchestrate/2` treats a round as unavailable only when no engine answered.
  An engine that answered with nothing still carried the round.
- `campaign_search.eex` and `search_harvest.eex` as described above.
- `docs/configuration.md` documents the wall rule, the unwrapping, and the
  `BROWSER_USE_PROFILE_ID` risk.

The `orchestrate/2` condition overlaps Neureni issue #41, which is the next branch. #43
could not meet its own acceptance without it: once walls became failures, the old condition
would have failed the whole round on a walled Google while Yandex was answering. #41 adds
the reason-list contract, the host-visible degraded distinction, and its own tests.

## Acceptance

A campaign on the three public engines, no profile ID, from the spike's intake answers,
against a clean Dgraph v25.4.1:

| Type | Spike runs 3 and 4 | This run |
| --- | --- | --- |
| Organization | 0 | **6** |
| Source | 0 | **6** |
| Assertion (claims) | 0 | **77** |
| Person | 0 | 5 |
| Snapshot | 0 | 6 |
| Evidence | 0 | 49 |
| Post | 0 | 1 |
| Lead | 0 | 0 |

Organizations discovered: Zoom, SolarWinds, FinCEN Report, AirDoctor, COBAIT, IDS AI
Solutions. The requirement was at least one Organization, one Source and one Claim. All
three are met.

Run `93c08303-7cc8-4c73-868b-ba67517d3f13`, completed, `result.status: :no_qualified_leads`,
`stop_reason: :budget_exhausted`, 0 of 1 leads.

## Zero leads is still the honest outcome, and it is not this issue

Companies, sources and claims now exist. No lead was returned because no candidate had an
observed company email, which is exactly the product boundary in Neureni issue #42
(`neuron-12`). The summary still reads "No new people met the campaign criteria with a
verified professional contact channel", which collapses "no companies matched" into
"companies matched, no contact channel observed". #42 separates them. Before this branch
that distinction was unreachable, because there were no companies either way.

## New findings, not fixed here

- **Google is bot-walled on Browser Use cloud IPs, on every query.** Seven of seven in the
  acceptance run, four of four in the diagnostic. It contributes nothing from this
  infrastructure and is now honestly reported as skipped rather than silently empty.
  DuckDuckGo is walled intermittently, one query in six in the acceptance run. Yandex
  answered every time and carried both rounds. Whether Google stays in the default engine
  list is a decision for Rusty, not something this branch changes.
- **Six ingestion children failed on Dgraph write conflicts**, `Transaction has been aborted.
  Please retry`, when concurrent children upserted overlapping entities. The parent recorded
  each as a failure and continued, so the run was not lost, but evidence was. This is a
  retry gap in the graph write path and deserves its own issue.

## Cost

$0.3251 on Browser Use across 14 sessions for the diagnostic runs and the acceptance run,
against the $2 cap agreed for this issue. Zero sessions left running afterwards, confirmed
against the provider, which is the #44 fix working on a real run.

## Reproducing

```sh
docker run -d --name neuron-acceptance -p 18080:8080 -p 19080:9080 dgraph/standalone:v25.4.1
export NEURON_DGRAPH_ENDPOINT=localhost:19080 NEURON_DGRAPH_ENABLED=true
mix neuron.models.fetch && mix neuron.migrate && mix neuron.dgraph.migrate
unset BROWSER_USE_PROFILE_ID
mix run --no-start scripts/discovery_diagnostic.exs
```
