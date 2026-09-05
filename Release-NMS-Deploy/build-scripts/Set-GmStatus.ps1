<#
.SYNOPSIS
    Grants (or changes) GM status on an NMS account.

.DESCRIPTION
    Accounts are created by LOGGING IN, not by this script - the loginserver makes one on
    first connect when auto_create_accounts is on. So: create your character in-game first,
    then run this to raise the account's status.

    Reads the database credentials from the credentials file written by the setup script,
    so there is nothing to type in.

    EQEmu status levels (common ones; full table and per-command defaults in
    Release-NMS-Server/GM-COMMANDS.md):

        250   GMImpossible    everything, including the dangerous commands
        200   GMMgmt
        150   GMLeadAdmin
        100   GMAdmin         the usual "game master" level
         80   QuestTroupe
         50   Guide
         20   ApprenticeGuide
         10   Steward
          0   Player          the default

    Note: the command_settings table overrides the compiled defaults, so a
    status may not unlock what GM-COMMANDS.md says until that table agrees.

.PARAMETER Account
    The account name to modify. This is the LOGIN name, not the character name.

.PARAMETER Status
    Status level to set. Default 250 (full GM).

.PARAMETER List
    List existing accounts and their current status, then exit. Use this if you are not
    sure what your account is called.

.PARAMETER CredentialFile
    Where to read the database password from. Default C:\NMS\credentials.txt

.EXAMPLE
    .\Set-GmStatus.ps1 -List
    Show every account and its current status.

.EXAMPLE
    .\Set-GmStatus.ps1 -Account myaccount
    Grant full GM (250) to the account "myaccount".

.EXAMPLE
    .\Set-GmStatus.ps1 -Account helper -Status 100
    Make "helper" a regular GM.

.NOTES
    Status changes take effect on the account's NEXT login. If you are online, log out and
    back in.
#>

[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Position = 0, Mandatory)]
    [string] $Account,

    [Parameter(ParameterSetName = 'Set')]
    [ValidateRange(0, 255)]
    [int] $Status = 250,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch] $List,

    [string] $CredentialFile = 'C:\NMS\credentials.txt',
    [string] $DbName = 'peq'
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
    $cliArgs = @('--host=127.0.0.1', '--port=3306', "--user=$script:DbUser",
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
    return @($out)
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

    # ---- List mode -------------------------------------------------------
    if ($List) {
        Write-Host ''
        Write-Host '  Accounts' -ForegroundColor Cyan
        Write-Host '  --------' -ForegroundColor Cyan

        $rows = Invoke-Sql -Query @"
SELECT id, name, status, IFNULL(DATE_FORMAT(time_creation, '%Y-%m-%d'), '')
  FROM account ORDER BY status DESC, name;
"@ | Where-Object { $_ -match '\S' }

        if ($rows.Count -eq 0) {
            Write-Warn 'No accounts exist yet.'
            Write-Host ''
            Write-Host '  Accounts are created when someone logs in for the first time.' -ForegroundColor Gray
            Write-Host '  Connect with the client, then re-run this.' -ForegroundColor Gray
            exit 0
        }

        '{0,-6} {1,-24} {2,-8} {3}' -f 'ID', 'NAME', 'STATUS', 'CREATED' | Write-Host
        foreach ($r in $rows) {
            $f = "$r" -split "`t"
            $colour = if ([int]$f[2] -ge 100) { 'Yellow' } else { 'Gray' }
            Write-Host ('{0,-6} {1,-24} {2,-8} {3}' -f $f[0], $f[1], $f[2], $f[3]) -ForegroundColor $colour
        }
        Write-Host ''
        exit 0
    }

    # ---- Set mode --------------------------------------------------------
    # Parameterless quoting: escape single quotes so an account name containing one
    # cannot break the statement.
    $safe = $Account -replace "'", "''"

    $current = Invoke-Sql -Query "SELECT status FROM account WHERE name = '$safe';" |
        Where-Object { $_ -match '^\d+$' } | Select-Object -First 1

    if ($null -eq $current) {
        Write-Bad "No account named '$Account'."
        Write-Host ''
        Write-Warn 'Accounts are created on FIRST LOGIN, not by this script.'
        Write-Warn 'Connect with the client and create your character, then re-run.'
        Write-Host ''
        Write-Host "  See what exists:  .\Set-GmStatus.ps1 -List" -ForegroundColor Cyan
        exit 1
    }

    if ([int]$current -eq $Status) {
        Write-Ok "'$Account' is already at status $Status. Nothing to do."
        exit 0
    }

    Invoke-Sql -Query "UPDATE account SET status = $Status WHERE name = '$safe';" | Out-Null

    $after = Invoke-Sql -Query "SELECT status FROM account WHERE name = '$safe';" |
        Where-Object { $_ -match '^\d+$' } | Select-Object -First 1

    if ([int]$after -eq $Status) {
        Write-Ok "'$Account' status changed from $current to $after."
        Write-Host ''
        Write-Host '  Log out and back in for it to take effect.' -ForegroundColor Cyan
        if ($Status -ge 250) {
            Write-Host '  At 250 you have every GM command, including destructive ones.' -ForegroundColor Yellow
        }
        exit 0
    }

    Write-Bad "Update ran but status reads $after, expected $Status."
    exit 1
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    exit 1
}
