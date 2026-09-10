# Handoff: feat/neuron-12 return leads without an observed contact channel

## Context

Neureni issue #42, `neuron-12`, from the owner's answer to question 1 of the spike handoff.

Neuron required an observed company email or verified professional profile before it would
return a person as a lead. The host does not need that: it resolves contacts through its own
provider waterfall, Apollo then Hunter then a verifier. Finding the right person at the right
company is the valuable work; the email is bought afterwards. As it stood, Neuron discarded
exactly the leads the host is built to complete.

## What changed

**`require_contact_channel`, default `true`.** Every existing caller gets the behaviour it
had. Under `false`, a person with a name, a title and a sourced employer is returned as a
lead with `observed_email: nil`, empty `contact_channels`, `preferred_channel: nil`, and no
draft.

`Neuron.Selection.score/4` used to fold "does this person match the campaign" and "can we
reach them" into one boolean. Those are different questions and the host answers the second
itself, so they are now separate: `nil` still means the person does not match, and
`:no_contact_channel` means they match but cannot be reached. `candidates/2` returns
`{:ok, ranked, withheld}` where `withheld` counts the second group.

**No email is ever invented.** `observed_email` is null precisely when nothing was observed,
and the existing rule that an email must appear in a retained excerpt attributed to that
person is untouched. The campaign result validation now also rejects a channel-less lead that
somehow carries an `observed_email`, which is the shape an invented address would take.

**A channel-less lead carries no draft.** There is no recipient to address one to.
`Neuron.Outreach.confirm/2` keeps the model's reason and sets `outreach: nil`, discarding
whatever channel the model returned. The outreach prompt is told to return a null channel for
those leads, and the confirm path discards an invented one anyway, so a hallucinated
recipient cannot reach a caller through either route.

**The summary separates the two ways of returning nothing.** Zero leads used to read "No new
people met the campaign criteria with a verified professional contact channel" whether
nothing matched or plenty matched and none were reachable. Now:

- nothing matched: `"No companies matched the campaign criteria."`
- matched but unreachable: `"Companies matched the campaign criteria, but no contact channel
  was observed for any candidate."`

The second is exactly what `require_contact_channel: false` converts into leads, so the host
can tell a targeting problem from a contact problem it can solve itself.

## On `observed_email`

The issue asks for `observed_email: nil`. `neuron-06` is the issue that renames
`verified_email` to `observed_email`, and it is not in this batch, so `observed_email` is
added alongside `email` carrying the same value rather than replacing it. Nothing reading
`email` changes. When `neuron-06` lands it drops `email` and the rename is already done. This
is recorded in `docs/library.md` so the duplication is deliberate and dated rather than
mysterious.

## Tests

`test/neuron_contact_channel_test.exs`, eight cases:

- by default a person with no observed channel is withheld
- under `require_contact_channel: false` the same person is returned, with `observed_email:
  nil`, and with fit score, score breakdown, evidence, evidence URLs and criterion values
  unchanged, ranking below any lead that has a channel
- an observed company email is still required before one is reported
- **both summaries**, the acceptance case: "no companies matched" and "companies matched, no
  contact channel observed"
- a channel-less lead keeps its reason and carries no draft
- a channel-less lead whose draft names a channel anyway still yields no recipient
- a campaign result validates a channel-less lead, and rejects one carrying an email that was
  never observed

Two existing assertions in `test/neuron_selection_test.exs` changed from `== nil` to
`== :no_contact_channel`. The behaviour they cover is identical, withheld by default; the
answer is just more precise about why.

Full suite: 93 passed, 3 excluded. `mix format --check-formatted` clean.

## Not covered

The host's side of this is not Neuron's work: passing the option, treating
`observed_email: nil` as the normal case, and running the waterfall. `docs/03-architecture.md`
section 6 and `docs/06-integrations.md` carry it in the Neureni repository, which this session
does not touch.
