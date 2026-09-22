<#
.SYNOPSIS
    Runs every CCAM guard against its case file.

.EXAMPLE
    pwsh -File tests/run-all.ps1
#>
[CmdletBinding()]
param([switch] $ShowAll)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'run-guard-tests.ps1'

$suites = @(
    @{ Guard = 'guards/fim-readonly-guard.ps1'; Cases = 'tests/cases/fim-readonly-guard.cases'; Field = 'command'   },
    @{ Guard = 'guards/test-runner-guard.ps1';  Cases = 'tests/cases/test-runner-guard.cases';  Field = 'command'   },
    @{ Guard = 'guards/ama-writeguard.ps1';     Cases = 'tests/cases/ama-writeguard.cases';     Field = 'file_path' }
)

$anyFailed = $false

foreach ($s in $suites) {
    $args = @(
        '-NoProfile', '-File', $runner,
        '-Guard', (Join-Path $root $s.Guard),
        '-Cases', (Join-Path $root $s.Cases),
        '-Field', $s.Field
    )
    if ($ShowAll) { $args += '-ShowAll' }

    & (Get-Process -Id $PID).Path @args
    if ($LASTEXITCODE -ne 0) { $anyFailed = $true }
}

if ($anyFailed) {
    Write-Host "One or more suites failed." -ForegroundColor Yellow
    exit 1
}

Write-Host "All suites passed." -ForegroundColor Green
exit 0
