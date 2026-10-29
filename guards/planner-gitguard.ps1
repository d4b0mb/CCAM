# planner-gitguard.ps1
# PreToolUse hook for the PLANNER subagent's Bash tool.
# Reads the hook JSON on stdin, extracts tool_input.command, and ALLOWS only a short fixed list
# of git commands aimed at the archive repo at C:/Users/YOU/planner-logs :
#     git -C <root> status [--short|-s]
#     git -C <root> add -A            (or: add .)
#     git -C <root> commit -m "<plain text>"
#     git -C <root> push              (or: push origin <branch>)
#     git -C <root> log --oneline [-n <1-3 digits>]
# Anything else is denied. Allowlist, not denylist: the command must match one pattern in full.
#
#   exit 0 = allowed (no opinion; normal permission flow continues)
#   exit 2 = blocked; the reason is shown to the agent.
#
# Invoked by the agent frontmatter as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
# Any internal error fails CLOSED (denies).
# Known limit: the guard cannot see the repo's own .git/config or hooks. Those are the owner's
# setup; the companion write guard stops the agent from writing into .git.

$ErrorActionPreference = 'Stop'

$Root = 'C:/Users/YOU/planner-logs'

function Deny([string]$reason) {
    $flatReason = $reason -replace '[\r\n]+', ' '
    $flatReason = [regex]::Replace($flatReason, '[\x00-\x1F]', ' ')
    $safe = $flatReason -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Planner git guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('PLANNER GIT GUARD BLOCKED THIS COMMAND.')
    [Console]::Error.WriteLine('Reason: ' + $flatReason)
    [Console]::Error.WriteLine('Planner may run only: git -C "C:/Users/YOU/planner-logs" followed by status, add -A, commit -m "plain text", push, or log --oneline. Do NOT retry a variant of this command. Record the archive step as not performed and report it.')
    exit 2
}

$cmd = ''
try {
    $raw = [Console]::In.ReadToEnd()
    $j = $raw | ConvertFrom-Json
    if ($null -ne $j.tool_input -and $null -ne $j.tool_input.command) { $cmd = [string]$j.tool_input.command }
} catch {
    $cmd = ''
}
if ([string]::IsNullOrWhiteSpace($cmd)) {
    Deny 'could not read tool_input.command from the hook input, so the command cannot be proven safe (fail closed)'
}

try {
    $c = $cmd.Trim()

    if ($c.Length -gt 400) { Deny 'command is too long' }
    if ($c -match '[\r\n]') { Deny 'multi-line commands are not allowed' }

    $e = [regex]::Escape($Root)
    $r = '(?:"' + $e + '/?"|' + $e + '/?)'
    $pre = '^git -C ' + $r + ' '

    $patterns = @(
        ($pre + 'status(?: --short| -s)?$'),
        ($pre + 'add (?:-A|\.)$'),
        ($pre + 'commit -m "[A-Za-z0-9 .,:_/-]{1,200}"$'),
        ($pre + 'push(?: origin [A-Za-z0-9][A-Za-z0-9._-]{0,59})?$'),
        ($pre + 'log --oneline(?: -n [0-9]{1,3})?$')
    )

    foreach ($pat in $patterns) {
        # (?i) so the drive letter and folder name match regardless of case; the rest of each
        # pattern is already case-explicit or insensitive-safe (git subcommands are lowercase).
        if ([regex]::IsMatch($c, '(?i)' + $pat)) { exit 0 }
    }

    Deny 'command does not match any allowed git form for the archive repo'
} catch {
    Deny ('internal guard error, failing closed: ' + $_.Exception.Message)
}
