<#
.SYNOPSIS
    Stage 2 of 2 - clones, builds, configures and registers the NMS EverQuest server.

.DESCRIPTION
    Runs 1-Install-Prerequisites.ps1 first. Then this script takes it from source to a
    running server, in twelve resumable stages:

        Clone      Clone (or update) the public NMS-Release repo
        Database   Create schema + user with a generated password, import the 540 MB dump
        Build      CMake configure + build Release/x64
        Runtime    Assemble the run directory: binaries, patches, quests, plugins, logs
        Maps       Fetch zone pathing/LOS maps - NOT in the repo and in no README
        Config     Write eqemu_config.json and login.json with real credentials + public IP
        Migrate    Run shared_memory, then boot world to apply both manifests
        Patches    Apply the 10 loose .sql files that nothing else applies (CODEBASE.md 4.4).
                   Runs AFTER Migrate so manifest entries cannot clobber them.
        Login      Create the loginserver's five tables. Also in no manifest and not in
                   the dump - without them the login service exits on its first query.
        Health     Run the health-check SQL, because custom_version lies (CODEBASE.md 4.3)
        Export     Run export_client_files and stage the four client data files
        Services   Register world/zone/ucs/queryserv/loginserver as Windows services,
                   set to MANUAL start - use start-server.ps1, which sequences them
        Firewall   Open UDP 5998, 7000-7400, 7778, 9000. Never 3306, never telnet.

    Every stage is independently re-runnable. If one fails, fix the cause and resume from
    that stage rather than starting over.

.PARAMETER InstallRoot
    Where everything lives. Default C:\NMS. Source goes to <root>\src, the built server to
    <root>\server, client files to <root>\client-files.

.PARAMETER Stage
    Run only from this stage onward. In execution order: Clone, Database, Build, Runtime,
    Maps, Config, Migrate, Patches, Health, Export, Services, Firewall, All. Default All.

.PARAMETER OnlyStage
    Run exactly one stage and stop. Useful for iterating on a single failing step.

.PARAMETER RepoUrl
    Git URL to clone the server source from.

    If omitted, the script works it out in this order:
      1. the 'origin' remote of the checkout these scripts came from, if they were copied
         out of a clone and that clone is still reachable
      2. the 'origin' remote of an existing clone already at <InstallRoot>\src
    If neither applies it stops and asks for -RepoUrl. That keeps any particular fork's
    URL out of the script.

.PARAMETER PublicAddress
    The address players connect to. Auto-detected if omitted. Set this explicitly if the
    box is behind NAT or you have a DNS name you want in the config.

.PARAMETER ServerLongName
    Server name shown in the server list. Default 'NMS Server'.

.PARAMETER ServerShortName
    Short name used internally. Default 'nms'.

.PARAMETER DbName
    Schema name. Default 'peq'.

.PARAMETER DbUser
    DB user the server connects as. Default 'peq'.

.PARAMETER MariaDbRootPassword
    Root password, used only to create the schema and user. If omitted the script reads it
    from the credentials file written by stage 1, then falls back to prompting.

.PARAMETER SkipDatabaseImport
    Skip the 540 MB import. Use when re-running against a database already imported - it
    is by far the slowest stage.

.EXAMPLE
    .\2-Setup-NMSServer.ps1
    Full run, everything.

.EXAMPLE
    .\2-Setup-NMSServer.ps1 -Stage Build
    Resume from the build, keeping the existing clone and database.

.EXAMPLE
    .\2-Setup-NMSServer.ps1 -OnlyStage Health
    Just audit the database and print what content actually landed.

.NOTES
    Target:  Windows Server 2019/2022/2025 (also fine on Windows 10/11), full Administrator.
             Budget ~40 GB disk and expect the build to use every core you give it.
    Login:   local loginserver on 5998 (not Project EQ public login)
    Time:    2-4 hours on a fresh box; the build and the DB import dominate

    UNTESTED ON A REAL VPS. Treat the first run as a supervised dry run. A full transcript
    is written to <InstallRoot>\logs\.

    Read CODEBASE.md (one level up, in Release-NMS-Deploy/) before debugging anything
    here. Several stages exist only to work
    around documented traps in the codebase, and the comments reference it by section.
#>

[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\NMS',

    [ValidateSet('Clone','Database','Build','Runtime','Maps','Config',
                 'Migrate','Patches','Login','Health','Export','Services','Firewall','All')]
    [string] $Stage = 'All',

    [ValidateSet('Clone','Database','Build','Runtime','Maps','Config',
                 'Migrate','Patches','Login','Health','Export','Services','Firewall')]
    [string] $OnlyStage,

    # Where to clone the server source from. Left empty on purpose: the script derives it
    # from the checkout these scripts were copied out of, so a fork works with no edit.
    # Pass -RepoUrl explicitly when running the scripts standalone.
    [string] $RepoUrl,
    [string] $PublicAddress,
    [string] $ServerLongName  = 'NMS Server',
    [string] $ServerShortName = 'nms',
    [string] $DbName = 'peq',
    [string] $DbUser = 'peq',
    [string] $MariaDbRootPassword,
    [switch] $SkipDatabaseImport,

    # DESTRUCTIVE. login_schema.sql begins every statement with DROP TABLE IF EXISTS, so
    # re-applying it deletes every player login account. Only pass this to deliberately
    # rebuild the loginserver schema from scratch.
    [switch] $ForceLoginSchema,

    # Do not add a Defender exclusion for -InstallRoot. Expect to restore quarantined
    # binaries by hand: Defender removes the compiled server executables after they are
    # copied, and the services then fail to start with no stated cause.
    [switch] $SkipDefenderExclusion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell 7.4+ defaults $PSNativeCommandUseErrorActionPreference to $true, which turns
# ANY non-zero exit from a native command into a terminating error - before our own
# exit-code checks can run. That is fatal here: robocopy returns 1 on SUCCESS ("files
# copied"), so the Runtime stage would die on the first quest copy, and `git rev-list`
# with no upstream returns non-zero too. Native exit codes are checked explicitly
# throughout (robocopy >= 8, cmake, git); we do not want them thrown.
# On PowerShell 5.1 this variable does not exist and the assignment is a harmless no-op.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

$script:SrcRoot        = Join-Path $InstallRoot 'src'
$script:ServerRoot     = Join-Path $InstallRoot 'server'
$script:ClientOut      = Join-Path $InstallRoot 'client-files'
$script:LogRoot        = Join-Path $InstallRoot 'logs'
$script:CredentialFile = Join-Path $InstallRoot 'credentials.txt'

$script:RepoServer  = Join-Path $script:SrcRoot 'Release-NMS-Server'
$script:RepoQuests  = Join-Path $script:SrcRoot 'Release-NMS-Quests'
$script:RepoPlugins = Join-Path $script:SrcRoot 'Release-NMS-Plugins'
$script:RepoClient  = Join-Path $script:SrcRoot 'Release-NMS-Client'
$script:BuildDir    = Join-Path $script:RepoServer 'Build'
$script:BinDir      = Join-Path $script:BuildDir  'bin\Release'

# Zone pathing / line-of-sight maps. utils/defaults/Maps in the repo is an empty .keep
# directory and no README mentions this - zones misbehave badly without it.
#
# Layout inside this repo (per its readme):
#   base/<zone>.map    line of sight, best-Z calculation
#   water/<zone>.wtr   water/lava region detection
#   nav/<zone>.nav     navmesh for NPC pathing
# These land as Maps/base, Maps/water, Maps/nav under the server root.
$script:MapsRepo = 'https://github.com/EQEmu/maps.git'
$script:MapsSubdirs = @('base', 'water', 'nav')

# The ten loose .sql files. Nothing in the codebase applies these - grep confirms zero
# references. See CODEBASE.md 4.4.
$script:LoosePatches = @(
    'Release-NMS-Server\baztradeskills.sql',
    'Release-NMS-Server\environmentdoodads.sql',
    'Release-NMS-Server\holedoor.sql',
    'Release-NMS-Server\kaesoradoors.sql',
    'Release-NMS-Server\pojdoors.sql',
    'Release-NMS-Server\pomdoors.sql',
    'Release-NMS-Server\tranquilitydebris.sql',
    'Release-NMS-Quests\akanonfixyetanotherlamp.sql',
    'Release-NMS-Quests\overlordngrub.sql',
    'Release-NMS-Quests\skyfiredoodads.sql'
)

# Patches runs AFTER Migrate, deliberately. The ten loose .sql files are UPDATEs against
# doors/object/npc_types rows; if a manifest entry rewrites any of those rows, running the
# patches first means the manifest silently clobbers them and we would report success.
$script:StageOrder = @('Clone','Database','Build','Runtime','Maps','Config',
                       'Migrate','Patches','Login','Health','Export','Services','Firewall')

# The loginserver's own schema. Historically the loginserver ran against a separate
# database, so these tables are not in the PEQ dump and no migration manifest creates
# them - the files just sit in loginserver/login_util/ waiting to be applied by hand.
# Without them the service starts, connects, fails its first query and exits, which
# Windows reports only as "Failed to start service".
$script:LoginSchemaFiles = @(
    'Release-NMS-Server\loginserver\login_util\login_schema.sql',
    'Release-NMS-Server\loginserver\login_util\login_tickets.sql'
)

# Tables login_schema.sql creates. Used to decide whether it has already been applied.
$script:LoginTables = @(
    'login_accounts', 'login_server_admins', 'login_server_list_types',
    'login_world_servers', 'login_api_tokens'
)

# Lookup rows for login_server_list_types. The schema creates the table empty, but
# loginserver/login_types.h:147 defines the ids and world_server.cpp:436 auto-registers
# new worlds as Standard (3).
$script:LoginServerListTypes = @(
    @{ Id = 1; Description = 'Legends' }
    @{ Id = 2; Description = 'Preferred' }
    @{ Id = 3; Description = 'Standard' }
)

# Services, in boot order. shared_memory is deliberately absent: it is a run-once tool
# that must exit before world starts, not a service. See CODEBASE.md section 2.
$script:Services = @(
    @{ Name = 'NMS-LoginServer'; Exe = 'loginserver.exe'; Display = 'NMS Login Server';  Args = '' }
    @{ Name = 'NMS-World';       Exe = 'world.exe';       Display = 'NMS World Server';  Args = '' }
    @{ Name = 'NMS-Zone';        Exe = 'eqlaunch.exe';    Display = 'NMS Zone Launcher'; Args = 'zone' }
    @{ Name = 'NMS-UCS';         Exe = 'ucs.exe';         Display = 'NMS Chat Server';   Args = '' }
    @{ Name = 'NMS-QueryServ';   Exe = 'queryserv.exe';   Display = 'NMS Query Server';  Args = '' }
)

# All player-facing traffic is UDP. EQEmu builds every client-facing listener on
# EQStreamManager -> DaybreakConnectionManager -> uv_udp_t. In particular world's client
# listener is hardcoded UDP 9000 in world/main.cpp:335 and is NOT the world.tcp.port from
# the config; UCS is the same (ucs/clientlist.cpp:470). Opening these as TCP lets a player
# authenticate on 5998 and then hang forever at server select.
#
# 9001 (world servertalk) is bound to 127.0.0.1 in our config, so it is not listed here.
$script:FirewallRules = @(
    # 5998 is the Titanium opcode stream, 5999 the SoD-lineage one - loginserver runs BOTH
    # (client_manager.cpp:88 and :126) with DIFFERENT opcode files. RoF2 is SoD-lineage and
    # must use 5999; on 5998 the session opens and then OP_Login is never recognised, so
    # the client hangs at "Logging in to the server" forever with no server-side error.
    @{ Name = 'NMS Login Server';      Port = '5998'; Protocol = 'UDP' }
    @{ Name = 'NMS Login Server SoD';  Port = '5999'; Protocol = 'UDP' }
    @{ Name = 'NMS World Server';  Port = '9000';      Protocol = 'UDP' }
    @{ Name = 'NMS Chat Server';   Port = '7778';      Protocol = 'UDP' }
    @{ Name = 'NMS Zone Servers';  Port = '7000-7400'; Protocol = 'UDP' }
)

$script:Summary = [System.Collections.Generic.List[object]]::new()

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
            SUCCEEDED, and even when the stream is redirected to $null. This is not an edge
            case here: git writes clone/fetch progress to stderr on every single run, and
            cmake, robocopy and winget all do the same.
          * PowerShell 7.4+ escalates any non-zero exit code the same way - which would kill
            the Runtime stage outright, since robocopy returns 1 to mean "files copied".

        Every native exit code in this script is checked explicitly (robocopy >= 8, cmake,
        git), so relax the preference for the duration of the call and hand the code back
        for the caller to judge.

    .EXAMPLE
        $code = Invoke-Native -Show { git clone --depth 1 $url $dest }
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

function Write-TextFile {
    <#
    .SYNOPSIS
        Writes a text file as UTF-8 WITHOUT a byte-order mark.

    .DESCRIPTION
        This is not a style preference, it is a hard requirement for the JSON configs.

        PowerShell 5.1's `Set-Content -Encoding UTF8` prepends a BOM (EF BB BF). EQEmu
        parses its config with jsoncpp, which does not tolerate one, and fails with:

            Error from reader: * Line 1, Column 1
              Syntax error: value, object or array expected.
            Init Failed to load eqemu config

        world.exe then exits immediately, and export_client_files.exe cannot connect -
        so a single BOM takes out the Migrate and Export stages and leaves a server that
        will not boot, all with an error that points at the JSON rather than the encoding.

        PowerShell 7 changed the default to BOM-less, so this only bites on 5.1 - which
        is what ships with Windows Server. [IO.File]::WriteAllText is BOM-less on both.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    # Resolve to a full filesystem path. WriteAllText uses the PROCESS working directory,
    # which is not PowerShell's current location - they diverge after Push-Location, and a
    # relative path would land somewhere unexpected.
    #
    # GetUnresolvedProviderPathFromPSPath handles absolute and relative alike and does not
    # require the file to exist yet. Do NOT hand an already-rooted path to Join-Path first:
    # that yields "C:\current\dir\C:\other\path" and GetFullPath then throws
    # "The given path's format is not supported."
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Step { param([string] $Text) Write-Host "  -> $Text" -ForegroundColor Gray }
function Write-Ok   { param([string] $Text) Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string] $Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Add-Summary {
    param([string] $StageName, [string] $State, [string] $Detail = '')
    $script:Summary.Add([pscustomobject]@{ Stage = $StageName; State = $State; Detail = $Detail })
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-NmsServices {
    <#
        Stops any running NMS services and waits for the processes to release their files.

        Required before Runtime (which overwrites the binaries - Windows refuses to replace
        a running executable), and before Migrate (which starts its own world.exe and would
        otherwise collide with the service over port 9001).

        Paused counts as running here: that is NSSM's crash-loop state, and a paused service
        can still hold file handles.
    #>
    param([string] $Reason = 'to release file handles')

    $running = @(Get-Service -Name 'NMS-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -in 'Running', 'Paused' })

    if ($running.Count -eq 0) { return @() }

    Write-Step "Stopping $($running.Count) running service(s) $Reason..."
    foreach ($s in $running) {
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        Write-Step "  stopped $($s.Name)"
    }

    # Service 'Stopped' only means the SCM is done; the process can linger briefly and
    # keep its executable locked. Wait for the images themselves to go.
    $names = @('world', 'zone', 'ucs', 'queryserv', 'loginserver', 'eqlaunch', 'shared_memory')
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $alive = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }

    $alive = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($alive.Count -gt 0) {
        Write-Warn "$($alive.Count) server process(es) still running; forcing."
        $alive | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Ok 'Services stopped.'
    return @($running | ForEach-Object { $_.Name })
}

function Set-DefenderExclusion {
    <#
        Excludes the install root from Microsoft Defender.

        This is not optional hardening-avoidance, it is required for the build to survive.
        Defender quarantines freshly compiled, unsigned executables that open listening
        sockets and handle credentials - which describes world.exe, zone.exe, ucs.exe,
        shared_memory.exe and loginserver.exe exactly. Observed behaviour: the binaries
        are removed from the runtime folder AFTER being copied, so services get registered
        against files that then disappear, and Windows reports only "Failed to start
        service" with no cause.

        The trade-off is real and worth stating: nothing under this path is scanned any
        more. That is defensible for a directory containing only binaries you compiled
        yourself from source you control - but it does mean anything else written there
        is also unscanned, so do not use the install root as a general download folder.

        -SkipDefenderExclusion opts out; expect to re-add quarantined binaries by hand.
    #>
    if ($SkipDefenderExclusion) {
        Write-Warn 'Defender exclusion skipped by request.'
        Write-Warn 'If binaries vanish from the runtime folder after the build, this is why.'
        return
    }

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Step 'Defender cmdlets unavailable (third-party AV, or Defender removed).'
        Write-Step "If your AV quarantines the built binaries, exclude $InstallRoot by hand."
        return
    }

    try {
        $current = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        if ($current -contains $InstallRoot) {
            Write-Ok "Defender already excludes $InstallRoot"
            return
        }
        Add-MpPreference -ExclusionPath $InstallRoot -ErrorAction Stop
        Write-Ok "Added Defender exclusion for $InstallRoot"
        Write-Step 'Without this, Defender quarantines the compiled server binaries and the'
        Write-Step 'services fail to start with no explanation.'
    } catch {
        Write-Warn "Could not add the Defender exclusion: $($_.Exception.Message)"
        Write-Warn 'Add it by hand if binaries disappear after the build:'
        Write-Warn "  Add-MpPreference -ExclusionPath '$InstallRoot'"
    }
}

function Should-Run {
    param([string] $Name)
    if ($OnlyStage) { return $Name -eq $OnlyStage }
    if ($Stage -eq 'All') { return $true }
    return ($script:StageOrder.IndexOf($Name)) -ge ($script:StageOrder.IndexOf($Stage))
}

function New-Password {
    param([int] $Length = 28)
    # No quotes, backslash, backtick or shell metacharacters - this value travels through
    # JSON, a SQL statement and a PowerShell string, and escaping through all three is not
    # worth the risk.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_=+.'
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# ---------------------------------------------------------------------------
# Credential file
# ---------------------------------------------------------------------------

function Get-StoredCredential {
    param([string] $Label)
    if (-not (Test-Path $script:CredentialFile)) { return $null }
    $line = Get-Content $script:CredentialFile |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Label))\s*=\s*(.+)$" } |
        Select-Object -Last 1
    if ($line -match '=\s*(.+)$') { return $Matches[1].Trim() }
    return $null
}

function Set-StoredCredential {
    param([string] $Label, [string] $Value)

    if (-not (Test-Path $script:CredentialFile)) {
        $header = @(
            '# NMS server credentials',
            "# Created $(Get-Date -Format 'u')",
            '# Keep this. Back it up somewhere off this machine.',
            ''
        ) -join "`r`n"
        Write-TextFile -Path $script:CredentialFile -Content $header

        $acl = Get-Acl $script:CredentialFile
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($who in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $who, 'FullControl', 'Allow'))
        }
        Set-Acl -Path $script:CredentialFile -AclObject $acl
    }

    $existing = Get-Content $script:CredentialFile | Where-Object {
        $_ -notmatch "^\s*$([regex]::Escape($Label))\s*="
    }
    # @() so a single remaining line stays an array - bare + on a scalar string is
    # concatenation, not append, and would collapse the file to one mangled line.
    Write-TextFile -Path $script:CredentialFile -Content ((@($existing) + "$Label = $Value") -join "`r`n")
}

