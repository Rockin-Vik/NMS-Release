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

    Rules are layered the way RuleManager::LoadRules and zone/main.cpp do it:
      * variables.RuleSet names the active ruleset; when the variable is absent, "default".
      * "default" is loaded first, the active ruleset on top; a rule with no row in either is
        on its compiled default (see custom-rules/README.md).
      * If variables.RuleSet names a ruleset with no rule_sets row, LoadRules fails before it
        applies anything and every zone runs on compiled defaults. The script reports that and
        refuses to write until the variable is fixed.
      * A zone whose zone.ruleset is non-zero and differs from the active id loads THAT ruleset
        over the active one at boot (Zone::Init) and on #reload rules. The script lists those
        rulesets and, in write mode, pins the rule in each of them too.

    A bool rule is "on" the way the server reads it (Strings::ToBool: any value containing
    true / y / on / enable, or a non-zero number), not only the literal "true".

    Why this exists: the compiled default for Custom:HeroCatchupEnabled has been false since
    the multiclass follow-ups landed, but a rule_values row that reads as true re-enables the
    old behaviour - every class added at a guildmaster or on the Hero tab joins at
    Custom:NewClassStartLevel (1) and drags the character's effective level down with it.
    If a level-70 character shows "Level 1" after adding a class, that row is the usual cause.

    Read-only by default. -DisableCatchup writes Custom:HeroCatchupEnabled = false into the
    active ruleset and into every ruleset some zone overlays, inserting rows as needed.

.PARAMETER DisableCatchup
    Pin Custom:HeroCatchupEnabled = false in the active ruleset and every zone-overlay ruleset.

.PARAMETER RulesetId
    Override: write only this ruleset id (it must exist in rule_sets). Leave unset normally.

.PARAMETER CredentialFile
    Where to read the database password from. Default C:\NMS\credentials.txt

.EXAMPLE
    .\Check-HeroRules.ps1
    Show the five rules, where each value comes from, and the custom_version. Changes nothing.

.EXAMPLE
    .\Check-HeroRules.ps1 -DisableCatchup
    Pin the catch-up rule off so new classes join at the character's current level.

