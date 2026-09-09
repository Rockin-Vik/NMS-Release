<#
.SYNOPSIS
    Read-only report of the multiclass "hero" Custom rules as the server actually layers them.

.DESCRIPTION
    Connects to the server database with the credentials written by the setup script and
    reports the live values of:

        Custom:MulticlassingEnabled
        Custom:MaxMulticlasses
        Custom:HeroCatchupEnabled
        Custom:NewClassStartLevel
        Custom:AAIgnoreExpansionGate

    plus the custom_version from db_version. Nothing is written.

    Rules are layered the way RuleManager::LoadRules and zone/main.cpp do it:
      * variables.RuleSet names the active ruleset; when the variable is absent, "default".
      * "default" is loaded first, the active ruleset on top; a rule with no row in either is
        on its compiled default (see custom-rules/README.md).
      * If variables.RuleSet names a ruleset with no rule_sets row, LoadRules fails before it
        applies anything and every zone runs on compiled defaults. The script reports that.
      * A zone whose zone.ruleset is non-zero and differs from the active id loads THAT ruleset
        over the active one at boot (Zone::Init) and on "#reload rules". The script lists those
        rulesets, their zones, and what each one sees for the catch-up rule.

    A bool rule is "on" the way the server reads it (Strings::ToBool: any value containing
    true / y / on / enable, or a non-zero number; case-sensitive), not only the literal "true".

    The design (ADR-0002, 2026-09-08): a new class joins at level 1 and the hero's level is the
    lowest held class, so Custom:HeroCatchupEnabled is expected ON with NewClassStartLevel 1.
    The compiled default is OFF, which means the live database must carry a row that reads
    as on; this script tells you whether it does, in which layer, and what every zone sees.

.PARAMETER RulesetId
    Inspect this ruleset id as if it were the active one, instead of resolving it from
    variables.RuleSet. Leave unset normally.

.PARAMETER CredentialFile
    Where to read the database password from. Default C:\NMS\credentials.txt

.EXAMPLE
    .\Check-HeroRules.ps1
    Show the five rules, where each value comes from, the zone-level rulesets, and the verdict.

