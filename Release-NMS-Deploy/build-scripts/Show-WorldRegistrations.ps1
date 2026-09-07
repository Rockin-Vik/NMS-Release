<#
.SYNOPSIS
    Lists the loginserver's world registrations, and removes stale ones after a rename.

.DESCRIPTION
    The loginserver looks up a connecting world in login_world_servers by short_name AND
    long_name together (common/repositories/login_world_servers_repository.h -
    GetFromWorldContext). Change either name in eqemu_config.json and the old row stops
    matching, so world auto-registers a NEW row on its next connect. The old row is dead
    weight - only connected worlds are listed to players - but it is worth clearing out.

    Read-only by default. When eqemu_config.json is readable it marks the row that matches
    the CURRENT configured names, so you can see at a glance which registrations are stale.

.PARAMETER RemoveId
    Delete the login_world_servers row with this id. Prompts unless -Force.

.PARAMETER RemoveStale
    Delete every row that does NOT match the long/short name in eqemu_config.json.
    Requires the config to be readable. Prompts unless -Force.

.PARAMETER Force
    Skip the confirmation prompt on a delete.

.PARAMETER ConfigPath
    Path to eqemu_config.json. Default C:\NMS\Server\eqemu_config.json

.EXAMPLE
    .\Show-WorldRegistrations.ps1
    List every registration; the live one is marked CURRENT.

.EXAMPLE
    .\Show-WorldRegistrations.ps1 -RemoveStale
    Drop the leftovers from previous renames.

.NOTES
    Deleting a registration does not touch accounts or characters - those live in peq and
    are not keyed by server name. A world that is running will simply re-register itself.
#>

[CmdletBinding(DefaultParameterSetName = 'List', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(ParameterSetName = 'RemoveId', Mandatory)]
    [int] $RemoveId,

    [Parameter(ParameterSetName = 'RemoveStale', Mandatory)]
    [switch] $RemoveStale,

    [switch] $Force,

    [string] $ConfigPath     = 'C:\NMS\Server\eqemu_config.json',
    [string] $CredentialFile = 'C:\NMS\credentials.txt',
    [string] $DbName         = 'peq',
    [string] $DbHost         = '127.0.0.1',
    [int]    $DbPort         = 3306
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

function Write-Ok   { param([string] $T) Write-Host "  [ OK ] $T" -ForegroundColor Green }
function Write-Warn { param([string] $T) Write-Host "  [WARN] $T" -ForegroundColor Yellow }
function Write-Bad  { param([string] $T) Write-Host "  [FAIL] $T" -ForegroundColor Red }

function Resolve-MysqlClient {
    foreach ($n in 'mysql', 'mariadb') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($root in (Join-Path $env:ProgramFiles 'MariaDB*'),
                      (Join-Path $env:ProgramFiles 'MySQL\MySQL Server*')) {
        $hit = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                foreach ($exe in 'mysql.exe', 'mariadb.exe') {
                    $p = Join-Path $_.FullName "bin\$exe"
                    if (Test-Path $p) { $p }
                }
            } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    throw 'Could not find mysql.exe. Is MariaDB installed?'
}

function Get-StoredValue {
    param([string] $Label)
    if (-not (Test-Path $CredentialFile)) {
        throw "Credentials file not found: $CredentialFile"
    }
    $line = Get-Content $CredentialFile |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Label))\s*=\s*(.+)$" } |
        Select-Object -Last 1
    if ($line -match '=\s*(.+)$') { return $Matches[1].Trim() }
    return $null
}

function Invoke-Sql {
    param([Parameter(Mandatory)] [string] $Query)

    # Not $args - that is an automatic variable and shadowing it is a trap.
    $cliArgs = @("--host=$DbHost", "--port=$DbPort", "--user=$script:DbUser",
                 "--database=$DbName", '--batch', '--silent')

    $old = $env:MYSQL_PWD
    $env:MYSQL_PWD = $script:DbPass
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $Query | & $script:Client @cliArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -eq $old) { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $old }
    }

    if ($code -ne 0) { throw "Query failed: $($out -join [Environment]::NewLine)" }

    # 2>&1 merges the client's stderr into the stream: MariaDB prints notices there
    # (e.g. the --ssl-verify-server-cert warning on a passwordless login) and they are
    # NOT result rows. Merged stderr arrives as ErrorRecord objects, so drop those;
    # belt-and-braces, drop any residual WARNING/ERROR/Note text line too.
    $rows = @($out) |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        Where-Object { "$_" -notmatch '^\s*(WARNING|Warning|ERROR|Note|mysql:|mariadb:)\b' }

    foreach ($l in @($out)) { Write-Verbose "sql> $l" }
    return @($rows)
}

function Get-ConfiguredNames {
    if (-not (Test-Path $ConfigPath)) {
        Write-Verbose "Config not readable at $ConfigPath - cannot mark the current row."
        return $null
    }
    try {
        $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            LongName  = $j.server.world.longname
            ShortName = $j.server.world.shortname
        }
    } catch {
        Write-Verbose "Could not parse ${ConfigPath}: $($_.Exception.Message)"
        return $null
    }
}

function Get-Registrations {
    # Column order fixes the field positions below; do not SELECT *.
    $rows = Invoke-Sql -Query @"
SELECT id,
       long_name,
       short_name,
       IFNULL(last_ip_address, ''),
       IFNULL(DATE_FORMAT(last_login_date, '%Y-%m-%d'), '')
  FROM login_world_servers
 ORDER BY id;
"@

    $out = @()
    foreach ($r in $rows) {
        # --batch rows are tab-separated; anything short of 5 fields is not a result row.
        $f = "$r" -split "`t"
        if ($f.Count -lt 5) {
            Write-Verbose "Ignoring unparsable row: $r"
            continue
        }
        $out += [pscustomobject]@{
            Id        = [int] $f[0]
            LongName  = $f[1]
            ShortName = $f[2]
            LastIp    = $f[3]
            LastLogin = $f[4]
        }
    }
    return @($out)
}

