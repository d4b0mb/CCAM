# CCAM — Claude Code Agent Modules

**Three Claude Code subagents that build, audit and test — and can't claim work they didn't do.**

Claude Code will tell you it checked something. Usually it did. Sometimes it didn't,
and there's no way for you to tell the difference. CCAM's agents are built so the
difference is visible: each one is restricted to what it can honestly do, every claim
is tagged with how it was established, and every report ends with a list of what was
*not* checked.

> **Version 0.3.0 — early.** In daily use by its author. Windows-only, and the guards
> have no automated tests yet. Read [Limitations](#limitations) before relying on it.

---

## Who this is for

**You already use Claude Code. This is the part of it you're probably not using.**

Claude Code lets you build subagents — specialised assistants with their own
instructions, their own tool access, and their own hard limits. Most people never
build one, because it means learning which settings exist, which tool names are
valid, why hook paths have to be absolute, and — the one that catches everyone —
that the `description` field is what decides whether your agent ever gets picked.

CCAM gives you three that are already built, and one that builds more.

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

### test-runner — the honest test reporter

Runs a project's test suite and reports the failures — name, error, location — with
one summary line for everything that passed.

It has no ability to write files at all. That matters more than it sounds: told to
make the tests pass, a general-purpose assistant can edit the failing test. Sometimes
that's right. Often it's the worst outcome available — green tests, broken code.
test-runner physically cannot do it.

It also never guesses your test command. It reads your project's own config and cites
where it found it, or reports that it couldn't determine one.

---

## The idea underneath

Each agent is restricted to what it can do *honestly*:

- FIM reads, so it reports what is readable. It can spot a loop inside a loop; it
  cannot tell you how much memory your program uses, and it won't pretend to.
- test-runner runs tests, so it reports test results. It can't make them pass.
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

@test-runner project root is C:/code/myapp
```

---

## Limitations

Stated plainly, because agents you can't trust are worse than no agents.

- **Windows only.** All three guards are PowerShell. Cross-platform is planned.
- **The guards have no automated tests.** They were written carefully and work in
  practice, but nothing proves which commands they catch and which they miss. This
  is the top priority for the next release.
- **One known false positive:** the test-runner guard wrongly blocks
  `bundle exec rspec`.
- **A guard is a pattern matcher, not a sandbox.** It inspects the command an agent
  asks to run. It cannot see inside a script once that script starts, and a
  determined user could get past it. It is built to stop an agent's own mistakes,
  which is the actual threat here — not to contain an adversary.
- **Nothing here can safely execute your code.** All three agents are readers by
  design, so anything needing live execution has nowhere to go. That's what the
  fourth agent is for.
- **Some documentation inside `ama.md` is stale** — its list of confirmed settings
  is more conservative than what current versions actually accept.

---

## Roadmap

- [ ] **Test suite for the guards** — a corpus of commands with known correct
      verdicts, so the safety claims are measured rather than asserted
- [ ] **A fourth agent that can execute**, confined to a scratch copy of your code —
      so FIM can suspect a problem and something else can actually measure it
- [ ] Cross-platform guards (macOS / Linux)
- [ ] A validator script, so a definition can be checked without a reviewer agent
- [ ] Pre-tested guard library, replacing guard generation
- [ ] Worked examples

## License

MIT — see [LICENSE](LICENSE).
