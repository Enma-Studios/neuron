# Handoff: children, browser configuration, and what actually reproduced

## What was reported

Four child runs reported `:browser_use_not_configured` while the parent billed sixteen
sessions, and the question was why children do not inherit the browser configuration.

## What reproduced: nothing

**I could not reproduce a child failing to inherit browser configuration, and I have positive
evidence the in-process path works.** A real ingestion child, submitted with parent-style
options against the live provider, opened a session:

```
child run: 66dffdce-577f-4061-9aa0-27a910a49817
status: failed
error: {:zai_transport, %Req.TransportError{reason: :timeout}}
browser sessions: 1, seconds: 6.2
```

It browsed, then failed later on an unrelated model timeout. There is no in-process mechanism
by which a child could see different browser configuration from its parent:

- Application configuration is global to the VM. Parent and child read the same `:neuron,
  :browser` and the same `BROWSER_USE_API_KEY`.
- Run options round-trip exactly. `Neuron.Persistence` uses `:erlang.term_to_binary` with no
  filtering, `Neuron.Ingestion.submit/2` passes options straight to `start_run/3`, and a
  child's own stage worker overwrites only `:run_id`, `:stage` and `:transition_version`. A
  test asserts the parent's options arrive intact.
- Parent stages and child stages both run on the `agents` queue, so they are not even split
  across queues.

So the cause is outside the VM boundary: worker nodes that do not share an environment, a key
changed between parent and child, or the configuration shape below. **If you still have the
run IDs or the host's config block, that would settle it; I would rather find the real cause
than leave a guess in place of one.**

## The one shape that produces exactly this, and is now defended against

Elixir configuration **replaces** a keyword rather than merging into it. A host that writes

```elixir
config :neuron, browser: [fleet: [sessions: 2]]
```

wipes the `browser_use` block underneath it, and every browser call then depends on an ambient
`BROWSER_USE_API_KEY`. That is not hypothetical: neureni#37 is entirely about a host having to
declare every value because a dependency's config is never loaded, and a partial block is the
natural mistake.

`Neuron.Browser.BrowserUse.config/0` now merges application configuration over Neuron's own
defaults, and `api_key/0`, `configured?/0`, `profile_id/1`, `session_ttl_seconds/0`,
`list_sessions/1` and `sweep/1` all resolve through it. The resolution used to be copied into
five places, each free to drift. An empty string is not a key, which it previously was not
consistently.

**This does not change what happens when no key is configured anywhere.** It removes the
duplicated resolution and makes a partial block cost a default rather than a whole block. I am
not claiming it fixes the reported symptom, because I could not reproduce the reported symptom.

## What does change: the failure is no longer silent

Two things that were genuinely wrong regardless of cause.

**An unconfigured browser now says where it looked.** `[:neuron, :browser, :not_configured]`
carries the two places checked and the keys the host's `:browser` block actually has, which is
what distinguishes "no key anywhere" from "a partial block wiped it".

**A batch of children that all failed on configuration now fails the run.** It used to record
four child failures, continue, and finish `:no_qualified_leads` with the summary "No companies
matched the campaign criteria". A run that says it found nothing is a worse answer than one
that says it was never able to look. A batch that only partly failed still carries on, and a
child that failed for another reason is recorded rather than reinterpreted: the failure entries
now carry `kind` from `Neuron.Usage.error_class/1`.

## Tests

`test/neuron_child_browser_config_test.exs`, eight cases:

- **a child started under a configured parent can open a session**, the case that was asked
  for: options are dispatched the way `stage(:dispatch, ...)` dispatches them, the parent's
  options are asserted to arrive intact, and the child gets past the configuration check
- a host's partial browser block does not wipe the `browser_use` key, and defaults survive it
- the environment is the fallback and configuration wins over it
- an empty key is not a key, from either source
- an unconfigured browser emits where it looked, with the run id on the event
- a batch of children that all failed on configuration fails the run
- a batch that only partly failed carries on, with the cause recorded
- children that failed for other reasons are recorded, not reinterpreted

Full suite: 145 passed, 4 excluded.
