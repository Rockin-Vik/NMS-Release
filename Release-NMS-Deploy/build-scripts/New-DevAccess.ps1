<#
.SYNOPSIS
    Gives a developer SSH tunnel access to the database: OS account, public key, firewall.

.DESCRIPTION
    The counterpart to New-DbDevUser.ps1. That script creates the database account; this one
    creates the way to reach it. MariaDB stays bound to 127.0.0.1 and 3306 stays closed - the
    developer forwards it over SSH, so their connection arrives as localhost.

    What it does, all idempotent:

      1. Installs and starts OpenSSH Server if it is not already running
      2. Points sshd at a central key store (__PROGRAMDATA__/ssh/authorized_keys/%u) rather
         than each user's profile - a Windows profile does not exist until first logon, and
         pre-creating C:\Users\<name> makes Windows build the real profile as
         C:\Users\<name>.<MACHINE> instead, which silently breaks key auth
      3. Creates a local group (default NMS-DevTunnel) with an sshd Match block that allows
         port forwarding to 127.0.0.1:3306 ONLY, denies a TTY, and force-commands any shell
         attempt into a message
      4. Creates the OS account with a random password that is never displayed - key auth
         only - and adds it to Users and the tunnel group
      5. Installs the developer's public key with locked-down ACLs (SYSTEM + Administrators)
      6. Ensures a firewall rule for TCP 22, optionally scoped with -AllowedFrom

    The account is a standard user, NOT an administrator, and can forward one port. It is
    not a general shell account.

.PARAMETER Name
    OS account to create. Letters, digits and underscore, max 20 (SAM account limit).

.PARAMETER PublicKeyPath
    Path to the developer's .pub file - what they send you from
    ssh-keygen -t ed25519 on their machine. Never ask for their private key.

.PARAMETER PublicKey
    The key as a string, if you were sent the text rather than a file.

.PARAMETER AllowedFrom
    Source addresses for the SSH firewall rule. Omit to allow any - which is normal for SSH
    with key auth and password auth disabled.

.PARAMETER HardenSsh
    Also set PasswordAuthentication no in sshd_config. Do this once every admin who needs
    SSH has a key installed - you keep RDP and the console regardless.

.PARAMETER List
    Show the tunnel accounts that exist and whether each has a key installed.

.PARAMETER RemoveAccess
    Delete the OS account and its key. Does not touch their database account - remove that
    with New-DbDevUser.ps1 -Remove.

.EXAMPLE
    .\New-DevAccess.ps1 -Name alice -PublicKeyPath .\alice_ed25519.pub
    Full setup for one developer, then print what to send them.

.EXAMPLE
    .\New-DevAccess.ps1 -List

.EXAMPLE
    .\New-DevAccess.ps1 -Name alice -RemoveAccess

.NOTES
    Run as Administrator. Pair with:  .\New-DbDevUser.ps1 -Name alice
#>

[CmdletBinding(DefaultParameterSetName = 'Create', SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(ParameterSetName = 'Create', Position = 0, Mandatory)]
    [Parameter(ParameterSetName = 'Remove', Position = 0, Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_]{1,20}$')]
    [string] $Name,

    [Parameter(ParameterSetName = 'Create')]
    [string] $PublicKeyPath,

    [Parameter(ParameterSetName = 'Create')]
    [string] $PublicKey,

    [Parameter(ParameterSetName = 'Create')]
    [string[]] $AllowedFrom,

    [Parameter(ParameterSetName = 'Create')]
    [switch] $HardenSsh,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch] $RemoveAccess,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch] $List,

    # No whitespace: this lands verbatim in an sshd_config "Match Group <name>" line, and a
    # group name with a space in it silently becomes a second Match criterion.
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')]
    [string] $TunnelGroup = 'NMS-DevTunnel',
    [int]    $DbPort      = 3306
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

function Write-Ok   { param([string] $T) Write-Host "  [ OK ] $T" -ForegroundColor Green }
function Write-Warn { param([string] $T) Write-Host "  [WARN] $T" -ForegroundColor Yellow }
function Write-Bad  { param([string] $T) Write-Host "  [FAIL] $T" -ForegroundColor Red }
function Write-Step { param([string] $T) Write-Host "  $T" -ForegroundColor Gray }

$script:SshDataDir = Join-Path $env:ProgramData 'ssh'
$script:SshConfig  = Join-Path $script:SshDataDir 'sshd_config'
$script:KeyStore   = Join-Path $script:SshDataDir 'authorized_keys'
$script:Sentinel   = '# --- NMS dev tunnel accounts (managed by New-DevAccess.ps1) ---'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated PowerShell - it creates accounts and edits sshd_config.'
    }
}

