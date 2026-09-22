# AMA — Agent Maker

**A Claude Code subagent that builds other Claude Code subagents, by interviewing you.**

You describe the assistant you want. AMA works out the rest — what tools it needs,
what it must never be allowed to touch, how much it's allowed to do before it stops —
writes the definition file, and hands it to a reviewer before calling it finished.

> **Version 0.2 — early.** It works, and it's in daily use by its author.
> It is not polished, not tested automatically, and Windows-only for now.
> Read [Limitations](#limitations) before you rely on it.

---

## Who this is for

**You already use Claude Code. This is the part of it you're probably not using.**

Claude Code lets you build subagents — specialised assistants with their own
instructions, their own tool access, and their own hard limits. Most people never
build one, because it means learning which settings exist, which tool names are
valid, why hook paths have to be absolute, and — the one that catches everyone —
that the `description` field is what decides whether your agent ever gets picked
in the first place.

AMA already knows all of that. You say what you want; it asks only the questions
it genuinely can't answer itself.

## What makes it different

Most agent generators produce a file and tell you it's ready. AMA doesn't:

- **It won't claim work it didn't do.** It never says a file was written, reviewed,
  or tested unless that actually happened.
- **It marks its own guesses.** Every setting is labelled `STATED` (you said it),
  `DERIVED` (the job required it), or `ASSUMED` (it had to pick). You can see and
  correct every assumption before anything is built.
- **It separates what's confirmed from what isn't.** It tracks which settings are
  verified to work in the installed version and which aren't, and won't quietly
  emit an unverified one.
- **A draft is not a finished agent.** Until a reviewer has read the definition,
  AMA calls it a draft and says so.
- **It can't write outside its lane.** Enforced, not promised — see below.

## The write guard

AMA can create files. That's a risk: an agent-builder loose in your project
directory is exactly the kind of thing that ruins an afternoon.

So every write AMA makes is inspected first by `guards/ama-writeguard.ps1`, which
allows writes only inside an agents directory and denies everything else. It
resolves `~`, collapses `..`, rejects paths that aren't fully qualified, refuses
network paths, and **fails closed** — if the guard itself errors, the write is denied.

AMA is also told, in its own instructions, that a blocked write means the location
is out of bounds and it must not go looking for another way in.

## What's in here

```
ama.md                      the agent definition (this is the product)
guards/ama-writeguard.ps1   the write guard that keeps it in bounds
```

## Install (Windows)

1. Copy both files into your agents folder:

   ```powershell
   Copy-Item ama.md "$HOME\.claude\agents\"
   Copy-Item guards\ama-writeguard.ps1 "$HOME\.claude\agents\"
   ```

2. Open `$HOME\.claude\agents\ama.md` and replace `<ABSOLUTE-PATH-TO>` in the
   frontmatter with the real absolute path, **using forward slashes**:

   ```yaml
   command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/YOU/.claude/agents/ama-writeguard.ps1"; exit $LASTEXITCODE
   ```

   Claude Code requires an absolute path here — it can't be made relative.

3. Use it:

   ```
   @ama I want an agent that reviews my pull requests and flags anything that
   changes the database schema.
   ```

## Limitations

Stated plainly, because an agent-builder you can't trust is worse than none.

- **Windows only.** The guard is PowerShell. Cross-platform support is planned.
- **The guard has never been automatically tested.** It was written carefully and
  it works in practice, but there is no test suite proving which commands it
  catches and which it misses. This is the top priority for the next version.
- **The review step needs a reviewer agent.** AMA is built to hand every definition
  to a read-only auditor before calling it done. That auditor (FIM) is not published
  yet. Without it, AMA writes out a review request for you to run yourself, and
  correctly reports the definition as an unreviewed draft.
- **AMA cannot test a guard it writes.** It has no tool that executes anything. When
  it ships a guard, it says so and gives you the test commands to run yourself,
  rather than pretending the guard was verified.
- **Some documentation is stale.** The list of confirmed settings inside `ama.md`
  is more conservative than what actually works in current versions.

## Roadmap

- [ ] Automated test suite for the write guard
- [ ] Cross-platform guard (macOS / Linux)
- [ ] Publish the reviewer agent and wire up the full build → review loop
- [ ] Installer that sets the absolute path automatically
- [ ] Worked examples

## License

MIT — see [LICENSE](LICENSE).