.NOTES
    After a write, run "#reload rules global" in game (there is no #reloadrules command) or
    bounce every zone. A zone with its own zone.ruleset must be bounced.

    Characters already reset to level 1 recover on their next zone-in: with catch-up off,
    LoadClassExp restores the level from the highest held class row. BUT a character that is
    standing in a zone at level 1 when the rule flips must camp or zone BEFORE gaining any
    experience: the first SetEXP with catch-up off copies the level-1 pool into every class
    row, and after that there is nothing left to restore.
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
function Write-Note { param([string] $T) Write-Host "  $T" -ForegroundColor Cyan }

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

$RuleNames = @(
    'Custom:MulticlassingEnabled',
    'Custom:MaxMulticlasses',
    $CatchupRule,
    'Custom:NewClassStartLevel',
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
    #   Overlays   list of @{Id; Name; Zones} for every distinct non-zero zone.ruleset that
    #              differs from the active id (Zone::Init loads that set over the active one)
    $defaultId = Get-Id "SELECT ruleset_id FROM rule_sets WHERE name = 'default' LIMIT 1;"
    if ($null -eq $defaultId) {
        throw "rule_sets has no 'default' ruleset - the server could not load rules either."
    }

    $wanted = Get-Text "SELECT value FROM variables WHERE varname = 'RuleSet' LIMIT 1;"
    if ($null -eq $wanted) { $wanted = 'default' }

    $mode = 'layered'
    $activeId = Get-Id "SELECT ruleset_id FROM rule_sets WHERE name = $(ConvertTo-SqlLiteral $wanted) LIMIT 1;"
    # Round-trip the id back to a name and require a match: this is what defeats a value that
    # survives quoting but selects the wrong row (injection, whitespace). Case-insensitive, because
    # the server's own lookup is a SQL compare under the table collation (utf8mb4_general_ci on a
    # deployed server), so "NMS" loads the "nms" ruleset there too.
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
        ActiveId   = $activeId
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
                $o.CatchupOn = $false
                continue
            }
            $rows = Read-RulesetRows -Id $o.Id
            $nm = $o.Name
            if ($rows.ContainsKey($CatchupRule)) {
                $ov = $rows[$CatchupRule]; $osrc = 'own row'
            } elseif ($default.ContainsKey($CatchupRule)) {
                $ov = $default[$CatchupRule]; $osrc = 'inherits default ruleset'
            } else {
                $ov = $null; $osrc = 'compiled default'
            }
            $ovShown = if ($null -ne $ov) { Format-Value $ov } else { '<not set>' }
            $colour  = if (Test-RuleOn $ov) { 'Green' } else { 'Gray' }
            Write-Host ('  id {0,-3} {1,-16} {2} zone(s): {3}' -f $o.Id, $nm, $o.Count, $o.Zones) -ForegroundColor DarkGray
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

function Write-AfterWriteAdvice {
    param([bool] $HasOverlays)
    Write-Host ''
    Write-Note 'Next, in game as a GM:  #reload rules global      (there is no #reloadrules command)'
    if ($HasOverlays) {
        Write-Note 'Zones listed above with their own zone.ruleset must be bounced; #reload re-applies their own set.'
    }
    Write-Note 'Any character standing in a zone at level 1 must camp or zone BEFORE gaining experience.'
    Write-Host '  (The first exp gain with catch-up off copies the level-1 pool into every class row; after' -ForegroundColor Gray
    Write-Host '   that nothing is left to restore. A camp or zone-in first restores the earned level.)' -ForegroundColor Gray
    Write-Host ''
}

function Set-CatchupOff {
    # One statement per ruleset: insert or overwrite, then read back and require exactly one
    # cell that is exactly 'false'.
    param([int] $Id, [string] $Label)
    Invoke-Sql -Query @"
INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
VALUES ($Id, '$CatchupRule', 'false', 'new classes join at the current level (pinned)')
ON DUPLICATE KEY UPDATE rule_value = 'false';
"@ | Out-Null

    $after = Get-Text "SELECT rule_value FROM rule_values WHERE ruleset_id = $Id AND rule_name = '$CatchupRule';"
    if ($after -eq 'false') {
        Write-Ok "$CatchupRule = false  ($Label, id $Id)"
        return $true
    }
    Write-Bad "Write to ruleset $Id ran but the rule reads '$after', expected 'false'."
    return $false
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

    $overlayOn = @($sets.Overlays | Where-Object { $_.ContainsKey('CatchupOn') -and $_.CatchupOn })

    if (-not $DisableCatchup) {
        if ($sets.Mode -eq 'compiled') {
            Write-Warn "Fix variables.RuleSet first (a rule_sets row named '$($sets.ActiveName)', or point the variable at one), then re-run."
            Write-Host '  With compiled defaults the catch-up rule is off, so a level-1 join means an older zone binary.' -ForegroundColor Gray
            Write-Host ''
            exit 0
        }
        $effectiveOn = $live.ContainsKey($CatchupRule) -and (Test-RuleOn $live[$CatchupRule])
        if ($effectiveOn) {
            Write-Warn "$CatchupRule reads as ON ('$($live[$CatchupRule])') - new classes join at Custom:NewClassStartLevel and reset the character's level."
            Write-Host '  Pin it off:  .\Check-HeroRules.ps1 -DisableCatchup' -ForegroundColor Cyan
            Write-Host ''
        } elseif ($overlayOn.Count -gt 0) {
            Write-Warn "$CatchupRule is off in the active ruleset but ON in a zone-level ruleset (see above); those zones reset the level."
            Write-Host '  Pin it off everywhere:  .\Check-HeroRules.ps1 -DisableCatchup' -ForegroundColor Cyan
            Write-Host ''
        } else {
            Write-Ok "$CatchupRule is off in every ruleset this script can see."
            Write-Host '  If a level-70 character still joins a class at level 1, the remaining causes are:' -ForegroundColor Gray
            Write-Host '    - the running zone binary predates the multiclass follow-ups (compiled default true): rebuild/deploy' -ForegroundColor Gray
            Write-Host '    - the row was changed but zones never reloaded: #reload rules global, or bounce the zones' -ForegroundColor Gray
            Write-Host '    - the character stands in a zone with its own zone.ruleset (listed above if any)' -ForegroundColor Gray
            Write-Host ''
        }
        exit 0
    }

    # ---- Write mode: pin the catch-up rule off ----------------------------
    if ($sets.Mode -eq 'compiled') {
        Write-Bad "Refusing to write: variables.RuleSet names '$($sets.ActiveName)', which has no rule_sets row, so no ruleset is loaded at all. Fix the variable first."
        exit 1
    }

    # Every write is scoped to a ruleset id that exists in rule_sets: the active one and each
    # zone-overlay set (or the single -RulesetId override). rule_values is keyed by
    # (ruleset_id, rule_name); an unscoped UPDATE would flip the rule in EVERY ruleset.
    $targets = @()
    if ($RulesetId -gt 0) {
        $nm = Get-RulesetName -Id $RulesetId
        if ($null -eq $nm) {
            Write-Bad "Refusing to write: -RulesetId $RulesetId has no rule_sets row; a row there would belong to no ruleset."
            exit 1
        }
        $targets += @{ Id = $RulesetId; Label = "override ruleset $nm" }
    } else {
        $targets += @{ Id = $sets.ActiveId; Label = "active ruleset $($sets.ActiveName)" }
        foreach ($o in $sets.Overlays) {
            if ($null -eq $o.Name) {
                Write-Warn "zone.ruleset $($o.Id) ($($o.Zones)) has no rule_sets row; Zone::Init skips it, so it is not written."
                continue
            }
            $targets += @{ Id = $o.Id; Label = "zone-level ruleset $($o.Name)" }
        }
    }

    $allOk = $true
    foreach ($t in $targets) {
        if (-not (Set-CatchupOff -Id $t.Id -Label $t.Label)) { $allOk = $false }
    }
    if (-not $allOk) { exit 1 }

    Write-AfterWriteAdvice -HasOverlays ($sets.Overlays.Count -gt 0)
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