function Install-SshServer {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step 'Installing OpenSSH Server...'
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' |
            Where-Object { $_.State -ne 'Installed' } | Select-Object -First 1
        if ($cap) { $null = Add-WindowsCapability -Online -Name $cap.Name }
        $svc = Get-Service sshd -ErrorAction SilentlyContinue
        if (-not $svc) { throw 'OpenSSH Server did not install. Install it from Optional Features and re-run.' }
    }

    # Starting it once creates %ProgramData%\ssh and the default sshd_config.
    if ($svc.Status -ne 'Running') { Start-Service sshd }
    Set-Service sshd -StartupType Automatic
    Write-Ok 'OpenSSH Server is installed, running and set to start automatically.'
}

function Set-SshConfigContent {
    param([Parameter(Mandatory)] [string] $Content)

    # sshd refuses to start on a malformed config, and this script edits sshd_config on the
    # very box that is reached over SSH: a bad Match block (an unvalidated -TunnelGroup with
    # a space in it, say) would lock everyone out of the machine it just configured, with no
    # way back in except the console. So: back up, write, ask sshd to parse it, and restore
    # the backup if it refuses. BOM-less, like every other config this repo writes.
    $backup = "$($script:SshConfig).nms.bak"
    if (Test-Path $script:SshConfig) { Copy-Item $script:SshConfig $backup -Force }

    [IO.File]::WriteAllText($script:SshConfig, $Content, (New-Object System.Text.UTF8Encoding($false)))

    $sshd = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path $sshd)) {
        Write-Warn "sshd.exe not found at $sshd - wrote sshd_config without validating it."
        return
    }

    # Capture stderr to a file rather than merging with 2>&1: on PS 5.1 a merged native
    # stderr arrives as ErrorRecords and confuses $?. The exit code is the real signal.
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $null = & $sshd -t -f $script:SshConfig 2> $errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $detail = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
            if (Test-Path $backup) {
                Copy-Item $backup $script:SshConfig -Force
                Write-Warn 'sshd rejected the new configuration - sshd_config rolled back.'
            }
            throw "sshd -t rejected the new sshd_config (exit $code): $("$detail".Trim())"
        }
    }
    finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-KeyStoreLayout {
    if (-not (Test-Path $script:KeyStore)) {
        $null = New-Item -ItemType Directory -Path $script:KeyStore -Force
    }
    # SYSTEM and Administrators only. sshd refuses a key file that anyone else can write.
    $null = & icacls.exe $script:KeyStore /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 2>&1

    $cfg = Get-Content $script:SshConfig -Raw

    # AuthorizedKeysFile: central store keyed by username. See the profile gotcha in the
    # description - this is the whole reason the store is not in C:\Users.
    $wanted = 'AuthorizedKeysFile __PROGRAMDATA__/ssh/authorized_keys/%u'
    if ($cfg -notmatch [regex]::Escape($wanted)) {
        # Comment out any existing directive rather than deleting it, so the original is
        # still visible to whoever reads this file next.
        $cfg = $cfg -replace '(?m)^\s*(AuthorizedKeysFile\s+.*)$', '#$1   # replaced by New-DevAccess.ps1'
        $cfg = "$wanted`r`n$cfg"
        Write-Ok 'sshd_config: AuthorizedKeysFile pointed at the central key store.'
    }

    # Match blocks must come LAST in sshd_config: everything after a Match belongs to that
    # Match. Appending is therefore both correct and idempotent here.
    if ($cfg -notmatch [regex]::Escape($script:Sentinel)) {
        $block = @"

$($script:Sentinel)
# Tunnel-only accounts: they may forward the database port and nothing else, get no TTY,
# and any attempt to run a shell just prints a line and exits.
Match Group $TunnelGroup
    AllowTcpForwarding yes
    PermitOpen 127.0.0.1:$DbPort
    PermitTTY no
    X11Forwarding no
    ForceCommand cmd.exe /c echo This account is for database tunnelling only.
"@
        $cfg = $cfg.TrimEnd() + "`r`n" + $block + "`r`n"
        Write-Ok "sshd_config: Match block for group $TunnelGroup added."
    }

    Set-SshConfigContent -Content $cfg
}

