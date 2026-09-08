<#
.SYNOPSIS
    Reads (and optionally pins off) the multiclass "hero" Custom rules.

.DESCRIPTION
    Connects to the server database with the credentials written by the setup script and
    reports the live values of:

        Custom:MulticlassingEnabled
        Custom:MaxMulticlasses
        Custom:HeroCatchupEnabled
        Custom:NewClassStartLevel
        Custom:AAIgnoreExpansionGate

    plus the custom_version from db_version.

    Rules are layered: the server loads the "default" ruleset first, then the ruleset named
    by variables.RuleSet on top (RuleManager::LoadRules). A rule with no row in either is on
    its compiled default (see custom-rules/README.md). The script resolves both ruleset ids
    the same way, prints the row from each, and reports which one is in effect.

    Why this exists: the compiled default for Custom:HeroCatchupEnabled has been false since
    the multiclass follow-ups landed, but a live rule_values row set to true re-enables the
    old behaviour - every class added at a guildmaster or on the Hero tab joins at
    Custom:NewClassStartLevel (1) and drags the character's effective level down with it.
    If a level-70 character shows "Level 1" after adding a class, this row is the cause.

    Read-only by default. -DisableCatchup writes Custom:HeroCatchupEnabled = false in the
    ACTIVE ruleset (the one that wins), inserting the row if it is absent so the value is
    pinned rather than left to a default-ruleset row or the compiled default.

.PARAMETER DisableCatchup
    Pin Custom:HeroCatchupEnabled = false in the active ruleset (inserting the row if needed).

.PARAMETER RulesetId
    Override: treat this ruleset id as the active one instead of resolving it from
    variables.RuleSet. Leave unset normally.

.PARAMETER CredentialFile
    Where to read the database password from. Default C:\NMS\credentials.txt

.EXAMPLE
    .\Check-HeroRules.ps1
    Show the five rules and the custom_version. Changes nothing.

.EXAMPLE
    .\Check-HeroRules.ps1 -DisableCatchup
    Pin the catch-up rule off so new classes join at the character's current level.

.NOTES
    Rule changes are read by zones at boot / on #reloadrules - run #reloadrules (or bounce
    the zone) afterwards. A character that already joined a class at level 1 is repaired
    on its next login: with catch-up off, LoadClassExp converges every class row on the
    highest one held.
#>

