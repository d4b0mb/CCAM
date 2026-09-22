# Changelog

## 0.2 — 2026-09-22

First public release.

- `ama.md` — the Agent Maker subagent definition.
- `guards/ama-writeguard.ps1` — PreToolUse write guard restricting AMA's writes
  to agents directories only.
- Hook path replaced with a placeholder so the definition is not tied to one
  machine; set at install time.
- README documenting install, usage and known limitations.

Known open issues carried into 0.3:

- The write guard has no automated test coverage.
- Windows / PowerShell only.
- The review handoff has no published reviewer agent to hand off to.
- The confirmed-settings list inside `ama.md` is more conservative than reality.

## 0.1 — unreleased

Private version, developed and used locally.