# ---------------------------------------------------------------------------
# MySQL helpers
# ---------------------------------------------------------------------------

function Resolve-MysqlClient {
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
    throw 'Could not find mysql.exe or mariadb.exe. Run 1-Install-Prerequisites.ps1 first.'
}

function Invoke-Sql {
    <#
        Runs SQL through the client. The password goes via MYSQL_PWD rather than -p on the
        command line, so it does not show up in the process list or in this transcript.
    #>
    param(
        [Parameter(Mandatory)] [string] $Query,
        [string] $User = 'root',
        [string] $Password,
        [string] $Database,
        [switch] $Quiet
    )

    $client = Resolve-MysqlClient
    $cliArgs = @('--host=127.0.0.1', '--port=3306', "--user=$User", '--batch', '--silent')
    if ($Database) { $cliArgs += "--database=$Database" }

    $old = $env:MYSQL_PWD
    $env:MYSQL_PWD = $Password
    try {
        # EAP relaxed for the same reason as Invoke-Native: the client writes warnings to
        # stderr, and under 'Stop' PowerShell 5.1 turns those into a terminating error even
        # when the query succeeded. Exit code is checked explicitly below.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = $Query | & $client @cliArgs 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prevEap }
    } finally {
        if ($null -eq $old) { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $old }
    }

    if ($code -ne 0 -and -not $Quiet) {
        throw "SQL failed (exit $code): $($out -join [Environment]::NewLine)"
    }
    return $out
}

function Invoke-SqlFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $User = 'root',
        [string] $Password,
        [Parameter(Mandatory)] [string] $Database
    )

    $client = Resolve-MysqlClient
    $cliArgs = @('--host=127.0.0.1', '--port=3306', "--user=$User", "--database=$Database")

    $old = $env:MYSQL_PWD
    $env:MYSQL_PWD = $Password
    try {
        # cmd.exe redirection streams the file. Get-Content | pipe would pull a 540 MB
        # dump through PowerShell's object pipeline and take an eternity.
        # Invoke-Native because the client writes warnings to stderr on a large import,
        # and under 'Stop' those would abort a perfectly good restore.
        $cmdLine = "`"$client`" $($cliArgs -join ' ') < `"$Path`""
        $code = Invoke-Native -Capture { cmd.exe /c $cmdLine }
        $script:NativeOutput | ForEach-Object {
            if ($_ -match 'ERROR') { Write-Warn $_ }
        }
    } finally {
        if ($null -eq $old) { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $old }
    }

    if ($code -ne 0) { throw "Import of $(Split-Path -Leaf $Path) failed with exit code $code" }
}

function Get-RootPassword {
    if ($MariaDbRootPassword) { return $MariaDbRootPassword }

    $stored = Get-StoredCredential 'MariaDB root password'
    if ($stored) {
        Write-Step 'Using the root password recorded by stage 1.'
        return $stored
    }

    Write-Warn 'No MariaDB root password found in the credentials file.'
    $sec = Read-Host -Prompt '  Enter the MariaDB root password' -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

# ---------------------------------------------------------------------------
# Stage: Clone
# ---------------------------------------------------------------------------

function Resolve-RepoUrl {
    <#
        Works out where to clone from, without hardcoding anyone's fork.

        Order: the caller's -RepoUrl, then the origin of the checkout these scripts were
        copied out of (../.. from build-scripts/), then the origin of an existing clone at
        <InstallRoot>\src. Failing all three, ask.
    #>
    if ($RepoUrl) { return $RepoUrl }

    $candidates = @(
        (Resolve-Path (Join-Path $PSScriptRoot '..\..') -ErrorAction SilentlyContinue),
        $script:SrcRoot
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ '.git')) }

    foreach ($c in $candidates) {
        if ((Invoke-Native -Capture { git -C "$c" remote get-url origin }) -eq 0) {
            $url = ($script:NativeOutput | Select-Object -First 1)
            if ($url -match '\S') {
                Write-Step "Using the origin of $c"
                return "$url".Trim()
            }
        }
    }

    throw @'
Could not determine which repository to clone.

Pass it explicitly:
    .\2-Setup-NMSServer.ps1 -RepoUrl https://github.com/<owner>/NMS-Release.git

The script normally reads this from the checkout it was copied out of, so running it from
inside a clone needs no argument.
'@
}

