# plugins/

`marketplace.example.json` is a worked example of a plugin marketplace manifest in which every
plugin is declared from an upstream source a fetch can update. It is an example, not live
configuration: nothing in this repository reads it, and `install.sh` does not deploy it. To use
it, copy it to `.claude-plugin/marketplace.json` in the repository root of the marketplace you
are publishing, and replace the `example-org` placeholders with real ones.

The rule it demonstrates, and the reasoning, are in `docs/provenance.md`.

## The three upstream source forms

All three are fetchable, so all three receive upstream changes when the marketplace refreshes:

| Form | Use it for |
|---|---|
| `{"source": "github", "repo": "owner/repo"}` | a plugin in a GitHub repository, tracking its default branch |
| `{"source": "github", "repo": "owner/repo", "ref": "v2.0.0"}` | the same, pinned to a branch, tag, or (with `sha`) an exact commit |
| `{"source": "url", "url": "https://host/team/plugin.git"}` | any other git host — GitLab, Bitbucket, Azure DevOps, self-hosted |

A pin is not a copy. `ref` and `sha` still name a remote you can fetch: the version is recorded
in one line of JSON, moving it is a one-line edit, and the thing you are pinned to remains
reachable and inspectable. That is the difference that matters.

## Declaring it on the consumer side — and the auto-update trap

A marketplace manifest describes what is available. It does not, by itself, make any machine
fetch it. That happens in `.claude/settings.json` on the consuming side:

```json
{
  "extraKnownMarketplaces": {
    "example-team-tools": {
      "source": {
        "source": "github",
        "repo": "example-org/example-marketplace"
      },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "example-formatter@example-team-tools": true
  }
}
```

`"autoUpdate": true` is the line to not skip, and it is the one most easily missed. Official
Anthropic marketplaces have auto-update enabled by default; **third-party and local development
marketplaces have it disabled by default.** So a marketplace declared from a perfectly good
upstream git source still will not refresh on its own until someone sets this flag, or toggles
**Enable auto-update** under `/plugin` -> Marketplaces.

That default is worth sitting with, because it turns an upstream source into a snapshot without
anyone choosing to make one. The plugin can be fetched, the version is knowable, and the update
path exists — but nothing is asking. It is a slower, quieter form of the same failure as the
vendored copy below: a dependency that has stopped tracking the thing it came from.

Declaring the source and enabling auto-update are two separate decisions. Make both explicitly.

## Not every relative path is vendoring

One distinction worth being precise about, because the rule is easy to over-apply. A `source`
like `"./plugins/my-plugin"` pointing at a directory **inside the marketplace repository** is
fine. It is not a second copy of anything — it is a path into the same versioned repository as
the manifest, so it moves when that repository moves, and it is the documented way to publish
plugins you maintain yourself alongside the marketplace.

The anti-pattern is a path pointing at a **copy of something maintained elsewhere**: a plugin
that lives upstream, duplicated into a local directory and then sourced from there. The example
manifest uses only remote sources so the contrast stays unambiguous.

## Anti-example — do not copy this

The block below is documentation. It is deliberately outside the JSON file so it cannot be
loaded by accident:

```json
{
  "name": "example-vendored-plugin",
  "source": "./vendor/example-upstream-plugin"
}
```

This is a copy of `example-org/example-upstream-plugin`, taken once and now sourced from disk.
It works immediately, which is the trap. What it silently gives up:

- **Updates.** Upstream fixes, including security fixes, never arrive. `/plugin update` runs,
  succeeds, and changes nothing, because a directory has nothing to fetch.
- **A version.** There is no ref, tag, or commit to report, so "which version are you running?"
  has no answer beyond "whatever was copied, on some day nobody wrote down."
- **A direction of truth.** Two directories now hold the same plugin and neither is marked as
  downstream. Once someone fixes a bug in the local copy, the two have diverged permanently, and
  the next person to reconcile them has to guess which side is correct.

The correct form is the upstream one:

```json
{
  "name": "example-vendored-plugin",
  "source": {
    "source": "github",
    "repo": "example-org/example-upstream-plugin",
    "ref": "v1.4.0"
  }
}
```

## Escape hatch — when a local copy is genuinely necessary

Three cases justify it: you are developing the plugin and need the edit-reload loop; upstream
does not exist yet; or the machine has no network access. Each is temporary, which is what makes
the following finite rather than permanent.

A local copy is not finished until a file beside it records all four of these:

```markdown
# vendor/example-upstream-plugin — PROVENANCE

Origin:  https://github.com/example-org/example-upstream-plugin
         commit a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0 (tag v1.4.0), copied 2026-01-15
Reason:  Upstream has no release with the fix we need; we are running a local patch on top
         of v1.4.0 while the upstream pull request is open.
Update:  Re-sync FROM upstream INTO this directory — never the reverse:
             git -C /tmp/example-upstream-plugin fetch origin
             rsync -a --delete /tmp/example-upstream-plugin/ ./vendor/example-upstream-plugin/
         Then re-apply the local patch in patches/0001-fix.patch.
Expires: When the upstream pull request merges and a release ships. Review 2026-04-15.
```

Direction is stated explicitly because it is what people get wrong under time pressure, and
syncing the wrong way silently reverts real work. The expiry is what stops a temporary copy from
becoming a permanent one: a copy with no end condition is how the failure in
`docs/provenance.md` starts every time.

## Citations

Schema, source forms, and auto-update defaults in this file were checked against the official
documentation rather than written from memory:

- Marketplace manifest path, schema, and plugin source forms —
  <https://code.claude.com/docs/en/plugin-marketplaces>
- `extraKnownMarketplaces`, `enabledPlugins`, and the auto-update defaults —
  <https://code.claude.com/docs/en/discover-plugins>

Field names and defaults change between releases. If something here disagrees with the docs, the
docs are right; fix this file.
