# Experiment: layered context assembly

Branch `experiment/layered-context`, not merged, `main` untouched. Run on 2026-09-10 against
`v0.2.1`.

**Recommendation: iterate. Accepted by the owner on 2026-09-10, to be picked up later.** The
branch is kept, unmerged, with no pull request.

Two things are settled for whoever picks it up:

- **The next attempt replaces rules in the task prompts rather than restating them.** Layer 2
  currently repeats product-wide rules the task prompts already carry, so the prefix is
  additive and caching a cost it created. Deleting those rules from the task prompt files, so
  they are stated once in the cached prefix, is the change that decides whether the
  restructure pays for itself. It was excluded from this attempt by the brief, and it is the
  first thing to do in the next one.
- **Completion tokens are the cost to attack, not input.** This workload is completion
  dominated, so prefix caching addresses the cheaper half of the smaller half. If the
  motivation is cost, the numbers to go after are completion tokens and `reasoning_effort`.
  Prefix caching is worth having for what it makes possible, not for what it saves.

The layering works exactly as specified and prefix caching is real, measurable and large in
isolation. It does not pay for itself as built, for the reason above, and the arms could not
be separated on any outcome metric because run to run variance swamps them. Details in the
last two sections.

## What was built

`Neuron.Context` assembles every model call from six layers in a fixed order:

1. system and agent identity, `priv/prompts/layers/01_identity.eex`
2. product-wide knowledge, `priv/prompts/layers/02_product_knowledge.eex`
3. tenant overlay, `priv/prompts/layers/03_tenant_overlay.eex`
4. campaign overlay, `priv/prompts/layers/04_campaign_overlay.eex`
5. task-specific retrieved memories
6. current working context

Layers 1 to 4 are concatenated into the leading system message. Layers 5 and 6 are the
existing task prompt, untouched, in the user message. Prompts stayed in files and the layer
templates sit beside them under `priv/prompts/layers/`.

**Layers 5 and 6 are not separated from each other.** The brief said retrieval and scratch
context stay as they are, and in every current prompt they are interleaved inside one `.eex`
file. Splitting them would have meant rewriting all ten task prompts, which is a different
change from this one. They are therefore one layer in practice, and the six-layer claim is
honest only for 1 to 4.

Layer 4 is appended after 1 to 3 rather than interleaved, so two campaigns for the same tenant
still share the longest possible common prefix.

Overlays are caller-supplied through `start_run` options, never assembled by Neuron from its
own store. A map is serialized with sorted keys, because an overlay whose bytes move is an
overlay that never caches. Eleven tests in `test/neuron_context_test.exs` assert byte identity
across calls in a run, across runs of the same tenant, across campaigns, and that per-call
values such as `run_id`, `stage`, `trace_id` and `attempt` cannot move the stable prefix.

`layered_context: false` reproduces the pre-layer messages exactly, asserted by test, so both
arms ran from one commit with one option differing.

## Z.ai caching: what the documentation says

From `https://docs.z.ai/guides/capabilities/cache`, read on 2026-09-10:

- **Implicit.** "Implicit caching that intelligently identifies repeated context content
  without manual configuration." There is nothing to enable and no cache key to manage.
- **Coverage.** "Supports all mainstream models, including GLM-5, GLM-4.7, GLM-4.6, GLM-4.5
  series, etc." The examples use `glm-5.3`, which is what Neuron runs.
- **Reported at** `usage.prompt_tokens_details.cached_tokens`. This is the only honest
  evidence of a hit; repeated text alone proves nothing.
- **Billed** at a discount, "usually 50% of standard price".
- **TTL** is unspecified: "Cache has reasonable time limits, will recalculate after
  expiration."
- **No documented minimum prefix length.** The measurement below suggests there is an
  effective one.

Guidance matches the layering: keep the reusable system prompt, policies and reference
material at the start of the request and put changing data last.

## Were cached prefixes observed? Yes, decisively, in isolation

Full campaign runs could not answer this cleanly: their prompt sizes vary by two orders of
magnitude between runs, so a cache effect is buried in search variance. A controlled probe
(`scripts/layered_context_cache_probe.exs`) made six sequential calls per arm, varying only
the task text:

| arm | prefix | prompt tokens per call | cached, call 1 | cached, calls 2 to 6 |
| --- | --- | --- | --- | --- |
| baseline, pre-layer system message | 97 bytes | 50 | 0 | **0, every call** |
| layered prefix | 2264 bytes | 470 | 0 | **448 of 470, every call** |

The layered prefix caches from the second call onward and holds: 448 of 470 prompt tokens
reused, 95% of the call, 79% across the cold and warm calls together. The pre-layer system
message never cached once. A 97 byte prefix is below whatever effective minimum Z.ai applies;
a 2264 byte one is above it.