function Invoke-StageClone {
    Write-Head 'Stage 1/13 - Clone'

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is not on PATH. Run 1-Install-Prerequisites.ps1, then open a new shell.'
    }

    $RepoUrl = Resolve-RepoUrl

    if (Test-Path (Join-Path $script:SrcRoot '.git')) {
        Write-Step 'Repo already present; fetching updates...'
        Push-Location $script:SrcRoot
        try {
            $null = Invoke-Native { git fetch --all --quiet }

            # No upstream configured is a normal state, not an error - it just means we
            # cannot tell how far behind we are, so skip the pull.
            $behind = $null
            if ((Invoke-Native -Capture { git rev-list --count 'HEAD..@{u}' }) -eq 0) {
                $behind = $script:NativeOutput | Select-Object -First 1
            }

            if ($behind -and [int]$behind -gt 0) {
                Write-Step "$behind commit(s) behind; pulling..."
                $pullCode = Invoke-Native -Show { git pull --ff-only --quiet }
                if ($pullCode -eq 0) { Write-Ok 'Updated.' }
                else {
                    # Common on --depth 1 clones. Not fatal, but do NOT claim success -
                    # the build would then compile stale source under a green summary.
                    Write-Warn "git pull failed (exit $pullCode); continuing on the existing checkout."
                }
            } else {
                Write-Ok 'Already up to date.'
            }
        } finally { Pop-Location }
    } else {
        if (Test-Path $script:SrcRoot) {
            $n = (Get-ChildItem $script:SrcRoot -Force | Measure-Object).Count
            if ($n -gt 0) { throw "$($script:SrcRoot) exists, is not empty, and is not a git repo. Move it aside." }
        }
        Write-Step "Cloning $RepoUrl ..."
        Write-Step 'This pulls ~700 MB including the database dump. Give it a few minutes.'
        # git narrates clone progress on stderr even on success - Invoke-Native keeps that
        # from being escalated into a terminating error.
        $code = Invoke-Native -Show { git clone --depth 1 $RepoUrl $script:SrcRoot }
        if ($code -ne 0) { throw "git clone failed with exit code $code" }
        Write-Ok 'Cloned.'
    }

    foreach ($p in $script:RepoServer, $script:RepoQuests, $script:RepoPlugins, $script:RepoClient) {
        if (-not (Test-Path $p)) { throw "Expected folder missing after clone: $p" }
    }
    Write-Ok 'All four release folders present.'

    $sha = 'unknown'
    if ((Invoke-Native -Capture { git -C $script:SrcRoot rev-parse --short HEAD }) -eq 0) {
        $sha = $script:NativeOutput | Select-Object -First 1
    }
    Add-Summary 'Clone' 'Done' "at $sha"
}

# ---------------------------------------------------------------------------
# Stage: Database
# ---------------------------------------------------------------------------

function Invoke-StageDatabase {
    Write-Head 'Stage 2/13 - Database'

    $rootPw = Get-RootPassword

    Write-Step 'Testing the root connection...'
    Invoke-Sql -Query 'SELECT 1;' -Password $rootPw | Out-Null
    Write-Ok 'Connected as root.'

    $dbPw = Get-StoredCredential 'Database password'
    if (-not $dbPw) {
        $dbPw = New-Password
        Set-StoredCredential 'Database password' $dbPw
        Write-Step 'Generated a database password.'
    } else {
        Write-Step 'Reusing the existing database password.'
    }
    Set-StoredCredential 'Database name' $DbName
    Set-StoredCredential 'Database user' $DbUser

    # utf8mb4 throughout. The PEQ dump carries item and NPC names outside latin1.
    Write-Step "Creating schema '$DbName' and user '$DbUser'..."
    $setup = @"
CREATE DATABASE IF NOT EXISTS ``$DbName``
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'127.0.0.1' IDENTIFIED BY '$dbPw';
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$dbPw';
ALTER USER '$DbUser'@'127.0.0.1' IDENTIFIED BY '$dbPw';
ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$dbPw';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'127.0.0.1';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
"@
    Invoke-Sql -Query $setup -Password $rootPw | Out-Null
    Write-Ok "Schema and user ready."
    Write-Step 'Note: the user gets ALL PRIVILEGES because the server issues DDL at boot'
    Write-Step 'to run both migration manifests (CODEBASE.md 4.1). It is not optional.'

    if ($SkipDatabaseImport) {
        Write-Warn 'Import skipped by -SkipDatabaseImport.'
        Add-Summary 'Database' 'Partial' 'import skipped'
        return
    }

    $tableCount = Get-SqlScalar -RootPassword $rootPw -Query @"
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DbName';
"@

    if ($tableCount -gt 100) {
        Write-Ok "Database already has $tableCount tables; skipping import."
        Write-Step 'Force a fresh import by dropping the schema and re-running this stage.'
        Add-Summary 'Database' 'Done' "$tableCount tables (existing)"
        return
    }

    $zip = Join-Path $script:RepoServer 'database\release-peq.zip'
    if (-not (Test-Path $zip)) { throw "Database dump not found at $zip" }

    $extractDir = Join-Path $InstallRoot 'db-import'
    if (-not (Test-Path $extractDir)) { New-Item -ItemType Directory -Path $extractDir -Force | Out-Null }

    $sqlFile = Get-ChildItem -Path $extractDir -Filter '*.sql' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $sqlFile) {
        Write-Step 'Unpacking the dump (~56 MB zipped, ~540 MB unpacked)...'
        # Expand-Archive is slow and memory-hungry on a file this size; prefer 7-Zip,
        # then tar (built into Windows since 1803), then fall back.
        $sevenZip = @('7z', (Join-Path $env:ProgramFiles '7-Zip\7z.exe')) |
            Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1

        if ($sevenZip) {
            $null = Invoke-Native { & $sevenZip x $zip "-o$extractDir" -y }
        } elseif (Get-Command tar -ErrorAction SilentlyContinue) {
            Push-Location $extractDir
            try { $null = Invoke-Native { tar -xf $zip } } finally { Pop-Location }
        } else {
            Expand-Archive -Path $zip -DestinationPath $extractDir -Force
        }

        $sqlFile = Get-ChildItem -Path $extractDir -Filter '*.sql' | Select-Object -First 1
        if (-not $sqlFile) { throw "No .sql file found after unpacking $zip" }
        Write-Ok "Unpacked $($sqlFile.Name) ($([math]::Round($sqlFile.Length/1MB)) MB)"
    } else {
        Write-Step "Reusing the already-unpacked $($sqlFile.Name)"
    }

    Write-Step 'Importing. This is the slowest stage - expect 10-30 minutes.'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-SqlFile -Path $sqlFile.FullName -Password $rootPw -Database $DbName
    $sw.Stop()

    $tableCount = Get-SqlScalar -RootPassword $rootPw -Query @"
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DbName';
"@
    Write-Ok "Imported $tableCount tables in $([math]::Round($sw.Elapsed.TotalMinutes,1)) minutes."

    if ($tableCount -lt 100) { throw "Only $tableCount tables after import - something went wrong." }

    # Verify the two things migrations do NOT create. See CODEBASE.md 4.4.
    Write-Step 'Checking for content the migrations cannot supply...'

    $wp = Get-SqlScalar -RootPassword $rootPw -Query @"
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema='$DbName' AND table_name='nms_waypoints';
"@
    if ($wp -gt 0) {
        $rows = Get-SqlScalar -RootPassword $rootPw -Query 'SELECT COUNT(*) FROM nms_waypoints;'
        if ($rows -gt 0) { Write-Ok "nms_waypoints has $rows rows." }
        else {
            Write-Warn 'nms_waypoints exists but is EMPTY. Waypoints will silently do nothing.'
            Write-Warn 'The seed INSERTs live only as a comment in zone/nms_waypoints.h.'
        }
    } else {
        Write-Step 'nms_waypoints not in the dump; the custom manifest will create it (empty).'
    }

    $cs = Get-SqlScalar -RootPassword $rootPw -Query @"
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema='$DbName' AND table_name LIKE 'account_character_set%';
"@
    if ($cs -gt 0) { Write-Ok "account_character_set* tables present ($cs)." }
    else {
        Write-Warn 'account_character_set* tables are MISSING and have no migration'
        Write-Warn '(manifest v15-v17 are commented out). Character select may error.'
    }

    Add-Summary 'Database' 'Done' "$tableCount tables"
}

# ---------------------------------------------------------------------------
# Stage: Patches
# ---------------------------------------------------------------------------

function Invoke-StagePatches {
    Write-Head 'Stage 8/13 - Loose SQL patches'
    Write-Step 'These ten files are referenced nowhere in the codebase and are applied by'
    Write-Step 'nothing. Without this stage they simply never run. See CODEBASE.md 4.4.'

    $rootPw = Get-RootPassword
    $applied = 0
    $missing = 0

    foreach ($rel in $script:LoosePatches) {
        $path = Join-Path $script:SrcRoot $rel
        $name = Split-Path -Leaf $rel

        if (-not (Test-Path $path)) {
            Write-Warn "$name not found - skipping"
            $missing++
            continue
        }

        try {
            # These are all small idempotent UPDATEs, so re-running is harmless.
            Invoke-SqlFile -Path $path -Password $rootPw -Database $DbName
            Write-Ok $name
            $applied++
        } catch {
            Write-Warn "$name failed: $($_.Exception.Message)"
        }
    }

    Write-Step "Applied $applied of $($script:LoosePatches.Count) ($missing missing)."
    $state = if ($applied -eq $script:LoosePatches.Count) { 'Done' }
             elseif ($applied -eq 0)                      { 'Failed' }
             else                                         { 'Partial' }
    Add-Summary 'Patches' $state "$applied/$($script:LoosePatches.Count) applied"
}

# ---------------------------------------------------------------------------
# Stage: Login
# ---------------------------------------------------------------------------

function Invoke-StageLogin {
    Write-Head 'Stage 9/13 - Loginserver schema'
    Write-Step 'The loginserver needs five tables that are in no migration manifest and'
    Write-Step 'not in the PEQ dump - loginserver/login_util/login_schema.sql creates them,'
    Write-Step 'and nothing applies it. Without them the service exits on its first query.'

    $rootPw = Get-RootPassword

    $presentCount = Get-LoginTableCount -RootPassword $rootPw
    Write-Step "Found $presentCount of $($script:LoginTables.Count) loginserver tables."

    # Guard on ANY tables present, not on all five.
    #
    # The earlier version required a full set before backing off, so a server sitting at
    # 4 of 5 - which is normal, since login_api_tokens comes from the other file and
    # login_tickets.sql may never have been applied - fell straight through to
    # login_schema.sql and its leading DROP TABLE IF EXISTS. That silently destroyed every
    # player login account, with no prompt and without -ForceLoginSchema.
    if ($presentCount -gt 0 -and -not $ForceLoginSchema) {
        if ($presentCount -lt $script:LoginTables.Count) {
            Write-Warn "$presentCount of $($script:LoginTables.Count) loginserver tables exist."
            Write-Warn 'NOT re-applying the schema: it begins with DROP TABLE IF EXISTS and'
            Write-Warn 'would delete every existing login account to create the missing few.'
            Write-Warn 'Re-run with -ForceLoginSchema only if you mean to rebuild from scratch.'
            Invoke-SeedLoginServerListTypes -RootPassword $rootPw
            Invoke-SeedLauncher -RootPassword $rootPw
            Add-Summary 'Login' 'Partial' "$presentCount/$($script:LoginTables.Count) tables"
            return
        }
    }

    if ($presentCount -eq $script:LoginTables.Count -and -not $ForceLoginSchema) {
        Write-Ok 'Loginserver schema already present; leaving it alone.'
        # This is not laziness. Every statement in login_schema.sql begins with
        # DROP TABLE IF EXISTS, so re-applying it on a live server deletes every
        # player login account. Re-apply only on explicit instruction.
        Write-Step 'login_schema.sql starts with DROP TABLE - re-applying would delete all'
        Write-Step 'player accounts. Use -ForceLoginSchema only if you mean exactly that.'
        Invoke-SeedLoginServerListTypes -RootPassword $rootPw
        Invoke-SeedLauncher -RootPassword $rootPw
        Add-Summary 'Login' 'Done' 'schema already present'
        return
    }

    if ($ForceLoginSchema -and $presentCount -gt 0) {
        Write-Warn 'RE-APPLYING the loginserver schema because -ForceLoginSchema was given.'
        Write-Warn 'Every existing login account will be destroyed.'
        $accounts = Get-SqlScalar -RootPassword $rootPw -Query 'SELECT COUNT(*) FROM login_accounts;'
        if ($accounts -gt 0) {
            Write-Warn "There are currently $accounts login account(s)."
            # Always confirm interactively. -ForceLoginSchema says "rebuild the schema",
            # not "destroy accounts without asking", and there is no way to undo this.
            $answer = Read-Host '  Type DELETE to confirm'
            if ($answer -ne 'DELETE') {
                Write-Step 'Cancelled; schema left untouched.'
                Add-Summary 'Login' 'Skipped' 'user cancelled'
                return
            }
        }
    }

    $applied = 0
    foreach ($rel in $script:LoginSchemaFiles) {
        $path = Join-Path $script:SrcRoot $rel
        $name = Split-Path -Leaf $rel
        if (-not (Test-Path $path)) { Write-Warn "$name not found - skipping"; continue }
        try {
            Invoke-SqlFile -Path $path -Password $rootPw -Database $DbName
            Write-Ok $name
            $applied++
        } catch {
            Write-Bad "$name failed: $($_.Exception.Message)"
        }
    }

    if ($applied -eq 0) {
        Add-Summary 'Login' 'Failed' 'no schema applied'
        return
    }

    Invoke-SeedLoginServerListTypes -RootPassword $rootPw
    Invoke-SeedLauncher -RootPassword $rootPw

    $afterCount = Get-LoginTableCount -RootPassword $rootPw

    if ($afterCount -eq $script:LoginTables.Count) {
        Write-Ok "All $afterCount loginserver tables present."
        Add-Summary 'Login' 'Done' "$applied file(s) applied"
    } else {
        Write-Warn "Only $afterCount of $($script:LoginTables.Count) tables exist after applying."
        Add-Summary 'Login' 'Partial' "$afterCount/$($script:LoginTables.Count) tables"
    }
}

