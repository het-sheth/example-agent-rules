# Layered rules — which file does a rule belong in?

Four layers. Every rule belongs in exactly one, and the layer is decided by *scope*, not by
topic. Putting a rule in too broad a layer is the common failure: it loads into sessions that
will never use it, and it costs context in every one of them.

| Layer | File | Loaded by | Put a rule here when |
|---|---|---|---|
| Shared | `_global.md` | every agent, every session | it is true on every machine and for every harness |
| Machine | `_machine.md` (gitignored) | every agent on this machine | it is a path, hostname, identity, or local fact |
| Harness | `claude-extras.md` | one harness only | it depends on that harness's UI, tools, or session model |
| Deep | `docs/*.md` | on demand, via a pointer line | it is long, and only some tasks need it |

`assemble.sh` concatenates the shared and machine layers into `AGENTS.md`. The harness layer is
loaded separately by that harness's adapter — for Claude, an `@`-import line in the shim. The
deep layer is not loaded at all until an agent follows a pointer to it.

## The pointer pattern

The shared layer is the expensive one: it is injected into every session, so length there is a
tax on every task. When a topic needs more than about three lines, move the detail into
`docs/<topic>.md` and leave a single pointer line behind:

```
- Full commit + PR conventions -> `docs/git.md`
```

The agent reads the pointer every session and the file only when the task is about commits.
Two consequences worth designing around: a pointer to a file that does not exist is worse than
no pointer, which is why CI checks pointer targets; and a pointer only works if the line says
enough for an agent to know *when* to follow it. "See docs/git.md" does not.

## Deciding fast

Ask which of these changes would make the rule wrong:

- Moving to a different machine -> machine layer.
- Switching to a different agent -> harness layer.
- Neither -> shared layer, unless it is long enough to need the pointer pattern.

When two answers seem right, the rule is probably two rules. Split it: the machine-independent
half goes in the shared layer, the specific fact goes in the machine file.

## Keeping the layers honest

Rules migrate downward over time. A rule written in `_global.md` because it seemed universal
turns out to be about one harness; a harness rule turns out to apply everywhere. When you
notice, move it — the layers only stay useful if they keep matching reality. `_global.md`
growing without bound is the signal that this has stopped happening.
