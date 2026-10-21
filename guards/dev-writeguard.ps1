# dev-writeguard.ps1
# PreToolUse hook for the `dev` subagent's Write and Edit tools.
# Reads the hook JSON on stdin, extracts tool_input.file_path, and BLOCKS (exit 2) any write
# that is not a fully-qualified path or that targets a fixed denylist of locations from which
# written content could be executed or loaded automatically (git internals, Claude Code
# config, editor/devcontainer/cargo config, shell profiles, credentials, AppData, system dirs).
#
# LIMITATIONS (stated honestly):
# - A static hook cannot know which project root the caller named in a given call, so
#   confinement to THAT root is enforced by dev's prompt only, not by this script.
# - The denylist is fixed. A file type not on it is not blocked.
# - 8.3 short-name segments (anything containing ~<digit>) are denied outright, because
#   they could alias a protected name. Existing reparse points (symlinks/junctions) on the
#   target's ancestor chain are denied. A false deny is possible if a legitimate folder
#   is a reparse point (e.g. some OneDrive setups).
#
#   exit 0 = no opinion (normal permission flow continues)
#   exit 2 = blocked
# Any internal error fails CLOSED (denies).

$ErrorActionPreference = 'Stop'

function Deny([string]$reason) {
    $flatReason = $reason -replace '[\r\n]+', ' '
    $flatReason = [regex]::Replace($flatReason, '[\x00-\x1F]', ' ')
    $safe = $flatReason -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"dev write guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('DEV WRITE GUARD BLOCKED THIS WRITE.')
    [Console]::Error.WriteLine('Reason: ' + $flatReason)
    [Console]::Error.WriteLine('dev writes project files only, inside the project root the caller named. Do NOT retry this write at a variant path. Record it under NOT WRITTEN in your report with the reason, and tell the caller what they would need to do themselves.')
    exit 2
}

$raw = ''
try {
    try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $raw = [Console]::In.ReadToEnd()
} catch {
    Deny 'could not read the hook payload from stdin (fail closed)'
}

$toolName = ''
$path     = ''
try {
    $j = $raw | ConvertFrom-Json
    if ($null -ne $j.tool_name) { $toolName = [string]$j.tool_name }
    if ($null -ne $j.tool_input -and $null -ne $j.tool_input.file_path) {
        $path = [string]$j.tool_input.file_path
    }
} catch {
    Deny 'the hook payload was not valid JSON (fail closed)'
}

if ([string]::IsNullOrWhiteSpace($path)) {
    Deny "no target path was present in tool_input for tool '$toolName' (fail closed)"
}

try {
    $p = $path.Trim().Trim('"').Trim("'")

    if ($p -match '^~[/\\]') {
        $userHome = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:HOME }
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            Deny 'the path is home-relative (~) but neither USERPROFILE nor HOME is set (fail closed)'
        }
        $p = Join-Path $userHome ($p.Substring(2))
    }

    if ($p -match '^\\\\' -or $p -match '^//') {
        Deny 'UNC / network / device paths are not a permitted write target'
    }

    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        Deny "the target path is not fully qualified: $p . Use an absolute path beginning with a drive letter and a separator, inside the caller's project root"
    }

    $afterDrive = $p -replace '^[A-Za-z]:', ''
    if ($afterDrive.Contains(':')) {
        Deny "the path contains a colon after the drive specifier (alternate data stream or malformed path): $p"
    }

    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($p) } catch {
        Deny "the target path could not be resolved: $p"
    }
    if ([string]::IsNullOrWhiteSpace($full)) { Deny "the target path resolved to nothing: $path" }

    $norm = ($full -replace '\\', '/').ToLowerInvariant() -replace '/+', '/'
    # Strip trailing dots/spaces from each segment, which Windows ignores (".git." == ".git").
    $norm = ($norm.Split('/') | ForEach-Object { $_.TrimEnd('. ') }) -join '/'
    $segs = $norm.Split('/')

    # ---- 8.3 short names: could alias a protected name, so deny outright --------------
    foreach ($s in $segs) {
        if ($s -match '~\d') {
            Deny "target contains an 8.3 short-name segment ('$s'), which could alias a protected directory. Use the long path: $full"
        }
    }

    # ---- denylist: directory names anywhere in the path ---------------------------------
    $badSegs = @('.git', '.claude', '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker', '.husky',
                 '.vscode', '.devcontainer', '.cargo')
    foreach ($s in $segs) {
        if ($badSegs -contains $s) {
            Deny "target is inside a protected '$s' directory: $full"
        }
    }

    # ---- denylist: file names that are auto-loaded as configuration or execution ------
    $leaf = $segs[-1]
    if ([string]::IsNullOrWhiteSpace($leaf)) { Deny "target looks like a directory, not a file: $full" }
    $badLeaves = @('.gitconfig', '.gitattributes', '.gitmodules', '.git-credentials',
                   '.npmrc', '.yarnrc', '.yarnrc.yml', '.pypirc', '.netrc', '_netrc',
                   '.bashrc', '.bash_profile', '.bash_login', '.bash_logout', '.profile',
                   '.zshrc', '.zshenv', '.zprofile', '.zlogin', '.envrc',
                   '.mcp.json', 'claude.md', 'claude.local.md',
                   'microsoft.powershell_profile.ps1', 'profile.ps1', 'microsoft.vscode_profile.ps1')
    if ($badLeaves -contains $leaf) {
        Deny "target file '$leaf' is on the protected-file denylist (auto-loaded configuration, credentials, or a shell profile): $full"
    }

    # ---- denylist: system and per-user auto-run locations ------------------------------
    $badPrefixes = @('c:/windows/', 'c:/program files/', 'c:/program files (x86)/', 'c:/programdata/')
    foreach ($b in $badPrefixes) {
        if ($norm.StartsWith($b)) { Deny "target is in a system directory: $full" }
    }
    $badInfixes = @('/appdata/', '/documents/windowspowershell/', '/documents/powershell/', '/start menu/programs/startup/')
    foreach ($b in $badInfixes) {
        if ($norm.Contains($b)) { Deny "target is in a protected per-user location ($b): $full" }
    }

    if ($segs.Count -le 2) { Deny "target is at a drive root, which is never a project file: $full" }

    # ---- reparse points: deny if the target or any existing ancestor is a link/junction --
    $cur = $full
    while (-not [string]::IsNullOrEmpty($cur)) {
        if (Test-Path -LiteralPath $cur) {
            $item = Get-Item -LiteralPath $cur -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Deny "target or one of its ancestors is a symlink/junction ($cur), which could redirect the write: $full"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ($parent -eq $cur) { break }
        $cur = $parent
    }

    exit 0
} catch {
    Deny ('the guard failed while evaluating the path (fail closed): ' + $_.Exception.Message)
}