So the restructure does what it was designed to do, and it is the restructure that makes the
prefix cacheable rather than the provider doing it anyway.

## But caching was already happening, and not because of this

In full runs the **baseline** arm showed the single highest cache rate of any run:

| run | prompt tokens | cached | rate |
| --- | --- | --- | --- |
| baseline 3 | 55228 | 25600 | **46.4%** |
| layered 1 | 25970 | 6272 | 24.2% |
| layered 2 | 9691 | 2368 | 24.4% |
| layered 3 | 48556 | 5568 | 11.5% |
| baseline 4 | 12239 | 3200 | 26.1% |
| baseline 1, 5 | 20574, 20681 | 0, 0 | 0% |

Z.ai's implicit caching catches whatever large span repeats, and in this workload the task
prompts themselves repeat: `campaign_search.eex` is re-sent every round, `search_harvest.eex`
once per transcript, `normalize_source.eex` once per chunk. Those are far larger than the 448
token prefix. The layered prefix adds a guaranteed cached head; it does not add much to a
total that was already being cached by accident.

## The economics, which is where it stops paying

The prefix is additive. Product-wide rules were added in layer 2 without being removed from
the task prompts that already state them, because the brief said prompts stay in files and the
layer templates go beside them. So every call now carries roughly 450 extra tokens.

Per warm call, at the documented 50% cache discount:

- baseline: 50 input tokens, none cached, 50 billed
- layered: 470 input tokens, 448 cached, 22 + 224 = 246 effective

That is about five times the input cost of the bare system message per call, in exchange for
a cached prefix. Against real task prompts averaging near 2400 tokens per call it is a smaller
relative penalty, roughly 9% more effective input tokens per call, but it is still a penalty
rather than a saving.

**And input is the small half.** Across the ten runs, completion tokens averaged 36902
(baseline) and 22385 (layered) against prompt tokens of 21856 and 17234. Completion is billed
at full rate and typically several times the input rate. Prefix caching is optimizing the
cheaper half of the smaller half of this workload.

The layering pays for itself only if layer 2 **replaces** the duplicated rules in the task
prompts instead of restating them. That is the iterate step.

## Full run comparison

Ten runs, spike intake answers, engines DuckDuckGo and Yandex, no `BROWSER_USE_PROFILE_ID`,
`require_contact_channel: false`, bounds `max_rounds: 2, searches_per_round: 4, max_queries: 8,
max_pages: 6, batch_size: 3, budget_seconds: 600, sessions: 1, pages_per_session: 3`,
`lead_count: 1`, fresh graph data per run, arms alternated to control for engine drift.

Trials 1 to 3 are the three per arm that were asked for. Trials 4 and 5 are an extension, run
because the primary sample produced one failure per arm and only one lead-bearing run, which
left the requested qualitative comparison with nothing to compare. Two extra runs were added
to **both** arms, declared before they ran, and every run is reported.

| run | prompt | cached | completion | calls | browser $ | sessions | browser s | wall s | orgs | sources | claims | evidence | leads | conflicts | verbatim |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline 1 | 20574 | 0 | 42563 | 9 | 0.0328 | 4 | 45.7 | 235 | 3 | 3 | 68 | 20 | **3** | 0 | 100% (68) |
| baseline 2 | 557 | 0 | 2158 | 1 | 0.0047 | 5 | 43.9 | 175 | 0 | 0 | 0 | 0 | 0 | 0 | n/a |
| baseline 3 | 55228 | 25600 | 80590 | 17 | 0.0437 | 6 | 50.0 | 675 | 6 | 4 | 97 | 65 | 0 | 0 | 100% (97) |
| baseline 4 | 12239 | 3200 | 46430 | 8 | 0.0105 | 3 | 37.0 | 1501 | 4 | 5 | 66 | 32 | 0 | 0 | 100% (66) |
| baseline 5 | 20681 | 0 | 12768 | 11 | 0.0242 | 6 | 80.5 | 280 | 1 | 1 | 21 | 23 | 0 | 0 | 100% (21) |
| **baseline mean** | **21856** | **5760** | **36902** | **9.2** | **0.0232** | **4.8** | **51.4** | **573** | **2.8** | **2.6** | **50.4** | **28.0** | **0.6** | **0** | **100%** |
| layered 1 | 25970 | 6272 | 28453 | 12 | 0.0053 | 4 | 32.3 | 330 | 2 | 1 | 14 | 9 | 0 | 0 | 100% (14) |
| layered 2 | 9691 | 2368 | 9860 | 6 | 0.0076 | 8 | 160.4 | 420 | 0 | 0 | 0 | 0 | 0 | 0 | n/a |
| layered 3 | 48556 | 5568 | 69259 | 15 | 0.0397 | 10 | 65.8 | 500 | 7 | 6 | 53 | 20 | 0 | 0 | 100% (53) |
| layered 4 | 977 | 0 | 2674 | 1 | 0.0049 | 5 | 43.5 | 180 | 0 | 0 | 0 | 0 | 0 | 0 | n/a |
| layered 5 | 977 | 960 | 1677 | 1 | 0.0045 | 5 | 42.0 | 170 | 0 | 0 | 0 | 0 | 0 | 0 | n/a |
| **layered mean** | **17234** | **3034** | **22385** | **7.0** | **0.0124** | **6.4** | **68.8** | **320** | **1.8** | **1.4** | **12.8** | **5.8** | **0.0** | **0** | **100%** |