function Invoke-SeedLauncher {
    <#
        Seeds the `launcher` table with a row named 'zone'.

        Without it the zone launcher is rejected and NO ZONES EVER BOOT - and this is the
        worst failure signature in the whole deployment, because everything looks healthy:

          world/launcher_link.cpp:92-97 - eqlaunch announces itself, world calls
          GetConfig(name), gets nullptr because `SELECT name FROM launcher` returned
          nothing (world/worlddb.cpp:828), logs "Unknown launcher [zone] connected.
          Disconnecting" at INFO level, and drops the connection.

        The NMS-Zone service reports Running. status-server.ps1 looks clean. Players log
        in, see the server, and then hang forever at character select because no zone
        process exists. The only trace is an INFO line in the world log.

        The PEQ dump ships this table empty and no migration seeds it.
        'dynamics' is the number of zone processes to keep spare; 20 fits the configured
        7000-7400 port range and its firewall rule.
    #>
    param([Parameter(Mandatory)] [string] $RootPassword)

    try {
        Invoke-Sql -Password $RootPassword -Database $DbName -Query @"
INSERT INTO launcher (name, dynamics) VALUES ('zone', 20)
  ON DUPLICATE KEY UPDATE dynamics = GREATEST(dynamics, 20);
"@ | Out-Null
        $n = Get-SqlScalar -RootPassword $RootPassword `
            -Query "SELECT dynamics FROM launcher WHERE name = 'zone';"
        Write-Ok "launcher 'zone' present with $n dynamic zones."
    } catch {
        Write-Bad "Could not seed the launcher row: $($_.Exception.Message)"
        Write-Warn 'Without it eqlaunch is rejected and no zones boot - while every service'
        Write-Warn 'still reports Running. Add it by hand:'
        Write-Warn "  INSERT INTO launcher (name, dynamics) VALUES ('zone', 20);"
    }
}

function Get-SqlScalar {
    <#
        Runs a query expected to yield ONE number and returns it as [int].

        Counting output lines is not reliable: Invoke-Sql merges stderr into its result,
        so any client warning or stray blank becomes an extra "row" - which is how a check
        for 5 tables managed to report 6. Ask the database for the number instead, and
        take the last line that is purely digits.
    #>
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [string] $RootPassword
    )
    # -Quiet + try/catch: several callers ask about tables that may not exist yet, where
    # "the query failed" and "the answer is zero" mean the same thing to us. Returning 0
    # is correct there and avoids an [int] cast blowing up on an error string.
    try {
        $out = @(Invoke-Sql -Password $RootPassword -Database $DbName -Query $Query -Quiet)
    } catch {
        return 0
    }
    $num = $out | Where-Object { "$_".Trim() -match '^\d+$' } | Select-Object -Last 1
    if ($null -eq $num) { return 0 }
    return [int]("$num".Trim())
}

function Get-LoginTableCount {
    param([Parameter(Mandatory)] [string] $RootPassword)

    $list = ($script:LoginTables | ForEach-Object { "'$_'" }) -join ','
    return Get-SqlScalar -RootPassword $RootPassword -Query @"
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema = '$DbName' AND table_name IN ($list);
"@
}

function Invoke-SeedLoginServerListTypes {
    <#
        login_schema.sql creates login_server_list_types empty. The ids come from
        loginserver/login_types.h:147 (Legends 1, Preferred 2, Standard 3), and
        world_server.cpp:436 auto-registers a new world as Standard - so row 3 in
        particular has to exist.

        INSERT IGNORE, so this is safe to run on every setup.
    #>
    param([Parameter(Mandatory)] [string] $RootPassword)

    $values = ($script:LoginServerListTypes |
        ForEach-Object { "($($_.Id), '$($_.Description)')" }) -join ', '

    try {
        Invoke-Sql -Password $RootPassword -Database $DbName -Query @"
INSERT IGNORE INTO login_server_list_types (id, description) VALUES $values;
"@ | Out-Null
        $n = Get-SqlScalar -RootPassword $RootPassword -Query 'SELECT COUNT(*) FROM login_server_list_types;'
        Write-Ok "login_server_list_types has $n row(s)."
    } catch {
        Write-Warn "Could not seed login_server_list_types: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Stage: Build
# ---------------------------------------------------------------------------

function Resolve-CMake {
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $null = Invoke-Native -Capture { & $vswhere -latest -products '*' -property installationPath }
        $vsPath = $script:NativeOutput | Select-Object -First 1
        if ($vsPath) {
            $bundled = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $bundled) { return $bundled }
        }
    }
    throw 'CMake not found. Run 1-Install-Prerequisites.ps1 first.'
}

function Invoke-StageBuild {
    Write-Head 'Stage 3/13 - Build'

    $cmake = Resolve-CMake
    Write-Step "CMake: $cmake"

    # The repo commits a PARTIAL vcpkg/vcpkg-export-x64/ tree, and it is easy to
    # misread that as "dependencies are vendored, no download needed". They are not:
    #
    #   * DependencyHelperMSVC.cmake:40 gates on the ZIP, not the directory, and .gitignore
    #     excludes vcpkg-export-x64.zip - so CMake re-downloads ~132 MB on every fresh clone.
    #   * .gitignore has a bare 'bin/', which git applies at every depth. That excluded
    #     vcpkg-export-x64/installed/x64-windows/bin/ entirely, so the committed tree has
    #     NO runtime DLLs. The build only links because the download restores them.
    #
    # So: the first configure needs internet, full stop. Do not set
    # EQEMU_FETCH_MSVC_DEPENDENCIES_VCPKG=OFF on the strength of that directory existing -
    # the DLL copy in the Runtime stage would silently come up empty and nothing would run.
    $vcpkgZip = Join-Path $script:RepoServer 'vcpkg\vcpkg-export-x64.zip'
    if (Test-Path $vcpkgZip) {
        Write-Ok 'vcpkg dependency archive already downloaded - configure will reuse it.'
    } else {
        Write-Step 'First configure: CMake will download ~132 MB of vcpkg dependencies.'
        Write-Step 'This needs a working internet connection. The partial vcpkg tree in the'
        Write-Step 'repo is not sufficient on its own - it is missing all runtime DLLs.'
    }

    Write-Step 'Configuring...'
    Push-Location $script:RepoServer
    try {
        $code = Invoke-Native -Capture { & $cmake -S . -B Build -G 'Visual Studio 17 2022' -A x64 -DEQEMU_BUILD_LOGIN=ON }
        $script:NativeOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        # CMake reports a missing Perl as a STATUS line and exits 0. Without PerlLibs the
        # build simply omits -DEMBPERL, so zone.exe comes out with no Perl quest parser at
        # all: it starts fine, .lua quests work, and every one of the ~4,000 .pl scripts
        # and 52 plugins silently does nothing. Catch it here rather than in production.
        if ($script:NativeOutput -match 'Perl:\s+MISSING') {
            throw @'
CMake did not find PerlLibs.

zone.exe would build WITHOUT the embedded Perl parser, and every .pl quest script and
plugin would silently do nothing - with no error at runtime.

Run 1-Install-Prerequisites.ps1 and confirm Perl reports Present before building.
'@
        }

        if ($code -ne 0) {
            throw @"
CMake configure failed (exit $code).

Usual causes:
  * Visual Studio Build Tools installed without the native x64 C++ toolset
  * A stale Build\ folder - delete $($script:BuildDir) and re-run this stage
  * No internet on the very first configure, if vcpkg deps had to be fetched
"@
        }
        Write-Ok 'Configured.'

        # 8 cores on this box. Leave one for the OS so the box stays responsive over RDP.
        $jobs = [Math]::Max(1, [Environment]::ProcessorCount - 1)
        Write-Step "Building Release/x64 with $jobs parallel jobs. Expect 20-45 minutes."

        $sw = [Diagnostics.Stopwatch]::StartNew()
        # MSVC writes warnings to stderr constantly; a compiler warning must not abort us.
        $code = Invoke-Native -Show { & $cmake --build Build --config Release --parallel $jobs }
        $sw.Stop()

        if ($code -ne 0) { throw "Build failed with exit code $code after $([math]::Round($sw.Elapsed.TotalMinutes,1)) minutes." }
        Write-Ok "Built in $([math]::Round($sw.Elapsed.TotalMinutes,1)) minutes."
    } finally { Pop-Location }

    $expected = @('world.exe','zone.exe','ucs.exe','queryserv.exe','loginserver.exe',
                  'eqlaunch.exe','shared_memory.exe','export_client_files.exe')
    $found = @()
    $absent = @()
    foreach ($e in $expected) {
        if (Test-Path (Join-Path $script:BinDir $e)) { $found += $e } else { $absent += $e }
    }

    Write-Ok "$($found.Count)/$($expected.Count) binaries in $($script:BinDir)"
    if ($absent) {
        Write-Bad "Missing: $($absent -join ', ')"
        throw 'Build did not produce all expected binaries.'
    }

    Add-Summary 'Build' 'Done' "$($found.Count) binaries"
}

# ---------------------------------------------------------------------------
# Stage: Runtime
# ---------------------------------------------------------------------------

function Invoke-StageRuntime {
    Write-Head 'Stage 4/13 - Runtime directory'

    # 'export' matters: export_client_files writes with a bare std::ofstream to
    # <ServerRoot>/export/spells_us.txt (client_files/export/main.cpp:132 and friends).
    # ofstream does not create the parent directory and PathManager never does either, so
    # without this the exporter logs "unable to open ... skipping" for all four files and
    # produces nothing.
    foreach ($d in $script:ServerRoot,
                   (Join-Path $script:ServerRoot 'assets\patches'),
                   (Join-Path $script:ServerRoot 'logs'),
                   (Join-Path $script:ServerRoot 'shared'),
                   (Join-Path $script:ServerRoot 'Maps'),
                   (Join-Path $script:ServerRoot 'export'),
                   (Join-Path $script:ServerRoot 'quests\plugins'),
                   $script:ClientOut) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Windows will not let us overwrite a running executable, so the services must go
    # down first. Without this the stage dies with "being used by another process".
    $null = Stop-NmsServices -Reason 'before overwriting binaries'

    Write-Step 'Copying binaries and their DLLs...'
    Copy-Item -Path (Join-Path $script:BinDir '*') -Destination $script:ServerRoot `
        -Include '*.exe', '*.dll' -Force
    $n = @(Get-ChildItem $script:ServerRoot -Filter '*.exe').Count
    Write-Ok "$n executables copied."

    # The vcpkg runtime DLLs are NOT all emitted into Build\bin\Release - CMake copies
    # some, but boost, icu, zstd, lzma and friends stay in the vcpkg tree. Without them
    # the binaries load-fail with -1073741515 and no output whatsoever, because the
    # Windows loader gives up before main() runs and there is nothing to print.
    # Some DLLs the project builds itself do NOT land in bin\Release - zlib-ng1.dll is
    # built by libs/zlibng and ends up elsewhere in the build tree. world.exe imports it,
    # so without this sweep world dies at load with -1073741515 and no output, while
    # shared_memory.exe (which does not link it) runs fine and makes everything look OK.
    Write-Step 'Sweeping the build tree for any other DLLs...'
    $swept = 0
    Get-ChildItem $script:BuildDir -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $dest = Join-Path $script:ServerRoot $_.Name
            if (-not (Test-Path $dest) -or $_.LastWriteTime -gt (Get-Item $dest).LastWriteTime) {
                Copy-Item $_.FullName $dest -Force
                $swept++
            }
        }
    if ($swept -gt 0) { Write-Ok "$swept additional DLL(s) from the build tree." }

    $vcpkgBin = Join-Path $script:RepoServer 'vcpkg\vcpkg-export-x64\installed\x64-windows\bin'
    if (Test-Path $vcpkgBin) {
        Write-Step 'Copying vcpkg runtime DLLs...'
        Copy-Item -Path (Join-Path $vcpkgBin '*.dll') -Destination $script:ServerRoot -Force
        $d = @(Get-ChildItem $script:ServerRoot -Filter '*.dll').Count
        Write-Ok "$d DLLs in place."
    } else {
        Write-Warn "vcpkg runtime DLLs not found at $vcpkgBin"
        Write-Warn 'If binaries exit with -1073741515, this is why. The vcpkg tree is'
        Write-Warn 'restored by the CMake configure step - re-run the Build stage.'
    }

    # The VC++ runtime is a SYSTEM component, not something the build emits. Build Tools
    # installs the compiler, not the redistributable the compiled binaries load, and
    # vcpkg does not ship it either - so nothing upstream of here provides it.
    $vcRuntime = @('vcruntime140.dll', 'msvcp140.dll') | Where-Object {
        -not (Test-Path (Join-Path $env:SystemRoot "System32\$_"))
    }
    if ($vcRuntime) {
        Write-Bad "VC++ runtime missing from System32: $($vcRuntime -join ', ')"
        Write-Warn 'Every server binary will fail to load with exit code -1073741515 and'
        Write-Warn 'no error message. Install it:'
        Write-Warn '  winget install --id Microsoft.VCRedist.2015+.x64 --exact --silent'
        Write-Warn 'Stage 1 does this - re-run 1-Install-Prerequisites.ps1.'
        throw 'VC++ runtime redistributable is not installed.'
    }
    Write-Ok 'VC++ runtime present in System32.'

    # Verify BY NAME, not by count. Counting hid a real failure once: the stage reported
    # "9 exe" while loginserver.exe was absent, so the service was registered against a
    # binary that did not exist and Windows could only say "failed to start".
    $required = @(
        @{ Name = 'world.exe';               Why = 'world server' }
        @{ Name = 'zone.exe';                Why = 'zone server' }
        @{ Name = 'eqlaunch.exe';            Why = 'zone launcher' }
        @{ Name = 'shared_memory.exe';       Why = 'must run before world' }
        @{ Name = 'ucs.exe';                 Why = 'chat and mail' }
        @{ Name = 'queryserv.exe';           Why = 'query server' }
        @{ Name = 'loginserver.exe';         Why = 'local login (needs -DEQEMU_BUILD_LOGIN=ON)' }
        @{ Name = 'export_client_files.exe'; Why = 'generates the four client data files' }
    )

    $absent = @()
    foreach ($r in $required) {
        if (Test-Path (Join-Path $script:ServerRoot $r.Name)) {
            Write-Ok "$($r.Name)"
        } else {
            Write-Bad "$($r.Name) MISSING - $($r.Why)"
            $absent += $r.Name
        }
    }

    Test-BinaryDependencies

    if ($absent.Count -gt 0) {
        Write-Warn ''
        Write-Warn "$($absent.Count) required binary/binaries did not reach the runtime folder."
        Write-Warn "Check what the build actually produced in:"
        Write-Warn "  $($script:BinDir)"
        Write-Warn 'If they are missing there too, re-run the Build stage. If they are present'
        Write-Warn 'there but not here, the copy failed - check for a file lock or a running'
        Write-Warn 'service holding the old binary open.'
        throw "Runtime assembly incomplete: $($absent -join ', ')"
    }

    # patch_*.conf and the opcode files. The config points at assets/patches/.
    Write-Step 'Copying opcode and patch files...'
    Copy-Item -Path (Join-Path $script:RepoServer 'utils\patches\*') `
        -Destination (Join-Path $script:ServerRoot 'assets\patches') -Force
    $rof2 = Join-Path $script:ServerRoot 'assets\patches\patch_RoF2.conf'
    if (Test-Path $rof2) {
        # Sanity-check the custom opcode block. Without it, every custom feature is dark.
        if ((Get-Content $rof2 -Raw) -match 'OP_PetList|#CUSTOM') {
            Write-Ok 'patch_RoF2.conf contains the custom opcode block.'
        } else {
            Write-Warn 'patch_RoF2.conf has no custom opcode block. Custom features will not work.'
        }
    } else { Write-Warn 'patch_RoF2.conf missing - this is the only supported client patch.' }

    Write-Step 'Copying defaults (mime.types, log.ini)...'
    foreach ($f in 'mime.types', 'log.ini') {
        $src = Join-Path $script:RepoServer "utils\defaults\$f"
        if (Test-Path $src) { Copy-Item $src $script:ServerRoot -Force }
    }

    # Quests: 8,054 files across 220 zone directories. Robocopy handles this far better
    # than Copy-Item, which chokes on trees this wide.
    Write-Step 'Copying quests (8,000+ files - takes a minute)...'
    $questDst = Join-Path $script:ServerRoot 'quests'
    # Robocopy exit codes < 8 are SUCCESS (1 = files copied). Only 8+ is a real failure.
    $rc = Invoke-Native { robocopy $script:RepoQuests $questDst /E /NFL /NDL /NJH /NJS /NC /NS /NP /XD '.git' }
    if ($rc -ge 8) { throw "robocopy failed copying quests (exit $rc)" }
    $qCount = @(Get-ChildItem $questDst -Recurse -File -Include '*.pl','*.lua').Count
    Write-Ok "$qCount quest scripts in quests\"

    Write-Step 'Copying plugins...'
    $pluginDst = Join-Path $script:ServerRoot 'quests\plugins'
    $rc = Invoke-Native { robocopy $script:RepoPlugins $pluginDst /E /NFL /NDL /NJH /NJS /NC /NS /NP /XD '.git' }
    if ($rc -ge 8) { throw "robocopy failed copying plugins (exit $rc)" }
    $pCount = @(Get-ChildItem $pluginDst -File -Filter '*.pl').Count
    Write-Ok "$pCount plugins in quests\plugins\"

    if ($pCount -lt 40) { Write-Warn "Expected ~52 plugins, found $pCount." }

    Add-Summary 'Runtime' 'Done' "$n exe, $qCount quests, $pCount plugins"
}

# ---------------------------------------------------------------------------
# Stage: Maps
# ---------------------------------------------------------------------------

function Test-BinaryDependencies {
    <#
        Verifies every DLL the server binaries import can actually be found.

        This is the check that would have caught zlib-ng1.dll immediately instead of via a
        silent service failure. A missing import gives exit code -1073741515 with NO output
        at all - the loader gives up before main() runs - so there is nothing to log, and
        under NSSM it surfaces only as a service stuck in Paused.

        Uses dumpbin from the MSVC toolset. If it is unavailable the check is skipped
        rather than failing the stage; it is a diagnostic, not a gate.

        api-ms-win-crt-* entries are virtual API sets resolved by the UCRT and never exist
        as real files, so they are excluded.
    #>
    $dumpbin = Get-ChildItem `
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' `
        -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $dumpbin) {
        Write-Step 'dumpbin not found; skipping the DLL dependency check.'
        return
    }

    Write-Step 'Checking DLL dependencies of each binary...'
    $problems = @{}

    foreach ($exe in @(Get-ChildItem $script:ServerRoot -Filter '*.exe')) {
        $null = Invoke-Native -Capture { & $dumpbin.FullName /DEPENDENTS $exe.FullName }
        $deps = @($script:NativeOutput |
            Select-String '^\s+(\S+\.dll)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value })

        foreach ($d in $deps) {
            if ($d -like 'api-ms-win-*') { continue }   # virtual API sets
            $found = (Test-Path (Join-Path $script:ServerRoot $d)) -or
                     (Test-Path (Join-Path $env:SystemRoot "System32\$d")) -or
                     [bool](Get-Command $d -ErrorAction SilentlyContinue)
            if (-not $found) {
                if (-not $problems.ContainsKey($d)) { $problems[$d] = @() }
                $problems[$d] += $exe.Name
            }
        }
    }

    if ($problems.Count -eq 0) {
        Write-Ok 'All binaries resolve their imports.'
        return
    }

    Write-Bad "$($problems.Count) DLL(s) cannot be found:"
    foreach ($d in $problems.Keys) {
        Write-Bad "  $d  (needed by $($problems[$d] -join ', '))"
    }
    Write-Warn 'Those binaries will exit with -1073741515 and print nothing at all.'
    Write-Warn 'Look for the DLL under the build tree or the vcpkg bin directory and copy'
    Write-Warn "it into $($script:ServerRoot)."
    throw "Missing runtime DLL(s): $($problems.Keys -join ', ')"
}

