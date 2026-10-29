# researcher-writeguard.ps1
# PreToolUse hook for the Researcher subagent's Write tool.
# Reads the hook JSON on stdin and BLOCKS (exit 2) any Write unless the target is a NEW .txt
# file placed directly inside C:/Users/YOU/Documents/research/ .
#
#   exit 0 = allowed (no opinion; normal permission flow continues)
#   exit 2 = blocked; the reason is shown to the agent.
#
# Fails CLOSED: any internal error denies.
# Rules enforced after resolving .. :
#   - absolute drive-letter path only (relative, home-relative "~", UNC, drive-relative,
#     root-relative all rejected rather than resolved)
#   - no colon after the drive specifier (alternate data streams)
#   - target is a direct child of the research folder (no subfolders)
#   - file name matches ^[A-Za-z0-9][A-Za-z0-9._ -]*\.txt$ and is not a reserved device name
#   - the file must not already exist (no overwrite)

$ErrorActionPreference = 'Stop'

# The only permitted folder. Lowercase, forward slashes, trailing slash.
$AllowedRoot = 'c:/users/you/documents/research/'

function Deny([string]$reason) {
    $flat = $reason -replace '[\r\n]+', ' '
    $flat = [regex]::Replace($flat, '[\x00-\x1F]', ' ')
    $safe = $flat -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Researcher write guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('RESEARCHER WRITE GUARD BLOCKED THIS WRITE.')
    [Console]::Error.WriteLine('Reason: ' + $flat)
    [Console]::Error.WriteLine('The Researcher may only create ONE NEW .txt file directly inside C:/Users/YOU/Documents/research/ . It may not overwrite an existing file. If the reason says the file already exists, choose a different unused file name once. If the reason says the location or name is invalid, correct it once as the reason describes. If a second write is also blocked, stop and tell the caller the write was blocked and why. Do not try other locations or tricks.')
    exit 2
}

# ---- read payload ---------------------------------------------------------------------
$raw = ''
try {
    $raw = [Console]::In.ReadToEnd()
} catch {
    Deny 'could not read the hook payload from stdin (fail closed)'
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    Deny 'the hook payload was empty, so the target path cannot be proven safe (fail closed)'
}

$path = ''
try {
    $j = $raw | ConvertFrom-Json
    if ($null -ne $j.tool_input -and $null -ne $j.tool_input.file_path) {
        $path = [string]$j.tool_input.file_path
    }
} catch {
    Deny 'the hook payload was not valid JSON (fail closed)'
}

if ([string]::IsNullOrWhiteSpace($path)) {
    Deny 'no target path was present in tool_input (fail closed)'
}

try {
    $p = $path.Trim().Trim('"').Trim("'")

    # Home-relative paths are rejected, not resolved: the Write tool might not resolve "~"
    # the same way this process would, so the guard could rule on a different file.
    if ($p.StartsWith('~')) {
        Deny "home-relative (~) paths are not accepted: $p . Supply the full absolute path, for example C:/Users/YOU/Documents/research/<name>.txt"
    }

    if ($p -match '^\\\\' -or $p -match '^//') {
        Deny 'UNC / network paths are not a permitted write target'
    }

    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        Deny "the target path is not fully qualified: $p . Supply an absolute path beginning with a drive letter and a separator"
    }

    $afterDrive = $p -replace '^[A-Za-z]:', ''
    if ($afterDrive.Contains(':')) {
        Deny "the path contains a colon after the drive specifier (alternate data stream or malformed path): $p"
    }

    $full = ''
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        Deny "the target path could not be resolved: $p"
    }
    if ([string]::IsNullOrWhiteSpace($full)) {
        Deny "the target path resolved to nothing: $path"
    }

    $norm = ($full -replace '\\', '/').ToLowerInvariant()
    $norm = $norm -replace '/+', '/'

    # The research folder itself (either spelling).
    if ($norm -eq $AllowedRoot.TrimEnd('/') -or $norm -eq $AllowedRoot) {
        Deny "target is the research folder itself, not a file inside it: $full"
    }

    if (-not $norm.StartsWith($AllowedRoot)) {
        Deny "target is outside the permitted folder: $full . Allowed: C:/Users/YOU/Documents/research/"
    }

    $tail = $norm.Substring($AllowedRoot.Length)
    if ([string]::IsNullOrWhiteSpace($tail)) {
        Deny "target is the research folder itself, not a file inside it: $full"
    }
    if ($tail.Contains('/')) {
        Deny "target is in a subfolder or looks like a directory; the file must sit directly in the research folder: $full"
    }

    if ($tail -notmatch '^[a-z0-9][a-z0-9._ -]*\.txt$') {
        Deny "the file name must be letters, digits, dot, underscore, space or hyphen, start with a letter or digit, and end in .txt: $tail"
    }

    $stem = $tail.Substring(0, $tail.Length - 4).TrimEnd(' ', '.')
    $stemBase = ($stem -split '\.')[0].TrimEnd(' ')
    if ($stemBase -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$') {
        Deny "the file name is a reserved Windows device name: $tail"
    }

    if (Test-Path -LiteralPath $full) {
        Deny "a file or folder already exists at $full . Overwriting is not permitted; choose a different unused file name"
    }

    exit 0

} catch {
    Deny ('the guard failed while evaluating the path, so the write is denied (fail closed): ' + $_.Exception.Message)
}
