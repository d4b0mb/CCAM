# planner-writeguard.ps1
# PreToolUse hook for the PLANNER subagent's Write tool.
# Reads the hook JSON on stdin, extracts tool_input.file_path, and BLOCKS (exit 2) any write
# whose target is not a Markdown file inside the planner archive folder:
#     C:/Users/YOU/planner-logs/**/*.md
# Everything else (project source, other folders, the .git directory, scripts) is out of bounds.
#
#   exit 0 = no opinion (normal permission flow continues)
#   exit 2 = blocked; the reason is shown to the agent so it corrects the target path
#            instead of retrying the same write somewhere else.
#
# Invoked by the agent frontmatter as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
# Deliberately conservative. Any internal error fails CLOSED (denies).
# Modelled on ama-writeguard.ps1.

$ErrorActionPreference = 'Stop'

$ArchiveRoot = 'c:/users/you/planner-logs'

function Deny([string]$reason) {
    $flatReason = $reason -replace '[\r\n]+', ' '
    $flatReason = [regex]::Replace($flatReason, '[\x00-\x1F]', ' ')
    $safe = $flatReason -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Planner write guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('PLANNER WRITE GUARD BLOCKED THIS WRITE.')
    [Console]::Error.WriteLine('Reason: ' + $flatReason)
    [Console]::Error.WriteLine('Planner may write only .md files inside C:/Users/YOU/planner-logs/ (never inside a .git folder). Do NOT retry this write at another path or with a variant spelling. Re-target the write inside the archive folder, or report that the write was blocked.')
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
    if ($null -ne $j.tool_input -and $null -ne $j.tool_input.file_path) { $path = [string]$j.tool_input.file_path }
} catch {
    Deny 'the hook payload was not valid JSON, so the target path cannot be proven safe (fail closed)'
}

if ([string]::IsNullOrWhiteSpace($path)) {
    Deny "no target path was present in tool_input for tool '$toolName', so the write cannot be proven safe (fail closed)"
}

try {
    $p = $path.Trim().Trim('"').Trim("'")

    if ($p -match '^~[/\\]') {
        $userHome = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:HOME }
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            Deny 'the path is home-relative (~) but neither USERPROFILE nor HOME is set, so it cannot be resolved (fail closed)'
        }
        $p = Join-Path $userHome ($p.Substring(2))
    }

    if ($p -match '^\\\\' -or $p -match '^//') {
        Deny 'UNC / network paths are not a permitted write target'
    }

    # Fully-qualified drive-letter path only (drive-relative and root-relative forms refused).
    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        Deny "the target path is not fully qualified, so it cannot be checked reliably: $p . Supply an absolute path beginning with a drive letter and a separator"
    }

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
    if ($norm -eq $ArchiveRoot -or $norm -eq ($ArchiveRoot + '/')) {
        Deny "target is the archive folder itself, not a file inside it: $full"
    }
    $prefix = $ArchiveRoot + '/'
    if (-not $norm.StartsWith($prefix)) {
        Deny "target is outside the archive folder: $full . Planner may only write under C:/Users/YOU/planner-logs/"
    }

    $tail = $norm.Substring($prefix.Length)
    if ([string]::IsNullOrWhiteSpace($tail) -or $tail.EndsWith('/')) {
        Deny "target looks like a directory, not a file: $full"
    }

    foreach ($seg in $tail.Split('/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') {
            Deny "target contains an empty or parent-directory segment after resolution: $full"
        }
        # .git (and .gitignore, .gitattributes ...) are never writable: a file inside .git can be
        # executable (hooks) or can redirect git. GIT~1 is the Windows 8.3 alias of .git, and
        # Windows strips trailing dots and spaces, so those spellings are refused too.
        if ($seg.StartsWith('.git')) {
            Deny "target is inside or named like a git control path ($seg): $full"
        }
        if ($seg.Contains('~')) {
            Deny "target contains a tilde segment ($seg), which may be a Windows 8.3 short-name alias: $full"
        }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) {
            Deny "target segment ends in a dot or space, which Windows normalizes away ($seg): $full"
        }
    }

    # Only Markdown files: no scripts, batch files or executables can be created in the archive.
    if (-not $norm.EndsWith('.md')) {
        Deny "only .md files may be written to the archive: $full"
    }

    exit 0

} catch {
    Deny ('the guard failed while evaluating the path, so the write is denied (fail closed): ' + $_.Exception.Message)
}