function Invoke-StageMaps {
    Write-Head 'Stage 5/13 - Zone maps'
    Write-Step 'utils/defaults/Maps in the repo is an empty .keep directory, and no README'
    Write-Step 'mentions this. Without map files, NPC pathing and line-of-sight are broken.'

    $mapDir = Join-Path $script:ServerRoot 'Maps'
    # Check EACH subdirectory, not the total. base/ alone is thousands of files, so a
    # run where nav/ or water/ failed would look complete forever and never be retried.
    $haveAll = $true
    foreach ($sub in $script:MapsSubdirs) {
        $c = @(Get-ChildItem (Join-Path $mapDir $sub) -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($c -eq 0) { $haveAll = $false; break }
    }

    if ($haveAll) {
        $existing = @(Get-ChildItem $mapDir -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Ok "$existing map files already present in all of $($script:MapsSubdirs -join ', '); skipping."
        Add-Summary 'Maps' 'Done' "$existing files (existing)"
        return
    }

    $tmp = Join-Path $InstallRoot 'maps-tmp'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }

    Write-Step "Cloning maps from $($script:MapsRepo) (~1-2 GB)..."
    try {
        $code = Invoke-Native -Show { git clone --depth 1 $script:MapsRepo $tmp }
        if ($code -ne 0) { throw "git clone returned $code" }
    } catch {
        Write-Bad "Map download failed: $($_.Exception.Message)"
        Write-Warn 'The server will still boot, but pathing and LOS will misbehave.'
        Write-Warn "Fetch them by hand into $mapDir when you can."
        Add-Summary 'Maps' 'Failed' $_.Exception.Message
        return
    }

    # EQEmu/maps keeps base/, water/ and nav/ at the REPO ROOT, and the server expects
    # them at Maps/base, Maps/water, Maps/nav. Copy each subdirectory across by name
    # rather than guessing at a nested layout.
    $copied = @()
    foreach ($sub in $script:MapsSubdirs) {
        $src = Join-Path $tmp $sub
        if (-not (Test-Path $src -PathType Container)) {
            Write-Warn "$sub/ not present in the maps repo - skipping."
            continue
        }
        $dst = Join-Path $mapDir $sub
        Write-Step "Copying $sub/ ..."
        $rc = Invoke-Native { robocopy $src $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP /XD '.git' }
        if ($rc -ge 8) {
            Write-Warn "robocopy failed on $sub (exit $rc)"
            continue
        }
        $count = @(Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Ok "$sub/ - $count files"
        $copied += $sub
    }

    if ($copied.Count -eq 0) {
        Write-Warn 'Cloned, but none of the expected map directories were found.'
        Write-Warn "Expected: $($script:MapsSubdirs -join ', ') at the repo root."
        Add-Summary 'Maps' 'Failed' 'unexpected layout'
        return
    }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    $total = @(Get-ChildItem $mapDir -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Ok "$total map files installed ($($copied -join ', '))."
    Add-Summary 'Maps' 'Done' "$total files"
}

# ---------------------------------------------------------------------------
# Stage: Config
# ---------------------------------------------------------------------------

function Get-PublicAddress {
    if ($PublicAddress) {
        Write-Step "Using the address you supplied: $PublicAddress"
        return $PublicAddress
    }

    Write-Step 'Detecting the public address...'
    foreach ($svc in 'https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
        try {
            $ip = (Invoke-RestMethod -Uri $svc -TimeoutSec 10).ToString().Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                Write-Ok "Detected $ip (via $(([uri]$svc).Host))"
                return $ip
            }
        } catch { continue }
    }

    # @() so an empty result is an empty array rather than $null - reading .IPAddress off
    # $null is a hard error under Set-StrictMode -Version Latest.
    $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' })
    $local = if ($candidates.Count -gt 0) { $candidates[0].IPAddress } else { $null }

    if ($local) {
        Write-Warn "Could not reach any detection service; falling back to local IP $local"
        Write-Warn 'If this box is behind NAT, re-run with -PublicAddress <your public IP>.'
        return $local
    }
    throw 'Could not determine an address. Re-run with -PublicAddress <ip-or-hostname>.'
}

function Invoke-StageConfig {
    param([string] $Address)

    Write-Head 'Stage 6/13 - Configuration'

    # Detected once by the caller and passed in. Calling Get-PublicAddress twice risks the
    # second call timing out and falling back to a private LAN address, which would put a
    # different address in the config than the one advertised everywhere else.
    $addr = if ($Address) { $Address } else { Get-PublicAddress }

    $dbPw = Get-StoredCredential 'Database password'
    if (-not $dbPw) { throw 'No database password on record. Run the Database stage first.' }

    # The world<->zone shared key. Not a player-facing secret, but it must be unguessable
    # or anyone who can reach 9001 can register a rogue zone server.
    $worldKey = Get-StoredCredential 'World key'
    if (-not $worldKey) {
        $worldKey = New-Password -Length 32
        Set-StoredCredential 'World key' $worldKey
    }

    $dbBlock = [ordered]@{
        db       = $DbName
        host     = '127.0.0.1'
        port     = '3306'
        username = $DbUser
        password = $dbPw
    }

    # Local loginserver, per the chosen deployment. The 'host' points back at this box on
    # 5998 rather than login.projecteq.net. To go public later, register with PEQ and swap
    # host/port/account/password here.
    $config = [ordered]@{
        server = [ordered]@{
            zones = [ordered]@{
                defaultstatus = '0'
                ports = [ordered]@{ low = '7000'; high = '7400' }
            }
            database   = $dbBlock
            qsdatabase = $dbBlock

            # Modern 'ucs' block, NOT the legacy chatserver/mailserver pair.
            #
            # eqemu_config.cpp:119 runs CheckUcsConfigConversion() on every load. If it
            # sees chatserver/mailserver with no ucs block, it copies the config to
            # eqemu_config.ucs-migrate-json.bak - a NEW file with inherited ACLs holding
            # our cleartext DB password - and then rewrites the config in place. Emitting
            # 'ucs' directly avoids both the leak and the surprise rewrite.
            ucs = [ordered]@{ host = $addr; port = '7778' }

            webinterface = [ordered]@{ port = '9081' }
            world = [ordered]@{
                longname     = $ServerLongName
                shortname    = $ServerShortName
                address      = $addr
                localaddress = '127.0.0.1'
                key          = $worldKey
                loginserver1 = [ordered]@{
                    account  = ''
                    password = ''
                    legacy   = 0
                    host     = '127.0.0.1'
                    port     = '5998'
                }
                tcp    = [ordered]@{ ip = '127.0.0.1'; port = '9001' }
                # Telnet bound to loopback deliberately. The default 0.0.0.0 exposes an
                # unauthenticated admin channel to the internet.
                telnet = [ordered]@{ ip = '127.0.0.1'; port = '9000'; enabled = 'true' }
                http   = [ordered]@{ port = '9080'; enabled = 'true'; mimefile = 'mime.types' }
            }
            files = [ordered]@{
                opcodes      = 'assets/patches/opcodes.conf'
                mail_opcodes = 'assets/patches/mail_opcodes.conf'
            }
            directories = [ordered]@{
                patches = 'assets/patches/'
                opcodes = 'assets/patches/'
                plugins = 'quests/plugins/'
                # lua_modules is NOT optional. zone/main.cpp:366 calls
                # CheckForCompatibleQuestPlugins() and returns 1 - refusing to start - unless
                # it finds "CheckHandin" in BOTH a plugin and a lua module. The lua side lives
                # in Release-NMS-Quests/lua_modules/, which robocopy lands at
                # quests/lua_modules/, but the default for this key is a bare 'lua_modules/'
                # at the server root. Without this line zone.exe exits 1 on every start with
                # "Failed to find CheckHandin in lua_modules" buried in logs\zone\.
                lua_modules = 'quests/lua_modules/'
            }
        }
    }

    $configPath = Join-Path $script:ServerRoot 'eqemu_config.json'
    if (Test-Path $configPath) {
        $backup = "$configPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item $configPath $backup -Force
        Write-Step "Backed up the existing config to $(Split-Path -Leaf $backup)"
    }
    # BOM-less: jsoncpp rejects a byte-order mark. See Write-TextFile.
    Write-TextFile -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)
    Write-Ok "Wrote eqemu_config.json (world address: $addr)"

    # login.json. auto_create_accounts is on: with a private loginserver, the first
    # connection from a player creates their account, which is what you want for a small
    # server. Turn it off if you ever want invite-only.
    $login = [ordered]@{
        database = [ordered]@{
            host = '127.0.0.1'; port = '3306'; db = $DbName
            user = $DbUser;     password = $dbPw
        }
        account      = [ordered]@{ auto_create_accounts = $true }
        worldservers = [ordered]@{
            unregistered_allowed             = $true
            show_player_count                = $true
            dev_test_servers_list_bottom     = $false
            special_character_start_list_bottom = $false
            reject_duplicate_servers         = $false
        }
        web_api  = [ordered]@{ enabled = $false; port = 6000 }
        security = [ordered]@{
            mode = 14
            allow_password_login = $true
            allow_token_login    = $true
        }
        logging = [ordered]@{
            trace = $false; world_trace = $false
            dump_packets_in = $false; dump_packets_out = $false
        }
        client_configuration = [ordered]@{
            titanium_port    = 5998
            titanium_opcodes = 'login_opcodes.conf'
            sod_port         = 5999
            sod_opcodes      = 'login_opcodes_sod.conf'
            display_expansions  = $true
            max_expansions_mask = 524287
        }
    }

    $loginPath = Join-Path $script:ServerRoot 'login.json'
    if (Test-Path $loginPath) {
        Copy-Item $loginPath "$loginPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" -Force
    }
    Write-TextFile -Path $loginPath -Content ($login | ConvertTo-Json -Depth 10)
    Write-Ok 'Wrote login.json (local loginserver on 5998).'

    # The loginserver needs its own opcode files next to it.
    $loginUtil = Join-Path $script:RepoServer 'loginserver\login_util'
    if (Test-Path $loginUtil) {
        Copy-Item -Path (Join-Path $loginUtil '*.conf') -Destination $script:ServerRoot `
            -Force -ErrorAction SilentlyContinue
        Write-Ok 'Copied loginserver opcode files.'
    }

    # Both config files hold the DB password in cleartext. Lock them down.
    foreach ($f in $configPath, $loginPath) {
        $acl = Get-Acl $f
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($who in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $who, 'FullControl', 'Allow'))
        }
        Set-Acl -Path $f -AclObject $acl
    }
    Write-Ok 'Restricted config file permissions (they contain the DB password).'

    # Verify what actually landed on disk. A BOM here is invisible in every editor and
    # takes out world, shared_memory and the exporter with an error that blames the JSON
    # rather than the encoding - so check the bytes, not just that the file exists.
    foreach ($f in $configPath, $loginPath) {
        $bytes = [IO.File]::ReadAllBytes($f)
        $name  = Split-Path -Leaf $f

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "$name was written with a UTF-8 BOM. EQEmu's JSON parser will reject it."
        }

        try {
            [IO.File]::ReadAllText($f) | ConvertFrom-Json | Out-Null
            Write-Ok "$name parses cleanly, no BOM."
        } catch {
            throw "$name is not valid JSON: $($_.Exception.Message)"
        }
    }

    Add-Summary 'Config' 'Done' "address $addr"
}

# ---------------------------------------------------------------------------
# Stage: Migrate
# ---------------------------------------------------------------------------

function Invoke-StageMigrate {
    Write-Head 'Stage 7/13 - Shared memory and migrations'

    # A running NMS-World would own port 9001, so the world.exe we launch below would
    # exit instantly and the stage would report Partial for the wrong reason.
    $null = Stop-NmsServices -Reason 'before running migrations'

    # Initialised out here, not inside the try: it is read after the try/finally, and a
    # future edit adding a catch would otherwise turn that into an uninitialised read
    # under Set-StrictMode.
    $settled = $false

    Push-Location $script:ServerRoot
    try {
        # shared_memory must run to completion BEFORE world starts, every time item or
        # spell data changes. See CODEBASE.md section 2.
        Write-Step 'Running shared_memory (loads items/spells into shared memory files)...'
        $sm = Start-Process -FilePath (Join-Path $script:ServerRoot 'shared_memory.exe') `
            -WorkingDirectory $script:ServerRoot -NoNewWindow -Wait -PassThru
        if ($sm.ExitCode -ne 0) {
            Write-Warn "shared_memory exited with code $($sm.ExitCode). Check logs\."
        } else { Write-Ok 'shared_memory completed.' }

        $rootPw = Get-RootPassword

        # Targets from common/version.h: CURRENT_BINARY_DATABASE_VERSION and
        # CUSTOM_BINARY_DATABASE_VERSION. Read them out of the header rather than
        # hardcoding, so this keeps working if the fork moves.
        $targetVersion = 9325
        $targetCustom  = 25
        $versionH = Join-Path $script:RepoServer 'common\version.h'
        if (Test-Path $versionH) {
            $vh = Get-Content $versionH -Raw
            if ($vh -match 'CURRENT_BINARY_DATABASE_VERSION\s+(\d+)') { $targetVersion = [int]$Matches[1] }
            if ($vh -match 'CUSTOM_BINARY_DATABASE_VERSION\s+(\d+)')  { $targetCustom  = [int]$Matches[1] }
        }
        Write-Step "Target versions from version.h: stock $targetVersion, custom $targetCustom"

        function Get-DbVersions {
            # NOT -Quiet: a failed query must surface as an exception, not be mistaken for
            # a result. The previous version of this code matched any digits in the output,
            # so a "column does not exist" error read as success.
            $row = Invoke-Sql -Password $rootPw -Database $DbName `
                -Query 'SELECT version, custom_version FROM db_version LIMIT 1;'
            $text = ($row | Out-String).Trim()
            if ($text -match '(?m)^\s*(\d+)\s+(\d+)\s*$') {
                return @{ Version = [int]$Matches[1]; Custom = [int]$Matches[2] }
            }
            return $null
        }

        # The shipped dump already carries db_version = (9325, 0, 25), so on a clean
        # import both manifests are no-ops and this returns immediately. That is fine and
        # expected - it is also exactly why the health check in the next stage exists
        # (CODEBASE.md 4.3): being stamped at 25 is not evidence the payloads landed.
        $before = $null
        try { $before = Get-DbVersions } catch { }
        if ($before -and $before.Version -ge $targetVersion -and $before.Custom -ge $targetCustom) {
            Write-Ok "Database already at $($before.Version)/$($before.Custom); no migrations pending."
            Write-Step 'Booting world briefly anyway to confirm it starts cleanly...'
        } else {
            Write-Step 'Booting world to apply migrations. Allowing up to 20 minutes...'
        }

        $world = Start-Process -FilePath (Join-Path $script:ServerRoot 'world.exe') `
            -WorkingDirectory $script:ServerRoot -NoNewWindow -PassThru

        $deadline = (Get-Date).AddMinutes(20)
        $last = $null
        $consecutiveErrors = 0
        $lastError = ''

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            if ($world.HasExited) {
                Write-Warn "world exited with code $($world.ExitCode) before reaching target. Check logs\."
                break
            }
            try {
                $now = Get-DbVersions
                $consecutiveErrors = 0
                if ($now) {
                    $desc = "$($now.Version)/$($now.Custom)"
                    if ($desc -ne $last) { Write-Step "db_version: $desc (target $targetVersion/$targetCustom)"; $last = $desc }
                    if ($now.Version -ge $targetVersion -and $now.Custom -ge $targetCustom) {
                        # Give any in-flight DDL a moment to commit before we stop world.
                        Start-Sleep -Seconds 20
                        $settled = $true
                        break
                    }
                }
            } catch {
                # A locked table during migration is transient and worth waiting out. A
                # missing column is not - it will fail identically forever, and that is
                # precisely the broken-schema case the Health stage exists to diagnose.
                # Bail after 8 consecutive failures (~2 min) rather than burning 20.
                $consecutiveErrors++
                $lastError = $_.Exception.Message
                if ($consecutiveErrors -ge 8) {
                    Write-Warn "The version query has failed $consecutiveErrors times running:"
                    Write-Warn "  $lastError"
                    Write-Warn 'Not waiting out the rest of the window. The Health stage will detail this.'
                    break
                }
                continue
            }
        }

        if (-not $world.HasExited) {
            # Note: Stop-Process always calls Process.Kill(); -Force only suppresses the
            # confirmation prompt for processes in another session. There is no soft-close
            # available here. That is why the success path above sleeps 20s first - to let
            # any in-flight DDL commit before we pull the rug out.
            Write-Step 'Stopping world...'
            Stop-Process -Id $world.Id -Force -ErrorAction SilentlyContinue
            if (-not $world.WaitForExit(30000)) {
                Write-Warn 'world is still running after 30s. Stop it by hand before continuing.'
            }
            Start-Sleep -Seconds 3
        }

        if ($settled) {
            Write-Ok "Migrations complete at $targetVersion/$targetCustom."
        } else {
            Write-Warn "Did not reach $targetVersion/$targetCustom within the window."
            Write-Warn 'The health stage will show what actually landed. Check logs\ too.'
        }

    } finally { Pop-Location }

    Add-Summary 'Migrate' $(if ($settled) { 'Done' } else { 'Partial' })
}

# ---------------------------------------------------------------------------
# Stage: Health
# ---------------------------------------------------------------------------

function Invoke-StageHealth {
    Write-Head 'Stage 10/13 - Content health check'
    Write-Step 'db_version.custom_version is a claim, not a fact - the authors found servers'
    Write-Step 'stamped past payloads that never landed. This audits the actual data.'
    Write-Step 'See CODEBASE.md 4.3.'

    $sqlPath = Join-Path $script:RepoServer 'utils\sql\nms_content_health_check.sql'
    if (-not (Test-Path $sqlPath)) {
        Write-Warn "Health check SQL not found at $sqlPath"
        Add-Summary 'Health' 'Skipped' 'sql missing'
        return
    }

    $rootPw = Get-RootPassword
    $client = Resolve-MysqlClient
    $outFile = Join-Path $script:LogRoot "health-check-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # --force is essential here. Without it the client aborts at the first failing
    # statement, and the first statement reads db_version.custom_version - exactly the
    # column that is missing on the broken databases this audit exists to find. We would
    # get one line of output and a "Done" summary. With --force all 20 checks run.
    $old = $env:MYSQL_PWD
    $env:MYSQL_PWD = $rootPw
    try {
        # --force makes the client keep going past errors, so it WILL write to stderr on
        # exactly the broken databases this audit exists to diagnose. Invoke-Native keeps
        # that from aborting the stage before we can report it.
        $cmdLine = "`"$client`" --host=127.0.0.1 --user=root --database=$DbName --table --force < `"$sqlPath`""
        $null = Invoke-Native -Capture { cmd.exe /c $cmdLine }
        $result = $script:NativeOutput
    } finally {
        if ($null -eq $old) { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $old }
    }

    $result | Out-File -FilePath $outFile -Encoding UTF8
    $result | ForEach-Object { Write-Host "    $_" }

    $errors = @($result | Where-Object { $_ -match 'ERROR \d+' })

    Write-Host ''
    Write-Ok "Saved to $outFile"
    if ($errors.Count -gt 0) {
        Write-Bad "$($errors.Count) statement(s) errored - the schema is incomplete:"
        $errors | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    }
    Write-Warn 'Read this yourself. Every line prints its own expected value - anything that'
    Write-Warn 'disagrees names the exact payload that is missing.'

    Add-Summary 'Health' $(if ($errors.Count -gt 0) { 'Partial' } else { 'Done' }) `
        (Split-Path -Leaf $outFile)
}

# ---------------------------------------------------------------------------
# Stage: Export
# ---------------------------------------------------------------------------

function Invoke-StageExport {
    Write-Head 'Stage 11/13 - Client data files'

    $exe = Join-Path $script:ServerRoot 'export_client_files.exe'
    if (-not (Test-Path $exe)) {
        Write-Warn 'export_client_files.exe not found; skipping.'
        Add-Summary 'Export' 'Skipped' 'binary missing'
        return
    }

    # The exporter writes to <ServerRoot>/export/ and will NOT create that directory
    # itself. Runtime stage makes it, but make it here too so -OnlyStage Export works.
    $exportDir = Join-Path $script:ServerRoot 'export'
    if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

    Push-Location $script:ServerRoot
    try {
        Write-Step 'Exporting spells_us.txt, dbstr_us.txt, SkillCaps.txt, BaseData.txt...'
        $p = Start-Process -FilePath $exe -WorkingDirectory $script:ServerRoot `
            -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Warn "export_client_files exited with $($p.ExitCode)" }
    } finally { Pop-Location }

    $wanted = @('spells_us.txt', 'dbstr_us.txt', 'SkillCaps.txt', 'BaseData.txt')
    $got = @()

    foreach ($f in $wanted) {
        $src = Join-Path $exportDir $f
        if (Test-Path $src) {
            Copy-Item $src $script:ClientOut -Force
            $got += $f
            Write-Ok "$f ($([math]::Round((Get-Item $src).Length/1KB)) KB)"
        } else {
            Write-Warn "$f was not produced (looked in $exportDir)"
        }
    }

    if ($got.Count -lt $wanted.Count) {
        Write-Warn 'Check logs\ - the exporter logs "unable to open ... skipping" when it'
        Write-Warn 'cannot write, and it needs a working DB connection in eqemu_config.json.'
    }

    # Stage the client overlay alongside the exported files so there is one folder to
    # hand players.
    $overlay = Join-Path $script:RepoClient 'ClientFiles'
    if (Test-Path $overlay) {
        $dst = Join-Path $script:ClientOut 'ClientFiles'
        $rc = Invoke-Native { robocopy $overlay $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP }
        if ($rc -lt 8) { Write-Ok 'Staged the client overlay (dinput8.dll + UI XML).' }
    }

    # Falls back to live detection so -OnlyStage Export (with no prior Config run in this
    # session) still produces a README with a real address rather than a blank line.
    $advertised = Get-StoredCredential 'Public address'
    if (-not $advertised) { $advertised = Get-PublicAddress }

    # eqhost.txt is how the client finds the loginserver. Without it the client sits at the
    # login screen forever with no error - it has nowhere to connect to. Neither the client
    # README nor any EQEmu doc in this repo mentions it, so generate it here with the real
    # address rather than leaving players to write it by hand.
    # 5999, not 5998: RoF2 is a SoD-lineage client and needs the SoD opcode stream.
    $eqhost = "[LoginServer]`r`nHost=$advertised" + ':5999' + "`r`n"
    Write-TextFile -Path (Join-Path $script:ClientOut 'eqhost.txt') -Content $eqhost
    Write-Ok "eqhost.txt written (points at $advertised`:5999 - the SoD stream RoF2 needs)"

    $readme = @"
