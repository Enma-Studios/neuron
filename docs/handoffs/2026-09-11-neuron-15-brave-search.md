# Handoff: neuron-15 a keyed search engine, Brave first

## Context

Bot checks from Browser Use cloud addresses had reduced public discovery to Yandex alone.
Google redirects every query to its `/sorry/` interstitial, measured seven times out of seven
in one run and four of four in another, and DuckDuckGo serves its anomaly modal
intermittently, one query in six in one run and four of four an hour earlier. Neither is
something to work around, so both are reported as skipped engines and the round carries on
with whatever is left. When what is left is one engine, a single bot check is the whole round.

A keyed API answers with a key instead of with a page. There is no wall to be stopped by, and
no browser session to bill.

## What was added

`Neuron.Search.Brave`, implementing the same `Neuron.Search.Engine` behaviour as DuckDuckGo
and Yandex, plus two optional callbacks the behaviour gains:

- `available?/0`, whether an engine can run here at all. Brave answers on whether it has a
  key. An engine that does not declare it is assumed available, so nothing else changes.
- `transcript/2`, fetch results without a browser. Brave returns the same transcript shape
  `Neuron.Search.Agent` produces, so the wall check, the harvest and its exact-URL contract
  all work unchanged. An engine that does not declare it is driven through the fleet, which is
  what every browser engine does.

`Neuron.Search.orchestrate/2` splits a round into keyed tasks and browser tasks. **A round of
only keyed engines never opens a fleet**, so it is never billed for one.

Brave is in the default engine list unconditionally. Without a key it is **absent** from the
round rather than failing in it, because an engine nobody asked cannot be evidence that search
is unavailable. That is the same rule neureni#72 already applies to an engine a round never
reached.

## One thing that changed beyond the engine

A fleet that will not open used to fail the round outright, as
`{:search_unavailable, reason: {:fleet_unavailable, reason}}`. It is now every browser task
failing, and whether that leaves the round unavailable is decided by the same rule as any
other failure. Otherwise a keyed engine that needs no browser would be taken down by a browser
it never wanted. `Neuron.CampaignPipeline` already handled both error shapes.

## Tests

`test/neuron_search_brave_test.exs`, ten cases against a fixture response, and two in
`test/neuron_search_test.exs` for the keyed path:

- parses the documented response; drops a result whose URL is not one; deduplicates
- parses an equivalent JSON string, and anything unexpected into nothing
- builds the transcript a browser page would have produced, with every selectable URL in
  `links` and nothing else
- that transcript harvests through the ordinary path, and **the exact-URL contract still
  rejects an invented URL over a keyed transcript**
- absent without a key, present with one, in `engines/0` as well as in `available?/0`
- the same behaviour surface as every other engine
- **a keyed engine answers without opening a browser**: no handles and no browser credentials
  are supplied, so a round that reached the fleet would fail to open one, and a successful
  round is the assertion that it never tried
- a keyed engine carries the round when the browser engines are walled

Full suite 128 passed, 4 excluded. `mix format --check-formatted` clean.

## The fixture is constructed, not captured

**No Brave key was available when this was written.** `test/support/fixtures/brave_web_search.json`
is built from the response shape Brave's Web Search API documents: a `web.results` array whose
entries carry `title`, `url` and `description`. The endpoint, the `X-Subscription-Token`
header and that shape were read from Brave's documentation on 2026-09-11.

That means the fixture proves the parser handles the documented shape. It does not prove the
documented shape is what the API actually sends. **Replace it with a captured response the
first time the live test runs with a real key**, and treat any difference as the fixture being
wrong rather than the API.

The live test is tagged `:integration` and fails loudly rather than skipping quietly when
`BRAVE_SEARCH_API_KEY` is unset, so it cannot pass by not running:

```sh
BRAVE_SEARCH_API_KEY=... mix test --include integration test/neuron_search_brave_test.exs
```

## Noticed, not fixed

`Neuron.Search.Engine.html_entities/1` decodes six entities and `&mdash;` is not among them,
so a title carrying one reaches a lead with the markup intact. The fixture keeps a real
`&mdash;` and the test asserts the behaviour that exists rather than the one that might be
assumed. Widening that helper is worth doing and is not part of adding an engine.
