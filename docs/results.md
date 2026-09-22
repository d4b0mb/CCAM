# Guard test results

**Run date:** 22 September 2026 · **CCAM version:** 0.4.0

The three guards are the mechanism behind CCAM's central claim: that each agent is
restricted to what it can honestly do. Until now that claim was asserted. This is the
first time it has been measured.

## Method

A guard is a PreToolUse hook. It reads the hook payload as JSON on standard input and
exits `0` to allow the tool call or `2` to deny it. That makes it directly testable:
feed it a command, read the exit code, compare against the verdict it was supposed to
give.

Each case file is a list of lines reading `ALLOW <command>` or `DENY <command>`.
`tests/run-guard-tests.ps1` runs one guard against one case file;
`tests/run-all.ps1` runs all three.

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-all.ps1
```

Run on **both** engines — PowerShell 7.4.6 and Windows PowerShell 5.1 — which produced
identical results, case for case. Claude Code invokes the guards through 5.1, so that
is the run that matters; 7.x agreeing with it means the suite is portable.

## Results

| Guard | Cases | Passed | Failed | Correct |
|---|---:|---:|---:|---:|
| `fim-readonly-guard.ps1` | 100 | 99 | 1 | 99.0% |
| `test-runner-guard.ps1` | 58 | 58 | 0 | 100% |
| `ama-writeguard.ps1` | 15 | 15 | 0 | 100% |
| **Total** | **173** | **172** | **1** | **99.4%** |

Two kinds of failure are counted separately, because they are not equally serious:

- **False alarm** — a safe command wrongly blocked. Costs the agent one denied call.
- **Missed mutation** — a dangerous command allowed through. The guard's promise did
  not hold.

Across 173 cases: **0 false alarms, 1 missed mutation.**

## The one failure

**`tsc` is allowed, and should not be.**

Run without arguments, the TypeScript compiler writes `.js` files next to the sources
it compiles. That is a mutation, and FIM is supposed to be incapable of it. FIM's own
instructions already say to prefer `tsc --noEmit`, but the guard does not enforce it,
so an agent that forgets is not stopped.

The guard already handles this exact pattern for other tools — `rustfmt`, `cargo fmt`,
`ruff format` and a dozen more are denied unless a check-only flag is present. `tsc` is
missing from that list.

There is a genuine argument on the other side: a project whose `tsconfig.json` sets
`"noEmit": true` writes nothing when `tsc` is run bare, so denying it would be a false
alarm in that case. But the guard's own stated principle settles it — "a rare false
positive costs one denied call; a false negative would break the read-only promise."

**Status: open.** The failing test is committed before any fix, so the fix has
something to prove itself against.

## A claim that did not survive testing

CCAM 0.3.0 documented a known false positive: the test-runner guard wrongly blocking
`bundle exec rspec`.

**It could not be reproduced.** `bundle exec rspec` passes, as do seven variants of it
(with a spec path, with `--format`, with a test-name filter, with a pinned bundler
version). Either the bug was fixed at some point before this suite existed, or it was
never in this guard.

The claim has been removed from the README rather than left standing as a documented
bug that does not occur. If it reappears, it comes back with a test case attached.

This is the test suite doing its actual job: the first claim it checked turned out to
be wrong, and now that is known instead of believed.

## What these numbers do not cover

- **Only two Windows PowerShell engines were tested** (5.1 and 7.4.6), on one machine.
  They agreed exactly. Other builds and locales are unexamined.
- **The suite is slow on Windows.** It launches a fresh PowerShell process per case,
  which costs roughly two minutes for 173 cases on 5.1 versus seconds on 7. Correct,
  but wasteful; batching is an obvious improvement.
- **A guard is a pattern matcher, not a sandbox.** Every case here is a command a
  well-intentioned agent might plausibly issue. None of them are attempts to defeat the
  guard deliberately — through encoded commands, variable indirection, or a script that
  mutates after it starts. Those would get through, and the design accepts that. The
  threat being defended against is an agent's own mistakes.
- **The corpus is not exhaustive.** 173 cases across three guards covers the common
  shapes and the obvious traps. It does not cover every shell on earth, every tool, or
  every flag.

Knowing precisely what has not been tested is the point of writing it down.
