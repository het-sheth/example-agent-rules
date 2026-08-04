# Provenance — upstream sources, and why a copy is a liability

Every artifact an agent loads comes from somewhere. This file is about keeping that "somewhere"
a single, live, updating place, and about what to do in the rare case you cannot.

One rule, stated once:

> **Declare a dependency from the upstream source that updates itself. Do not vendor a copy.**
> When you genuinely must hold a copy, the copy is not finished until it carries its
> provenance and its update procedure in writing.

This applies to plugins, marketplaces, skills, rules files, and to the artifacts `install.sh`
deploys onto the machine. It is one rule because they are one problem: the moment bytes exist in
two places, they can disagree, and nothing about a stale file looks stale.

## The two failure modes this prevents

**A copied artifact drifts from its source, silently.** A file is copied out of the repo that
owns it into a repo that consumes it. Both copies now look authoritative — same filename, same
contents, no marker saying which one is downstream. Edits then land on one side or the other,
usually the one the person happened to have open. Nothing detects the divergence, because
neither repo has any idea the other exists. The failure surfaces much later, at the worst
moment: someone tries to reconcile the two, cannot tell which version is current, and picks
wrong. The nastiest form is a "mirror" repo that has fallen behind the original. A sync run in
the obvious direction — from the mirror, because the mirror is the thing you were told to sync
from — quietly reverts real work in the original, and can break its checks in the process. The
mirror was never wrong to exist; it was wrong to exist without a recorded direction of truth.

**A locally-sourced plugin never receives upstream updates.** Point a plugin at a directory on
disk and it works immediately, which is exactly why the pattern spreads. What you have actually
done is pin yourself to whatever that directory contained on the day you pointed at it. Upstream
fixes do not arrive. Security patches do not arrive. There is no version to report, and the
update command runs and truthfully reports success without changing anything, because a
directory source has nothing to fetch. Months later the local copy has diverged from an upstream
that has moved on, and reconciling means a manual diff nobody scheduled.

Both are the same failure wearing different clothes: a copy with no live link to its origin.

## Applying it to plugins and marketplaces

Declare plugins and marketplaces from a remote source that a fetch can update — a git repository
identified by URL or `owner/repo`, resolved over the network, updated on demand. The example
config in `plugins/marketplace.example.json` shows only that form, in its three variants:
tracking a default branch, pinned to a tag, and hosted somewhere other than GitHub.

A pin is not a copy, and the difference is the whole point. `ref` and `sha` still name a remote
that can be fetched: the version is recorded in one line, moving it is a one-line edit, and what
you are pinned to stays reachable. A copy names nothing and can be moved only by hand.

Declaring an upstream source is necessary but not sufficient, and this is the part that catches
people. On the consuming side, auto-update is enabled by default only for official Anthropic
marketplaces; third-party and local ones default to **off**. A marketplace declared from a
genuinely good git source will therefore sit at whatever it was when added until someone sets
`"autoUpdate": true` on its `extraKnownMarketplaces` entry, or toggles it in the plugin manager.
Nothing about that state looks stale either — which is the recurring theme of this document. So
treat the source and the update flag as two separate decisions, and make both on purpose.
`plugins/README.md` has the settings snippet.

One precision, because this rule is easy to over-apply: a source path pointing at a directory
*inside the marketplace repository* is not vendoring. It is a path into the same versioned
repository as the manifest, so it moves when that repository moves, and it is the documented way
to publish plugins you maintain yourself. The anti-pattern is a path pointing at a copy of
something maintained *elsewhere*.

That vendored form appears in this repository exactly once, in `plugins/README.md`, as a fenced
code block under "Anti-example — do not copy this". It is prose, not configuration: it sits
outside the JSON file precisely so it cannot be loaded by accident, and it is printed next to
the three things it silently gives up and the escape hatch below.

There are three legitimate reasons to use a directory source anyway:

1. You are developing the plugin itself and need the edit-reload loop.
2. Upstream does not exist yet, and you are about to create it.
3. The machine cannot reach the network at all.

Note what these have in common: each is temporary, and each has an obvious end state. That is
what makes the escape hatch below finite rather than permanent.

## The escape hatch — what a local copy must carry

If a directory source or a vendored copy is unavoidable, it is not done until it records four
things, next to the copy itself, in a file a person will actually find:

1. **Origin** — the upstream URL, and the exact commit or tag the copy was taken from. A branch
   name is not enough; branches move, so "taken from `main`" does not identify anything.
2. **Reason** — which of the three cases above applies, in one sentence. If none of them does,
   the copy should not exist, and writing this line is what surfaces that.
3. **Update procedure** — the literal command that re-syncs the copy from upstream, in the
   correct direction, copy-pasteable. Direction is the part people get wrong under pressure, so
   state it explicitly: which side is the source, which side is the destination.
4. **Review trigger** — the event that ends the copy's life. A date, a released version, or a
   condition such as "delete once the upstream repository is public". A copy with no expiry is
   how a temporary decision becomes permanent.

A copy carrying all four is a considered decision with an owner. A copy carrying none is a
liability with nobody's name on it, and it is indistinguishable from the drift described above.

## Applying it to deployed artifacts

The same reasoning governs what `install.sh` puts on the machine, so the installer enforces it
mechanically rather than trusting anyone to remember.

**Prefer a symlink.** A symlink has no content of its own. Reading it always yields the repo
file, so the deployed artifact cannot drift by construction — there is only ever one copy of the
bytes. The rules file wired into each agent, and every skill directory, is deployed this way via
`managed_link`.

**When content must be generated, track it.** One artifact cannot be a symlink: the harness shim
whose text is built from this machine's repo path, so there is no repo file to point at. It is
written through `managed_copy`, which records its SHA-256 in the per-machine manifest at deploy
time. That digest is the entire mechanism — it is what lets `install.sh check` distinguish "the
file we wrote" from "the file we wrote, then someone edited in place."

The two commands divide cleanly, and the split is deliberate:

- `install.sh` **reconciles**. A drifted copy is rewritten from source, and the drifted version
  is moved into the backup directory first — the installer never destroys a change, even one it
  disagrees with, because it cannot know that the edit was worthless.
- `install.sh check` **reports**. It never repairs, so it is safe to run anywhere, including CI
  and on someone else's machine.

A drifted copy therefore fails `check` loudly:

```
FAIL: drifted managed copy ~/.claude/CLAUDE.md — edited outside this repo; the source of
      truth and the deployed file no longer match. Re-run install.sh to
      restore it (the drifted version is backed up, not discarded).
```

Which is the whole point. The edit was not wrong — editing a deployed file is a reasonable thing
to try. What was wrong is that, until this check existed, it was invisible: the edit worked, so
nothing complained, and the repo everyone believed was the source of truth quietly stopped being
it. Making the divergence loud is what turns "the source of truth" from a claim into a property.

If you meant the edit, make it in this repository and re-run `install.sh`. That is the only
direction that survives the next install.