function Disable-SshPasswordAuth {
    $cfg = Get-Content $script:SshConfig -Raw
    if ($cfg -match '(?m)^\s*PasswordAuthentication\s+no\s*$') {
        Write-Ok 'sshd_config: password authentication already disabled.'
        return
    }
    if ($cfg -match '(?m)^\s*#?\s*PasswordAuthentication\s+.*$') {
        $cfg = $cfg -replace '(?m)^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication no'
    } else {
        $cfg = "PasswordAuthentication no`r`n$cfg"
    }
    Set-SshConfigContent -Content $cfg
    Write-Ok 'sshd_config: password authentication disabled (keys only).'
    Write-Warn 'RDP and the console are unaffected - you are not locked out.'
}

function New-RandomPassword {
    param([int] $Length = 32)
    # Never displayed and never needed: the account authenticates by key. It exists only
    # because a Windows local account must have one.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'
    $bytes    = [byte[]]::new($Length)
    $rng      = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    # A foreach STATEMENT is not an expression in PS 5.1, so it cannot go inside ( ).
    # Assign it first, then join.
    $chars = foreach ($b in $bytes) { $alphabet[$b % $alphabet.Length] }
    return -join $chars
}

function Get-PublicKeyText {
    if ($PublicKeyPath) {
        if (-not (Test-Path $PublicKeyPath)) { throw "Public key not found: $PublicKeyPath" }
        $text = (Get-Content $PublicKeyPath -Raw).Trim()
    } elseif ($PublicKey) {
        $text = $PublicKey.Trim()
    } else {
        return $null
    }

    if ($text -match 'PRIVATE KEY') {
        throw 'That is a PRIVATE key. Ask for the .pub file - never accept anyone''s private key.'
    }
    if ($text -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+\S+') {
        throw 'That does not look like an OpenSSH public key (expected e.g. "ssh-ed25519 AAAA... comment").'
    }
    if (@($text -split "`r?`n" | Where-Object { $_ -match '\S' }).Count -ne 1) {
        throw 'Expected exactly one key. Install additional keys by re-running per key.'
    }
    return $text
}

function Get-TunnelAccounts {
    $members = @(Get-LocalGroupMember -Group $TunnelGroup -ErrorAction SilentlyContinue)
    $out = @()
    foreach ($m in $members) {
        # Name comes through as MACHINE\user.
        $short  = ("$($m.Name)" -split '\\')[-1]
        $key    = Join-Path $script:KeyStore $short
        $out += [pscustomobject]@{
            Name   = $short
            HasKey = Test-Path $key
        }
    }
    return @($out)
}

function Show-DevInstructions {
    param([string] $Account)

    $addr = $env:COMPUTERNAME
    $cfgPath = 'C:\NMS\Server\eqemu_config.json'
    if (Test-Path $cfgPath) {
        try {
            $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
            if ($j.server.world.address) { $addr = $j.server.world.address }
        } catch { Write-Verbose "Could not read address: $($_.Exception.Message)" }
    }

    Write-Host ''
    Write-Host '  Send this to the developer:' -ForegroundColor Cyan
    Write-Host '  ---------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Open the tunnel (leave the window running):' -ForegroundColor Gray
    Write-Host ("     ssh -N -L 3307:127.0.0.1:{0} {1}@{2}" -f $DbPort, $Account, $addr)
    Write-Host ''
    Write-Host '  Then connect the SQL client to 127.0.0.1 port 3307, with the database' -ForegroundColor Gray
    Write-Host '  username and password from New-DbDevUser.ps1.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Or let the client do it: HeidiSQL and DBeaver both have an SSH tunnel tab' -ForegroundColor Gray
    Write-Host ("  - SSH host {0}, user {1}, their private key; MySQL host 127.0.0.1 port {2}." -f $addr, $Account, $DbPort) -ForegroundColor Gray
    Write-Host ''
}

# ---------------------------------------------------------------------------