NMS client setup
================

Server address: $advertised
Login port:     5999  (the SoD-lineage stream; RoF2 requires this, not 5998)

1. Start from a RoF2-era EverQuest client. It is not included and cannot be - the client
   files are Daybreak's.

2. Copy eqhost.txt into the client root, next to eqgame.exe. This is what tells the
   client where the server is - without it the client sits at the login screen
   forever with no error message. It should read:

     [LoginServer]
     Host=$advertised`:5999

3. Copy everything in ClientFiles\ over your client, preserving structure:
     - dinput8.dll goes in the client root, next to eqgame.exe
     - uifiles\<skin>\*.xml go into the matching skin folders

4. Copy these four files into BOTH the client root AND the client's Resources\ folder.
   The client keeps two copies and will load stale data if you only do one:
     $($got -join "`r`n     ")

5. Launch eqgame.exe. Do NOT use any patcher or launcher - go straight to the exe.

Notes
-----
* dinput8.dll is REQUIRED. When Custom:ServerAuthStats is on, the CAuth handshake
  disconnects clients without it. It is a DirectInput proxy - eqgame.exe is never
  modified, and deleting the DLL fully reverts the install.

* Some equipment will be invisible and some inventory icons blank. That is the known art
  gap: 397 .eqg model archives and icon sheets dragitem179-222.dds that base RoF2 lacks.
  Cosmetic only. Copy them from a newer client if it bothers you.

* If you see "XML files are not compatible", do NOT follow its advice to run
  /loadskin Default 1 - that discards the custom windows. The popup can be silenced by
  editing eqstr_us.txt string id 3146.

Generated $(Get-Date -Format 'u')
"@
    Write-TextFile -Path (Join-Path $script:ClientOut 'README.txt') -Content $readme

    Write-Ok "Client package staged in $($script:ClientOut)"

    # Producing none of the four is a FAILURE, not a Done with a small number beside it.
    # Players cannot connect without these, so it must show up red in the summary.
    $state = if ($got.Count -eq $wanted.Count) { 'Done' }
             elseif ($got.Count -eq 0)         { 'Failed' }
             else                              { 'Partial' }
    Add-Summary 'Export' $state "$($got.Count)/$($wanted.Count) files"
}

# ---------------------------------------------------------------------------
# Stage: Services
# ---------------------------------------------------------------------------

function Invoke-StageServices {
    Write-Head 'Stage 12/13 - Services'

    # sc.exe can run a bare .exe as a service, but EQEmu binaries are console apps that do
    # not implement the service control protocol, so Windows kills them at startup. A
    # supervisor is required. NSSM is the standard answer.
    $nssm = Get-Command nssm -ErrorAction SilentlyContinue
    if (-not $nssm) {
        $local = Join-Path $InstallRoot 'tools\nssm.exe'
        if (Test-Path $local) { $nssm = @{ Source = $local } }
    }

    if (-not $nssm) {
        Write-Step 'NSSM not found; installing via winget...'
        try {
            $null = Invoke-Native -Show { winget install --id NSSM.NSSM --exact --silent `
                --accept-package-agreements --accept-source-agreements --disable-interactivity }
            $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
            $user    = [Environment]::GetEnvironmentVariable('Path','User')
            $env:Path = (@($machine,$user) | Where-Object { $_ }) -join ';'
            $nssm = Get-Command nssm -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Could not install NSSM: $($_.Exception.Message)"
        }
    }

    if (-not $nssm) {
        Write-Warn 'NSSM unavailable - skipping service registration.'
        Write-Warn 'Use the start-server.ps1 script instead; it launches the same processes.'
        Add-Summary 'Services' 'Skipped' 'no nssm'
        New-HelperScripts
        return
    }

    Write-Ok "NSSM: $($nssm.Source)"

    $registered = 0
    foreach ($svc in $script:Services) {
        $exe = Join-Path $script:ServerRoot $svc.Exe
        if (-not (Test-Path $exe)) { Write-Warn "$($svc.Exe) missing - skipping $($svc.Name)"; continue }

        $existing = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Step "$($svc.Name) already registered; reconfiguring..."
            if ($existing.Status -eq 'Running') { Stop-Service -Name $svc.Name -Force }
        } else {
            $null = Invoke-Native { & $nssm.Source install $svc.Name $exe }
        }

        $null = Invoke-Native { & $nssm.Source set $svc.Name Application       $exe                    }
        $null = Invoke-Native { & $nssm.Source set $svc.Name AppDirectory      $script:ServerRoot      }
        $null = Invoke-Native { & $nssm.Source set $svc.Name DisplayName       $svc.Display            }
        if ($svc.Args) { $null = Invoke-Native { & $nssm.Source set $svc.Name AppParameters $svc.Args  } }

        # Manual start. These must come up in order (world before zone), and Windows
        # service dependencies do not express "wait until world is actually serving".
        # start-server.ps1 sequences them properly.
        # Belt and braces on the PATH. Services run as LocalSystem, which reads only the
        # machine PATH; zone.exe needs perl532.dll and the MinGW runtime from Strawberry,
        # and shells out to bare `perl` to syntax-check quests. Stage 1 fixes the machine
        # PATH, but a service registered before that ran would not see it.
        $perlBins = @(
            'C:\Strawberry\perl\bin', 'C:\Strawberry\c\bin', 'C:\Strawberry\perl\site\bin'
        ) | Where-Object { Test-Path $_ }
        if (@($perlBins).Count -gt 0) {
            $envExtra = "PATH=$((@($perlBins) -join ';'));%PATH%"
            $null = Invoke-Native { & $nssm.Source set $svc.Name AppEnvironmentExtra $envExtra }
        }

        $null = Invoke-Native { & $nssm.Source set $svc.Name Start SERVICE_DEMAND_START }

        $null = Invoke-Native { & $nssm.Source set $svc.Name AppStdout (Join-Path $script:ServerRoot "logs\$($svc.Name).out.log") }
        $null = Invoke-Native { & $nssm.Source set $svc.Name AppStderr (Join-Path $script:ServerRoot "logs\$($svc.Name).err.log") }
        $null = Invoke-Native { & $nssm.Source set $svc.Name AppRotateFiles 1        }
        $null = Invoke-Native { & $nssm.Source set $svc.Name AppRotateBytes 10485760 }

        Write-Ok "$($svc.Name) -> $($svc.Exe)"
        $registered++
    }

    Write-Step "$registered service(s) registered, all set to manual start."
    Write-Step 'Use start-server.ps1 - it runs shared_memory first and sequences the rest.'

    New-HelperScripts
    Register-BootTask
    Add-Summary 'Services' 'Done' "$registered services"
}