Restricted to the three runs per arm that were asked for, the means are: baseline 25453
prompt, 8533 cached, 41770 completion, 9.0 calls, $0.0271, 5.0 sessions, 46.5 browser seconds,
362 s wall, 3.0 orgs, 2.3 sources, 55.0 claims, 28.3 evidence, 1.0 leads, 0 conflicts; layered
28072 prompt, 4736 cached, 35857 completion, 11.0 calls, $0.0175, 7.3 sessions, 86.2 browser
seconds, 417 s wall, 3.0 orgs, 2.3 sources, 22.3 claims, 9.7 evidence, 0 leads, 0 conflicts.

**Do not read these means as a result.** Prompt tokens range from 557 to 55228 and wall time
from 170 to 1501 seconds within a single arm. Four of ten runs failed before doing any work.
The between-run variance is larger than any difference between arms on every metric, and with
five runs per arm nothing here separates them. The honest reading is that the layering did not
visibly help or hurt, and that this design cannot detect an effect smaller than the noise.

Total browser spend for all ten runs plus a discarded first sweep and the cache probe:
**$0.1779**, against a $3 cap. Model spend is in tokens only; Neuron does not price tokens and
this report does not invent a rate.

## Qualitative diff of drafts and fit reasons

**It could not be made, and the reason is worth more than the comparison would have been.**

- **No run in either arm produced an outreach draft.** Every lead that was returned had no
  observed contact channel, so by the `neuron-12` rule there is no recipient and `outreach` is
  null. That is correct behaviour and it means there is nothing to diff.
- **Only one run of ten returned leads at all**: baseline 1, three leads, `target_met`. The
  layered arm returned zero leads in five runs.

The one set of fit reasons that exists is high quality and worth recording. From baseline 1:

> Top-scored lead (fit 0.7898; role 1.0, evidence 1.0, geography 1.0, freshness ~1.0, market
> 0.3995). Rewind's own team blog (URL) verifies James Ciesielski as co-founder and CTO who
> 'leads the technical side of the business', based in Ottawa.

and the run summary volunteered its own weakness without being asked:

> Market fit is the weakest score component for all three (~0.39-0.40), and the verified
> evidence does not confirm a need to outsource engineering: Ciesielski is described as
> leading Rewind's technical side, and USAND itself markets done-for-you build services.

That is the behaviour the product wants: a cited reason, a named score breakdown, and an
explicit statement of what the evidence does not support. It happened in the **baseline** arm,
with no layered counterpart to compare against.

The layered arm returning zero leads in five runs against baseline's three in five is a
direction, not a finding. Three of the five layered runs died in the first round for a reason
unrelated to context assembly (below), so they never reached selection at all.

## What would be needed on the host side to supply the overlays honestly

Neuron now accepts `tenant_overlay` and `campaign_overlay` and will send whatever it is given
on every model call of the run, including every ingestion child. For the host to supply them
honestly:

