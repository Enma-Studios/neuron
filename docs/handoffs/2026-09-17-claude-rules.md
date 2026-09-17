# Handoff: claude-rules 2026-09-17

## Context
Bring Neuron's working rules level with Neureni's `CLAUDE.md` (at 547a9c5) before neureni#349,
adapted to a library with no screens. Issue [#92](https://github.com/Enma-Studios/neuron/issues/92).

## What changed
- `b901c5e docs(claude): add working rules level with Neureni (Refs #92)`
- This handoff commit, which also repoints `HANDOFF.md`.

Files added: `CLAUDE.md`, `docs/handoffs/2026-09-17-claude-rules.md`. `.gitignore` gains
`/.claude/worktrees/`.

## State of the tree
Branch `docs/92-claude-rules` in `.claude/worktrees/92-claude-rules`, from `origin/main` at
`234370e`. Clean after this commit. No migrations.

## Verified
- `git rev-parse HEAD origin/main` on the main checkout: both `234370e`, branch `main`, clean.
- `grep -c` for U+2014 in `CLAUDE.md`: 0.
- `mix format --check-formatted`: exit 0.
- `mix test`: 210 passed, 14 excluded, 6.5 s.
- `config/test.exs:17` excludes `integration: true`, and `scripts/dgraph_integration.sh` runs
  `mix test --include integration` in a disposable container, as section 3 says.

## Not verified
`scripts/dgraph_integration.sh` was not run: no code or fixture changed.

## Host-facing changes
None.

## Issues
- Opened [#92](https://github.com/Enma-Studios/neuron/issues/92), this work.
- Opened [#93](https://github.com/Enma-Studios/neuron/issues/93): three committed fixtures are
  whole pages (`test/fixtures/nyx-labs.html`,
  `test/fixtures/people_pages/lumenglobal-home.html`,
  `test/fixtures/people_pages/lumenglobal-contact-us.md`) and predate section 7.

## Decisions
- Left out of the port: the browser-pass skill, `NEURENI_LIVE`, the seed, the prototype and
  frontend sections, Oban queue ownership, `mix probe`, credo and dialyzer. Neuron has none of
  them, and a rule naming a command that does not exist would be a false claim.
- "Pipe long output to a file" is new in Neuron, not in Neureni's file.
- The handoff template swaps "Contract and prototype notes" for "Host-facing changes".
- Review bundle date follows Neureni's example: `neuron-0917-<topic>.zip`.

## Next
- neureni#349.
- [#93](https://github.com/Enma-Studios/neuron/issues/93), replace the whole-page fixtures.
- [#86](https://github.com/Enma-Studios/neuron/issues/86), a cancelled run loses its profile.

## Questions for the owner
None.
