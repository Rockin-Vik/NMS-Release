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

# PowerShell 7.4+ defaults $PSNativeCommandUseErrorActionPreference to $true, which turns
# ANY non-zero exit from a native command into a terminating error - before our own
# exit-code checks can run. That breaks this script in three guaranteed ways on a fresh
# box: winget returns benign non-zero codes we deliberately tolerate, and `perl -M<mod>`
# exits 2 for every module that is missing, which is the whole point of that check.
# Native exit codes are handled explicitly throughout; we do not want them thrown.
# On PowerShell 5.1 this variable does not exist and the assignment is a harmless no-op.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:MinCMakeVersion  = [version]'3.12'
$script:MinMariaDbVersion = [version]'10.6'
$script:RequiredCpanModules = @('DBI', 'JSON', 'Switch')

# The database driver is handled separately because EITHER of these satisfies the server,
# and which one you can actually build depends on the database you installed:
#
#   DBD::MariaDB - the maintained driver for MariaDB. Builds cleanly against MariaDB's
#                  client libraries. This is what we install.
#   DBD::mysql   - version 5.x DELIBERATELY dropped MariaDB support ("use DBD::MariaDB
#                  instead") and will not configure against MariaDB client libs. Version
#                  4.050 could, but predates modern Perl and no longer builds on 5.42.
#                  Accepted if already present, e.g. on a box running real MySQL.
#
# Preference order: probe both, install the first that builds.
$script:DbDriverCandidates = @('DBD::MariaDB', 'DBD::mysql')

# winget package ids. Pinned deliberately - see README for how to bump these.
$script:Packages = @{
    BuildTools = 'Microsoft.VisualStudio.2022.BuildTools'
    CMake      = 'Kitware.CMake'
    Git        = 'Git.Git'
    SevenZip   = '7zip.7zip'
    MariaDB    = 'MariaDB.Server'
}

# Perl is pinned to 5.32.1.1, and NOT installed via winget, which would give the latest.
#
# This version is load-bearing for two independent reasons:
#
#  1. It is what zone.exe EMBEDS. cmake/DependencyHelperMSVC.cmake calls FIND_PACKAGE
#     (PerlLibs) and uses whatever Perl it finds, falling back to downloading portable
#     Strawberry 5.24.4.1. So EQEmu targets Perl 5.24 (Windows) / 5.32 (Linux static, see
#     CMakeLists.txt:28) - its embedded-Perl code predates the API churn in newer Perls.
#     5.32.1.1 is the newest version the project demonstrably builds against.
#
#  2. Strawberry 5.40+ switched to UCRT. DBD::MariaDB's dbdimp.c still references the
#     msvcrt-era internal __pioinfo, so on 5.42 it compiles and then dies at link with
#     "undefined reference to `__imp___pioinfo'". 5.32.1.1 is pre-UCRT and links.
#
# The quest plugins run inside the interpreter zone.exe embeds, so the DBD driver and the
# CPAN modules must be installed into THIS Perl - not some other one that happens to be
# on PATH. See CODEBASE.md section 6.
$script:PerlVersion = '5.32.1.1'
$script:PerlMsiUrl  = 'https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_5321_5321/strawberry-perl-5.32.1.1-64bit.msi'

# Perl versions known to break the build or the DBD driver, warned about on sight.
$script:PerlMinVersion = [version]'5.32'
$script:PerlMaxVersion = [version]'5.38'   # 5.40+ is UCRT; see note above

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

