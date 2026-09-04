<#
.SYNOPSIS
    Stage 1 of 2 - installs everything the NMS EverQuest server needs to build and run.

.DESCRIPTION
    Audits a fresh Windows box, then installs whatever is missing:

        Visual Studio 2022 Build Tools (C++ workload)   ~12 GB, needed to compile the server
        CMake                                            build system
        Git                                              to clone the repo
        7-Zip                                            to unpack the 540 MB database dump
        MariaDB 11 LTS                                   the database, bound to loopback only
        Strawberry Perl                                  the quest scripting engine
        Perl CPAN: DBI, DBD::mysql, JSON, Switch         required by the NMS plugins

    Every step is skip-if-present, so re-running is safe and cheap. Nothing is uninstalled
    or downgraded. When a component is already present at an acceptable version the script
    says so and moves on.

    Run this FIRST. Then run 2-Setup-NMSServer.ps1.

.PARAMETER CheckOnly
    Audit and report, install nothing. Use this to see where the box stands.

.PARAMETER SkipBuildTools
    Skip Visual Studio Build Tools. Only sensible if you intend to build the server
    elsewhere and copy binaries in - note that the Strawberry Perl version on THIS box must
    then match the one the binaries were linked against, or zone.exe will not start.

.PARAMETER MariaDbRootPassword
    Root password for a new MariaDB install. If omitted, one is generated and written to
    the credentials file. Ignored when MariaDB is already installed.

.PARAMETER CredentialFile
    Where to record generated secrets. Default: C:\NMS\credentials.txt

    Stage 2 derives this same path from its -InstallRoot, so if you change one you must
    change the other to match. Otherwise stage 2 will not find the MariaDB root password
    recorded here and will prompt for it.

.EXAMPLE
    .\1-Install-Prerequisites.ps1 -CheckOnly
    Report what is missing without changing anything.

.EXAMPLE
    .\1-Install-Prerequisites.ps1
    Install everything missing. Expect 30-60 minutes on a fresh box, mostly Build Tools.

.NOTES
    Target:  Windows Server 2025 (also fine on 2019/2022 and Windows 10/11)
    Needs:   Administrator, internet access
    Author:  Generated for the NMS-Release deployment. See CODEBASE.md for context.

    UNTESTED ON A REAL VPS. Treat the first run as supervised. A full transcript is written
    next to the credentials file so any failure can be diagnosed after the fact.
#>

