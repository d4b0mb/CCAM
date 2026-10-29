# CCAM — Claude Code Agent Modules

**Six Claude Code subagents that build, plan, research and audit — and can't claim work they didn't do.**

Claude Code will tell you it checked something. Usually it did. Sometimes it didn't,
and there's no way for you to tell the difference. CCAM's agents are built so the
difference is visible: each one is restricted to what it can honestly do, every claim
is tagged with how it was established, and every report ends with a list of what was
*not* checked.

> **Version 0.4.1 — early.** In daily use by its author. Windows-only.
> The `fim` and `ama` guards are measured, not assumed: **121 test cases** — see
> [Guard test results](docs/results.md).
> Read [Limitations](#limitations) before relying on it.

---

## Who this is for

**You already use Claude Code. This is the part of it you're probably not using.**

Claude Code lets you build subagents — specialised assistants with their own
instructions, their own tool access, and their own hard limits. Most people never
build one, because it means learning which settings exist, which tool names are
valid, why hook paths have to be absolute, and — the one that catches everyone —
that the `description` field is what decides whether your agent ever gets picked.

CCAM gives you six that are already built, one of which builds more.

---

## The agents

### AMA — the agent maker

You describe the assistant you want. AMA works out the rest: which tools it needs,
what it must never touch, how many turns before it stops. It writes the definition
file and gets it reviewed before calling it finished.

It marks every setting as `STATED` (you said it), `DERIVED` (the job required it) or
`ASSUMED` (it had to pick) — so you can see and correct every guess it made. Until a
reviewer has read the result, AMA calls it a draft and says so.

### FIM — the auditor

Reads code and reports whether it is correct, functional, necessary, and in the right
place. It **cannot change anything** — a guard blocks every command that would modify
a file, a package, or git state.

Every claim carries one of three tags: `EXECUTED` (a command was run and this is its
real output), `READ` (this line was read), or `UNVERIFIED` (couldn't confirm it — and
here's what would). Every finding quotes the exact text and cites `file:line`. Every
report ends with **NOT CHECKED**: what wasn't examined, why, and the exact command
that would close the gap.

A short report on clean code is the correct output, not a lazy one.

### Also included

- **dev** — writes code to disk but never executes anything; returns the commands for
  you to run.
- **planner** — turns a scope into a technical plan and briefs for other agents, and
  archives each run. Needs an archive folder: edit the `YOU` paths in `planner.md`,
  `guards/planner-writeguard.ps1` and `guards/planner-gitguard.ps1`.
- **researcher** — researches a topic online and writes one new `.txt` file. Edit the
  `YOU` paths in `researcher.md` and `guards/researcher-writeguard.ps1`.
- **ssea** — senior software engineer agent for architecture and technical review; can
  delegate to `dev` and `fim` behind an approval gate.

`dev`, `planner` and `researcher` guards are not yet covered by the test suite.

---

## The idea underneath

Each agent is restricted to what it can do *honestly*:

- FIM reads, so it reports what is readable. It can spot a loop inside a loop; it
  cannot tell you how much memory your program uses, and it won't pretend to.
- AMA builds definitions, so it builds definitions — and won't call one finished
  before someone has reviewed it.

The limits aren't a safety feature bolted on afterwards. They're what makes the
output trustworthy.

---

## Install (Windows)

```powershell
# copy the agents and their guards into your agents folder
Copy-Item *.md "$HOME\.claude\agents\"
Copy-Item guards\*.ps1 "$HOME\.claude\agents\"
```

Then open each `.md` file and replace `<ABSOLUTE-PATH-TO>` in the frontmatter with
the real path, **using forward slashes**:

```yaml
command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/YOU/.claude/agents/fim-readonly-guard.ps1"; exit $LASTEXITCODE
```

Claude Code requires an absolute path here — it can't be made relative.

### Using them

```
@ama I want an agent that flags any pull request touching the database schema.

@fim review src/auth/. It should validate a JWT and reject expired tokens.
Built with: npm run build. Do not run anything.
```

---

## Testing the guards

The guards are what make the agents' limits real, so their behaviour is measured
rather than asserted:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-all.ps1
```

`-ExecutionPolicy Bypass` is required because Windows blocks unsigned scripts by
default. The agent hooks pass the same flag for the same reason.

**121 cases for the `fim` and `ama` guards.** Full write-up,
including the one gap this suite found and what the tests do *not* cover, in
[docs/results.md](docs/results.md).

Each case is a single line — `ALLOW git status`, `DENY rm -rf build/` — so adding a
case for a command you care about takes seconds.

---

## Limitations

Stated plainly, because agents you can't trust are worse than no agents.

- **Windows only.** All the guards are PowerShell. Cross-platform is planned.
- **The suite is slow on Windows PowerShell 5.1** — about two minutes, because it
  starts a fresh process for every case. Correct, but wasteful.
- **A guard is a pattern matcher, not a sandbox.** It inspects the command an agent
  asks to run. It cannot see inside a script once that script starts, and a
  determined user could get past it. It is built to stop an agent's own mistakes,
  which is the actual threat here — not to contain an adversary.
- **Nothing here executes your code.** `fim` reads, `dev` writes without running
  anything, and the rest plan or research, so anything needing live execution has
  nowhere to go.
- **Some documentation inside `ama.md` is stale** — its list of confirmed settings
  is more conservative than what current versions actually accept.

---

## Roadmap

- [x] **Test suite for the guards** — cases with known correct verdicts, so the
      safety claims are measured rather than asserted
- [x] Close the bare-`tsc` gap found by the suite
- [ ] Test cases for the `dev`, `planner` and `researcher` guards
- [ ] Cross-platform guards (macOS / Linux)
- [ ] A validator script, so a definition can be checked without a reviewer agent
- [ ] Pre-tested guard library, replacing guard generation
- [ ] Worked examples

## License

MIT — see [LICENSE](LICENSE).
