<#
.SYNOPSIS
    Push quest scripts and plugins from the repo to the running server.

.DESCRIPTION
    2-Setup-NMSServer.ps1 copies Release-NMS-Quests and Release-NMS-Plugins into
    <InstallRoot>\server\quests once, at install time. After that the server reads
    its own copy, not the repo. Run this after editing anything under
    Release-NMS-Quests or Release-NMS-Plugins, then type  #reload quest  in game.

    Only changed files are copied (robocopy /E, no /MIR - nothing on the server
    side is deleted).

.PARAMETER InstallRoot
    Server install root. Default C:\NMS (same as 2-Setup-NMSServer.ps1).

.PARAMETER RepoRoot
    Root of the NMS-Release checkout. Defaults to two levels above this script.

.EXAMPLE
    .\Sync-Quests.ps1
    .\Sync-Quests.ps1 -InstallRoot D:\eqemu
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\NMS',
    [string] $RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$src = @{
    Quests  = Join-Path $RepoRoot 'Release-NMS-Quests'
    Plugins = Join-Path $RepoRoot 'Release-NMS-Plugins'
}
$dst = @{
    Quests  = Join-Path $InstallRoot 'server\quests'
    Plugins = Join-Path $InstallRoot 'server\quests\plugins'
}

foreach ($k in 'Quests', 'Plugins') {
    if (-not (Test-Path $src[$k])) { throw "Repo folder not found: $($src[$k])" }
}
if (-not (Test-Path (Join-Path $InstallRoot 'server'))) {
    throw "No server at $InstallRoot\server. Pass -InstallRoot if you installed elsewhere."
}

foreach ($k in 'Quests', 'Plugins') {
    Write-Host "Syncing $k -> $($dst[$k])" -ForegroundColor Cyan
    # /E recurse, /XO skip files newer on the server side, /XD skip .git and (for quests) the plugins dir
    $xd = @('.git'); if ($k -eq 'Quests') { $xd += 'plugins' }
    robocopy $src[$k] $dst[$k] /E /NJH /NJS /NDL /NC /NS /NP /XD $xd | Where-Object { $_ -match '\S' }
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $k (exit $LASTEXITCODE)" }
}

Write-Host "`nDone. In game (GM): #reload quest" -ForegroundColor Green