[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $SkipBuildTools,
    [string] $MariaDbRootPassword,
    [string] $CredentialFile = 'C:\NMS\credentials.txt'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:MinCMakeVersion  = [version]'3.12'
$script:MinMariaDbVersion = [version]'10.6'
$script:RequiredCpanModules = @('DBI', 'DBD::mysql', 'JSON', 'Switch')

# winget package ids. Pinned deliberately - see README for how to bump these.
$script:Packages = @{
    BuildTools = 'Microsoft.VisualStudio.2022.BuildTools'
    CMake      = 'Kitware.CMake'
    Git        = 'Git.Git'
    SevenZip   = '7zip.7zip'
    MariaDB    = 'MariaDB.Server'
    Perl       = 'StrawberryPerl.StrawberryPerl'
}

$script:Results = [System.Collections.Generic.List[object]]::new()

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

function Add-Result {
    param(
        [string] $Component,
        [ValidateSet('Present', 'Installed', 'Missing', 'Failed', 'Skipped')]
        [string] $State,
        [string] $Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Component = $Component
        State     = $State
        Detail    = $Detail
    })
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# winget and MSI installers extend the machine PATH, but our already-running process keeps
# the PATH it started with. Re-read it after every install or nothing we just installed is
# findable for the rest of the run.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Command {
    param([string] $Name)
    return [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-NewPassword {
    param([int] $Length = 28)
    # Deliberately excludes quotes, backslash, backtick, $, and shell metacharacters. This
    # password ends up inside JSON config, a MySQL statement and a PowerShell string, and
    # escaping it correctly through all three is not worth the risk.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_=+.'
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Save-Credential {
    param([string] $Label, [string] $Value)

    $dir = Split-Path -Parent $CredentialFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (-not (Test-Path $CredentialFile)) {
        @(
            '# NMS server credentials - generated by 1-Install-Prerequisites.ps1',
            "# Created $(Get-Date -Format 'u')",
            '# Keep this file. Back it up somewhere off this machine.',
            ''
        ) | Set-Content -Path $CredentialFile -Encoding UTF8

        # Administrators + SYSTEM only. Break inheritance so the box's default ACL,
        # which usually grants Users read, does not apply.
        $acl = Get-Acl $CredentialFile
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($who in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $who, 'FullControl', 'Allow'))
        }
        Set-Acl -Path $CredentialFile -AclObject $acl
    }

    Add-Content -Path $CredentialFile -Value "$Label = $Value" -Encoding UTF8
    Write-Step "Recorded '$Label' in $CredentialFile"
}

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------

function Test-Winget {
    if (-not (Test-Command 'winget')) { return $false }
    try { winget --version *> $null; return $LASTEXITCODE -eq 0 } catch { return $false }
}

function Install-WithWinget {
    param(
        [string] $PackageId,
        [string] $Component,
        [string[]] $Override = @()
    )

    Write-Step "Installing $Component ($PackageId) via winget..."

    # Not $args - that is an automatic variable, and shadowing it is a trap for the next
    # person to edit this function.
    $cliArgs = @(
        'install', '--id', $PackageId,
        '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Override.Count -gt 0) { $cliArgs += @('--override', ($Override -join ' ')) }

    & winget @cliArgs
    $code = $LASTEXITCODE

    # winget returns a pile of non-zero codes that are not failures.
    #   0x8A150061 (-1978335135) no applicable upgrade / already installed
    #   0x8A15002B (-1978335189) already installed
    #   0x8A150109 (-1978334967) reboot required to finish
    $benign = @(0, -1978335135, -1978335189, -1978334967)

    if ($code -notin $benign) {
        throw "winget failed for $Component with exit code $code (0x$('{0:X8}' -f $code))"
    }
    if ($code -eq -1978334967) {
        Write-Warn "$Component installed but Windows wants a reboot to finish."
    }

    Update-SessionPath
}

# ---------------------------------------------------------------------------
# Individual component checks
# ---------------------------------------------------------------------------

function Resolve-VsInstall {
    <#
        vswhere is the only supported way to find a VS install. It ships with any VS
        Installer, at a fixed path. -products * covers Build Tools as well as full VS.
        We require the native x64 C++ toolset component specifically, because the
        "Desktop development with C++" workload id alone does not guarantee it.
    #>
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }

    $json = & $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -format json 2>$null

    if (-not $json) { return $null }

    $parsed = $json | ConvertFrom-Json
    if (-not $parsed -or $parsed.Count -eq 0) { return $null }
    return $parsed[0]
}

function Invoke-CheckBuildTools {
    Write-Head 'Visual Studio 2022 Build Tools (C++)'

    if ($SkipBuildTools) {
        Write-Warn 'Skipped by -SkipBuildTools.'
        Write-Warn 'You must supply prebuilt binaries AND match this box''s Perl version.'
        Add-Result 'VS Build Tools' 'Skipped' '-SkipBuildTools'
        return
    }

    $vs = Resolve-VsInstall
    if ($vs) {
        Write-Ok "$($vs.displayName) $($vs.installationVersion)"
        Write-Step "at $($vs.installationPath)"
        Add-Result 'VS Build Tools' 'Present' $vs.installationVersion
        return
    }

    Write-Bad 'Not found (no install with the native x64 C++ toolset).'
    if ($CheckOnly) { Add-Result 'VS Build Tools' 'Missing'; return }

    Write-Warn 'This is the big one: roughly 12 GB and 20-40 minutes. Be patient.'

    # --quiet --wait --norestart makes the VS bootstrapper synchronous. Without --wait it
    # returns immediately and the rest of this script races an install still in flight.
    Install-WithWinget -PackageId $script:Packages.BuildTools -Component 'VS Build Tools' -Override @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        '--includeRecommended'
    )

    $vs = Resolve-VsInstall
    if ($vs) {
        Write-Ok "Installed: $($vs.displayName) $($vs.installationVersion)"
        Add-Result 'VS Build Tools' 'Installed' $vs.installationVersion
    } else {
        Write-Bad 'Install reported success but vswhere still cannot find the C++ toolset.'
        Write-Warn 'A reboot is sometimes needed. Reboot and re-run this script.'
        Add-Result 'VS Build Tools' 'Failed' 'not detected post-install'
    }
}

