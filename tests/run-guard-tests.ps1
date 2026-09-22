<#
.SYNOPSIS
    Runs a CCAM guard against a file of test cases and reports which verdicts
    it got wrong.

.DESCRIPTION
    A CCAM guard is a PreToolUse hook: it reads the hook payload as JSON on
    standard input and exits 0 to allow or 2 to deny. That makes it directly
    testable - feed it a command, check the exit code.

    Each case file line is "ALLOW <command>" or "DENY <command>", stating the
    verdict the guard is expected to return.

    Exit code: 0 if every case passed, 1 if any failed.

.EXAMPLE
    pwsh -File tests/run-guard-tests.ps1 `
         -Guard guards/fim-readonly-guard.ps1 `
         -Cases tests/cases/fim-readonly-guard.cases
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Guard,
    [Parameter(Mandatory = $true)] [string] $Cases,

    # Which hook field carries the payload. Command guards inspect
    # tool_input.command; the AMA write guard inspects tool_input.file_path.
    [ValidateSet('command', 'file_path')]
    [string] $Field = 'command',

    # Print every case, not just the failures.
    [switch] $ShowAll
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Guard)) { Write-Error "Guard not found: $Guard"; exit 1 }
if (-not (Test-Path $Cases)) { Write-Error "Case file not found: $Cases"; exit 1 }

# The interpreter running this script also runs the guard, so the suite works
# on Windows PowerShell and on PowerShell 7 alike.
$pwshExe = (Get-Process -Id $PID).Path

function Invoke-Guard {
    param([string] $Payload)

    $payloadJson = @{ tool_input = @{ $Field = $Payload } } |
                   ConvertTo-Json -Compress -Depth 5

    $tmpOut = [IO.Path]::GetTempFileName()
    $tmpErr = [IO.Path]::GetTempFileName()
    $tmpIn  = [IO.Path]::GetTempFileName()
    try {
        # -NoNewline: a trailing newline is harmless, but keeping stdin exact
        # means the guard sees precisely what Claude Code would send.
        [IO.File]::WriteAllText($tmpIn, $payloadJson)

        $p = Start-Process -FilePath $pwshExe `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Resolve-Path $Guard).Path) `
                -RedirectStandardInput $tmpIn `
                -RedirectStandardOutput $tmpOut `
                -RedirectStandardError $tmpErr `
                -NoNewWindow -PassThru -Wait

        return $p.ExitCode
    }
    finally {
        Remove-Item $tmpIn, $tmpOut, $tmpErr -ErrorAction SilentlyContinue
    }
}

$total = 0
$passed = 0
$failures = New-Object System.Collections.Generic.List[object]

Write-Host ""
Write-Host "Guard : $Guard"
Write-Host "Cases : $Cases"
Write-Host ""

foreach ($line in Get-Content -LiteralPath $Cases) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    if ($trimmed -notmatch '^(ALLOW|DENY)\s+(.+)$') {
        Write-Warning "Skipping unparseable line: $trimmed"
        continue
    }

    $expected = $Matches[1]
    $payload  = $Matches[2]
    $total++

    $code   = Invoke-Guard -Payload $payload
    $actual = if ($code -eq 2) { 'DENY' } else { 'ALLOW' }

    if ($actual -eq $expected) {
        $passed++
        if ($ShowAll) { Write-Host ("  ok    {0,-5}  {1}" -f $expected, $payload) }
    }
    else {
        $failures.Add([pscustomobject]@{
            Expected = $expected
            Actual   = $actual
            Command  = $payload
            Kind     = if ($expected -eq 'ALLOW') { 'FALSE ALARM   ' } else { 'MISSED MUTATION' }
        })
        Write-Host ("  FAIL  expected {0,-5} got {1,-5}  {2}" -f $expected, $actual, $payload)
    }
}

$failed = $total - $passed
$rate   = if ($total -gt 0) { [math]::Round(100.0 * $passed / $total, 1) } else { 0 }

Write-Host ""
Write-Host "-------------------------------------------------------------"
Write-Host ("  {0} cases   {1} passed   {2} failed   ({3}% correct)" -f $total, $passed, $failed, $rate)

if ($failures.Count -gt 0) {
    $falseAlarms = @($failures | Where-Object { $_.Expected -eq 'ALLOW' }).Count
    $missed      = @($failures | Where-Object { $_.Expected -eq 'DENY'  }).Count
    Write-Host ""
    Write-Host ("  False alarms    : {0}   (safe command wrongly blocked)"   -f $falseAlarms)
    Write-Host ("  Missed mutations: {0}   (dangerous command allowed through)" -f $missed)
    Write-Host ""
    Write-Host "  A missed mutation is the serious kind: the guard's promise did not hold."
}
Write-Host "-------------------------------------------------------------"
Write-Host ""

exit $(if ($failed -gt 0) { 1 } else { 0 })
