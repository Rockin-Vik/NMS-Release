<#
.SYNOPSIS
    Creates, rotates, lists and removes per-developer database accounts.

.DESCRIPTION
    MariaDB stays bound to 127.0.0.1 and 3306 stays closed at the firewall - see
    1-Install-Prerequisites.ps1 (Set-MariaDbBindAddress) and 2-Setup-NMSServer.ps1, which
    open UDP 5998/5999/7000-7400/7778/9000 and deliberately never 3306. Developers reach
    the database through an SSH tunnel, so their connections arrive as 'localhost' and the
    accounts this script creates are scoped to @localhost.

    Each developer gets their OWN account. Never share the server's account (world and zone
    use it) and never hand out root: when something drops a table you want to know whose
    session did it.

    The generated password is printed ONCE. It is not written to credentials.txt, not
    logged, and cannot be recovered - rotate with -Rotate if it is lost. Send it to the
    developer over something other than the channel you sent their username on.

.PARAMETER Name
    The developer account to create. Letters, digits and underscore only; a 'dev_' prefix
    is added if you do not supply one, so these are obvious in SHOW GRANTS output.

.PARAMETER Write
    Grant SELECT, INSERT, UPDATE, DELETE. Default is SELECT only - start people read-only
    and widen when they need it.

.PARAMETER Rotate
    Generate and set a new password for an existing account. Grants are left alone.

.PARAMETER Remove
    Drop the account entirely.

.PARAMETER List
    Show the dev accounts that exist and what they can do, then exit.

.PARAMETER ServerAddress
    Host the developer types in their ssh command. Read from eqemu_config.json when
    omitted, falling back to this machine's name.

.PARAMETER AdminUser
    Database account used to run the CREATE USER / GRANT. Defaults to the one in
    credentials.txt - which is the server's own account and does NOT have rights on
    mysql.* , so in practice you want -AdminUser root.

    The password is looked up per account: 'root' reads 'MariaDB root password' from
    credentials.txt, the stored 'Database user' reads 'Database password', and anything
    else prompts. Pass -AdminPassword to override.

.PARAMETER AdminPassword
    Password for -AdminUser, when it is not in credentials.txt. Prompted for if omitted.

.EXAMPLE
    .\New-DbDevUser.ps1 -Name alice
    Create dev_alice with read-only access to peq, and print her tunnel command.

.EXAMPLE
    .\New-DbDevUser.ps1 -Name bob -Write
    Create dev_bob with read/write access.

.EXAMPLE
    .\New-DbDevUser.ps1 -List
    Show every dev account and its grants.

.NOTES
    This grants database access only. The developer still needs an OS account on the box
    with their public key in authorized_keys before the tunnel will open.
#>

[CmdletBinding(DefaultParameterSetName = 'Create', SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(ParameterSetName = 'Create', Position = 0, Mandatory)]
    [Parameter(ParameterSetName = 'Rotate', Position = 0, Mandatory)]
    [Parameter(ParameterSetName = 'Remove', Position = 0, Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_]{1,24}$')]
    [string] $Name,

    [Parameter(ParameterSetName = 'Create')]
    [switch] $Write,

    [Parameter(ParameterSetName = 'Rotate', Mandatory)]
    [switch] $Rotate,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch] $Remove,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch] $List,

    [string] $ServerAddress,
    [string] $AdminUser = 'root',
    [securestring] $AdminPassword,
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
                 '--batch', '--silent')

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

    # Deliberately not Write-Verbose'ing the query: these carry passwords.
    return @($rows)
}

function New-DbPassword {
    param([int] $Length = 24)

    # Alphanumeric only. Symbols would need escaping in the SQL literal, in the shell the
    # developer pastes it into, and in whatever client they use - not worth the entropy.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no l/I/0/O
    $bytes    = [byte[]]::new($Length)
    $rng      = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    # Modulo bias across 56 symbols in a 256-value byte is negligible at this length.
    $chars = foreach ($b in $bytes) { $alphabet[$b % $alphabet.Length] }
    return -join $chars
}

function Get-ServerAddress {
    if ($ServerAddress) { return $ServerAddress }
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($j.server.world.address) { return $j.server.world.address }
        } catch {
            Write-Verbose "Could not read address from ${ConfigPath}: $($_.Exception.Message)"
        }
    }
    return $env:COMPUTERNAME
}