function Register-BootTask {
    <#
        The services are manual-start on purpose: Windows service dependencies cannot
        express "wait until world is actually serving before starting zones", and starting
        them all at once does not work. So instead of auto-start services, a single boot
        task runs start-server.ps1, which runs shared_memory and then sequences the rest
        with the right delays.
    #>
    $taskName = 'NMS Server Startup'
    $startScript = Join-Path $script:ServerRoot 'start-server.ps1'

    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`"" `
            -WorkingDirectory $script:ServerRoot

        # 90 second delay: let the network stack and MariaDB settle before world tries to
        # connect. Without it, a fast boot races the database service.
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT90S'

        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description 'Starts the NMS EverQuest server in the correct order after boot.' | Out-Null

        Write-Ok "Boot task '$taskName' registered (90s delay after startup)."
        Write-Step 'Disable it with: Disable-ScheduledTask -TaskName ''NMS Server Startup'''
    } catch {
        Write-Warn "Could not register the boot task: $($_.Exception.Message)"
        Write-Warn 'The server will not start automatically after a reboot. Run'
        Write-Warn 'start-server.ps1 by hand, or create the task yourself.'
    }
}

function New-HelperScripts {
    $start = @'
<#
    Starts the NMS server in the correct order.

    shared_memory must run and EXIT before world starts - it loads items and spells into
    shared memory files that world and zone then map. Re-run this script after any change
    to item or spell data, or the servers will keep serving the old values.
#>
[CmdletBinding()]
param([switch] $SkipSharedMemory)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $SkipSharedMemory) {
    Write-Host 'Running shared_memory...' -ForegroundColor Cyan
    $p = Start-Process -FilePath (Join-Path $root 'shared_memory.exe') `
        -WorkingDirectory $root -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warning "shared_memory exited with $($p.ExitCode); continuing anyway."
    }
}

$order = @(
    @{ Name = 'NMS-LoginServer'; Exe = 'loginserver.exe'; Wait = 3  },
    @{ Name = 'NMS-World';       Exe = 'world.exe';       Wait = 15 },  # world must be serving before zones attach
    @{ Name = 'NMS-Zone';        Exe = 'eqlaunch.exe';    Wait = 5  },
    @{ Name = 'NMS-UCS';         Exe = 'ucs.exe';         Wait = 2  },
    @{ Name = 'NMS-QueryServ';   Exe = 'queryserv.exe';   Wait = 0  }
)

foreach ($s in $order) {
    $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warning "$($s.Name) is not registered; skipping."; continue }
    if ($svc.Status -eq 'Running') { Write-Host "$($s.Name) already running." -ForegroundColor DarkGray; continue }

    # NSSM parks a service in Paused when the application keeps exiting faster than its
    # restart throttle. A paused service cannot be started - Start-Service fails with
    # "Cannot open <name> service on computer '.'", which reads like a permissions
    # problem and is not. It has to be stopped first.
    if ($svc.Status -eq 'Paused') {
        Write-Warning "$($s.Name) is Paused (NSSM restart throttle - it was crash-looping). Resetting."
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        (Get-Service -Name $s.Name).WaitForStatus('Stopped', '00:00:20')
    }

    Write-Host "Starting $($s.Name)..." -ForegroundColor Cyan
    try {
        Start-Service -Name $s.Name -ErrorAction Stop
    } catch {
        Write-Warning "$($s.Name) failed to start: $($_.Exception.Message)"
        Write-Warning "Run it directly to see why:  cd $PSScriptRoot; .\$($s.Exe)"
        continue
    }
    if ($s.Wait -gt 0) { Start-Sleep -Seconds $s.Wait }
}

Write-Host ''
Get-Service -Name 'NMS-*' | Format-Table Name, Status, DisplayName -AutoSize
'@

    $stop = @'
# Stops the NMS server, reverse of start order.
$ErrorActionPreference = 'Continue'

foreach ($n in 'NMS-QueryServ', 'NMS-UCS', 'NMS-Zone', 'NMS-World', 'NMS-LoginServer') {
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    # Paused counts as needing a stop too - that is NSSM's crash-loop state, and leaving
    # it paused blocks the next Start-Service.
    if ($svc -and $svc.Status -in 'Running', 'Paused') {
        Write-Host "Stopping $n..." -ForegroundColor Cyan
        Stop-Service -Name $n -Force
    }
}

Write-Host ''
Get-Service -Name 'NMS-*' | Format-Table Name, Status -AutoSize
'@

    $status = @'
# Quick health view: services, listening ports, recent errors.
Write-Host 'Services' -ForegroundColor Cyan
Get-Service -Name 'NMS-*' -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize

# All player-facing listeners are UDP: login 5998, world 9000, UCS 7778, zones 7000-7400.
# Only servertalk (9001) and the web/telnet endpoints are TCP.
Write-Host 'Listening ports (UDP - player facing)' -ForegroundColor Cyan
Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
    Where-Object {
        $_.LocalPort -in 5998, 7778, 9000 -or
        ($_.LocalPort -ge 7000 -and $_.LocalPort -le 7400)
    } |
    Sort-Object LocalPort |
    Select-Object -First 15 LocalAddress, LocalPort | Format-Table -AutoSize

Write-Host 'Listening ports (TCP - internal)' -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 9000, 9001, 9080, 9081 } |
    Sort-Object LocalPort |
    Select-Object LocalAddress, LocalPort | Format-Table -AutoSize

Write-Host 'Recent log errors' -ForegroundColor Cyan
$logs = Join-Path $PSScriptRoot 'logs'
if (Test-Path $logs) {
    Get-ChildItem $logs -Filter '*.log' | Sort-Object LastWriteTime -Descending |
        Select-Object -First 5 | ForEach-Object {
            $hits = Select-String -Path $_.FullName -Pattern 'error|fail|fatal' -ErrorAction SilentlyContinue |
                Select-Object -Last 3
            if ($hits) {
                Write-Host "  $($_.Name)" -ForegroundColor Yellow
                $hits | ForEach-Object { Write-Host "    $($_.Line)" -ForegroundColor DarkGray }
            }
        }
} else { Write-Host '  no logs directory yet' -ForegroundColor DarkGray }
'@

    Write-TextFile -Path (Join-Path $script:ServerRoot 'start-server.ps1')  -Content $start
    Write-TextFile -Path (Join-Path $script:ServerRoot 'stop-server.ps1')   -Content $stop
    Write-TextFile -Path (Join-Path $script:ServerRoot 'status-server.ps1') -Content $status

    Write-Ok 'Wrote start-server.ps1, stop-server.ps1, status-server.ps1'
}

# ---------------------------------------------------------------------------
# Stage: Firewall
# ---------------------------------------------------------------------------

function Invoke-StageFirewall {
    Write-Head 'Stage 13/13 - Firewall'

    foreach ($r in $script:FirewallRules) {
        $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Step "$($r.Name) already exists; updating..."
            Remove-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
        }

        New-NetFirewallRule `
            -DisplayName $r.Name `
            -Direction Inbound `
            -Action Allow `
            -Protocol $r.Protocol `
            -LocalPort $r.Port `
            -Profile Any `
            -Group 'NMS EverQuest Server' | Out-Null

        Write-Ok "$($r.Protocol)/$($r.Port)  $($r.Name)"
    }

    Write-Host ''
    Write-Warn 'This opens WINDOWS Firewall only. Most VPS providers run their own network'
    Write-Warn 'firewall in front of the machine, and many block inbound UDP by default.'
    Write-Warn 'If clients cannot connect while every service reports Running, open these'
    Write-Warn 'inbound UDP ports in the provider control panel as well:'
    Write-Warn '  5998 (login)  9000 (world)  7000-7400 (zones)  7778 (chat)'

    # Deliberate omissions, stated so nobody "fixes" them later:
    Write-Host ''
    Write-Step 'Deliberately NOT opened:'
    Write-Step '  3306/TCP (MariaDB)   - loopback only; nothing outside the box needs it'
    Write-Step '  9000/TCP (telnet)    - unauthenticated admin channel, bound to 127.0.0.1.'
    Write-Step '                         Note UDP/9000 above is a different thing: that is'
    Write-Step '                         the world client listener and it must be open.'
    Write-Step '  9001/TCP (servertalk)- world<->zone, bound to 127.0.0.1'
    Write-Step '  9080/9081 (http/web) - bound locally; expose only behind a reverse proxy'

    Add-Summary 'Firewall' 'Done' "$($script:FirewallRules.Count) rules"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

