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

## The fixture is a real capture

Captured from the live API on 2026-09-11 with a real key, for the query
`"meet the team" "co-founder" CTO SaaS company`, and saved verbatim: every field the API sent
is in `test/support/fixtures/brave_web_search.json`, including the ones Neuron ignores. The
two edge cases a real response did not happen to contain, a result whose URL is not one and a
duplicate, are inline in the test as synthetic maps labelled as such, rather than smuggled
into the capture.

The live test is tagged `:integration` and **fails loudly rather than skipping quietly** when
`BRAVE_SEARCH_API_KEY` is unset, so it cannot pass by not running. Both paths were checked:

```sh
BRAVE_SEARCH_API_KEY=... mix test --include integration test/neuron_search_brave_test.exs
# 11 passed

mix test --include integration test/neuron_search_brave_test.exs
# fails: BRAVE_SEARCH_API_KEY must be set to run the live Brave test
```

## What the live API does that the documentation did not say

- **Descriptions carry markup.** Matched terms come back wrapped in `<strong>`. The shared
  `text/1` helper strips tags, so this was already handled, and the test now asserts it rather
  than assuming it.
- **Result objects carry far more than three fields**: `age`, `profile`, `meta_url`,
  `thumbnail`, `extra_snippets`, `language` and a dozen others. Only `title`, `url` and
  `description` are read, and the capture keeps the rest so a future reader can see what was
  on offer.
- **Brave rewrites the query.** The response carries
  `query.search_operators: %{applied: true, cleaned_query: ...}`, and the cleaned form has the
  quotes and `inurl:` stripped. An operator-heavy planner query returned one result where a
  plainer phrasing returned more. `keywords/1` is left as the identity, because the response
  says the operators were applied and guessing otherwise would be worse than reporting it, but
  **this is worth measuring before Brave is relied on for volume.**

## html_entities/1, widened

`Neuron.Search.Engine.html_entities/1` decoded six entities, so a title carrying anything else
reached a lead as markup. It now decodes a table of the named entities that actually turn up
in titles and snippets, including the Latin-1 letters that appear in European company and
person names, plus **every numeric entity**, which is where the long tail lives.

Two things it deliberately does not do. An entity with no decoding is left exactly as written,
because mangling it into something that looks decoded means nobody can tell afterwards. And a
codepoint outside Unicode, or inside the surrogate block, is not decoded at all.

It now decodes in **one pass**. The old version replaced `&amp;` first, which decoded
`&amp;lt;script&amp;gt;` twice and turned an escaped entity into a real tag delimiter. There
is a test for that specific string.
