# Locked external skill sources

Ordinary installation prepares the complete selected union in an isolated Git cache before
reconciling all external links in one deployment transaction. Shipped catalogs remain empty.
Source `lib/common.sh`, `lib/profile.sh`, `lib/adapters.sh`, then `lib/external-skills.sh`.

`external_skills_validate repo` checks catalog structure and locks without fetching or writing.
Optional missing catalogs are empty. All rows are validated, including excluded skills.
`skills/external.list` contains portable rows; `skills/claude-only.list` contains Claude-only
rows. A row is `name URL relative-path`. Blank lines and full-line `#` comments are allowed.
Fields cannot contain whitespace or quoting. Names use letters, numbers, underscores and
hyphens, starting with a letter or number. Names must be unique across both catalogs and
local skill directories. Relative paths use letters, numbers, underscores, dots, hyphens and
slashes; `.` selects the source root. Absolute paths, empty segments and traversal are rejected.

Every referenced URL needs exactly one `URL full-lowercase-SHA-1` row in
`skills/external.lock`. Duplicate locks, including identical duplicates, fail validation.
Only HTTPS URLs with an explicit path and absolute `file:///` URLs are supported. The latter
permit offline fixtures. User information, queries, fragments, encoded characters, whitespace,
traversal and alternate Git transport syntax are rejected. Host names and paths use a
conservative ASCII subset. Accepted URLs retain their exact spelling, protocol, case and
`.git` suffix. Locks are never advanced automatically.

Wrappers can replace these read-only callbacks after sourcing the library:

- `external_catalog_path repo portable|claude-only`: print one catalog path.
- `external_local_names repo`: print one local skill name per line.
- `external_skill_selected repo name agent`: return 0 for selected, 1 for excluded, and a
  larger status for configuration failure. The public default uses skill profile enablement
  and agent detection. Catalog scope independently excludes Claude-only rows from Codex.
- `skills_dest_for agent`: print the absolute skill-directory path, or reject unsupported
  agents. The existing public adapter supplies this resolver; the library provides a default
  when used alone. Cache preparation does not create destinations.

Diagnostics go to stderr. Validation prints no results. Internal `_external_selected_rows`
returns TSV fields: agent, name, exact URL, relative path and locked revision. It emits no
partial plan if a selection callback fails. These helpers do not depend on manifest formats
or private profile names.

`external_skills_prepare repo cache` resolves selections once and prepares their union. It
prints TSV fields `(agent, name, absolute prepared skill directory)` only after every selected
source succeeds. Excluded sources cause no cache access or fetch, but their syntax and locks
must still validate. An empty selection creates nothing. The caller supplies the dedicated
cache path. The installer uses `AGENT_RULES_SKILL_CACHE` when set, otherwise
`${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/skills`. Cache paths must be absolute and contain
no whitespace.

Cache entries are SHA-256 keys of the exact URL and locked revision, separated by newlines.
Equal repository basenames, different URL spellings and different revisions remain separate.
Existing entries must have exactly one origin value matching the catalog URL byte for byte,
the exact HEAD, a clean index and working tree, no untracked or ignored files, and all selected
skill directories and `SKILL.md` files inside the entry. Hidden index flags are refused.
Invalid final entries fail without reset or deletion.
Cache-local configuration is restricted to the basic keys written by initialization and the
origin remote; filters, includes and other customizations are refused before inspecting the
working tree. Raw config control bytes other than tabs and newlines are refused before Git
interprets the file. Git replacement objects are disabled, and graft metadata is refused.
Valid entries are reusable offline without fetches. Git hooks, inherited configuration,
content filters and recursive submodule checkout are disabled during preparation.

Missing entries fetch only the full locked revision into a unique `.agent-rules-stage.*`
sibling. Its `installer-stage` file identifies this attempt; its `repo/` is verified before an
atomic rename publishes the final entry. Reported failures clean up only their own staging.
Process death can leave marked staging, which is ignored by retries and never automatically
removed. Inspect and remove abandoned staging manually when no preparation is running. Do not
reset or delete an invalid final cache as part of a normal install.

Preparation holds a cache-wide `.prepare.lock`. An installer must acquire its installation
lock first, then call preparation. Cache locking runs in a child subshell because the shared
lock helper opens fd 9; the waiting parent must retain its installation lock. This also
serializes separate state directories that share a cache. No manifest or deployment state is
read or changed by this library.