foreach ($d in $InstallRoot, $script:LogRoot) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$transcript = Join-Path $script:LogRoot "setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcript -Force | Out-Null

$overall = [Diagnostics.Stopwatch]::StartNew()

try {
    Write-Head 'NMS server - Stage 2 of 2 - Setup'
    Write-Host "  Install root: $InstallRoot"
    Write-Host "  Stage:        $(if ($OnlyStage) { "$OnlyStage (only)" } else { $Stage })"
    Write-Host "  Repo:         $(if ($RepoUrl) { $RepoUrl } else { '(derived from the local checkout at clone time)' })"
    Write-Host "  Log:          $transcript"

    if (-not (Test-Admin)) { throw 'Must run as Administrator.' }
    Write-Ok 'Running elevated.'

    Set-DefenderExclusion

    if (Should-Run 'Clone')    { Invoke-StageClone }
    if (Should-Run 'Database') { Invoke-StageDatabase }
    if (Should-Run 'Build')    { Invoke-StageBuild }
    if (Should-Run 'Runtime')  { Invoke-StageRuntime }
    if (Should-Run 'Maps')     { Invoke-StageMaps }
    if (Should-Run 'Config')   {
        $publicAddr = Get-PublicAddress
        Set-StoredCredential 'Public address' $publicAddr
        Invoke-StageConfig -Address $publicAddr
    }
    if (Should-Run 'Migrate')  { Invoke-StageMigrate }
    if (Should-Run 'Patches')  { Invoke-StagePatches }
    if (Should-Run 'Login')    { Invoke-StageLogin }
    if (Should-Run 'Health')   { Invoke-StageHealth }
    if (Should-Run 'Export')   { Invoke-StageExport }
    if (Should-Run 'Services') { Invoke-StageServices }
    if (Should-Run 'Firewall') { Invoke-StageFirewall }

    $overall.Stop()

    # ---- Summary ----------------------------------------------------------
    Write-Head 'Summary'
    $script:Summary | Format-Table -AutoSize | Out-String -Width 100 | Write-Host
    Write-Host "  Total time: $([math]::Round($overall.Elapsed.TotalMinutes,1)) minutes"

    # @() - a single matching row would otherwise be a scalar, and .Count on a scalar
    # throws under Set-StrictMode -Version Latest.
    $failed = @($script:Summary | Where-Object { $_.State -eq 'Failed' })
    if ($failed) {
        Write-Bad "$($failed.Count) stage(s) failed:"
        $failed | ForEach-Object { Write-Host "         - $($_.Stage): $($_.Detail)" -ForegroundColor Red }
    }

    Write-Head 'Next steps'
    $addr = Get-StoredCredential 'Public address'
    Write-Host @"
  1. Start the server:
         cd $($script:ServerRoot)
         .\start-server.ps1

  2. Watch it come up:
         .\status-server.ps1

  3. Connect a client to $addr on port 5998. The client package - dinput8.dll, the UI
     files and the four exported data files - is staged in:
         $($script:ClientOut)
     Its README.txt has the player-facing instructions.

  4. Log in once to create your account, then grant yourself GM:
         UPDATE account SET status = 250 WHERE name = '<your login>';

  5. Read the health check output before you trust the content:
         $($script:LogRoot)\health-check-*.txt
     db_version.custom_version is not evidence. See CODEBASE.md 4.3.

  Credentials: $($script:CredentialFile)
  Back that file up somewhere off this machine.
"@ -ForegroundColor Cyan

    Write-Host ''
    Write-Warn 'These scripts have not been run against a real VPS. If a stage fails, the'
    Write-Warn 'transcript above has the detail, and you can resume with -Stage <name>.'

    exit $(if ($failed) { 1 } else { 0 })
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''
    Write-Host "  Full log: $transcript" -ForegroundColor Yellow
    Write-Host '  Fix the cause, then resume with:  -Stage <StageName>' -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
