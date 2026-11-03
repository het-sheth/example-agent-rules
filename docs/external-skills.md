# Locked external skill sources

The source library validates catalogs and prepares an isolated Git cache. It does not yet
participate in ordinary install, check or dry-run, and it does not deploy skill links.
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
cache path; ordinary installer cache-default and override wiring is deferred.

Cache entries are SHA-256 keys of the exact URL and locked revision, separated by newlines.
Equal repository basenames, different URL spellings and different revisions remain separate.
Existing entries must have the exact origin and HEAD, a clean index and working tree, no
untracked or ignored files, and all selected skill directories and `SKILL.md` files inside the
entry. Hidden index flags are refused. Invalid final entries fail without reset or deletion.
Cache-local configuration is restricted to the basic keys written by initialization and the
origin remote; filters, includes and other customizations are refused before inspecting the
working tree. Git replacement objects are disabled, and graft metadata is refused.
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

To advance a lock, review the chosen source commit and selected skill paths, update the full
SHA manually, then validate and prepare it against a test cache. Review the catalog and lock
diff together. Retain old cache entries for rollback; restoring an old catalog and lock can
reuse them offline. Destination deployment and transactional rollback are later integration
work, so source preparation alone does not change any installed skill.
