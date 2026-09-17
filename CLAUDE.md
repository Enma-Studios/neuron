# CLAUDE.md

Operating rules for any Claude Code or agent session in the Neuron repository. These rules are
binding. If a rule here conflicts with a request in the moment, stop and say so; do not silently
pick one.

Neuron is an embeddable Elixir research library. Its host is Neureni (Enma-Studios/neureni), whose
`CLAUDE.md` these rules are ported from and kept level with. Neuron has no screens, so nothing
here is about a prototype, a browser pass or a frontend track. See `README.md` and `docs/` for
the layout.

---

## 1. Start of every session

1. **Confirm the branch and the SHA before anything else**: `git rev-parse --abbrev-ref HEAD`
   and `git rev-parse HEAD`, against `git rev-parse origin/main` after a `git fetch`. Say both
   in the first message that reports work. A session that reasons from a checkout it has not
   identified reasons about code it may not be running.
2. Read the newest file in `docs/handoffs/`, then `HANDOFF.md` at the root.
3. `git status`, `git log --oneline -20`, and the open issues.

Do not start work on a tree with uncommitted changes you did not make. Ask.

**The main checkout stays on `main`.** Work happens only in `.claude/worktrees/`, and a branch
that has to be parked is parked in a worktree, never in the main checkout. Subagents that clone
`deps/` clone them from a checkout on `main`, and the lead confirms that checkout's branch before
briefing them. In Neureni on 2026-09-16 a main checkout parked on another branch at a different
Neuron pin led a subagent to reason about a shape its own branch did not compile.

**Pipe long output to a file.** Anything longer than a screen (`mix test`, a Dgraph integration
run, a diff, a log) goes to a file in the session's scratchpad, and only its tail or a `grep` of
it is read back: `mix test 2>&1 | tee <scratchpad>/test.log | tail -40`. The file is what the
handoff's Verified section is written from.

## 2. Issue before code

No change begins without an issue in GitHub. Use the `gh` CLI.

1. **One issue per task.** Title in the imperative. Body: context in one or two sentences, and
   acceptance criteria as a checklist. Tasks larger than two days are split.
2. **Every commit references an issue** (`Refs #12` or `Closes #12` in the body). Work with no
   issue is not done; open the issue first, even mid-session.
3. **Bugs and discoveries become issues the moment they are found**, so nothing lives only in a
   chat transcript. An issue in Neureni that needs Neuron work gets its own Neuron issue that
   links it.

A session that ends with code but no issue movement is a failed session.

## 3. Tests first

- A behavior change starts with a test that fails for the reason the issue gives, and is seen to
  fail before the implementation is written. A test that has never failed has not been shown to
  check anything.
- A test for a function that promises work asserts the work (the job enqueued, the stage run, the
  write made), not only a state the function sets.
- A guard no test can make fire is not defence in depth. Remove it and point the test at where
  the rule actually lives.
- No test calls a paid API or a live service by default. Live and Dgraph-backed tests carry the
  `:integration` tag, which `config/test.exs` excludes from `mix test`;
  `scripts/dgraph_integration.sh` runs the Dgraph set in a disposable container.
- Fixtures follow section 7.

## 4. Pull requests

- **One pull request per issue.** Branches are `feat/<issue>-<slug>`, `fix/<issue>-<slug>`,
  `chore/<issue>-<slug>`, `docs/<issue>-<slug>`, `test/<issue>-<slug>`.
- **Nothing is pushed straight to `main`**, including a doc, a handoff, a rule or a release
  bump. Everything goes through a pull request.
- **Docs are in the same pull request** as the behavior they describe: `README.md`, `docs/`,
  moduledocs and the handoff. A change a host can observe is described where a host reads.
- Before every push: `mix format --check-formatted` and `mix test`, plus
  `scripts/dgraph_integration.sh` when the change touches Dgraph, a campaign stage or a fixture
  those tests read. A commit that fails any of them is not pushed.
- PR title follows the commit summary style. The body links the issue, lists what was verified
  (commands and what they printed), and names anything not verified. Non-squash merge, so history
  stays readable.
- **`Closes #N` only when every acceptance line on the issue is checked in the pull request
  body.** Otherwise `Refs #N`, and open a follow-up issue for the remainder in the same pull
  request. A closed issue is a claim that the thing is done.
- A chained merge is done one link at a time, with the result of each checked before the next,
  and branches are deleted only after the whole chain is on `main`.
- Never force-push a shared branch. Never rewrite `main`. Never commit secrets or `.env` files.
- Releases go through `mix neuron.release.check <tag>` in the release pull request, and a
  published tag is never moved.

## 5. Commits

- **Conventional Commits.** `type(scope): imperative summary` on the first line, 72 characters
  or fewer, lowercase type, no trailing period. Types: `feat`, `fix`, `refactor`, `test`, `docs`,
  `chore`, `perf`, `build`, `ci`. Scope is the area (`campaign`, `search`, `intake`, `knowledge`,
  `browser`, `dgraph`), and may be left out when none fits.
