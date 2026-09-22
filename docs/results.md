# Guard test results

**Run date:** 22 September 2026 · **CCAM version:** 0.4.1

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
| `fim-readonly-guard.ps1` | 106 | 106 | 0 | 100% |
| `test-runner-guard.ps1` | 58 | 58 | 0 | 100% |
| `ama-writeguard.ps1` | 15 | 15 | 0 | 100% |
| **Total** | **179** | **179** | **0** | **100%** |

The 0.4.0 run scored 172 of 173, with one missed mutation. That gap is now closed and
six further cases were added around it; see below.

Two kinds of failure are counted separately, because they are not equally serious:

- **False alarm** — a safe command wrongly blocked. Costs the agent one denied call.
- **Missed mutation** — a dangerous command allowed through. The guard's promise did
  not hold.

Across 179 cases: **0 false alarms, 0 missed mutations.**

## The gap that was found, and closed

**0.4.0 — `tsc` was allowed, and should not have been.**

Run without arguments, the TypeScript compiler writes `.js` files next to the sources
it compiles. That is a mutation, and FIM is supposed to be incapable of it. FIM's own
instructions already said to prefer `tsc --noEmit`, but nothing enforced it, so an
agent that forgot was not stopped.

The guard already handled this exact pattern for a dozen other tools — `rustfmt`,
`cargo fmt`, `ruff format` and the rest are denied unless a check-only flag is
present. `tsc` was simply missing from that list.

**0.4.1 — fixed.** `tsc` (and `tsgo`) are now denied unless `--noEmit` or `--dry` is
present. The flag test is case-insensitive, because TypeScript's own flags are.

There is a genuine argument on the other side: a project whose `tsconfig.json` sets
`"noEmit": true` writes nothing when `tsc` runs bare, so denying it is a false alarm
in that case. The guard cannot see the tsconfig, and its own stated principle settles
the trade-off — "a rare false positive costs one denied call; a false negative would
break the read-only promise."

Six cases were added alongside the fix, covering the forms most likely to slip past a
narrow patch: `npx tsc`, `tsc -p .`, `tsc --project <file>`, `tsc --init`, and two
`--noEmit` spellings that must still be allowed.

**The order matters.** The failing test was committed in 0.4.0, before any fix existed.
The fix in 0.4.1 had something to prove itself against, rather than being declared
correct by the person who wrote it.

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
