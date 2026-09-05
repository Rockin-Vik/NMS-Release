<#
.SYNOPSIS
    Removes Strawberry Perl and every artefact of a failed DBD driver build, so
    1-Install-Prerequisites.ps1 can install the pinned version cleanly.

.DESCRIPTION
    Run this when the wrong Perl version is installed - typically 5.40 or newer, which
    breaks in two ways at once:

      * zone.exe EMBEDS whichever Perl CMake finds. EQEmu targets 5.24 (Windows) or
        5.32 (Linux), and its embedded-Perl code predates the API churn in newer Perls.
      * Strawberry 5.40+ switched to UCRT, and DBD::MariaDB still references the
        msvcrt-era internal __pioinfo, so it dies at link with
        "undefined reference to `__imp___pioinfo'".

    What this removes:

      1. Every installed Strawberry Perl (via its own MSI uninstaller)
      2. Leftover install directories the uninstaller does not clean up
      3. The cpanm build cache and work logs
      4. Scratch build directories from manual DBD attempts
      5. Stale PATH entries pointing at the removed Perl

    It does NOT touch MariaDB, Git, CMake, Visual Studio Build Tools, or anything the
    server needs. Only Perl and its build residue.

    Nothing is removed without showing you the list first, unless you pass -Force.

.PARAMETER WhatIf
    Show everything that would be removed and exit. Changes nothing. Start here.

.PARAMETER Force
    Skip the confirmation prompt. For unattended re-runs.

.PARAMETER KeepCpanCache
    Leave ~/.cpanm alone. Keeps downloaded tarballs, so a rebuild re-fetches less - but
    also keeps the stale build logs that make diagnosing the next failure confusing.

.EXAMPLE
    .\0-Reset-Perl.ps1 -WhatIf
    See what would go, without touching anything.

.EXAMPLE
    .\0-Reset-Perl.ps1
    Show the plan, ask once, then remove it.

.NOTES
    Needs Administrator. Open a NEW PowerShell window afterwards so it picks up the
    corrected PATH, then run 1-Install-Prerequisites.ps1.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Force,
    [switch] $KeepCpanCache
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Native commands (msiexec) return non-zero for benign reasons and write to stderr; under
# 'Stop' PowerShell would escalate both into terminating errors before our own checks run.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Head {
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

function Write-Step { param([string] $Text) Write-Host "  -> $Text" -ForegroundColor Gray }
function Write-Ok   { param([string] $Text) Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string] $Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Invoke-Native {
    param([Parameter(Mandatory)] [scriptblock] $Command, [switch] $Show)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Show) { & $Command 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        else       { & $Command 2>&1 | Out-Null }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

function Get-InstalledPerl {
    <#
        Finds Strawberry Perl (and ActivePerl, which causes the same embedding problem)
        via the uninstall registry, 64- and 32-bit views.

        @() on every result: a single match would otherwise be a bare object, and .Count
        on a scalar throws under Set-StrictMode -Version Latest.
    #>
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $found = @()
    foreach ($root in $roots) {
        $keys = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSObject.Properties.Name -contains 'DisplayName' -and
                $_.DisplayName -match 'Strawberry Perl|ActivePerl'
            })
        foreach ($k in $keys) {
            $found += [pscustomobject]@{
                Name        = $k.DisplayName
                Version     = if ($k.PSObject.Properties.Name -contains 'DisplayVersion') { $k.DisplayVersion } else { '?' }
                ProductCode = $k.PSChildName
                Location    = if ($k.PSObject.Properties.Name -contains 'InstallLocation') { $k.InstallLocation } else { $null }
            }
        }
    }
    return $found
}