.NOTES
    If you change a rule row by hand, run "#reload rules global" in game (there is no
    #reloadrules command) or bounce every zone; a zone with its own zone.ruleset must be bounced.

    Never turn the catch-up rule OFF while a hero stands in a zone at level 1: the first
    experience gain with catch-up off copies the level-1 pool into every class row and the
    recorded 70s are gone. Have them camp first.
#>

[CmdletBinding()]
param(
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
    # residual WARNING/ERROR/Note text line too. Callers still validate the SHAPE of
    # every cell they use, so a notice that slips through cannot become a value.
    $rows = @($out) |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        Where-Object { "$_" -notmatch '^\s*(WARNING|Warning|ERROR|Note|Deprecated|mysql:|mariadb:)\b' }

    foreach ($l in @($out)) { Write-Verbose "sql> $l" }
    return @($rows)
}

function ConvertTo-SqlLiteral {
    # Server-side names go through Strings::Escape, which doubles backslashes as well as
    # quotes; do the same so a value like  \' OR 1=1 --  stays inside the string literal.
    param([string] $S)
    return "'" + $S.Replace('\', '\\').Replace("'", "''") + "'"
}

function Get-Cells {
    # Result rows as arrays of cells, split on tabs. Blank lines dropped.
    param([string] $Query)
    $rows = @()
    foreach ($r in (Invoke-Sql -Query $Query)) {
        $line = "$r"
        if ($line -notmatch '\S') { continue }
        $rows += , @($line -split "`t")
    }
    return , $rows
}

function Get-Id {
    # Exactly one row, first cell an integer; anything else is "not found".
    param([string] $Query)
    $rows = Get-Cells -Query $Query
    if ($rows.Count -ne 1) { return $null }
    $cell = "$($rows[0][0])"
    if ($cell -match '^\d+$') { return [int] $cell }
    return $null
}

function Get-Text {
    # Exactly one row, first cell as text; NULL and empty count as "not found".
    param([string] $Query)
    $rows = Get-Cells -Query $Query
    if ($rows.Count -ne 1) { return $null }
    $cell = "$($rows[0][0])"
    if ($cell -eq '' -or $cell -eq 'NULL' -or $cell -eq '\N') { return $null }
    return $cell
}

function Test-RuleOn {
    # Mirrors Strings::ToBool (common/strings.cpp): substring tests, then a non-zero number.
    param([string] $V)
    if ($null -eq $V) { return $false }
    if ($V -eq 'NULL' -or $V -eq '\N') { return $false }
    foreach ($needle in 'true', 'y', 'on', 'enable') {
        if ($V.Contains($needle)) { return $true }
    }
    if ($V -match '^\s*-?\d+\s*$') { return ([long] $V.Trim()) -ne 0 }
    return $false
}

$CatchupRule = 'Custom:HeroCatchupEnabled'
$StartRule   = 'Custom:NewClassStartLevel'

$RuleNames = @(
    'Custom:MulticlassingEnabled',
    'Custom:MaxMulticlasses',
    $CatchupRule,
    $StartRule,
    'Custom:AAIgnoreExpansionGate'
)

function Get-RulesetName {
    param([int] $Id)
    return Get-Text "SELECT name FROM rule_sets WHERE ruleset_id = $Id LIMIT 1;"
}

function Resolve-Rulesets {
    # Returns a hashtable:
    #   Mode       'layered'  - default + active, like a healthy LoadRules
    #              'compiled' - variables.RuleSet names a ruleset that does not exist;
    #                           LoadRules fails before applying anything (rulesys.cpp) and
    #                           zone/main.cpp does NOT fall back to loading "default"
    #   DefaultId, ActiveId, ActiveName
    #   Overlays   list of @{Id; Name; Zones; Count} for every distinct non-zero zone.ruleset
    #              that differs from the active id (Zone::Init loads that set over the active one)
    $defaultId = Get-Id "SELECT ruleset_id FROM rule_sets WHERE name = 'default' LIMIT 1;"
    if ($null -eq $defaultId) {
        throw "rule_sets has no 'default' ruleset - the server could not load rules either."
    }

    $mode = 'layered'
    if ($RulesetId -gt 0) {
        $activeId = $RulesetId
        $wanted = Get-RulesetName -Id $RulesetId
        if ($null -eq $wanted) {
            throw "-RulesetId $RulesetId has no rule_sets row; nothing loads from it."
        }
    } else {
        $wanted = Get-Text "SELECT value FROM variables WHERE varname = 'RuleSet' LIMIT 1;"
        if ($null -eq $wanted) { $wanted = 'default' }

        $activeId = Get-Id "SELECT ruleset_id FROM rule_sets WHERE name = $(ConvertTo-SqlLiteral $wanted) LIMIT 1;"
        # Round-trip the id back to a name and require a match: this is what defeats a value that
        # survives quoting but selects the wrong row (injection, whitespace). Case-insensitive,
        # because the server's own lookup is a SQL compare under the table collation
        # (utf8mb4_general_ci on a deployed server), so "NMS" loads the "nms" ruleset there too.
        if ($null -ne $activeId) {
            $back = Get-RulesetName -Id $activeId
            if ($null -eq $back -or -not [string]::Equals($back, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                $activeId = $null
            }
        }
        if ($null -eq $activeId) {
            $mode = 'compiled'
            $activeId = $defaultId
        }
    }

    $overlays = @()
    foreach ($row in (Get-Cells "SELECT ruleset, COUNT(*), GROUP_CONCAT(short_name ORDER BY short_name SEPARATOR ' ') FROM zone WHERE ruleset <> 0 AND ruleset <> $activeId GROUP BY ruleset ORDER BY ruleset;")) {
        $id = "$($row[0])"
        if ($id -notmatch '^\d+$') { continue }
        $zones = if ($row.Count -ge 3) { "$($row[2])" } else { '' }
        $name = Get-RulesetName -Id ([int] $id)
        $overlays += @{ Id = [int] $id; Name = $name; Zones = $zones; Count = "$($row[1])" }
    }

    return @{
        Mode       = $mode
        DefaultId  = $defaultId
        ActiveId   = [int] $activeId
        ActiveName = $wanted
        Overlays   = $overlays
    }
}

function Read-RulesetRows {
    # Scoped to one ruleset: rule_values is keyed by (ruleset_id, rule_name), so an
    # unscoped read returns one row PER ruleset and the last one silently wins.
    param([int] $Id)
    $inList = ($RuleNames | ForEach-Object { "'$_'" }) -join ",`n                     "
    $live = @{}
    foreach ($row in (Get-Cells @"
SELECT rule_name, rule_value
  FROM rule_values
 WHERE ruleset_id = $Id
   AND rule_name IN ($inList);
"@)) {
        # A cell that is not one of our rule names is a stray line, not a row.
        if ($row.Count -lt 2) { continue }
        $name = "$($row[0])"
        if ($RuleNames -notcontains $name) { continue }
        $live[$name] = "$($row[1])"
    }
    return $live
}

function Format-Value {
    param([string] $V)
    if ($V -eq 'NULL' -or $V -eq '\N') { return '<NULL>' }
    if ($V -eq '') { return '<empty>' }
    return $V
}

function Show-Rules {
    param([hashtable] $Sets)

    Write-Host ''
    Write-Host '  Multiclass rules (rule_values)' -ForegroundColor Cyan
    Write-Host '  ------------------------------' -ForegroundColor Cyan

    if ($Sets.Mode -eq 'compiled') {
        Write-Warn "variables.RuleSet is '$($Sets.ActiveName)' but rule_sets has no such row."
        Write-Host '  RuleManager::LoadRules fails before it applies anything and zone/main.cpp does not' -ForegroundColor Gray
        Write-Host '  fall back to "default": every zone is running on COMPILED defaults. No rule_values' -ForegroundColor Gray
        Write-Host '  row matters until the variable names a real ruleset.' -ForegroundColor Gray
        Write-Host ''
        foreach ($n in $RuleNames) {
            Write-Host ('  {0,-32} {1}' -f $n, '<compiled default>') -ForegroundColor DarkGray
        }
        Write-Host ''
        return @{}
    }

    $active  = Read-RulesetRows -Id $Sets.ActiveId
    $default = if ($Sets.ActiveId -eq $Sets.DefaultId) { $active } else { Read-RulesetRows -Id $Sets.DefaultId }

    Write-Host ('  active ruleset  : {0} (id {1})' -f $Sets.ActiveName, $Sets.ActiveId) -ForegroundColor DarkGray
    if ($Sets.ActiveId -ne $Sets.DefaultId) {
        Write-Host ('  default ruleset : default (id {0}) - loaded underneath the active one' -f $Sets.DefaultId) -ForegroundColor DarkGray
        $activeRowCount = Get-Id "SELECT COUNT(*) FROM rule_values WHERE ruleset_id = $($Sets.ActiveId);"
        if ($activeRowCount -eq 0) {
            Write-Host '  note: the active ruleset has no rule_values rows at all; LoadRules reports a failure' -ForegroundColor DarkGray
            Write-Host '  after the default rows are already applied, so the default layer is what runs.' -ForegroundColor DarkGray
        }
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
            $shown  = Format-Value $v
            $colour = if (Test-RuleOn $v) { 'Green' } elseif ($v -match '^\s*(false|0)\s*$') { 'Yellow' } else { 'Gray' }
            Write-Host ('  {0,-32} {1,-8} ({2})' -f $n, $shown, $src) -ForegroundColor $colour
            if ($colour -eq 'Gray' -and $shown -notmatch '^<') {
                # Strings::ToBool is a case-sensitive substring test: "True", "On", "TRUE" all read as OFF.
                Write-Host ('  {0,-32} reads as OFF to the server (Strings::ToBool is case-sensitive)' -f '') -ForegroundColor DarkGray
            }
        } else {
            Write-Host ('  {0,-32} {1}' -f $n, '<not set - compiled default>') -ForegroundColor DarkGray
        }
        if ($src -eq 'active' -and $default.ContainsKey($n) -and $default[$n] -ne $v) {
            Write-Host ('  {0,-32} default ruleset row is {1}, shadowed' -f '', (Format-Value $default[$n])) -ForegroundColor DarkGray
        }
    }

    # Zone overlays: those zones load their own ruleset over the active one.
    if ($Sets.Overlays.Count -gt 0) {
        Write-Host ''
        Write-Host '  Zone-level rulesets (zone.ruleset <> active; loaded over the active set by those zones)' -ForegroundColor Cyan
        foreach ($o in $Sets.Overlays) {
            if ($null -eq $o.Name) {
                # Zone::Init looks the id up by name and skips the load when there is none, so
                # those zones simply run the active ruleset. Not an overlay, just a stale column.
                Write-Host ('  id {0,-3} {1,-16} {2} zone(s): {3}' -f $o.Id, '<no rule_sets row>', $o.Count, $o.Zones) -ForegroundColor DarkGray
                Write-Host '       Zone::Init skips a ruleset with no rule_sets row; these zones use the active ruleset.' -ForegroundColor DarkGray
                $o.CatchupOn = $null
                continue
            }
            $rows = Read-RulesetRows -Id $o.Id
            if ($rows.ContainsKey($CatchupRule)) {
                $ov = $rows[$CatchupRule]; $osrc = 'own row'
            } elseif ($default.ContainsKey($CatchupRule)) {
                $ov = $default[$CatchupRule]; $osrc = 'inherits default ruleset'
            } else {
                $ov = $null; $osrc = 'compiled default'
            }
            $ovShown = if ($null -ne $ov) { Format-Value $ov } else { '<not set>' }
            $colour  = if (Test-RuleOn $ov) { 'Green' } else { 'Gray' }
            Write-Host ('  id {0,-3} {1,-16} {2} zone(s): {3}' -f $o.Id, $o.Name, $o.Count, $o.Zones) -ForegroundColor DarkGray
            Write-Host ('       {0,-32} {1,-8} ({2})' -f $CatchupRule, $ovShown, $osrc) -ForegroundColor $colour
            $o.CatchupOn = Test-RuleOn $ov
        }
    }

    $ver = Get-Text 'SELECT custom_version FROM db_version LIMIT 1;'
    Write-Host ''
    Write-Host ('  custom_version: {0}' -f $(if ($ver -match '^\d+$') { $ver } else { '<none>' })) -ForegroundColor Cyan
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

    # ---- Verdict against the design: catch-up ON, start level 1 ------------
    if ($sets.Mode -eq 'compiled') {
        Write-Warn "No ruleset is loaded, so $CatchupRule is on its compiled default (OFF): new classes join at the hero's current level, against the design."
        Write-Host "  Fix variables.RuleSet first (a rule_sets row named '$($sets.ActiveName)', or point the variable at one), then re-run." -ForegroundColor Gray
        Write-Host ''
        exit 0
    }

    $catchupOn = $live.ContainsKey($CatchupRule) -and (Test-RuleOn $live[$CatchupRule])
    $startLevel = if ($live.ContainsKey($StartRule) -and $live[$StartRule] -match '^\s*\d+\s*$') { [int] $live[$StartRule].Trim() } else { 1 }
    $overlaysOff = @($sets.Overlays | Where-Object { $_.ContainsKey('CatchupOn') -and $null -ne $_.CatchupOn -and -not $_.CatchupOn })

    if ($catchupOn) {
        Write-Ok "$CatchupRule reads as ON: a new class joins at level $startLevel and the hero's level is its lowest class (the design)."
    } else {
        $shown = if ($live.ContainsKey($CatchupRule)) { "'$($live[$CatchupRule])'" } else { 'not set (compiled default false)' }
        Write-Warn "$CatchupRule is $shown - new classes join at the hero's CURRENT level, against the design."
        Write-Host '  To turn it on, by hand, in the active ruleset (then "#reload rules global"):' -ForegroundColor Gray
        Write-Host ("    INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes) VALUES ({0}, '{1}', 'true', 'hero: new class joins at level 1')" -f $sets.ActiveId, $CatchupRule) -ForegroundColor Cyan
        Write-Host "    ON DUPLICATE KEY UPDATE rule_value = 'true';" -ForegroundColor Cyan
    }
    if ($startLevel -ne 1) {
        Write-Warn "$StartRule is $startLevel; the design is 1."
    }
    if ($overlaysOff.Count -gt 0) {
        Write-Warn 'A zone-level ruleset above reads the catch-up rule as OFF; heroes adding a class in those zones join at the current level.'
    }
    Write-Host ''
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