1. **The facts have to exist as records.** Nothing in the Neureni data model holds "forbidden
   claims" or "prior decisions" today. `docs/04-data-model.md` has Organization, Campaign and
   Brief, and `PolicyFinding` exists for the drafting side, but there is no per-tenant standing
   policy a run could read. That is a schema addition to the Campaigns or Accounts domain
   (neureni#26, neureni#24), not a formatting exercise.
2. **The rendering has to be deterministic and stored, not recomputed.** If the host builds the
   overlay from a database query whose row order is not fixed, the bytes move between runs and
   the prefix never caches. The host should render the overlay once, store the rendered text
   against the tenant with a version, and pass that exact string. Neuron sorts map keys as a
   safety net, but the host owning a stored rendering is what makes the guarantee real.
3. **A version, so invalidation is deliberate.** Changing a tenant's forbidden claims should
   visibly change the prefix and cost one cold call, not silently diverge. Storing a version
   alongside the rendered text gives an answer to "which policy was in force for this run".
4. **An audit trail of what the model actually saw.** The overlay is authoritative instruction
   sent on every call. The host should record the rendered overlay against each run, because
   "what was the model told about this tenant" is a question that will be asked after a bad
   draft, and neither telemetry nor `get_run/1` answers it today.
5. **A size budget and a privacy review.** It is prepended to every call, so a large overlay
   multiplies across every stage and every ingestion child. It also leaves the host on every
   call, so whatever goes in it must be cleared for that, which is a different question from
   whether it may be stored.
6. **A decision about precedence.** The templates say the overlay is authoritative over
   anything inferred. Nothing enforces that, and a model can still be argued out of it by a
   long task prompt. If the host relies on a forbidden claim actually being honoured, that
   needs a check on the output, not only an instruction in the prefix.

## Three defects found while running this, none of them about layering

1. **A crash on `main`, introduced by `neuron-12`.** Splitting match from contact channel moved
   the check from `if valid` into `cond do not matched`. The match chain returns `nil` when a
   candidate has no name or no employment claim; `if` accepts `nil`, `not` raises. The first
   sweep's baseline trial 2 died with `ArgumentError` at `lib/neuron/selection.ex:119` after
   ingesting 47 claims. `require_contact_channel: false` makes it much more likely, because
   candidates that used to be filtered out before scoring now reach the scoring branch. Fixed
   on this branch as its own commit with a regression test, and **it belongs on main
   independently of whether this experiment is merged.**
2. **Four of ten runs failed with `:search_unavailable`, all identically.** In every case the
   planner put all four queries of the round on DuckDuckGo and none on Yandex, DuckDuckGo bot
   checked all four, so every attempted engine failed and the round was declared unavailable.
   Yandex was enabled, healthy, and never asked. `:search_unavailable` is documented as every
   **enabled** engine failing; the code checks every **attempted** engine. With two engines
   configured this is a 40% run failure rate in this sample. Either the round should ensure
   engine coverage before running, or the unavailable rule should account for enabled engines
   that were never tried. This is neureni#41 reappearing in a different guise and deserves its
   own issue.
3. **No assertion carries a source edge.** Across all ten runs, 0 of 319 assertions had
   `sources` populated, so a claim cannot be traced in the graph to the document it came from.
   The evidence verbatim check had to be weakened to "does this excerpt appear in any document
   this run ingested" rather than "in the document this assertion cites". **Evidence verbatim
   pass rate was 100% in every run that produced claims** (68, 97, 66, 21, 14, 53 checked), so
   the model is not paraphrasing, but the provenance link that would let anyone verify that
   per claim is missing.

## Recommendation: iterate

**Not merge**, because as built the layering is a net input cost increase with no measured
benefit, and because the arms could not be separated on any outcome metric.

**Not drop**, because the mechanism provably works. The prefix caches at 95% from the second
call onward, which the pre-layer system message never did at all, and the tenant overlay is a
capability Neuron does not otherwise have: today there is no way for a host to tell every model
call in a run what this tenant has forbidden and what was already decided.

Iterate on three specific things, in this order:

1. **Make layer 2 replace rather than repeat.** Delete from the task prompts the product-wide
   rules that layer 2 now states, so the prefix carries them once and cached instead of twice
   and billed. Until that happens the restructure cannot pay for itself. This is the change the
   brief deliberately excluded, and it is the one that decides the economics.
2. **Re-measure on a workload where input dominates.** This one is completion-heavy, so prefix
   caching addresses the cheaper half of the smaller half. If the motivation is cost, the
   number to attack is completion tokens and `reasoning_effort`, not the prefix.
3. **Fix the engine coverage defect first, then re-run.** With 40% of runs dying in the first
   round for an unrelated reason, no context experiment on this pipeline can produce a readable
   outcome metric. That fix is worth more than this branch either way.

The value case that survives the measurement is governance, not cost: a caller-supplied,
byte-stable, auditable statement of tenant policy on every model call. If that is why it is
wanted, it should be justified on that basis and the caching treated as a small bonus, because
on these numbers the caching does not carry it.

## Reproducing

```sh
git checkout experiment/layered-context
docker run -d --name neuron-acceptance -p 18080:8080 -p 19080:9080 dgraph/standalone:v25.4.1
export NEURON_DGRAPH_ENDPOINT=localhost:19080 NEURON_DGRAPH_ENABLED=true
mix neuron.migrate && mix neuron.dgraph.migrate
unset BROWSER_USE_PROFILE_ID
ARM=baseline TRIAL=1 mix run scripts/layered_context_trial.exs
ARM=layered  TRIAL=1 mix run scripts/layered_context_trial.exs
mix run --no-start scripts/layered_context_cache_probe.exs
```

Raw per-run records are in `docs/experiments/2026-09-10-layered-context-data/`.
