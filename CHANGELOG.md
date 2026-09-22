# Changelog

## 0.4.1 — 2026-09-22

Closed the gap the 0.4.0 suite found.

Fixed:

- `fim-readonly-guard.ps1` now denies `tsc` (and `tsgo`) unless `--noEmit` or `--dry`
  is present. Bare `tsc` writes `.js` files next to its sources, which FIM is supposed
  to be incapable of. The flag test is case-insensitive, matching TypeScript's own
  flag handling.

Added:

- Six further cases around the fix: `npx tsc`, `tsc -p .`, `tsc --project <file>`,
  `tsc --init`, and two `--noEmit` spellings that must still be allowed.

Results: **179 cases, 179 passed, 0 false alarms, 0 missed mutations.**

The failing test for this gap was committed in 0.4.0, before the fix existed.

## 0.4.0 — 2026-09-22

The guards are now measured rather than asserted.

Added:

- `tests/run-guard-tests.ps1` — runs one guard against one case file. A guard reads
  the hook payload on stdin and exits 0 (allow) or 2 (deny), so testing it is a matter
  of feeding it a command and reading the exit code.
- `tests/run-all.ps1` — runs all three suites.
- `tests/cases/*.cases` — 173 cases: safe commands that must be allowed, dangerous
  ones that must be blocked, and the deliberately tricky middle (`grep -rn "rm -rf"`,
  `docker ps --all`, `git status > /dev/null`, test filters whose values are ordinary
  English words).
- `docs/results.md` — the numbers, the one failure, and what the tests do not cover.

Results: **173 cases, 172 passed, 0 false alarms, 1 missed mutation (99.4%).**
Verified on Windows PowerShell 5.1 and PowerShell 7.4.6 — identical results on both.

Open, with a failing test committed for it:

- The FIM guard allows bare `tsc`, which writes `.js` files. Other write-by-default
  tools (`rustfmt`, `cargo fmt`, `ruff format`) are already denied without a
  check-only flag; `tsc` is missing from that list.

Removed:

- The documented `bundle exec rspec` false positive. It could not be reproduced —
  the command passes, as do seven variants of it. The claim has been withdrawn rather
  than left standing. If it reappears it comes back with a test case attached.

## 0.3.0 — 2026-09-22

Became a suite. Renamed to CCAM (Claude Code Agent Modules).

Added:

- `fim.md` + `guards/fim-readonly-guard.ps1` — read-only code auditor. Every claim
  tagged EXECUTED / READ / UNVERIFIED, every finding cited to `file:line`, every
  report closing with a NOT CHECKED section.
- `test-runner.md` + `guards/test-runner-guard.ps1` — runs a test suite and reports
  failures. Holds no file-writing tool, so it cannot "fix" a failing test.

Changed:

- Hook paths in all three agent definitions replaced with `<ABSOLUTE-PATH-TO>`
  placeholders, set at install time.
- README rewritten to cover the suite and to aim at existing Claude Code users.

Known open issues carried into 0.4.0:

- No automated test coverage for any of the three guards.
- Windows / PowerShell only.
- test-runner guard wrongly denies `bundle exec rspec`.
- The confirmed-settings list inside `ama.md` is more conservative than reality.
- No agent in the suite can execute code; all three are read-only by design.

## 0.2 — 2026-09-22

First public release. AMA only.

- `ama.md` — the Agent Maker subagent definition.
- `guards/ama-writeguard.ps1` — write guard restricting AMA to agents directories.
- README, MIT licence, `.gitignore`.

## 0.1 — unreleased

Private version, developed and used locally.