Without `flock`, acquisition and stale-owner recovery share a regular `.d.reap` PID guard,
claimed with Bash noclobber file creation and held through main-lock PID publication.
This avoids depending on external `mkdir` exit status for mutual exclusion: affected
[uutils mkdir versions can report success after EEXIST](https://github.com/uutils/coreutils/issues/13970).
A replacement cannot acquire while recovery inspects the old owner. Any existing guard path,
including a FIFO, symlink or legacy directory guard, is refused before opening it. The claim
subshell preserves the caller's shell options and does not truncate existing guard files.

Recovery requires an ordinary, readable lock directory and PID file owned by the current user.
Unsafe evidence is rejected before opening the PID file, including FIFOs. Recovery also requires
a positive numeric PID, failed `kill -0`, and successful PID-only `ps -e` inspection containing
the current lock subprocess but no recorded owner. This relies on visibility of this user's
processes. Visible, inaccessible or unknown owners and malformed or unavailable inspection
are refused. Owned cleanup verifies ordinary, non-symlink PID evidence matching this subprocess.
Substituted or retargeted evidence is preserved. Refused cleanup makes an otherwise successful
call fail; an existing protected-command error keeps its original status.

An interrupted or failed claim can leave `.d.reap` behind. Inspect and remove it manually only
after confirming no acquisition or recovery is running. Unknown main-lock evidence also requires
manual inspection. This is a cooperative same-user protocol whose contenders create only regular
guard files; the absent-path check and noclobber claim do not promise resistance to hostile
pathname changes. All participants sharing a lock must use the fixed protocol; replace older
helpers only while no installation or preparation is running.

The fallback runs the protected command in a child subshell; the `flock` path retains fd 9 in
its caller. Source-cache consumers must pin a revision containing the complete recovery and
noclobber guard protocol. The earlier PID-read-then-delete helper does not provide safe fallback
cache serialization.

To advance a lock, review the chosen source commit and selected skill paths, update the full
SHA manually, then validate and prepare it against a test cache. Review the catalog and lock
diff together. Retain old cache entries for rollback; restoring an old catalog and lock can
reuse them offline. Source preparation alone does not change any installed skill. Deployment
uses the separate transaction below.

## External deployment library

Source `lib/manifest.sh` and the source-library dependencies before `lib/external-deploy.sh`.
`external_deploy_all repo desired_tsv` takes a **file path** containing the complete desired
set for both agents. Each no-header TSV row is `(agent, name, absolute destination, expected
absolute target)`. Empty input reconciles to no external skills without parsing disabled
catalogs. Nonempty input validates catalog applicability, destination resolvers and existing
source directories with `SKILL.md`. Names and paths cannot contain whitespace or control bytes.
Destinations, state, backup locations and prepared sources must not overlap physically.
No source cache is fetched, edited or removed by the deployment transaction.

The caller must create the per-machine state directory and hold the install lock throughout
this call. This library does not acquire a nested lock, infer agent selection or provide a
dry-run mode. Pass the already resolved complete selection once, including an empty selection
for profile disablement. Source preparation must finish before deployment starts.

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/agent-rules/`:

- `external-installed.tsv` is the complete desired set from the last successful deployment.
- `external-relinquished.tsv` uses the same four-column schema to retain conflict evidence for
  previously managed destinations now occupied by user artifacts. While occupied, these paths
  cannot be selected again. Removing the artifact permits a successful deployment to clear
  that record. Empty files are valid state. Downstream snapshots must include both files.

Removal requires agreement between prior selection, one typed manifest link record and the
current link target. Retargeted live/broken links and substituted files survive cleanup, and
stale manifest ownership is dropped. Other destination collisions receive the public
`BACKUP/name.pre-install.TIMESTAMP[.N]` backup policy, including directories. All agents share
one transaction. Plan errors return 1 before mutation. Reported deployment failure returns 1
after restoring touched artifacts, backup displacements and exact prior metadata bytes or
absence. Return 2 means recovery or cleanup needs inspection; never treat it as success.

A `.external-deploy.*` state directory holds indexed `paths/` snapshots, `paths.tsv` mappings,
`backups.tsv` moves and `directories.tsv` newly created parents. The path mapping columns are
`index`, `present|absent`, and `original path`. A `snapshots-complete` marker confirms that all
originals were captured before mutation. Without it, staging did not reach deployment; do not
infer original absence from missing snapshot files. Failed compensation retains evidence and blocks
retries. Inspect it while holding the install lock, restore the recorded original paths and
metadata, and remove the evidence only after verifying recovery. An interrupted live deployment
also requires that inspection. This provides compensation for reported failures, not atomicity
across arbitrary process death. Cache entries remain available for later offline rollback.

## Installation orchestration

Source `lib/external-install.sh` after both source and deployment libraries.
`install_external_skills_all repo cache` prepares selected sources once, builds the complete
desired set and calls `external_deploy_all` once with a temporary TSV file. Its caller initializes
`MANIFEST`, `BACKUP` and the state directory and holds the installation lock. It returns the
deployment status, including 2 for recovery requiring inspection. Globally disabled skills
bypass catalog parsing and preparation, then reconcile to an empty set. Enabled profiles
validate every catalog row but only prepare skills selected for detected applicable agents.

Run `./install.sh` to install the exact locked commits. Ordinary installation never advances a
lock. Remove a catalog row and reinstall to remove its still-owned links. Moving a portable row
to the Claude-only catalog also removes its owned Codex link. Switching to a disabled profile
cleans up external selections even when catalogs are malformed. User-retargeted artifacts survive.

## Check and dry-run

`external_skills_plan repo cache` is the read-only planning API for downstream adoption and
pinning. It prints the complete desired `(agent, name, destination, expected target)` TSV only
after offline source verification succeeds, or prints nothing and returns nonzero on failure.
A disabled profile returns an empty plan without catalog parsing. It reads no installed state
and creates no files. Pinning can compare this plan with its separately snapshotted state.

`check_external_skills_all repo cache` uses the same profile, selection callbacks, destination
resolver and cache identity as installation. It verifies selected paths, source origin, locked
revision and cache cleanliness offline, then compares the complete installed set and exact typed
manifest ownership. It rejects missing/wrong destinations, malformed installed or relinquished
state, stale selections and manifest links into the current cache without installed evidence.
Occupied relinquished destinations report conflicts. Absent relinquished destinations report
stale evidence until a successful installation clears it. These reports do not remove user files.

`external_skill_cache` prints the canonical absolute cache path from the override or default.
It does not create that path. Source all libraries in this order: `common.sh`, `profile.sh`,
`manifest.sh`, `adapters.sh`, `external-skills.sh`, `external-deploy.sh`, `external-install.sh`.
Wrappers can override the four read-only callbacks after sourcing. Installation, check and
dry-run each evaluate selection once for the complete union. Check never calls preparation or
deployment, fetches, assembles, creates a cache, takes a write lock or writes state.

`install_external_skills_all` with `DRY=true` reports selected URLs, exact revisions, paths and
intended destinations plus selection reconciliation. It does not call preparation or deployment,
create temporary files or inspect missing source contents. A successful dry-run therefore does
not prove that unavailable sources can be fetched or that their selected paths exist. Both check
and dry-run report retained `.external-deploy.*` recovery evidence and fail pending inspection.
The checker skips missing optional state or manifest evidence only after confirming absence
through readable, searchable ancestors and successful parent enumeration. Unavailable evidence
fails inspection. Recovery discovery also requires successful directory enumeration before
checking actual marker paths. Neither check nor dry-run creates evidence to replace what it
cannot inspect. `_external_deploy_absent path` returns 0 only for confirmed absence, and 1 for
present, invalid or unavailable paths. `_external_deploy_read_state file` clears its row arrays
and returns empty success only for confirmed absence; existing state must be readable and valid.
The mandatory `_external_deploy_read file` plan-reader contract is unchanged.

## Source updates and rollback

1. Review the source commit and selected skill contents. Edit the full SHA in
   `skills/external.lock` manually, reviewing the catalog and lock diff together.
2. Run `PROFILE=personal ./install.sh --dry-run` to inspect selected sources and destinations.
3. Run `PROFILE=personal ./install.sh` to prepare missing locked revisions and deploy the union.
   Existing invalid cache entries fail without repair. Failed preparation keeps the previous
   external deployment; a reported deployment failure compensates all agents together.
4. Run `PROFILE=personal ./install.sh check` to verify the cache, links and ownership offline.
5. To roll back, restore the previous catalog and lock and run installation again. Retain old
   cache entries so this works offline. Neither ordinary install nor check advances a source.

For selection removal, delete the catalog row and reinstall; no source deletion is needed.
Portable-to-Claude-only reclassification removes only the still-owned Codex deployment.
A disabled profile bypasses malformed catalogs and reconciles to no external selections.
Snapshot both external TSV files with the typed manifest, displaced artifacts/backups and any
recovery evidence when moving or pinning machine state. Restoration must keep source cache
entries and expected paths available. Never interpret return 2 as a completed installation.