function Invoke-Native {
    <#
    .SYNOPSIS
        Runs a native command safely and returns its exit code. Never throws.

    .DESCRIPTION
        $ErrorActionPreference = 'Stop' is right for cmdlets and actively wrong for native
        commands, in two separate ways:

          * PowerShell 5.1 converts anything a native command writes to STDERR into
            ErrorRecords, and 'Stop' escalates those to terminating - even when the command
            succeeded, and even when the stream is redirected to $null. git, cpanm, cmake
            and winget all write to stderr routinely.
          * PowerShell 7.4+ escalates any non-zero exit code the same way.

        Neither is wanted here: every native exit code in this script is checked explicitly,
        and some commands (the `perl -M` probes) are EXPECTED to fail as part of a check.

        So: relax the preference for the duration of the call, capture the merged streams,
        and hand back the exit code for the caller to judge.

    .EXAMPLE
        $code = Invoke-Native { perl "-MDBI" -e '1' }
        Probe for a module; $code is 0 when present, non-zero when missing. Silent.

    .EXAMPLE
        $code = Invoke-Native -Show { git clone --depth 1 $url $dest }
        Run and stream output to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Command,
        [switch] $Show,          # stream merged output to the console
        [switch] $Capture        # collect merged output into $script:NativeOutput
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:NativeOutput = @()
    try {
        if ($Capture) {
            $script:NativeOutput = @(& $Command 2>&1)
        } elseif ($Show) {
            & $Command 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        } else {
            & $Command 2>&1 | Out-Null
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
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

    # winget writes progress and some warnings to stderr even on a clean install.
    $code = Invoke-Native -Show { winget @cliArgs }

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

    $null = Invoke-Native -Capture {
        & $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -format json
    }
    $json = $script:NativeOutput

    if (-not $json) { return $null }

    # @() is load-bearing here. vswhere emits a JSON array, but ConvertFrom-Json unrolls a
    # single-element array to a bare object - which is the NORMAL case, one VS install. A
    # scalar has no .Count under Set-StrictMode -Version Latest, so the next line would
    # throw on exactly the machines where Build Tools is present.
    $parsed = @($json | ConvertFrom-Json)
    if ($parsed.Count -eq 0) { return $null }
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
        $null = Invoke-Native -Capture { cmake --version }
        $raw = $script:NativeOutput | Select-Object -First 1
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
        $null = Invoke-Native -Capture { cmake --version }
        $v = $script:NativeOutput | Select-Object -First 1
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

function Get-PerlVersion {
    if (-not (Test-Command 'perl')) { return $null }
    $null = Invoke-Native -Capture { perl -e 'printf "%vd", $^V' }
    $raw = ($script:NativeOutput | Select-Object -First 1)
    if ($raw -match '(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    return $null
}

function Install-PinnedPerl {
    <#
        Installs Strawberry Perl 5.32.1.1 from the vendor MSI.

        Not winget: winget installs the latest, and the version genuinely matters here -
        see the note on $script:PerlVersion. msiexec /qn is silent; PERL_PATH=Yes puts it
        on the machine PATH, which is how CMake will find it later.
    #>
    $msi = Join-Path $env:TEMP "strawberry-perl-$($script:PerlVersion).msi"

    if (-not (Test-Path $msi)) {
        Write-Step "Downloading Strawberry Perl $($script:PerlVersion) (~120 MB)..."
        try {
            Invoke-WebRequest -Uri $script:PerlMsiUrl -OutFile $msi -UseBasicParsing
        } catch {
            Write-Bad "Download failed: $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Step 'Using the already-downloaded installer.'
    }

    Write-Step 'Installing (a few minutes)...'
    # /i install, /qn silent, PERL_PATH=Yes puts it on the machine PATH so CMake finds it.
    $code = Invoke-Native -Show { msiexec /i $msi /qn PERL_PATH=Yes }
    if ($code -ne 0) { Write-Warn "msiexec returned $code." }

    Update-SessionPath
    if (Test-Command 'perl') { return $true }

    # The MSI writes the machine PATH, but that write can lag behind msiexec returning, so
    # re-reading the environment is not always enough. Rather than stopping and making the
    # operator start a new shell just to continue, add the known install location to THIS
    # session directly. The machine PATH is already correct for future shells.
    Write-Step 'Perl not on PATH yet; adding its install location to this session...'
    $bins = @(
        'C:\Strawberry\perl\bin',
        'C:\Strawberry\c\bin',
        'C:\Strawberry\perl\site\bin'
    ) | Where-Object { Test-Path $_ }

    if ($bins.Count -gt 0) {
        $env:Path = ($bins -join ';') + ';' + $env:Path
        if (Test-Command 'perl') {
            Write-Ok 'Perl is usable in this session.'
            return $true
        }
    }

    return $false
}

function Invoke-CheckPerl {
    Write-Head "Strawberry Perl (pinned to $($script:PerlVersion))"

    $v = Get-PerlVersion

    if ($v) {
        Write-Step "Found Perl $v at $((Get-Command perl).Source)"

        if ($v -ge $script:PerlMinVersion -and $v -lt $script:PerlMaxVersion) {
            Write-Ok "Perl $v is in the supported range."
            Add-Result 'Perl' 'Present' "$v"
        } else {
            # This is not cosmetic - both failure modes are real and already observed.
            Write-Bad "Perl $v is outside the supported range ($($script:PerlMinVersion) to below $($script:PerlMaxVersion))."
            Write-Warn 'Two things break with a newer Perl:'
            Write-Warn '  * zone.exe embeds this Perl. EQEmu targets 5.24 (Windows) / 5.32'
            Write-Warn '    (Linux) and its embedded-Perl code predates newer API changes.'
            Write-Warn '  * Strawberry 5.40+ is UCRT, and DBD::MariaDB fails to link with'
            Write-Warn '    undefined reference to __imp___pioinfo'
            Write-Warn ''

            if ($CheckOnly) {
                Add-Result 'Perl' 'Failed' "$v unsupported"
                Invoke-CheckCpanModules
                Invoke-CheckDbDriver
                return
            }

            Write-Warn "Uninstall Perl $v first (Programs and Features -> Strawberry Perl),"
            Write-Warn "then re-run. This script will install $($script:PerlVersion)."
            Write-Warn 'Uninstalling is left to you deliberately - removing a Perl that other'
            Write-Warn 'software on this box may depend on is not a decision to automate.'
            Add-Result 'Perl' 'Failed' "$v unsupported - uninstall it"
            return
        }
    } else {
        Write-Bad 'Not found.'
        if ($CheckOnly) {
            Add-Result 'Perl' 'Missing'
            Invoke-CheckCpanModules
            Invoke-CheckDbDriver
            return
        }

        if (Install-PinnedPerl) {
            $v = Get-PerlVersion
            Write-Ok "Installed Perl $v"
            Add-Result 'Perl' 'Installed' "$v"
        } else {
            Write-Warn 'Perl installed but not yet on PATH. Re-run in a new shell.'
            Add-Result 'Perl' 'Installed' 'PATH refresh pending'
            return
        }
    }

    Write-Step 'This is the interpreter zone.exe will embed, so the CPAN modules and the'
    Write-Step 'DBD driver below go into THIS Perl. CMake picks it up via FIND_PACKAGE.'

    Invoke-CheckCpanModules
    Invoke-CheckDbDriver
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
        # "-M$m" must be quoted. Unquoted, -M$m begins with a dash so PowerShell parses it
        # as a parameter-name token, and '$' is not a legal parameter-name character - so
        # it splits there and passes '-M' and 'DBI' as two separate arguments. Perl then
        # reports "Module name required with -M option". Quoting keeps it one token.
        #
        # Invoke-Native because a MISSING module is the expected outcome here: perl writes
        # "Can't locate Foo.pm in @INC" to stderr and exits 2, and under 'Stop' that would
        # abort the whole script instead of recording the module as missing.
        if ((Invoke-Native { perl "-M$m" -e '1' }) -eq 0) {
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
        # cpanm and cpan both narrate build progress on stderr even on success.
        if ($installer -eq 'cpanm') {
            $null = Invoke-Native -Show { cpanm --notest $m }
        } else {
            $null = Invoke-Native -Show { cpan -T $m }
        }

        # Re-probe rather than trusting the installer's exit code - what matters is
        # whether perl can actually load it now.
        if ((Invoke-Native { perl "-M$m" -e '1' }) -eq 0) { Write-Ok "$m installed" }
        else { Write-Bad "$m still not importable"; $failed += $m }
    }

    if ($failed.Count -eq 0) {
        Add-Result 'CPAN modules' 'Installed' ($script:RequiredCpanModules -join ', ')
    } else {
        Add-Result 'CPAN modules' 'Failed' ($failed -join ', ')
        Write-Warn "Install by hand: cpanm $($failed -join ' ')"
    }
}

function Invoke-CheckDbDriver {
    <#
        The Perl-side database driver, checked separately from the plain module list
        because either driver satisfies the server and they are not interchangeable to
        build:

          DBD::mysql 5.x REMOVED MariaDB support outright - upstream's own advice is
          "use DBD::MariaDB instead" - so on a MariaDB box its Makefile.PL fails at
          configure time, which is not something more build flags can fix. DBD::mysql
          4.050 could talk to MariaDB but predates Perl 5.42 and no longer builds.

        So on a MariaDB server the answer is DBD::MariaDB. An existing DBD::mysql is
        accepted as-is, which covers anyone running real MySQL.

        NOTE: the DSN in Release-NMS-Plugins/MySQL.pl decides which driver is actually
        used at runtime. 'dbi:mysql:' requires DBD::mysql; 'dbi:MariaDB:' requires
        DBD::MariaDB. See CODEBASE.md section 6.
    #>
    Write-Head 'Perl database driver'

    if (-not (Test-Command 'perl')) {
        Write-Warn 'Perl is not available yet; skipping driver check.'
        Add-Result 'DB driver' 'Skipped' 'perl missing'
        return
    }

    foreach ($d in $script:DbDriverCandidates) {
        if ((Invoke-Native { perl "-M$d" -e '1' }) -eq 0) {
            Write-Ok "$d is installed"
            Add-Result 'DB driver' 'Present' $d
            return
        }
        Write-Step "$d not present"
    }

    if ($CheckOnly) {
        Write-Bad 'No Perl database driver installed.'
        # Parenthesised: in an argument list PowerShell would otherwise read the '+' as
        # another positional argument rather than concatenating.
        Add-Result 'DB driver' 'Missing' ("none of: " + ($script:DbDriverCandidates -join ', '))
        return
    }

    # Both drivers fail at CONFIGURE time when they cannot locate the client library. On
    # Unix they shell out to mysql_config; Windows has no such thing, so the paths must be
    # handed to Makefile.PL explicitly or it gives up before compiling anything.
    $dev = Resolve-MariaDbDevPaths
    if ($dev) {
        Write-Ok "Client root:    $($dev.Root)"
        Write-Ok "Client headers: $($dev.Include)"
        Write-Ok "Client library: $($dev.Lib)  (-l$($dev.LibName))"
    } else {
        Write-Bad 'Could not find MariaDB client headers/libraries on this box.'
        Write-Warn 'The MariaDB installer ships them only when its "Development Components"'
        Write-Warn 'feature is selected, and a quiet install can skip it. Add it via'
        Write-Warn 'Programs and Features -> MariaDB -> Change, then re-run this script.'
        Add-Result 'DB driver' 'Failed' 'no client dev files'
        return
    }

    # Source tarballs, so the build can be driven directly. cpanm is not used for these:
    # its --configure-args takes ONE string that it re-splits, and the value we must pass
    # contains a space (--libs=-L<dir> -lmariadb). That reliably arrives split, and
    # Makefile.PL then reports `Unknown option: lmariadb`.
    $sources = @{
        'DBD::MariaDB' = 'https://cpan.metacpan.org/authors/id/P/PA/PALI/DBD-MariaDB-1.24.tar.gz'
        'DBD::mysql'   = 'https://cpan.metacpan.org/authors/id/D/DV/DVEEDEN/DBD-mysql-5.013.tar.gz'
    }

    foreach ($d in $script:DbDriverCandidates) {
        Write-Step "Building $d from source (several minutes)..."
        if (-not $sources.ContainsKey($d)) { continue }

        if (Install-DbdDriverManually -Module $d -Url $sources[$d] -Dev $dev) {
            Write-Ok "$d installed."
            Add-Result 'DB driver' 'Installed' $d
            if ($d -eq 'DBD::MariaDB') { Write-DsnNotice }
            return
        }
        Write-Warn "$d could not be built here."
    }

    Write-Bad 'Could not install a Perl database driver.'
    Write-Warn 'Item upgrade tiers and expansion progression call plugin::LoadMysql() and'
    Write-Warn 'will silently do nothing without one. See CODEBASE.md section 6.'
    Write-Warn ''
    Write-Warn 'This does NOT block building or running the server - only those two plugin'
    Write-Warn 'features. You can proceed to stage 2 and settle it afterwards.'
    Write-Warn ''
    # Single-quoted here-string: nothing in it is interpolated or escaped, so the quotes
    # and dollar signs in the sample commands are literal. Values are substituted after,
    # by plain replacement, rather than by nesting quotes inside quotes.
    $help = @'
To debug by hand, from an unpacked driver source directory:

    $cflags = "--cflags=-I{INCLUDE}"
    $libs   = "--libs=-L{LIB} -l{LIBNAME}"
    perl Makefile.PL $cflags $libs

Keep each argument in its own variable. PowerShell then quotes the one containing
a space, which is what Makefile.PL needs to see - passing it inline splits it and
Makefile.PL reports "Unknown option: l{LIBNAME}".
'@
    $help = $help.Replace('{INCLUDE}', $dev.Include).
                  Replace('{LIBNAME}', $dev.LibName).
                  Replace('{LIB}',     $dev.Lib)

    foreach ($line in $help -split "`n") { Write-Warn $line.TrimEnd() }
    Add-Result 'DB driver' 'Failed' 'none could be built'
}

function Install-DbdDriverManually {
    <#
        Builds a DBD driver from source, bypassing cpanm entirely.

        Why not cpanm: the driver cannot find the client library on Windows (there is no
        mysql_config), so the paths must be passed to Makefile.PL. Getting them there
        through `cpanm --configure-args="..."` means surviving PowerShell's native-argument
        quoting AND cpanm's own re-splitting of that string, and the value legitimately
        contains a space:

            --libs=-LC:\...\lib -lmariadb

        In practice that splits and Makefile.PL reports `Unknown option: lmariadb`. Calling
        perl directly with the arguments in variables lets PowerShell quote each one
        correctly, which is the only reliable route.

        Returns $true when the module is importable afterwards.
    #>
    param(
        [Parameter(Mandatory)] [string] $Module,
        [Parameter(Mandatory)] [string] $Url,
        $Dev
    )

    $work = Join-Path $env:TEMP 'nms-dbd-build'
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $tarball = Join-Path $work 'driver.tar.gz'
    Write-Step "Downloading $Module source..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tarball -UseBasicParsing
    } catch {
        Write-Warn "Download failed: $($_.Exception.Message)"
        return $false
    }

    Push-Location $work
    try {
        $null = Invoke-Native { tar -xzf $tarball }
        $src = Get-ChildItem -Directory | Select-Object -First 1
        if (-not $src) { Write-Warn 'Nothing unpacked from the tarball.'; return $false }
        Set-Location $src.FullName

        # Prefer the vendor's own config helper when it exists - it derives cflags and
        # libs itself and removes all the path guesswork.
        $cfgTool = @(
            Get-ChildItem (Join-Path $Dev.Root 'bin') -Filter '*_config*' -ErrorAction SilentlyContinue
        ) | Where-Object { $_.Extension -in '.exe', '' } | Select-Object -First 1

        if ($cfgTool) {
            Write-Step "Configuring via $($cfgTool.Name)..."
            $code = Invoke-Native -Show {
                perl Makefile.PL "--mysql_config=$($cfgTool.FullName)"
            }
        } else {
            # Each argument in its own variable so PowerShell quotes the one with a space.
            $cflags = "--cflags=-I$($Dev.Include)"
            $libs   = "--libs=-L$($Dev.Lib) -l$($Dev.LibName)"
            Write-Step "Configuring with explicit paths..."
            Write-Step "  $cflags"
            Write-Step "  $libs"
            $code = Invoke-Native -Show { perl Makefile.PL $cflags $libs }
        }

        if ($code -ne 0) { Write-Warn "Makefile.PL failed (exit $code)."; return $false }

        # Strawberry Perl ships gmake; older ones shipped dmake.
        $make = @('gmake', 'dmake', 'make') | Where-Object { Test-Command $_ } | Select-Object -First 1
        if (-not $make) { Write-Warn 'No make utility found (expected gmake with Strawberry Perl).'; return $false }

        Write-Step "Building with $make..."
        $code = Invoke-Native -Show { & $make }
        if ($code -ne 0) { Write-Warn "$make failed (exit $code)."; return $false }

        Write-Step "Installing..."
        $code = Invoke-Native -Show { & $make install }
        if ($code -ne 0) { Write-Warn "$make install failed (exit $code)."; return $false }

        return ((Invoke-Native { perl "-M$Module" -e '1' }) -eq 0)
    } finally {
        Pop-Location
    }
}

function ConvertTo-ShortPath {
    <#
        Returns the 8.3 short form of a path, e.g. C:\PROGRA~1\MARIAD~1\include\mysql.

        Why: these paths are handed to cpanm, which passes them to Makefile.PL, which
        feeds them to gcc. "C:\Program Files\MariaDB 11.8\..." has to survive three levels
        of quoting to get there intact, and reliably does not. The 8.3 form has no spaces
        and sidesteps the problem completely.

        Falls back to the original path if 8.3 generation is disabled on the volume
        (fsutil 8dot3name), in which case the caller quotes and hopes.
    #>
    param([string] $Path)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = if (Test-Path $Path -PathType Container) {
            $fso.GetFolder($Path).ShortPath
        } else {
            $fso.GetFile($Path).ShortPath
        }
        if ($short -and $short -notmatch '\s') { return $short }
        return $Path
    } catch {
        return $Path
    }
}

function Resolve-MariaDbDevPaths {
    <#
        Locates the MariaDB (or MySQL) client development files: the directory holding
        mysql.h, and the directory holding the import library.

        Both DBD drivers need these at configure time and cannot discover them on Windows
        by themselves. Returns $null when the dev components are not installed - which is
        the usual reason a configure step fails on an otherwise healthy box.
    #>
    $roots = @(
        (Get-ChildItem (Join-Path $env:ProgramFiles 'MariaDB*') -Directory -ErrorAction SilentlyContinue),
        (Get-ChildItem (Join-Path $env:ProgramFiles 'MySQL\MySQL Server*') -Directory -ErrorAction SilentlyContinue)
    ) | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object Name -Descending

    foreach ($root in $roots) {
        # Headers live in include\mysql\ on MariaDB, include\ on MySQL.
        $header = @(
            (Join-Path $root.FullName 'include\mysql\mysql.h'),
            (Join-Path $root.FullName 'include\mysql.h')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $header) { continue }

        # Import library: libmariadb.lib (MariaDB) or libmysql.lib / mysqlclient.lib.
        $libFile = @(
            'lib\libmariadb.lib', 'lib\mariadbclient.lib',
            'lib\libmysql.lib',   'lib\mysqlclient.lib'
        ) | ForEach-Object { Join-Path $root.FullName $_ } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $libFile) { continue }

        # 8.3 short paths: these travel through cpanm -> Makefile.PL -> gcc, and the
        # spaces in "Program Files" / "MariaDB 11.8" do not survive that trip quoted.
        return [pscustomobject]@{
            Root    = $root.FullName
            Include = ConvertTo-ShortPath (Split-Path -Parent $header)
            Lib     = ConvertTo-ShortPath (Split-Path -Parent $libFile)
            # -l wants the name without the 'lib' prefix or the extension.
            LibName = [IO.Path]::GetFileNameWithoutExtension($libFile) -replace '^lib', ''
        }
    }
    return $null
}

function Write-DsnNotice {
    Write-Host ''
    Write-Warn 'ACTION NEEDED - DBD::MariaDB is installed, but the quest plugins ask for'
    Write-Warn 'DBD::mysql by name. Release-NMS-Plugins/MySQL.pl line 48 builds a'
    Write-Warn "DSN of the form 'dbi:mysql:...', which only DBD::mysql can serve."
    Write-Warn ''
    Write-Warn 'Until that DSN also offers a MariaDB form, plugin::LoadMysql() returns'
    Write-Warn 'undef and item upgrade tiers plus expansion progression fail silently.'
    Write-Warn 'The deploy folder ships a patch for this - see README.md, "MySQL.pl DSN".'
}

function Invoke-CheckDiskSpace {
    Write-Head 'Disk space'

    # 12 GB Build Tools + ~4 GB build tree + 540 MB dump unpacked + ~2 GB DB + Maps + slack.
    $needGb = 40

    # Resolve the drive letter from the PATH STRING, never from the filesystem. On a first
    # run the credentials file does not exist yet, so Get-Item returns $null - and reading
    # a property off $null is a hard error under Set-StrictMode -Version Latest.
    $drive = $null
    try {
        $drive = (Split-Path -Qualifier $CredentialFile -ErrorAction Stop).TrimEnd(':')
    } catch {
        $drive = ($env:SystemDrive).TrimEnd(':')
        Write-Warn "'$CredentialFile' has no drive letter; checking ${drive}: instead."
    }

    $freeBytes = $null

    $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
    if ($vol) {
        $freeBytes = $vol.SizeRemaining
    } else {
        # Get-Volume is missing on some SKUs and older PowerShell. CIM always works.
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'" -ErrorAction SilentlyContinue
        if ($disk) { $freeBytes = $disk.FreeSpace }
    }

    # -eq $null, not -not: a genuinely full disk reports 0 free, and that is precisely the
    # case this check exists to catch - it must not be mistaken for "unreadable".
    if ($null -eq $freeBytes) {
        Write-Warn "Could not read free space on ${drive}: - skipping this check."
        Add-Result 'Disk space' 'Skipped' 'unreadable'
        return
    }

    $freeGb = [math]::Round($freeBytes / 1GB, 1)
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

    # @() matters: Where-Object returns a bare object when exactly one row matches, and
    # under Set-StrictMode -Version Latest a scalar has no .Count property - it throws
    # rather than returning 1. Wrapping guarantees an array.
    $bad = @($script:Results | Where-Object { $_.State -in 'Missing', 'Failed' })

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