function Invoke-CheckCMake {
    Write-Head 'CMake'

    # Prefer CMake on PATH; fall back to the copy bundled inside VS, which is what
    # build-windows.bat does. Either satisfies the build.
    $found = $null
    if (Test-Command 'cmake') {
        $raw = (& cmake --version 2>$null | Select-Object -First 1)
        if ($raw -match '(\d+)\.(\d+)\.(\d+)') {
            $found = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    }

    if (-not $found) {
        $vs = Resolve-VsInstall
        if ($vs) {
            $bundled = Join-Path $vs.installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $bundled) {
                Write-Ok "Using the CMake bundled with Visual Studio"
                Write-Step "at $bundled"
                Add-Result 'CMake' 'Present' 'bundled with VS'
                return
            }
        }
    }

    if ($found -and $found -ge $script:MinCMakeVersion) {
        Write-Ok "CMake $found (need $($script:MinCMakeVersion)+)"
        Add-Result 'CMake' 'Present' "$found"
        return
    }

    if ($found) { Write-Bad "CMake $found is older than $($script:MinCMakeVersion)." }
    else        { Write-Bad 'Not found.' }

    if ($CheckOnly) { Add-Result 'CMake' 'Missing'; return }

    Install-WithWinget -PackageId $script:Packages.CMake -Component 'CMake'

    if (Test-Command 'cmake') {
        $v = (& cmake --version 2>$null | Select-Object -First 1)
        Write-Ok "Installed: $v"
        Add-Result 'CMake' 'Installed' $v
    } else {
        Write-Warn 'CMake installed but not yet on PATH. It will be after a new shell.'
        Add-Result 'CMake' 'Installed' 'PATH refresh pending'
    }
}

function Invoke-CheckSimpleTool {
    param(
        [string] $Component,
        [string] $CommandName,
        [string] $PackageId,
        [string[]] $ExtraProbePaths = @()
    )

    Write-Head $Component

    if (Test-Command $CommandName) {
        $ver = try { (& $CommandName --version 2>$null | Select-Object -First 1) } catch { 'installed' }
        Write-Ok "$ver"
        Add-Result $Component 'Present' "$ver"
        return
    }

    foreach ($p in $ExtraProbePaths) {
        if (Test-Path $p) {
            Write-Ok "Found at $p"
            Write-Warn 'Present but not on PATH; stage 2 probes the fixed path too.'
            Add-Result $Component 'Present' $p
            return
        }
    }

    Write-Bad 'Not found.'
    if ($CheckOnly) { Add-Result $Component 'Missing'; return }

    Install-WithWinget -PackageId $PackageId -Component $Component

    if ((Test-Command $CommandName) -or ($ExtraProbePaths | Where-Object { Test-Path $_ })) {
        Write-Ok 'Installed.'
        Add-Result $Component 'Installed'
    } else {
        Write-Warn 'Installed but not yet visible. Should resolve in a new shell.'
        Add-Result $Component 'Installed' 'PATH refresh pending'
    }
}

function Get-MariaDbService {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(MariaDB|MySQL)' } |
        Select-Object -First 1
}

