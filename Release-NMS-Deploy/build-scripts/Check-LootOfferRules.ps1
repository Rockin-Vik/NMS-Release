<#
.SYNOPSIS
    Reads (and optionally flips on, for a test window) the loot-offer Custom rules.

.DESCRIPTION
    Connects to the server database with the credentials written by the setup script and
    reports the live values of:

        Custom:NmsLootOffers
        Custom:DimensionalVault
        Custom:NmsLootOfferExpireSeconds

    plus the custom_version from db_version. A rule that is MISSING from rule_values is
    running on its compiled default - which for Custom:NmsLootOffers is why "Pending" comes
    back empty.

    Read-only by default. -Enable does the disposable test-window write: inserts
    Custom:NmsLootOffers if absent, then sets it to true.

.PARAMETER Enable
    Set Custom:NmsLootOffers = true (inserting the row if needed). Disposable test window
    only - undo with -Disable, or delete the row by hand when you are done.

.PARAMETER Disable
    Set Custom:NmsLootOffers = false. Does not delete a row this script inserted.

.PARAMETER RulesetId
    Ruleset the inserted row belongs to. Default 1 (the default ruleset).

.PARAMETER CredentialFile
    Where to read the database password from. Default C:\NMS\credentials.txt

.EXAMPLE
    .\Check-LootOfferRules.ps1
    Show the three rules and the custom_version. Changes nothing.

.EXAMPLE
    .\Check-LootOfferRules.ps1 -Enable
    Turn Custom:NmsLootOffers on for a test window.

