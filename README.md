# CCAM — Claude Code Agent Modules

**Six Claude Code subagents that build, plan, research and audit — and can't claim work they didn't do.**

Claude Code will tell you it checked something. Usually it did. Sometimes it didn't,
and there's no way for you to tell the difference. CCAM's agents are built so the
difference is visible: each one is restricted to what it can honestly do, and the
auditor tags every claim with how it was established and ends every report with a list
of what was *not* checked.

> **Version 0.4.1 — early.** In daily use by its author. Windows-only.
> The `fim` and `ama` guards are measured, not assumed: **121 test cases, all passing
> on Windows PowerShell 5.1** — see [Guard test results](docs/results.md). The `dev`,
> `planner` and `researcher` guards have no test cases yet.
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

| Agent | Job | Tools | Guard |
|---|---|---|---|
| [`ama`](ama.md) | Builds new agent definitions | Read, Write, Glob, Agent | `ama-writeguard.ps1` |
| [`fim`](fim.md) | Audits code, read-only | Read, Grep, Glob, Bash | `fim-readonly-guard.ps1` |
| [`dev`](dev.md) | Writes code, never runs it | Read, Grep, Glob, Write, Edit | `dev-writeguard.ps1` |
| [`planner`](planner.md) | Turns a scope into a plan and briefs | Read, Grep, Glob, Write, Bash | `planner-writeguard.ps1`, `planner-gitguard.ps1` |
| [`researcher`](researcher.md) | Researches a topic online | WebSearch, WebFetch, Write | `researcher-writeguard.ps1` |
| [`ssea`](ssea.md) | Senior engineer: architecture and technical review | Read, Grep, Glob, WebSearch, WebFetch, Agent | none |

### AMA — the agent maker

You describe the assistant you want. AMA works out the rest: which tools it needs,
what it must never touch, how many turns before it stops. It writes the definition
file and gets it reviewed by FIM before calling it finished.

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

FIM also has an optional project mode: for a new or mid-project codebase it runs in
two passes (questions first, then answers) and returns a master reference document for
you to save.

### dev — the developer

Writes and edits code inside the project root you give it, after reading the existing
codebase. It never executes anything: no tests, builds, installers, package managers or
git. It returns the exact commands for you to run, including commit and push.

### planner — the briefer

Dissects a scope, task or conversation into a technical plan plus ready-to-paste briefs
for models and local agents, so you can delegate accurately without writing the
technical detail yourself. If it hits blocking gaps it returns numbered questions first
and stops.

Every run is archived (prompt, reply, plan) as Markdown in a log folder that is meant to
be a clone of your own private git repo. Its guards allow writing `.md` files only
inside that folder, and only a fixed set of git commands against it. Those logs are
yours; they are not part of this repo.

### researcher — the researcher

Looks a topic up online, writes the findings to one new `.txt` file in a research
folder, and replies with the file's path. Its guard allows exactly one new `.txt` file
there and never overwrites an existing one. The research notes are yours; they are not
part of this repo.

### ssea — the senior software engineer

Takes a scope or planner output and makes it technically correct: architecture and
technology choices, sequencing, risks and an end-to-end workflow, checked against
current best practice on the web. It then either reports back, hands over delegation
briefs, or calls agents such as `dev` and `fim` to do the work, depending on an
approval gate.

---

## The idea underneath

Each agent is restricted to what it can do *honestly*:

- FIM reads, so it reports what is readable. It can spot a loop inside a loop; it
  cannot tell you how much memory your program uses, and it won't pretend to.
- `dev` writes, so it can't claim its code works — it hasn't run it, and says so.
- AMA builds definitions, so it builds definitions — and won't call one finished
  before someone has reviewed it.
- `researcher` searches and writes one file, so it can't touch your code.

The limits aren't a safety feature bolted on afterwards. They're what makes the
output trustworthy.

---

## Install (Windows)

```powershell
# copy the agents and their guards into your agents folder
foreach ($a in 'ama','dev','fim','planner','researcher','ssea') {
    Copy-Item "$a.md" "$HOME\.claude\agents\"
}
Copy-Item guards\*.ps1 "$HOME\.claude\agents\"
```

Then edit the copies:

1. In each `.md` file that has a `hooks:` block (`ama`, `dev`, `fim`, `planner`,
   `researcher`), replace `<ABSOLUTE-PATH-TO>` with the real path, **using forward
   slashes**:

   ```yaml
   command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/YOU/.claude/agents/fim-readonly-guard.ps1"; exit $LASTEXITCODE
   ```

   Claude Code requires an absolute path here — it can't be made relative.

2. For `planner` and `researcher`, also replace `YOU` in the folder paths. They are
   hard-coded in `planner.md`, `researcher.md` and the matching guards
   (`planner-writeguard.ps1`, `planner-gitguard.ps1`, `researcher-writeguard.ps1`):

   - `C:/Users/YOU/planner-logs` — a git clone of your own private archive repo
   - `C:/Users/YOU/Documents/research` — where research notes are written

### Using them

```
@ama I want an agent that flags any pull request touching the database schema.

@fim review src/auth/. It should validate a JWT and reject expired tokens.
Built with: npm run build. Do not run anything.

@dev project root is C:/code/myapp. Add rate limiting to the login route.

@planner Scope: add SSO to the admin app. Executor: dev.

@researcher Compare SQLite and DuckDB for local analytics.

@ssea review this plan technically. Plan only, don't start the work.
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

**121 cases for the `fim` (106) and `ama` (15) guards, all passing on Windows
PowerShell 5.1.** Full write-up, including the one gap an earlier suite found and what
the tests do *not* cover, in [docs/results.md](docs/results.md).

Each case is a single line — `ALLOW git status`, `DENY rm -rf build/` — so adding a
case for a command you care about takes seconds.

---

## Limitations

Stated plainly, because agents you can't trust are worse than no agents.

- **Windows only.** All the guards are PowerShell. Cross-platform is planned.
- **Not every guard is tested.** The `dev`, `planner` and `researcher` guards parse
  cleanly but have no test cases, and `ssea` has no guard.
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