try {
    Assert-Admin

    # ---- List ------------------------------------------------------------
    if ($List) {
        $accts = Get-TunnelAccounts
        Write-Host ''
        Write-Host "  Tunnel accounts (group $TunnelGroup)" -ForegroundColor Cyan
        Write-Host '  ------------------------------------' -ForegroundColor Cyan
        if ($accts.Count -eq 0) {
            Write-Host '  none' -ForegroundColor Gray
        } else {
            foreach ($a in $accts) {
                $state  = if ($a.HasKey) { 'key installed' } else { 'NO KEY - cannot log in' }
                $colour = if ($a.HasKey) { 'Gray' } else { 'Yellow' }
                Write-Host ('  {0,-22} {1}' -f $a.Name, $state) -ForegroundColor $colour
            }
        }
        Write-Host ''
        exit 0
    }

    # ---- Remove ----------------------------------------------------------
    if ($RemoveAccess) {
        $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
        $key  = Join-Path $script:KeyStore $Name
        if (-not $user -and -not (Test-Path $key)) { Write-Bad "No OS account or key for '$Name'."; exit 1 }
        if (-not $PSCmdlet.ShouldProcess("OS account '$Name'", 'Remove account and key')) { exit 0 }

        if (Test-Path $key) { Remove-Item $key -Force; Write-Ok "Removed key for '$Name'." }
        if ($user) { Remove-LocalUser -Name $Name; Write-Ok "Removed OS account '$Name'." }
        Write-Host '  Their database account is separate:  .\New-DbDevUser.ps1 -Name ' -NoNewline -ForegroundColor Gray
        Write-Host "$Name -Remove" -ForegroundColor Gray
        Write-Host ''
        exit 0
    }

    # ---- Create ----------------------------------------------------------
    $keyText = Get-PublicKeyText
    if (-not $keyText) {
        Write-Bad 'Supply the developer public key with -PublicKeyPath or -PublicKey.'
        Write-Host ''
        Write-Host '  They generate one on their machine with:' -ForegroundColor Gray
        Write-Host '     ssh-keygen -t ed25519 -C "alice-nms"'
        Write-Host '  and send you the .pub file only - never the private key.' -ForegroundColor Gray
        Write-Host ''
        exit 1
    }

    if (-not $PSCmdlet.ShouldProcess("OS account '$Name'", 'Create tunnel account and install key')) { exit 0 }

    Install-SshServer
    Set-KeyStoreLayout

    if (-not (Get-LocalGroup -Name $TunnelGroup -ErrorAction SilentlyContinue)) {
        $null = New-LocalGroup -Name $TunnelGroup -Description 'Database tunnel access only'
        Write-Ok "Created local group $TunnelGroup."
    }

    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($user) {
        Write-Warn "OS account '$Name' already exists - reusing it and replacing the key."
    } else {
        $pw = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        $null = New-LocalUser -Name $Name -Password $pw -PasswordNeverExpires -AccountNeverExpires `
                              -Description 'NMS database tunnel access' -UserMayNotChangePassword
        Write-Ok "Created OS account '$Name' (random password, never displayed - key auth only)."
    }

    foreach ($g in @('Users', $TunnelGroup)) {
        $already = @(Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue |
            Where-Object { ("$($_.Name)" -split '\\')[-1] -eq $Name })
        if ($already.Count -eq 0) { Add-LocalGroupMember -Group $g -Member $Name }
    }
    Write-Ok "'$Name' is in Users and $TunnelGroup (NOT Administrators)."

    $keyFile = Join-Path $script:KeyStore $Name
    [IO.File]::WriteAllText($keyFile, $keyText + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $null = & icacls.exe $keyFile /inheritance:r /grant 'SYSTEM:F' 'Administrators:F' 2>&1
    Write-Ok "Installed public key at $keyFile"

    $ruleName = 'NMS Dev SSH'
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        $params = @{
            DisplayName = $ruleName; Direction = 'Inbound'; Protocol = 'TCP'
            LocalPort   = 22;        Action    = 'Allow'
        }
        if ($AllowedFrom) { $params['RemoteAddress'] = $AllowedFrom }
        $null = New-NetFirewallRule @params
        Write-Ok ("Firewall: TCP 22 allowed from {0}." -f $(if ($AllowedFrom) { $AllowedFrom -join ', ' } else { 'any address' }))
    } elseif ($AllowedFrom) {
        Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress $AllowedFrom
        Write-Ok ("Firewall: TCP 22 scoped to {0}." -f ($AllowedFrom -join ', '))
    } else {
        Write-Ok 'Firewall: rule for TCP 22 already present.'
    }

    if ($HardenSsh) { Disable-SshPasswordAuth }

    Restart-Service sshd
    Write-Ok 'sshd restarted with the new configuration.'

    Write-Host ''
    Write-Step "Next:  .\New-DbDevUser.ps1 -Name $Name    (their database account)"
    Show-DevInstructions -Account $Name
    exit 0
}
catch {
    Write-Bad $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-Host ("  at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber,
                                            $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
    }
    Write-Host '  sshd logs:  Get-Content $env:ProgramData\ssh\logs\sshd.log -Tail 40' -ForegroundColor Gray
    exit 1
}