[CmdletBinding(DefaultParameterSetName = 'Read')]
param(
    [Parameter(ParameterSetName = 'DisableCatchup', Mandatory)]
    [switch] $DisableCatchup,

    [int]    $RulesetId      = 0,
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

$CatchupRule = 'Custom:HeroCatchupEnabled'

$RuleNames = @(
    'Custom:MulticlassingEnabled',
    'Custom:MaxMulticlasses',
    $CatchupRule,
    'Custom:NewClassStartLevel',
    'Custom:AAIgnoreExpansionGate'
)

function Get-FirstCell {
    # First non-blank result line, first column only.
    param([string] $Query)
    $row = Invoke-Sql -Query $Query | Where-Object { "$_" -match '\S' } | Select-Object -First 1
    if ($null -eq $row) { return $null }
    $line = "$row"
    $i = $line.IndexOf("`t")
    if ($i -ge 0) { return $line.Substring(0, $i) }
    return $line
}

function Resolve-Rulesets {
    # Mirrors RuleManager::LoadRules: the ruleset named by variables.RuleSet is active
    # (falling back to "default" when the variable is absent), and "default" is loaded
    # underneath it. Returns the ids of both. -RulesetId overrides the active id only.
    $activeName = Get-FirstCell "SELECT value FROM variables WHERE varname = 'RuleSet' LIMIT 1;"
    if (-not $activeName) { $activeName = 'default' }
    $escaped = $activeName.Replace("'", "''")

    $defaultId = Get-FirstCell "SELECT ruleset_id FROM rule_sets WHERE name = 'default' LIMIT 1;"
    if (-not ($defaultId -match '^\d+$')) {
        throw "rule_sets has no 'default' ruleset - the server could not load rules either."
    }

    if ($RulesetId -gt 0) {
        $activeId = "$RulesetId"
        $activeName = Get-FirstCell "SELECT name FROM rule_sets WHERE ruleset_id = $RulesetId LIMIT 1;"
        if (-not $activeName) { $activeName = "<no rule_sets row for id $RulesetId>" }
    } else {
        $activeId = Get-FirstCell "SELECT ruleset_id FROM rule_sets WHERE name = '$escaped' LIMIT 1;"
        if (-not ($activeId -match '^\d+$')) {
            Write-Warn "variables.RuleSet names '$activeName' but rule_sets has no such row; the server falls back to compiled defaults. Reading 'default' instead."
            $activeId = $defaultId
            $activeName = 'default'
        }
    }

    return @{
        DefaultId  = [int] $defaultId
        ActiveId   = [int] $activeId
        ActiveName = $activeName
    }
}

function Read-RulesetRows {
    # Scoped to one ruleset: rule_values is keyed by (ruleset_id, rule_name), so an
    # unscoped read returns one row PER ruleset and the last one silently wins.
    param([int] $Id)
    $inList = ($RuleNames | ForEach-Object { "'$_'" }) -join ",`n                     "
    $rows = Invoke-Sql -Query @"
SELECT rule_name, rule_value
  FROM rule_values
 WHERE ruleset_id = $Id
   AND rule_name IN ($inList);
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
    return $live
}

function Show-Rules {
    param([hashtable] $Sets)

    $active  = Read-RulesetRows -Id $Sets.ActiveId
    $default = if ($Sets.ActiveId -eq $Sets.DefaultId) { $active } else { Read-RulesetRows -Id $Sets.DefaultId }

    Write-Host ''
    Write-Host '  Multiclass rules (rule_values)' -ForegroundColor Cyan
    Write-Host '  ------------------------------' -ForegroundColor Cyan
    Write-Host ('  active ruleset  : {0} (id {1})' -f $Sets.ActiveName, $Sets.ActiveId) -ForegroundColor DarkGray
    if ($Sets.ActiveId -ne $Sets.DefaultId) {
        Write-Host ('  default ruleset : default (id {0}) - loaded underneath the active one' -f $Sets.DefaultId) -ForegroundColor DarkGray
    }
    Write-Host ''

    # Effective value per rule, with where it came from.
    $effective = @{}
    foreach ($n in $RuleNames) {
        if ($active.ContainsKey($n)) {
            $v = $active[$n]; $src = 'active'
        } elseif ($default.ContainsKey($n)) {
            $v = $default[$n]; $src = 'default ruleset'
        } else {
            $v = $null; $src = 'compiled default'
        }
        if ($null -ne $v) {
            $effective[$n] = $v
            $colour = if ($v -match '^(true|1)$') { 'Green' }
                      elseif ($v -match '^(false|0)$') { 'Yellow' }
                      else { 'Gray' }
            Write-Host ('  {0,-32} {1,-8} ({2})' -f $n, $v, $src) -ForegroundColor $colour
        } else {
            Write-Host ('  {0,-32} {1}' -f $n, '<not set - compiled default>') -ForegroundColor DarkGray
        }
        if ($src -eq 'active' -and $default.ContainsKey($n) -and $default[$n] -ne $v) {
            Write-Host ('  {0,-32} default ruleset row is {1}, shadowed' -f '', $default[$n]) -ForegroundColor DarkGray
        }
    }

    $ver = Invoke-Sql -Query 'SELECT custom_version FROM db_version LIMIT 1;' |
        Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1
    Write-Host ''
    Write-Host ('  custom_version: {0}' -f $(if ($ver) { $ver } else { '<none>' })) -ForegroundColor Cyan
    Write-Host ''

    return $effective
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

    $sets = Resolve-Rulesets
    $live = Show-Rules -Sets $sets
    $WriteId = $sets.ActiveId

    if (-not $DisableCatchup) {
        if ($live.ContainsKey($CatchupRule) -and $live[$CatchupRule] -match '^(true|1)$') {
            Write-Warn "$CatchupRule is '$($live[$CatchupRule])' - new classes join at Custom:NewClassStartLevel and reset the character's level."
            Write-Host '  Pin it off:  .\Check-HeroRules.ps1 -DisableCatchup' -ForegroundColor Cyan
            Write-Host ''
        } else {
            Write-Ok "$CatchupRule is off - a new class joins at the character's current level."
            Write-Host ''
        }
        exit 0
    }

    # ---- Write mode: pin the catch-up rule off ----------------------------
    # Every write below is scoped to the ACTIVE ruleset, because that row is the one
    # the server reads last and therefore the one that wins over a default-ruleset row.
    # rule_values is keyed by (ruleset_id, rule_name); an unscoped UPDATE flips the rule
    # in EVERY ruleset. FROM DUAL is the portable MySQL/MariaDB constant-row INSERT..SELECT.
    Invoke-Sql -Query @"
INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
SELECT $WriteId, '$CatchupRule', 'false', 'new classes join at the current level (pinned)'
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM rule_values
                    WHERE ruleset_id = $WriteId
                      AND rule_name  = '$CatchupRule');
"@ | Out-Null

    Invoke-Sql -Query @"
UPDATE rule_values
   SET rule_value = 'false'
 WHERE ruleset_id = $WriteId
   AND rule_name  = '$CatchupRule';
"@ | Out-Null

    $after = Invoke-Sql -Query @"
SELECT rule_value FROM rule_values
 WHERE ruleset_id = $WriteId
   AND rule_name  = '$CatchupRule';
"@ | Where-Object { $_ -match '\S' } | Select-Object -First 1

    if ("$after" -eq 'false') {
        Write-Ok "$CatchupRule = $after (ruleset $($sets.ActiveName), id $WriteId)"
        Write-Host ''
        Write-Host '  Run #reloadrules in game (or bounce the zones) so running zones pick it up.' -ForegroundColor Cyan
        Write-Host '  Characters already reset to level 1 recover on their next login.' -ForegroundColor Cyan
        Write-Host ''
        exit 0
    }

    Write-Bad "Write ran but the rule reads '$after', expected 'false'."
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
