# Handoff: default engines become DuckDuckGo and Yandex

## Context

Owner decision on 2026-09-10, answering the first finding in the v0.2.0 handoff. Google is
bot-walled on Browser Use cloud addresses on every query: seven of seven in the #43
acceptance run and four of four in the diagnostic an hour earlier. Since #43 it is reported
honestly as a skipped engine rather than as an engine that found nothing, but reporting it
accurately every round is not the same as it being worth attempting.

## What changed

The default engine set is now `[Neuron.Search.DuckDuckGo, Neuron.Search.Yandex]`, the two
that return public results to a signed-out cloud browser, in both the application config and
the compiled fallback in `Neuron.Search`. Those two had disagreed since Reddit was removed:
config carried five engines and the fallback carried five different ones, so the engine set
depended on whether config had been loaded. A host does not load a dependency's config, which
is neureni#37's whole subject, so that gap mattered. They now agree, and a test asserts it.

`Neuron.Search.Google` is untouched as a module and stays fully supported. Its moduledoc
records why it ships off and that a local browser provider may be an address it serves
results to, which is `neuron-02`. That is the same shape as the note `Neuron.Search.Reddit`
already carries.

`docs/configuration.md` now names all four switched-off engines with the specific reason each
one needs: Google's bot check, Reddit's login wall on datacenter addresses, and LinkedIn and
X needing a logged-in profile. It also repeats that engines are module names rather than
atoms, which neureni#37 records as a trap that fails open.

## Tests

Three cases in `test/neuron_search_test.exs`:

- the default is exactly DuckDuckGo and Yandex, asserted against both the application config
  and `Neuron.Search.engines/0`, so the two cannot drift apart again
- **the default never contains LinkedIn, X, Reddit or Google.** This is neureni#37's
  requested invariant, extended to Google. An edit that puts one back fails here rather than
  in a billed run
- an engine switched off by default is still selected when a caller asks for it, so "off" is
  a default and not a removal

Full suite: 96 passed, 3 excluded. `mix format --check-formatted` clean.

## Consequence

A default run now searches two engines rather than three, and one of the three was
contributing nothing. The #43 acceptance run's ingested organizations all came from Yandex
and DuckDuckGo, so nothing that produced evidence is lost.
