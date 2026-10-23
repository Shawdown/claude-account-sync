param(
    [Parameter(Position = 0)]
    [string]$Command = 'status',
    [Parameter(Position = 1)]
    [string]$Account,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

try {
    switch ($Command.ToLowerInvariant()) {
        'setup' { Invoke-Setup -Force:$Force }
        'switch' { Invoke-Switch $Account }
        'sync' { Invoke-SyncCommand -Quiet:$Quiet }
        'status' { Show-Status }
        'uninstall' { Invoke-Uninstall -Force:$Force }
        default { throw "Unknown command '$Command'. Use setup, switch, sync, status or uninstall." }
    }
}
catch {
    Write-Log "Error during '$Command': $($_.Exception.Message)"
    if (-not $Quiet) { Write-Host $_.Exception.Message -ForegroundColor Red }
    exit 1
}