function Remove-Registration {
    param([int] $Id)

    if (-not ($Force -or $PSCmdlet.ShouldProcess("login_world_servers id $Id", 'DELETE'))) {
        return $false
    }
    Invoke-Sql -Query "DELETE FROM login_world_servers WHERE id = $Id;" | Out-Null
    $still = @(Invoke-Sql -Query "SELECT id FROM login_world_servers WHERE id = $Id;" |
        Where-Object { $_ -match '^\s*\d+\s*$' })
    if ($still.Count -gt 0) {
        Write-Bad "Row $Id is still present after the delete."
        return $false
    }
    Write-Ok "Deleted registration $Id."
    return $true
}

# ---------------------------------------------------------------------------

try {
    $script:Client = Resolve-MysqlClient
    $script:DbUser = Get-StoredValue 'Database user'
    $script:DbPass = Get-StoredValue 'Database password'
    if (-not $script:DbUser) { $script:DbUser = 'peq' }
    if (-not $script:DbPass) { throw "No 'Database password' entry in $CredentialFile" }

    $stored = Get-StoredValue 'Database name'
    if ($stored) { $DbName = $stored }

    $cfg = Get-ConfiguredNames
    # @() is required: returning a one-element array unrolls it to a bare object on
    # assignment, and under Set-StrictMode a bare object has no .Count in PS 5.1.
    $regs = @(Get-Registrations)

    if ($regs.Count -eq 0) {
        Write-Host ''
        Write-Warn 'No rows in login_world_servers - world has not registered yet.'
        Write-Host '  Start NMS-World and NMS-LoginServer, then re-run.' -ForegroundColor Gray
        Write-Host ''
        exit 0
    }

    # A row is CURRENT only if BOTH names match - that is how the loginserver matches.
    foreach ($r in $regs) {
        $isCurrent = $cfg -and $r.LongName -eq $cfg.LongName -and $r.ShortName -eq $cfg.ShortName
        Add-Member -InputObject $r -NotePropertyName IsCurrent -NotePropertyValue $isCurrent
    }

    Write-Host ''
    Write-Host '  World registrations (login_world_servers)' -ForegroundColor Cyan
    Write-Host '  -----------------------------------------' -ForegroundColor Cyan
    if ($cfg) {
        Write-Host ("  config: longname '{0}'  shortname '{1}'" -f $cfg.LongName, $cfg.ShortName) -ForegroundColor Gray
    } else {
        Write-Warn "Could not read $ConfigPath - cannot tell which row is live."
    }
    Write-Host ''
    '  {0,-5} {1,-30} {2,-12} {3,-16} {4,-11} {5}' -f 'ID', 'LONG NAME', 'SHORT', 'LAST IP', 'LAST LOGIN', '' | Write-Host
    foreach ($r in $regs) {
        $mark   = if ($r.IsCurrent) { 'CURRENT' } elseif ($cfg) { 'stale' } else { '' }
        $colour = if ($r.IsCurrent) { 'Green' } elseif ($cfg) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0,-5} {1,-30} {2,-12} {3,-16} {4,-11} {5}' -f
                    $r.Id, $r.LongName, $r.ShortName, $r.LastIp, $r.LastLogin, $mark) -ForegroundColor $colour
    }
    Write-Host ''

    if ($PSCmdlet.ParameterSetName -eq 'List') {
        $stale = @($regs | Where-Object { -not $_.IsCurrent })
        if ($cfg -and $stale.Count -gt 0) {
            Write-Host ("  {0} stale registration(s). Remove with:  .\Show-WorldRegistrations.ps1 -RemoveStale" -f $stale.Count) -ForegroundColor Cyan
            Write-Host ''
        }
        exit 0
    }

    # ---- Delete modes ----------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'RemoveId') {
        $target = $regs | Where-Object { $_.Id -eq $RemoveId } | Select-Object -First 1
        if (-not $target) { Write-Bad "No registration with id $RemoveId."; exit 1 }
        if ($target.IsCurrent) {
            Write-Warn "Id $RemoveId is the CURRENT registration - a running world will just re-add it."
        }
        if (Remove-Registration -Id $RemoveId) { exit 0 } else { exit 1 }
    }

    if (-not $cfg) {
        Write-Bad "Cannot use -RemoveStale without reading $ConfigPath - there is nothing to compare against."
        Write-Host '  Pass -ConfigPath, or delete a specific row with -RemoveId.' -ForegroundColor Gray
        exit 1
    }

    $stale = @($regs | Where-Object { -not $_.IsCurrent })
    if ($stale.Count -eq 0) { Write-Ok 'No stale registrations.'; exit 0 }

    $failed = 0
    foreach ($r in $stale) {
        Write-Host ("  Removing {0} - '{1}' ({2})" -f $r.Id, $r.LongName, $r.ShortName) -ForegroundColor Gray
        if (-not (Remove-Registration -Id $r.Id)) { $failed++ }
    }
    Write-Host ''
    if ($failed -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Bad $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-Host ("  at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber,
                                            $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
    }
    Write-Host '  Re-run with -Verbose to see the raw client output.' -ForegroundColor Gray
    exit 1
}