.NOTES
    Rule changes are read by zones at boot / on "#reload rules global" (there is no
    #reloadrules command) - run that, or bounce the zone, before retesting.
#>

[CmdletBinding(DefaultParameterSetName = 'Read')]
param(
    [Parameter(ParameterSetName = 'Enable', Mandatory)]
    [switch] $Enable,

    [Parameter(ParameterSetName = 'Disable', Mandatory)]
    [switch] $Disable,

    [int]    $RulesetId      = 1,
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
    # (e.g. the --ssl-verify-server-cert warning) and they are NOT result rows. Merged
    # stderr arrives as ErrorRecord objects, so drop those; belt-and-braces, drop any
    # residual WARNING/ERROR/Note text line too.
    $rows = @($out) |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        Where-Object { "$_" -notmatch '^\s*(WARNING|Warning|ERROR|Note|mysql:|mariadb:)\b' }

    foreach ($l in @($out)) { Write-Verbose "sql> $l" }
    return @($rows)
}

$RuleNames = @(
    'Custom:NmsLootOffers',
    'Custom:DimensionalVault',
    'Custom:NmsLootOfferExpireSeconds'
)

function Show-Rules {
    # Scoped to one ruleset: rule_values is keyed by (ruleset_id, rule_name), so an
    # unscoped read returns one row PER ruleset and the last one silently wins below.
    $rows = Invoke-Sql -Query @"
SELECT rule_name, rule_value
  FROM rule_values
 WHERE ruleset_id = $RulesetId
   AND rule_name IN ('Custom:NmsLootOffers',
                     'Custom:DimensionalVault',
                     'Custom:NmsLootOfferExpireSeconds');
"@ | Where-Object { $_ -match '\S' }

    # --batch output is tab-separated, but a row can carry a tab inside the value and
    # the client can emit a stray note line. Split on the FIRST tab only, and skip
    # anything that does not look like "<rule name><tab><value>".
    $live = @{}
    foreach ($r in $rows) {
        $line = "$r"
        $i = $line.IndexOf("`t")
        if ($i -lt 1) {
            Write-Verbose "Ignoring unparsable row: $line"
            continue
        }
        $live[$line.Substring(0, $i)] = $line.Substring($i + 1)
    }

    Write-Host ''
    Write-Host '  Loot-offer rules (rule_values)' -ForegroundColor Cyan
    Write-Host '  ------------------------------' -ForegroundColor Cyan
    foreach ($n in $RuleNames) {
        if ($live.ContainsKey($n)) {
            $v = $live[$n]
            $colour = if ($v -match '^(true|1)$') { 'Green' }
                      elseif ($v -match '^(false|0)$') { 'Yellow' }
                      else { 'Gray' }
            Write-Host ('  {0,-36} {1}' -f $n, $v) -ForegroundColor $colour
        } else {
            Write-Host ('  {0,-36} {1}' -f $n, '<not set - compiled default>') -ForegroundColor DarkGray
        }
    }
    Write-Host ('  (ruleset_id {0})' -f $RulesetId) -ForegroundColor DarkGray

    $ver = Invoke-Sql -Query 'SELECT custom_version FROM db_version LIMIT 1;' |
        Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1
    Write-Host ''
    Write-Host ('  custom_version: {0}' -f $(if ($ver) { $ver } else { '<none>' })) -ForegroundColor Cyan
    Write-Host ''

    return $live
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

    $live = Show-Rules

    if (-not ($Enable -or $Disable)) {
        if (-not $live.ContainsKey('Custom:NmsLootOffers')) {
            Write-Warn 'Custom:NmsLootOffers has no row - the server is on the compiled default.'
            Write-Host '  If that default is false, Pending will always be empty.' -ForegroundColor Gray
            Write-Host '  Test window:  .\Check-LootOfferRules.ps1 -Enable' -ForegroundColor Cyan
            Write-Host ''
        } elseif ($live['Custom:NmsLootOffers'] -notmatch '^(true|1)$') {
            Write-Warn "Custom:NmsLootOffers is '$($live['Custom:NmsLootOffers'])' - that is why Pending is empty."
            Write-Host '  Test window:  .\Check-LootOfferRules.ps1 -Enable' -ForegroundColor Cyan
            Write-Host ''
        }
        exit 0
    }

    # ---- Write mode: disposable test window ------------------------------
    $target = if ($Enable) { 'true' } else { 'false' }

    # Every write below is scoped to $RulesetId. rule_values is keyed by
    # (ruleset_id, rule_name); an unscoped UPDATE flips the rule in EVERY ruleset,
    # which is not what a disposable test window on one ruleset should do.
    if ($Enable) {
        # FROM DUAL is the portable MySQL/MariaDB idiom for a constant-row INSERT..SELECT.
        Invoke-Sql -Query @"
INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
SELECT $RulesetId, 'Custom:NmsLootOffers', 'true', 'temp loot-offer test'
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM rule_values
                    WHERE ruleset_id = $RulesetId
                      AND rule_name  = 'Custom:NmsLootOffers');
"@ | Out-Null
    }
    elseif (-not $live.ContainsKey('Custom:NmsLootOffers')) {
        # -Disable with no row: the rule is already on its compiled default (false).
        # There is nothing to undo, and an unscoped UPDATE would touch 0 rows and then
        # read back '' - which used to look like a write failure.
        Write-Ok 'Custom:NmsLootOffers has no row in this ruleset - already on the compiled default (false).'
        Write-Host ''
        exit 0
    }

    Invoke-Sql -Query @"
UPDATE rule_values
   SET rule_value = '$target'
 WHERE ruleset_id = $RulesetId
   AND rule_name  = 'Custom:NmsLootOffers';
"@ | Out-Null

    $after = Invoke-Sql -Query @"
SELECT rule_value FROM rule_values
 WHERE ruleset_id = $RulesetId
   AND rule_name  = 'Custom:NmsLootOffers';
"@ | Where-Object { $_ -match '\S' } | Select-Object -First 1

    if ("$after" -eq $target) {
        Write-Ok "Custom:NmsLootOffers = $after"
        Write-Host ''
        Write-Host '  Run "#reload rules global" in game (or bounce the zone) before retesting.' -ForegroundColor Cyan
        if ($Enable) {
            Write-Host '  Disposable test window - undo with:  .\Check-LootOfferRules.ps1 -Disable' -ForegroundColor Yellow
        }
        Write-Host ''
        exit 0
    }

    Write-Bad "Write ran but the rule reads '$after', expected '$target'."
    exit 1
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
