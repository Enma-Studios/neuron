# Handoff: fix/38 model fetch and loader resolve one path

## Context

Neureni issue #38, `neuron-10`. `mix neuron.models.fetch` resolved its target as
`Path.expand(directory, "priv")`, which is relative to the current working directory.
`Neuron.Embedding.Local.start_link/1` resolved the same directory as
`Application.app_dir(:neuron, "priv/" <> directory)`.

Those agree only when Neuron is the project being run. As a dependency the fetch wrote into
the **host's** `priv/models/multilingual-e5-small` and startup then read **Neuron's**, so the
documented setup always ended in `embedding model missing; run mix neuron.models.fetch
before starting Neuron`, naming the command that had just succeeded. The spike worked around
it by copying the model into `_build/dev/lib/neuron/priv/models/` by hand.

The standalone case worked, which is why this survived: `_build/<env>/lib/neuron/priv` is a
symlink to the project's `priv`, so both expressions land on the same files.

## What changed

One function now owns the answer and both callers ask it.

- `Neuron.Embedding.directory/0`, the single resolution, through the application directory.
- `Neuron.Embedding.manifest_path/0` and `manifest/0`. The manifest read returns `{:ok,
  manifest}`, `{:error, :missing}`, or `{:error, {:misplaced, found, expected}}`, where
  `found` is the old working-directory location. A model in the wrong place needs the fetch
  re-running against this application; a model that was never fetched needs it running at
  all, and the two used to produce the same sentence.
- `Neuron.Embedding.load!/0` verifies the manifest against configuration and returns the
  directory, raising with the three distinct messages: missing, misplaced, and a model whose
  manifest does not match the configured model or revision. The last case was a bare `true =`
  match that failed with `MatchError` and no explanation.
- `mix neuron.models.fetch`, `Neuron.Embedding.Local.start_link/1` and
  `Neuron.Embedding.Local.chunks/1` all call those instead of resolving paths themselves.
  `chunks/1` had the same `Application.app_dir` expression copied into it, which is the third
  caller the issue does not mention.

## Tests

`test/neuron_embedding_path_test.exs`, five cases, every one of them run from inside a
temporary host application's working directory, because the standalone case is the one that
always worked and it hid the bug:

- the fetch target and the loader resolve one directory from a host app, and it is not under
  the host
- **a model written by the fetch task loads inside a host app**, the acceptance case: write
  the manifest the way the task writes it, then load it the way startup loads it, both from
  the host's working directory
- a model in the host's own `priv` is reported as misplaced, naming both paths, not missing
- a model that was never fetched is reported as missing
- a fetched model that does not match configuration is reported as neither

Full suite: 78 passed, 3 excluded. `mix format --check-formatted` clean.

Verified against the real fetched model in `dev`: `load!/0` returns
`_build/dev/lib/neuron/priv/models/multilingual-e5-small` with all 8 files present.

## Not covered

The test proves the two resolutions agree and that a manifest written by one is read by the
other. It does not download the model, and it does not build a second Mix project to have
Neuron as a real dependency. The working directory is the whole of the defect, and that is
what the fixture varies.