function Resolve-MysqlClient {
    <#
        Returns a path to mysql.exe (or mariadb.exe). MariaDB's MSI does not reliably put
        its bin/ on the machine PATH, so probe the standard install roots as well.
    #>
    foreach ($n in 'mysql', 'mariadb') {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    $roots = @(
        (Join-Path $env:ProgramFiles 'MariaDB*'),
        (Join-Path ${env:ProgramFiles(x86)} 'MariaDB*'),
        (Join-Path $env:ProgramFiles 'MySQL\MySQL Server*')
    )
    foreach ($root in $roots) {
        $hit = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                foreach ($exe in 'mysql.exe', 'mariadb.exe') {
                    $p = Join-Path $_.FullName "bin\$exe"
                    if (Test-Path $p) { $p }
                }
            } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Invoke-CheckMariaDb {
    Write-Head 'MariaDB'

    $svc = Get-MariaDbService
    $client = Resolve-MysqlClient

    if ($svc -and $client) {
        $verLine = try { (& $client --version 2>$null) } catch { '' }
        Write-Ok "Service '$($svc.Name)' is $($svc.Status)"
        Write-Step "client: $client"
        if ($verLine) { Write-Step $verLine.Trim() }

        if ($svc.Status -ne 'Running') {
            if ($CheckOnly) {
                Write-Warn 'Service is not running. Stage 2 will need it up.'
            } else {
                Write-Step 'Starting the service...'
                Start-Service -Name $svc.Name
                Write-Ok 'Started.'
            }
        }

        # Harden pre-existing installs too, not just ones we install ourselves. This is
        # the highest-value hardening step on the box and it is exactly the re-run case
        # where it would otherwise be silently skipped.
        if (-not $CheckOnly) { Set-MariaDbLoopbackOnly }
        else { Test-MariaDbLoopbackOnly }

        Add-Result 'MariaDB' 'Present' $svc.Name
        return
    }

    Write-Bad 'Not found.'
    if ($CheckOnly) { Add-Result 'MariaDB' 'Missing'; return }

    if (-not $MariaDbRootPassword) {
        $MariaDbRootPassword = Get-NewPassword
        Write-Step 'Generated a root password.'
    }

    # SERVICENAME/PORT/PASSWORD are MariaDB MSI properties. UTF8=1 sets utf8mb4 as the
    # server default, which the PEQ dump expects.
    #
    # Caveat, stated plainly: PASSWORD= travels on the msiexec command line, so it is
    # briefly visible in the process list and lands in any verbose MSI log. The MariaDB
    # MSI offers no better channel for the initial root password. It is only exposed to
    # someone already on the box during the install window; rotate it afterwards if that
    # matters to you.
    Install-WithWinget -PackageId $script:Packages.MariaDB -Component 'MariaDB' -Override @(
        '/quiet',
        'SERVICENAME=MariaDB',
        'PORT=3306',
        "PASSWORD=$MariaDbRootPassword",
        'UTF8=1'
    )

    Save-Credential -Label 'MariaDB root password' -Value $MariaDbRootPassword

    Start-Sleep -Seconds 5
    $svc = Get-MariaDbService
    if ($svc) {
        if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name }
        Write-Ok "Service '$($svc.Name)' is running."
        Add-Result 'MariaDB' 'Installed' $svc.Name
    } else {
        Write-Bad 'Install finished but no MariaDB service appeared.'
        Add-Result 'MariaDB' 'Failed' 'no service'
        return
    }

    Set-MariaDbLoopbackOnly
}

function Resolve-MariaDbIni {
    $iniPaths = @(
        (Join-Path $env:ProgramData 'MySQL\MariaDB*\my.ini'),
        (Join-Path $env:ProgramFiles 'MariaDB*\data\my.ini')
    )
    $iniPaths |
        ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
}

function Test-MariaDbLoopbackOnly {
    $ini = Resolve-MariaDbIni
    if (-not $ini) { Write-Warn 'Could not locate my.ini to check bind-address.'; return }

    if ((Get-Content $ini.FullName -Raw) -match '(?m)^\s*bind-address\s*=\s*127\.0\.0\.1') {
        Write-Ok 'MariaDB is bound to loopback.'
    } else {
        Write-Warn 'MariaDB is NOT bound to 127.0.0.1. Re-run without -CheckOnly to fix.'
    }
}

function Set-MariaDbLoopbackOnly {
    <#
        The server, the quest Perl and every tool all connect over loopback. Nothing needs
        3306 reachable from outside, so bind it to 127.0.0.1 and never open the firewall
        for it. This is the single highest-value hardening step on the box.

        Safe to call on an existing install: if bind-address is already 127.0.0.1 we do
        not rewrite the file or bounce the service.
    #>
    $ini = Resolve-MariaDbIni
    if (-not $ini) {
        Write-Warn 'Could not locate my.ini. Bind it to 127.0.0.1 by hand.'
        return
    }

    $content = Get-Content $ini.FullName -Raw

    if ($content -match '(?m)^\s*bind-address\s*=\s*127\.0\.0\.1') {
        Write-Ok 'MariaDB is already bound to loopback.'
        return
    }

    Write-Step 'Binding MariaDB to 127.0.0.1 only...'
    if ($content -match '(?m)^\s*bind-address\s*=') {
        $content = $content -replace '(?m)^\s*bind-address\s*=.*$', 'bind-address=127.0.0.1'
    } elseif ($content -match '(?m)^\s*\[mysqld\]') {
        $content = $content -replace '(?m)^\s*\[mysqld\]', "[mysqld]`r`nbind-address=127.0.0.1"
    } else {
        $content += "`r`n[mysqld]`r`nbind-address=127.0.0.1`r`n"
    }

    Copy-Item $ini.FullName "$($ini.FullName).nms-backup" -Force
    Set-Content -Path $ini.FullName -Value $content -Encoding ASCII

    $svc = Get-MariaDbService
    if ($svc) { Restart-Service -Name $svc.Name -Force }
    Write-Ok "Bound to loopback (backup at $($ini.Name).nms-backup)"
}

function Invoke-CheckPerl {
    Write-Head 'Strawberry Perl'

    if (Test-Command 'perl') {
        $v = (& perl -e 'print $^V' 2>$null)
        Write-Ok "Perl $v"
        Write-Step "at $((Get-Command perl).Source)"
        Add-Result 'Perl' 'Present' "$v"
    } else {
        Write-Bad 'Not found.'
        if ($CheckOnly) { Add-Result 'Perl' 'Missing'; Invoke-CheckCpanModules; return }

        Install-WithWinget -PackageId $script:Packages.Perl -Component 'Strawberry Perl'

        if (Test-Command 'perl') {
            $v = (& perl -e 'print $^V' 2>$null)
            Write-Ok "Installed Perl $v"
            Add-Result 'Perl' 'Installed' "$v"
        } else {
            Write-Warn 'Perl installed but not yet on PATH. Re-run in a new shell.'
            Add-Result 'Perl' 'Installed' 'PATH refresh pending'
            return
        }
    }

    Write-Warn 'Note the Perl version above. The server binaries link against it. If you'
    Write-Warn 'ever move binaries between machines, the Perl versions must match.'

    Invoke-CheckCpanModules
}

function Invoke-CheckCpanModules {
    <#
        Why these four matter (see CODEBASE.md section 6):
          DBI + DBD::mysql - MySQL.pl opens its own DB connection. NMS_item_utils.pl and
                             NMS_progression_utils.pl both depend on it, so item upgrade
                             tiers and expansion progression break WITHOUT ANY ERROR if
                             these are absent.
          JSON             - also used by MySQL.pl
          Switch           - illusion_tools.pl line 36 has 'use Switch', and Switch was
                             removed from core Perl in 5.14. Without it that file will not
                             compile on modern Strawberry Perl.
    #>
    Write-Head 'Perl CPAN modules'

    if (-not (Test-Command 'perl')) {
        Write-Warn 'Perl is not available yet; skipping module check.'
        Add-Result 'CPAN modules' 'Skipped' 'perl missing'
        return
    }

    $missing = @()
    foreach ($m in $script:RequiredCpanModules) {
        & perl -M$m -e '1' *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$m"
        } else {
            Write-Bad "$m is missing"
            $missing += $m
        }
    }

    if ($missing.Count -eq 0) {
        Add-Result 'CPAN modules' 'Present' 'all four'
        return
    }
    if ($CheckOnly) {
        Add-Result 'CPAN modules' 'Missing' ($missing -join ', ')
        return
    }

    # Strawberry ships cpanm; it is far better behaved unattended than raw cpan.
    $installer = if (Test-Command 'cpanm') { 'cpanm' } else { 'cpan' }
    Write-Step "Installing $($missing -join ', ') with $installer (this can take a while)..."

    $failed = @()
    foreach ($m in $missing) {
        Write-Step "  $m"
        if ($installer -eq 'cpanm') {
            & cpanm --notest --quiet $m
        } else {
            & cpan -T $m
        }

        & perl -M$m -e '1' *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "$m installed" }
        else { Write-Bad "$m still not importable"; $failed += $m }
    }

    if ($failed.Count -eq 0) {
        Add-Result 'CPAN modules' 'Installed' 'all four'
    } else {
        Add-Result 'CPAN modules' 'Failed' ($failed -join ', ')
        Write-Warn "Install by hand: cpanm $($failed -join ' ')"
        if ($failed -contains 'DBD::mysql') {
            Write-Warn 'DBD::mysql often needs MariaDB installed first. Re-run this script'
            Write-Warn 'after MariaDB is in place and it will usually build cleanly.'
        }
    }
}