function Resolve-AccountName {
    param([string] $Raw)
    if ($Raw -like 'dev_*') { return $Raw }
    return "dev_$Raw"
}

function Test-UserExists {
    param([string] $Account)
    $rows = @(Invoke-Sql -Query @"
SELECT COUNT(*) FROM mysql.user WHERE user = '$Account' AND host = 'localhost';
"@ | Where-Object { $_ -match '^\s*\d+\s*$' })
    if ($rows.Count -eq 0) { return $false }
    return ([int] $rows[0]) -gt 0
}

function Show-TunnelInstructions {
    param([string] $Account, [string] $Password, [string] $Addr)

    Write-Host ''
    Write-Host '  Send these to the developer (password over a DIFFERENT channel):' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Open the tunnel and leave it running:' -ForegroundColor Gray
    Write-Host ("     ssh -N -L 3307:127.0.0.1:3306 <their-os-user>@{0}" -f $Addr)
    Write-Host ''
    Write-Host '  2. Point the SQL client at the local end of the tunnel:' -ForegroundColor Gray
    Write-Host  '     host      127.0.0.1'
    Write-Host  '     port      3307'
    Write-Host ("     user      {0}" -f $Account)
    Write-Host ("     password  {0}" -f $Password) -ForegroundColor Yellow
    Write-Host ("     database  {0}" -f $DbName)
    Write-Host ''
    Write-Warn 'This password is shown once and is not stored anywhere. Rotate with -Rotate if lost.'
    Write-Host ''
}

# ---------------------------------------------------------------------------

try {
    $script:Client = Resolve-MysqlClient
    $script:DbUser = $AdminUser

    # Creating users and granting needs rights on mysql.* , which the server's own account
    # does not have (it gets ERROR 1142 on mysql.user). So the admin credential is resolved
    # per account rather than always reading 'Database password'.
    $storedDbUser = Get-StoredValue 'Database user'
    if (-not $storedDbUser) { $storedDbUser = 'peq' }

    if ($AdminPassword) {
        $script:DbPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
    }
    elseif ($script:DbUser -eq 'root') {
        $script:DbPass = Get-StoredValue 'MariaDB root password'
        if (-not $script:DbPass) {
            Write-Warn "No 'MariaDB root password' entry in $CredentialFile."
            $sec = Read-Host "Password for '$($script:DbUser)'" -AsSecureString
            $script:DbPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
    }
    elseif ($script:DbUser -eq $storedDbUser) {
        $script:DbPass = Get-StoredValue 'Database password'
        Write-Warn "'$($script:DbUser)' is the server's own account; it cannot create users."
        Write-Host '  Re-run without -AdminUser to use root.' -ForegroundColor Gray
    }
    else {
        $sec = Read-Host "Password for '$($script:DbUser)'" -AsSecureString
        $script:DbPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }

    if (-not $script:DbPass) { throw "No password available for '$($script:DbUser)'." }

    $stored = Get-StoredValue 'Database name'
    if ($stored) { $DbName = $stored }

    # ---- List ------------------------------------------------------------
    if ($List) {
        $rows = @(Invoke-Sql -Query @"
SELECT user FROM mysql.user WHERE user LIKE 'dev\_%' AND host = 'localhost' ORDER BY user;
"@ | Where-Object { $_ -match '\S' })

        Write-Host ''
        Write-Host '  Developer accounts (@localhost, tunnel only)' -ForegroundColor Cyan
        Write-Host '  --------------------------------------------' -ForegroundColor Cyan
        if ($rows.Count -eq 0) {
            Write-Host '  none' -ForegroundColor Gray
            Write-Host ''
            Write-Host '  Create one:  .\New-DbDevUser.ps1 -Name alice' -ForegroundColor Cyan
            Write-Host ''
            exit 0
        }
        foreach ($u in $rows) {
            $acct   = "$u".Trim()
            $grants = @(Invoke-Sql -Query "SHOW GRANTS FOR '$acct'@'localhost';" |
                Where-Object { "$_" -match "ON ``?$([regex]::Escape($DbName))" })
            $what = if ($grants.Count -eq 0) { 'no grants on ' + $DbName }
                    elseif ("$($grants[0])" -match 'INSERT|UPDATE|DELETE|ALL PRIVILEGES') { 'read/write' }
                    else { 'read-only' }
            $colour = if ($what -eq 'read/write') { 'Yellow' } else { 'Gray' }
            Write-Host ('  {0,-24} {1}' -f $acct, $what) -ForegroundColor $colour
        }
        Write-Host ''
        exit 0
    }

    $account = Resolve-AccountName -Raw $Name
    $exists  = Test-UserExists -Account $account

    # ---- Remove ----------------------------------------------------------
    if ($Remove) {
        if (-not $exists) { Write-Bad "No account '$account'@'localhost'."; exit 1 }
        if (-not $PSCmdlet.ShouldProcess("'$account'@'localhost'", 'DROP USER')) { exit 0 }
        Invoke-Sql -Query "DROP USER '$account'@'localhost';" | Out-Null
        Invoke-Sql -Query 'FLUSH PRIVILEGES;' | Out-Null
        if (Test-UserExists -Account $account) { Write-Bad "Drop ran but '$account' still exists."; exit 1 }
        Write-Ok "Dropped '$account'@'localhost'."
        Write-Host '  Their OS account and authorized_keys entry are separate - remove those too.' -ForegroundColor Gray
        Write-Host ''
        exit 0
    }

    # ---- Rotate ----------------------------------------------------------
    if ($Rotate) {
        if (-not $exists) { Write-Bad "No account '$account'@'localhost'. Create it without -Rotate."; exit 1 }
        if (-not $PSCmdlet.ShouldProcess("'$account'@'localhost'", 'SET PASSWORD')) { exit 0 }
        $pw = New-DbPassword
        Invoke-Sql -Query "SET PASSWORD FOR '$account'@'localhost' = PASSWORD('$pw');" | Out-Null
        Write-Ok "New password set for '$account'@'localhost'. The old one no longer works."
        Show-TunnelInstructions -Account $account -Password $pw -Addr (Get-ServerAddress)
        exit 0
    }

    # ---- Create ----------------------------------------------------------
    if ($exists) {
        Write-Bad "'$account'@'localhost' already exists."
        Write-Host '  Change its password:  .\New-DbDevUser.ps1 -Name ' -NoNewline -ForegroundColor Cyan
        Write-Host "$Name -Rotate" -ForegroundColor Cyan
        exit 1
    }

    $privs = if ($Write) { 'SELECT, INSERT, UPDATE, DELETE' } else { 'SELECT' }
    if (-not $PSCmdlet.ShouldProcess("'$account'@'localhost'", "CREATE USER + GRANT $privs ON $DbName.*")) { exit 0 }

    $pw = New-DbPassword
    Invoke-Sql -Query "CREATE USER '$account'@'localhost' IDENTIFIED BY '$pw';" | Out-Null
    # Scoped to the game database only, and no GRANT OPTION: a dev account must not be
    # able to widen its own privileges or reach mysql.* .
    Invoke-Sql -Query "GRANT $privs ON ``$DbName``.* TO '$account'@'localhost';" | Out-Null
    Invoke-Sql -Query 'FLUSH PRIVILEGES;' | Out-Null

    if (-not (Test-UserExists -Account $account)) {
        Write-Bad "CREATE USER ran but '$account' is not present."
        exit 1
    }

    Write-Ok "Created '$account'@'localhost' with $privs on $DbName."
    Write-Host '  @localhost is deliberate: the tunnel makes their connection arrive as local.' -ForegroundColor Gray
    Write-Host '  3306 stays closed at the firewall and MariaDB stays bound to 127.0.0.1.' -ForegroundColor Gray
    Show-TunnelInstructions -Account $account -Password $pw -Addr (Get-ServerAddress)
    exit 0
}
catch {
    Write-Bad $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-Host ("  at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber,
                                            $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
    }
    Write-Host "  ERROR 1142 on mysql.* means the admin account cannot create users." -ForegroundColor Gray
    Write-Host "  Default is -AdminUser root, using 'MariaDB root password' from $CredentialFile." -ForegroundColor Gray
    exit 1
}
