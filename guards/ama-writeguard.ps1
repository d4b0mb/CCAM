# ama-writeguard.ps1
# PreToolUse hook for the AMA (Agent Maker) subagent's file-writing tools.
# Reads the hook JSON on stdin, extracts tool_input.file_path, and BLOCKS (exit 2) any write
# whose target is not inside an agents directory.
# AMA authors agent definitions and their support files. It may write:
#     <userprofile>/.claude/agents/**        (user-level agents)
#     <anything>/.claude/agents/**           (project-level agents)
# and nothing else. Project source, config, tests and docs are out of bounds.
#
#   exit 0 = no opinion (normal permission flow continues)
#   exit 2 = blocked; the reason is shown to AMA so it corrects the target path
#            instead of retrying the same write somewhere else.
#
# Invoked by the agent frontmatter as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
# Deliberately conservative: a false positive costs one denied call and a corrected path;
# a false negative would let an agent-maker scribble into a user's project. Any internal
# error fails CLOSED (denies).

$ErrorActionPreference = 'Stop'

function Deny([string]$reason) {
    # Collapse newlines, then JSON-escape rather than strip. Stripping backslashes would
    # mangle every Windows path in the message, and the message is the actionable advice
    # the blocked agent is told to act on - a path it cannot read is useless advice.
    $flatReason = $reason -replace '[\r\n]+', ' '
    # Any remaining control character below 0x20 (a tab in a path, say) would be emitted raw
    # inside the JSON string and make the line unparseable, silently costing the structured
    # reason. Replace them before escaping; such characters are illegal in Windows paths
    # anyway, so nothing of value is lost.
    $flatReason = [regex]::Replace($flatReason, '[\x00-\x1F]', ' ')
    $safe = $flatReason -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"AMA write guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('AMA WRITE GUARD BLOCKED THIS WRITE.')
    [Console]::Error.WriteLine('Reason: ' + $flatReason)
    [Console]::Error.WriteLine('AMA writes agent definitions only. Permitted targets are ~/.claude/agents/<name>.md and <project>/.claude/agents/<name>.md, plus support files (guard hooks) in that same directory. Do NOT retry this write at another path outside an agents directory. Re-target the write, or report to the caller that the requested location is outside AMA''s write boundary.')
    exit 2
}

# ---- read the hook payload ------------------------------------------------------------
$raw = ''
try {
    $raw = [Console]::In.ReadToEnd()
} catch {
    Deny 'could not read the hook payload from stdin, so the target path cannot be proven safe (fail closed)'
}

$toolName = ''
$path     = ''
try {
    $j = $raw | ConvertFrom-Json
    if ($null -ne $j.tool_name) { $toolName = [string]$j.tool_name }
    if ($null -ne $j.tool_input) {
        # Write/Edit use file_path; NotebookEdit uses notebook_path.
        if ($null -ne $j.tool_input.file_path)     { $path = [string]$j.tool_input.file_path }
        elseif ($null -ne $j.tool_input.notebook_path) { $path = [string]$j.tool_input.notebook_path }
    }
} catch {
    Deny 'the hook payload was not valid JSON, so the target path cannot be proven safe (fail closed)'
}

if ([string]::IsNullOrWhiteSpace($path)) {
    Deny "no target path was present in tool_input for tool '$toolName', so the write cannot be proven safe (fail closed)"
}

try {
    # ---- normalize --------------------------------------------------------------------
    # Expand a leading ~ , make the path absolute, collapse any .. segments, unify
    # separators, and lowercase for comparison. GetFullPath does not require the file
    # to exist, which matters because Write creates new files.
    $p = $path.Trim().Trim('"').Trim("'")

    if ($p -match '^~[/\\]') {
        # NB: do not name this $home - that is a read-only PowerShell automatic variable
        # and assigning to it throws, which would fail every home-relative path closed.
        $userHome = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:HOME }
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            Deny 'the path is home-relative (~) but neither USERPROFILE nor HOME is set, so it cannot be resolved (fail closed)'
        }
        $p = Join-Path $userHome ($p.Substring(2))
    }

    # Reject UNC and alternate-stream forms outright rather than trying to reason about them.
    if ($p -match '^\\\\' -or $p -match '^//') {
        Deny 'UNC / network paths are not a permitted write target'
    }

    # Require a fully-qualified drive-letter path. Anything else would be completed by
    # GetFullPath using THIS process's state, which is not guaranteed to match the state
    # the calling tool resolves against - so the guard could rule on a different file than
    # the one actually written. Refuse to guess.
    #
    # NB: IsPathRooted is NOT sufficient here. It returns true for drive-relative paths
    # ("C:foo\bar", completed against the process's current directory on drive C) and for
    # root-relative paths ("\foo", "/foo", completed against the process's current drive).
    # Both are exactly the failure this check exists to prevent. Requiring a separator
    # immediately after the drive specifier excludes all three forms in one test.
    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        Deny "the target path is not fully qualified, so it cannot be checked reliably: $p . Supply an absolute path beginning with a drive letter and a separator"
    }

    # Alternate data stream / malformed drive specifier: after the leading drive letter,
    # no further colon is legal in a real file path. Checked by stripping the drive
    # specifier and looking at what remains - testing the whole string would match every
    # ordinary absolute Windows path and never fire.
    $afterDrive = $p -replace '^[A-Za-z]:', ''
    if ($afterDrive.Contains(':')) {
        Deny "the path contains a colon after the drive specifier, which indicates an alternate data stream or a malformed path: $p"
    }

    $full = ''
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        Deny "the target path could not be resolved to an absolute path: $p"
    }

    if ([string]::IsNullOrWhiteSpace($full)) {
        Deny "the target path resolved to nothing: $path"
    }

    $norm = ($full -replace '\\', '/').ToLowerInvariant()
    $norm = $norm -replace '/+', '/'

    # ---- the allowlist ----------------------------------------------------------------
    # After full resolution, the path must sit inside a directory literally named
    # ".claude/agents". Resolution has already collapsed "..", so a traversal such as
    # ~/.claude/agents/../../evil.txt cannot survive this check.
    # Catch the directory itself first, in both spellings, so the blocked agent gets the
    # accurate reason. Without this, the no-trailing-separator form fails the marker test
    # below and is denied as "outside every agents directory", which is the wrong advice.
    if ($norm.EndsWith('/.claude/agents') -or $norm.EndsWith('/.claude/agents/')) {
        Deny "target is the agents directory itself, not a file inside it: $full"
    }

    $marker = '/.claude/agents/'
    $idx = $norm.IndexOf($marker)
    if ($idx -lt 0) {
        Deny "target is outside every agents directory: $full . AMA may only write under ~/.claude/agents/ or <project>/.claude/agents/"
    }

    # Must name a file inside the directory, not the directory itself.
    $tail = $norm.Substring($idx + $marker.Length)
    if ([string]::IsNullOrWhiteSpace($tail)) {
        Deny "target is the agents directory itself, not a file inside it: $full"
    }
    if ($tail.EndsWith('/')) {
        Deny "target looks like a directory, not a file: $full"
    }

    # A nested second agents-marker or any residual traversal is a sign of a crafted path.
    if ($tail -match '(^|/)\.\.(/|$)') {
        Deny "target still contains a parent-directory segment after resolution: $full"
    }

    # ---- allowed ----------------------------------------------------------------------
    # No opinion: let the normal permission flow decide.
    exit 0

} catch {
    Deny ('the guard failed while evaluating the path, so the write is denied (fail closed): ' + $_.Exception.Message)
}