function Get-PerlLeftovers {
    <#
        Directories that survive the MSI uninstall, plus scratch from manual builds.
        Only paths that actually exist are returned.
    #>
    $candidates = @(
        @{ Path = 'C:\Strawberry';                             What = 'Strawberry Perl install tree' }
        @{ Path = 'C:\dbd-build';                              What = 'manual DBD build scratch' }
        @{ Path = (Join-Path $env:TEMP 'nms-dbd-build');        What = 'script DBD build scratch' }
        @{ Path = (Join-Path $env:USERPROFILE 'perl5');         What = 'local::lib module tree' }
    )

    if (-not $KeepCpanCache) {
        $candidates += @{ Path = (Join-Path $env:USERPROFILE '.cpanm'); What = 'cpanm cache and build logs' }
        $candidates += @{ Path = (Join-Path $env:USERPROFILE '.cpan');  What = 'CPAN.pm build tree' }
    }

    return @($candidates |
        Where-Object { Test-Path $_.Path } |
        ForEach-Object {
            $size = 0
            try {
                $size = (Get-ChildItem $_.Path -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            } catch { }
            [pscustomobject]@{
                Path   = $_.Path
                What   = $_.What
                SizeMB = if ($size) { [math]::Round($size / 1MB, 1) } else { 0 }
            }
        })
}

function Get-StalePathEntries {
    <#
        PATH entries pointing into a Perl tree. Matched on the directory, not on the word
        'perl' anywhere - so C:\Tools\perl-scripts is left alone.
    #>
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $entries = @($machine -split ';' | Where-Object { $_ })
    return @($entries | Where-Object {
        $_ -match '\\Strawberry\\' -or $_ -match '\\Strawberry$' -or $_ -match '\\ActivePerl'
    })
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

function Remove-PerlInstall {
    param([Parameter(Mandatory)] $Perl)

    Write-Step "Uninstalling $($Perl.Name) $($Perl.Version)..."

    # Product code form means it is an MSI; /x with /qn is the silent uninstall.
    if ($Perl.ProductCode -match '^\{[0-9A-Fa-f-]+\}$') {
        $code = Invoke-Native -Show { msiexec /x $Perl.ProductCode /qn /norestart }
        # 3010 = success, reboot required. 1605 = already gone.
        if ($code -in 0, 1605, 3010) {
            if ($code -eq 3010) { Write-Warn 'Uninstalled; Windows wants a reboot to finish.' }
            Write-Ok "Removed $($Perl.Name)"
            return $true
        }
        Write-Bad "msiexec returned $code for $($Perl.Name)"
        return $false
    }

    Write-Warn "$($Perl.Name) has no MSI product code - remove it via Programs and Features."
    return $false
}

function Remove-Leftover {
    param([Parameter(Mandatory)] $Item)
    try {
        Remove-Item -Path $Item.Path -Recurse -Force -ErrorAction Stop
        Write-Ok "Removed $($Item.Path)"
        return $true
    } catch {
        Write-Warn "Could not remove $($Item.Path): $($_.Exception.Message)"
        Write-Warn 'A file may be locked - close any shell sitting in that directory.'
        return $false
    }
}

function Remove-StalePath {
    param([string[]] $Entries)

    if ($Entries.Count -eq 0) { return }

    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')

    # Back the old value up before touching it. PATH corruption is painful to undo from
    # memory, and this is the one genuinely irreversible thing the script does.
    $backup = Join-Path $env:ProgramData "nms-path-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    Set-Content -Path $backup -Value $machine -Encoding UTF8
    Write-Step "PATH backed up to $backup"

    $kept = @($machine -split ';' | Where-Object { $_ -and ($Entries -notcontains $_) })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')

    foreach ($e in $Entries) { Write-Ok "Removed from PATH: $e" }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Head 'Perl reset - removes Strawberry Perl and DBD build residue'

    if (-not (Test-Admin)) {
        throw 'Must run as Administrator. Right-click PowerShell -> Run as administrator.'
    }

    # ---- Survey ----------------------------------------------------------
    $perls     = @(Get-InstalledPerl)
    $leftovers = @(Get-PerlLeftovers)
    $stalePath = @(Get-StalePathEntries)

    Write-Head 'What will be removed'

    if ($perls.Count -gt 0) {
        Write-Host '  Installed Perl:' -ForegroundColor White
        foreach ($p in $perls) { Write-Host "    - $($p.Name) $($p.Version)" -ForegroundColor Yellow }
    } else {
        Write-Step 'No Strawberry/ActivePerl installation found in the registry.'
    }

    if ($leftovers.Count -gt 0) {
        Write-Host ''
        Write-Host '  Directories:' -ForegroundColor White
        foreach ($l in $leftovers) {
            Write-Host ("    - {0,-46} {1,7} MB  ({2})" -f $l.Path, $l.SizeMB, $l.What) -ForegroundColor Yellow
        }
    } else {
        Write-Step 'No leftover directories.'
    }

    if ($stalePath.Count -gt 0) {
        Write-Host ''
        Write-Host '  PATH entries:' -ForegroundColor White
        foreach ($e in $stalePath) { Write-Host "    - $e" -ForegroundColor Yellow }
    } else {
        Write-Step 'No stale PATH entries.'
    }

    if ($perls.Count -eq 0 -and $leftovers.Count -eq 0 -and $stalePath.Count -eq 0) {
        Write-Host ''
        Write-Ok 'Nothing to clean - this box is already in a fresh state.'
        Write-Host ''
        Write-Host '  Next: .\1-Install-Prerequisites.ps1' -ForegroundColor Cyan
        exit 0
    }

    Write-Host ''
    Write-Step 'NOT touched: MariaDB, Git, CMake, VS Build Tools, the repo, the database.'

    # ---- Confirm ---------------------------------------------------------
    if ($WhatIfPreference) {
        Write-Host ''
        Write-Warn 'Dry run (-WhatIf) - nothing was changed.'
        exit 0
    }

    if (-not $Force) {
        Write-Host ''
        $answer = Read-Host '  Proceed with removal? (y/N)'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host ''
            Write-Step 'Cancelled - nothing was changed.'
            exit 0
        }
    }

    # ---- Remove ----------------------------------------------------------
    $problems = @()

    if ($perls.Count -gt 0) {
        Write-Head 'Uninstalling Perl'
        foreach ($p in $perls) {
            if (-not (Remove-PerlInstall -Perl $p)) { $problems += $p.Name }
        }
    }

    # Re-survey: the uninstaller removes most of C:\Strawberry, so sizes and existence
    # both change. Deleting a path that is already gone would just add noise.
    $leftovers = @(Get-PerlLeftovers)
    if ($leftovers.Count -gt 0) {
        Write-Head 'Removing leftover directories'
        foreach ($l in $leftovers) {
            if (-not (Remove-Leftover -Item $l)) { $problems += $l.Path }
        }
    }

    $stalePath = @(Get-StalePathEntries)
    if ($stalePath.Count -gt 0) {
        Write-Head 'Cleaning PATH'
        Remove-StalePath -Entries $stalePath
    }

    # ---- Verify ----------------------------------------------------------
    Write-Head 'Result'

    $remaining = @(Get-InstalledPerl)
    if ($remaining.Count -eq 0) { Write-Ok 'No Perl installation remains.' }
    else {
        Write-Warn 'Still registered:'
        foreach ($r in $remaining) { Write-Host "    - $($r.Name) $($r.Version)" -ForegroundColor Yellow }
    }

    if ($problems.Count -gt 0) {
        Write-Warn "$($problems.Count) item(s) could not be removed:"
        foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Yellow }
        Write-Warn 'Usually a locked file. Close other shells, or reboot, and re-run.'
    }

    Write-Host ''
    Write-Host @"
  Next steps:

    1. Open a NEW PowerShell window as Administrator.
       This one still has the old PATH in its environment.

    2. Confirm Perl is gone:
           Get-Command perl -ErrorAction SilentlyContinue

    3. Run the installer - it pins Strawberry Perl 5.32.1.1, which is
       pre-UCRT and is what EQEmu's embedded Perl expects:
           .\1-Install-Prerequisites.ps1
"@ -ForegroundColor Cyan

    exit $(if ($problems.Count -gt 0) { 1 } else { 0 })
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}