- Body: why the change exists, constraints that shaped it, what was tested and how. Wrap at 72.
  End with `Refs #N` or `Closes #N`.
- **No attribution trailers.** No `Co-authored-by:`, no `Generated with`, no tool attribution
  footers, no signatures of any kind, in commits or pull request bodies.
- **No em dashes** anywhere we write: commit messages, code, comments, docs, issue and pull
  request text. Use a comma, a colon, parentheses, or a new sentence. Hyphens in compound words
  are fine.
- Quoted data (a captured page, an excerpt, a value returned by a model or a provider) is stored
  byte for byte and is exempt from the em dash rule; it is never edited to comply. An excerpt
  must be a slice of its capture, so editing quoted data to satisfy a style rule would break the
  guarantee the library exists to give. A dash inside quoted data is not a finding.
- No emojis in commits, code, or docs.
- One logical change per commit. Do not commit generated output separately from the change that
  regenerated it.

## 6. Handoffs and the review bundle

Every session ends with a handoff, even a short one. Write it to
`docs/handoffs/YYYY-MM-DD-<slug>.md` in the session's pull request and update the root
`HANDOFF.md` to point at it. Use exactly this structure; empty sections say "None", they are not
deleted.

```
# Handoff: <slug> <date>

## Context
What the session set out to do, in two sentences, with the issue links.

## What changed
Commits on the branch, newest last, one line each: `<hash> <summary> (Refs #N)`.
Files added or removed, if any.

## State of the tree
Branch name and SHA. Clean or dirty. If dirty, exactly what is uncommitted and why.
Migrations (SQL or Dgraph) added and whether they have been run locally.

## Verified
Commands run and a summary of what each printed. Test counts. Fixture data used.
Anything checked against a live service, with the account used named (not the key).

## Not verified
What was written but not exercised, and why. Live checks pending credentials.

## Host-facing changes
Changes to the public API or to the result shape Neureni reads, with the Neureni issue
that consumes them. Otherwise "None".

## Issues
Issues opened, closed, or moved, with links.

## Decisions
Small decisions recorded in commit bodies that the next session should know about.

## Next
The next three concrete actions, each an issue link. Nothing vague.

## Questions for the owner
Only things the documents do not answer. Credentials needed. Otherwise "None".
```

Rules for handoffs:

- State what is implemented, tested, live-validated, and deferred as four separate facts. Never
  let "implemented" imply "tested".
- An untested path is named at the exact scope it was not tested, never a wider one.
- Summarize the delta, not the codebase.
- **A claim that an issue was filed carries its number, and a claim that a test exists carries
  its path.** A claim carrying its identifier is checkable in one command.
- **The Verified section lists the commands actually run and what each printed, never the word
  "passes" on its own.** A claim without its command belongs in Not verified.

**After the handoff commit, every session leaves a review bundle at
`~/Downloads/neuron-<date>-<topic>.zip`** (for example `neuron-0917-claude-rules.zip`). It holds
the session's handoffs, any fixture or fixture note that changed, and an `index.txt` mapping each
file to its issue or pull request. The bundle is for the owner's read: nothing is committed by
being in it, and a file that belongs in the repository still goes through a pull request.

## 7. Fixtures

- **No whole real page.** A capture is committed as windows of at most 400 bytes around each
  excerpt its test reads. A real page names people who are not its subject and links their
  profiles, and scrubbing a whole page by pattern cannot be verified complete. Where a test needs
  a page's structure, rebuild a small page that renders to the same shape.
- **No real person** in any committed file: fixtures, tests, docs or examples. People are
  pseudonymous, and a company is pseudonymous wherever its people are named. Titles and the shape
  a test reads are kept.
- **Inside every window, anything that identifies someone other than the subject is replaced**:
  names, handles, image filenames, profile and personal URLs, and phrases that point at one
  person (a named author line, a quoted testimonial with its byline). URLs become inert
  (`*.example`).
- Every window is read by a human before the commit, and changed windows are listed verbatim in
  the handoff and included in the review bundle.
- A capture carries its source URL and capture date in a fixture note beside it.
- Synthetic fixture data is allowed where a real run cannot produce one, and is marked synthetic
  in the first line of the file or its note.
- Three fixtures predate this section and are whole pages that name nobody:
  `test/fixtures/nyx-labs.html`, `test/fixtures/people_pages/lumenglobal-home.html` and
  `test/fixtures/people_pages/lumenglobal-contact-us.md`. Replacing them is #93. No new fixture
  follows their shape.

## 8. Decision discipline

- Small, reversible decisions: make them, record them in the commit body.
- Ask the owner only for credentials, paid-service spend, destructive operations, and changes to
  what a host receives that Neureni has not asked for.
- Never replace an unavailable integration with a mock and call the work complete. Build the
  real adapter, test it against a fixture, and mark live validation pending in the handoff.
- Do not add a dependency or a service without saying why in the issue.

## 9. Things that end a session immediately

Stop, write the handoff, and ask if you find yourself about to:

- push to `main`, or open a pull request with no issue;
- write a commit with an attribution trailer or an em dash;
- commit a whole real page or a real person's name;
- start code without an issue.
