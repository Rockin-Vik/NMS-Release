<#
.SYNOPSIS
    Pull the latest main and roll it onto an already-installed NMS server.
.DESCRIPTION
    The update path for a box that 2-Setup-NMSServer.ps1 has already built once. Runs the
    stages that a code change needs, in order, and stops at the first failure:

        Clone      Set-SourceRef.ps1 - put <InstallRoot>\src on the requested PR or ref,
                   or back on the default branch when neither is given
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
.PARAMETER PullRequest
    Roll out a specific pull request instead of the default branch. Handed to
    Set-SourceRef.ps1, which fetches refs/pull/<N>/head and checks it out as pr/<N>.
    Re-run with the same number after new commits land on the PR to pick them up.

    Only the Clone stage reads it, so it does nothing with -From Build or later: the
    build then compiles whatever is already checked out. The summary line printed by
    the Clone stage is the record of which source was actually built.

.PARAMETER GitRef
    Roll out an arbitrary branch, tag or commit. Mutually exclusive with -PullRequest.

.PARAMETER Force
    Passed to Set-SourceRef.ps1: discard uncommitted changes in <InstallRoot>\src rather
    than refusing to switch refs. Only affects the Clone stage.

.PARAMETER SkipExport
    Skip the Export stage when no client file changed.
.PARAMETER NoStart
    Leave the services stopped when done.
.EXAMPLE
    .\Update-Server.ps1
    .\Update-Server.ps1 -From Migrate
    .\Update-Server.ps1 -SkipExport -NoStart
    .\Update-Server.ps1 -PullRequest 17
    .\Update-Server.ps1 -PullRequest 17 -From Build   # already checked out; just rebuild
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\NMS',
    [ValidateSet('Clone', 'Build', 'Runtime', 'Migrate', 'Patches', 'Health', 'Export')]
    [string] $From = 'Clone',
    [ValidateRange(1, 999999)]
    [int]    $PullRequest,
    [string] $GitRef,
    [switch] $Force,
    [switch] $SkipExport,
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'

$setup  = Join-Path $PSScriptRoot '2-Setup-NMSServer.ps1'
$srcRef = Join-Path $PSScriptRoot 'Set-SourceRef.ps1'
$server = Join-Path $InstallRoot 'server'
if (-not (Test-Path $setup))  { throw "2-Setup-NMSServer.ps1 not found next to this script." }
if (-not (Test-Path $srcRef)) { throw "Set-SourceRef.ps1 not found next to this script." }
if (-not (Test-Path $server)) { throw "$server does not exist - run 2-Setup-NMSServer.ps1 first." }
if ($PullRequest -and $GitRef) {
    throw '-PullRequest and -GitRef are mutually exclusive. Pass one or neither.'
}

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
        if ($stage -eq 'Clone') {
            # Clone is this script's own step, not a call into the setup script. Setup
            # clones once and stays on the default branch; moving the checkout to a PR or
            # a ref is a separate job with its own script, so an update can target one.
            # Splatted so an unset pin is absent rather than passed as 0 or "", which
            # ValidateRange would reject and which -GitRef would read as a ref named "".
            $extra = @{}
            if ($PullRequest) { $extra.PullRequest = $PullRequest }
            if ($GitRef)      { $extra.GitRef      = $GitRef }
            if ($Force)       { $extra.Force       = $true }
            & $srcRef -InstallRoot $InstallRoot @extra
        } else {
            & $setup -InstallRoot $InstallRoot -OnlyStage $stage
        }
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
Write-Host "Health-check output is under $InstallRoot\logs."

# Read the target from version.h rather than printing a literal. A hardcoded number goes stale
# the next time a migration lands - this line said 33 from 2026-09-06 until v48 shipped. Same
# parse 2-Setup-NMSServer.ps1 does before it waits for migrations. Best-effort on purpose: the
# update already succeeded by the time this prints, so an unreadable version.h loses the number,
# not the run.
$versionH = Join-Path $InstallRoot 'src\Release-NMS-Server\common\version.h'
$target   = $null
if (Test-Path $versionH) {
    $vh = Get-Content $versionH -Raw
    if ($vh -match 'CUSTOM_BINARY_DATABASE_VERSION\s+(\d+)') { $target = [int]$Matches[1] }
}
if ($target) {
    Write-Host "Confirm db_version.custom_version reads $target and every 'expect' line matches."
} else {
    Write-Host "Confirm db_version.custom_version matches CUSTOM_BINARY_DATABASE_VERSION in common\version.h, and every 'expect' line matches."
}
# custom_version is a claim, not a fact (CODEBASE.md 4.3): early entries used bare UPDATEs that
# no-opped silently and still stamped. The 'expect' lines are the evidence, and they do not cover
# v26 or v29-v32 - a clean run is not proof those landed.
Write-Host "custom_version alone is not proof - the 'expect' lines are. No probes exist for v26 or v29-v32."
