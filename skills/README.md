# skills/

One directory per skill. Under the `personal` profile, `install.sh` symlinks each directory
here into every detected agent's skills directory (`~/.claude/skills/<name>`,
`~/.codex/skills/<name>`), so a skill is authored once and available everywhere.

```
skills/
  my-skill/
    SKILL.md      # required: the skill itself, with its trigger described in the frontmatter
    reference.md  # optional: supporting files the skill reads on demand
```

The directory name is the skill name — it becomes the link name in each agent's skills
directory, so keep it kebab-case and stable. Renaming a skill leaves the old link dangling;
`install.sh` prunes links it owns on the next run, and `install.sh check` reports any it cannot.

Linking is fail-closed. If a file or directory already sits at the destination and this repo
did not create it, the installer warns and leaves it alone rather than replacing it — a skill
you installed by hand is never silently overwritten.

This directory ships empty. It is a real capability, not a placeholder: the sync path, the
manifest tracking, and the check are all implemented, and adding a directory here is the whole
of the work needed to use it.
