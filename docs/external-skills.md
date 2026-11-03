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
