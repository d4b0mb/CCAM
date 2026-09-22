# Changelog

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
