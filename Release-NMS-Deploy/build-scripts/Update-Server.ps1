<#
.SYNOPSIS
    Pull the latest main and roll it onto an already-installed NMS server.
.DESCRIPTION
    The update path for a box that 2-Setup-NMSServer.ps1 has already built once. Runs the
    stages that a code change needs, in order, and stops at the first failure:

        Clone      git fetch + pull in <InstallRoot>\src
        Build      CMake + MSBuild, Release/x64 (~30 min)
        Runtime    Copy binaries, quests and plugins into <InstallRoot>\server
        Migrate    Boot world so the custom manifest applies any new versions
        Patches    Apply the loose .sql seeds (Fabled roster, loot buckets, ...)
        Health     nms_content_health_check.sql - read the output, custom_version lies
        Export     Refresh the client files (needed whenever dinput8.dll changes)

    Each stage stops the NMS-* services itself. The server is started again at the end
    unless -NoStart is given. Every stage is re-runnable: if one fails, fix the cause and
    run this script again with -From <Stage>.
.PARAMETER InstallRoot
    Server install root. Default C:\NMS (same as 2-Setup-NMSServer.ps1).
.PARAMETER From
    Resume from this stage instead of starting at Clone.
.PARAMETER SkipExport
    Skip the Export stage when no client file changed.
.PARAMETER NoStart
    Leave the services stopped when done.
.EXAMPLE
    .\Update-Server.ps1
    .\Update-Server.ps1 -From Migrate
    .\Update-Server.ps1 -SkipExport -NoStart
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\NMS',
    [ValidateSet('Clone', 'Build', 'Runtime', 'Migrate', 'Patches', 'Health', 'Export')]
    [string] $From = 'Clone',
    [switch] $SkipExport,
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'

$setup  = Join-Path $PSScriptRoot '2-Setup-NMSServer.ps1'
$server = Join-Path $InstallRoot 'server'
if (-not (Test-Path $setup))  { throw "2-Setup-NMSServer.ps1 not found next to this script." }
if (-not (Test-Path $server)) { throw "$server does not exist - run 2-Setup-NMSServer.ps1 first." }

$stages = @('Clone', 'Build', 'Runtime', 'Migrate', 'Patches', 'Health', 'Export')
$stages = $stages[$stages.IndexOf($From)..($stages.Count - 1)]
if ($SkipExport) { $stages = $stages | Where-Object { $_ -ne 'Export' } }

$started = Get-Date
Write-Host ''
Write-Host "NMS server update  -  $($stages -join ' > ')" -ForegroundColor Cyan
Write-Host "Install root: $InstallRoot"
Write-Host ''

foreach ($stage in $stages) {
    $t = Get-Date
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "  $stage" -ForegroundColor Yellow
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    try {
        & $setup -InstallRoot $InstallRoot -OnlyStage $stage
    } catch {
        Write-Host ''
        Write-Host "FAILED in stage '$stage': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Fix the cause, then resume with:  .\Update-Server.ps1 -From $stage" -ForegroundColor Red
        exit 1
    }
    $mins = [math]::Round(((Get-Date) - $t).TotalMinutes, 1)
    Write-Host "  $stage done in $mins min" -ForegroundColor Green
    Write-Host ''
}

if (-not $NoStart) {
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host '  Start' -ForegroundColor Yellow
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Push-Location $server
    try {
        & .\start-server.ps1
        & .\status-server.ps1
    } finally {
        Pop-Location
    }
}

$total = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Write-Host ''
Write-Host "Update complete in $total min." -ForegroundColor Cyan
Write-Host "Health-check output is under $InstallRoot\logs - confirm db_version reads 33 and every 'expect' line matches."