function Invoke-CheckDiskSpace {
    Write-Head 'Disk space'

    # 12 GB Build Tools + ~4 GB build tree + 540 MB dump unpacked + ~2 GB DB + Maps + slack.
    $needGb = 40
    $drive = (Get-Item $CredentialFile -ErrorAction SilentlyContinue).PSDrive.Name
    if (-not $drive) { $drive = (Split-Path -Qualifier $CredentialFile).TrimEnd(':') }

    $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
    if (-not $vol) {
        Write-Warn "Could not read free space on ${drive}:"
        Add-Result 'Disk space' 'Skipped'
        return
    }

    $freeGb = [math]::Round($vol.SizeRemaining / 1GB, 1)
    if ($freeGb -ge $needGb) {
        Write-Ok "${freeGb} GB free on ${drive}: (need ~${needGb} GB)"
        Add-Result 'Disk space' 'Present' "$freeGb GB"
    } else {
        Write-Bad "${freeGb} GB free on ${drive}: - want at least ${needGb} GB"
        Add-Result 'Disk space' 'Missing' "$freeGb GB"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$transcript = Join-Path (Split-Path -Parent $CredentialFile) `
    "install-prereqs-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$dir = Split-Path -Parent $CredentialFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Head 'NMS server - Stage 1 of 2 - Prerequisites'
    Write-Host "  Mode:       $(if ($CheckOnly) { 'CHECK ONLY - nothing will be installed' } else { 'INSTALL' })"
    Write-Host "  Host:       $env:COMPUTERNAME"
    Write-Host "  OS:         $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "  Log:        $transcript"

    if (-not (Test-Admin)) {
        throw 'This script must run as Administrator. Right-click PowerShell -> Run as administrator.'
    }
    Write-Ok 'Running elevated.'

    if (-not (Test-Winget)) {
        throw @'
winget (App Installer) is not available, and this script relies on it.

On Windows Server 2025 winget normally ships in the box. If it is missing, install the
"App Installer" package from https://aka.ms/getwinget and re-run this script.
'@
    }
    Write-Ok "winget $(& winget --version)"

    Invoke-CheckDiskSpace
    Invoke-CheckSimpleTool -Component 'Git' -CommandName 'git' -PackageId $script:Packages.Git
    Invoke-CheckSimpleTool -Component '7-Zip' -CommandName '7z' -PackageId $script:Packages.SevenZip `
        -ExtraProbePaths @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
    Invoke-CheckBuildTools
    Invoke-CheckCMake
    Invoke-CheckMariaDb
    Invoke-CheckPerl

    # ---- Summary ----------------------------------------------------------
    Write-Head 'Summary'

    $script:Results |
        Format-Table -AutoSize @(
            @{ Label = 'Component'; Expression = { $_.Component } },
            @{ Label = 'State';     Expression = { $_.State } },
            @{ Label = 'Detail';    Expression = { $_.Detail } }
        ) | Out-String -Width 100 | Write-Host

    $bad = $script:Results | Where-Object { $_.State -in 'Missing', 'Failed' }

    if ($bad) {
        Write-Host ''
        Write-Bad "$($bad.Count) component(s) need attention:"
        $bad | ForEach-Object { Write-Host "         - $($_.Component)  $($_.Detail)" -ForegroundColor Red }

        if ($CheckOnly) {
            Write-Host ''
            Write-Host '  Re-run without -CheckOnly to install these.' -ForegroundColor Yellow
        } else {
            Write-Host ''
            Write-Warn 'Some installs want a reboot to finish. Reboot, then re-run this'
            Write-Warn 'script - it will skip everything already done.'
        }
        exit 1
    }

    Write-Host ''
    Write-Ok 'All prerequisites satisfied.'
    if (-not $CheckOnly) {
        Write-Host ''
        Write-Host '  Next: .\2-Setup-NMSServer.ps1' -ForegroundColor Cyan
        Write-Host ''
        Write-Warn 'Open a NEW PowerShell window first, so it picks up the updated PATH.'
    }
    exit 0
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''
    Write-Host "  Full log: $transcript" -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
