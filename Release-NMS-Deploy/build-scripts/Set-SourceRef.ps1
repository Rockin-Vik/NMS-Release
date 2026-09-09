<#
.SYNOPSIS
    Point <InstallRoot>\src at a pull request, a branch, a tag, a commit, or back at the
    default branch. Does not build anything.

.DESCRIPTION
    2-Setup-NMSServer.ps1 clones the repo and keeps it on the default branch. That is all it
    should ever do. This script is the separate step for "build that PR instead", so the
    setup path stays one thing and the ref-switching lives on its own.

    Three modes:

        -PullRequest N   fetch refs/pull/N/head, check it out as local branch pr/N
        -GitRef X        fetch branch, tag or commit X and check it out
        neither          return to the repo default branch and fast-forward it

    Every mode either lands on the requested source or stops with a non-zero exit. It never
    falls through to "whatever happened to be checked out": that produces a green build of
    the wrong source, which is silent until someone plays it.

    Nothing here writes outside the git checkout. Uncommitted local edits under
    <InstallRoot>\src are refused rather than discarded - pass -Force to overwrite them.

.PARAMETER InstallRoot
    Server install root, matching 2-Setup-NMSServer.ps1. The checkout is <InstallRoot>\src.

.PARAMETER PullRequest
    Pull request number to build. Fetched fresh on every run, so re-running the same number
    after new commits land on that PR picks them up.

.PARAMETER GitRef
    Branch, tag or commit to build. Mutually exclusive with -PullRequest. Use -PullRequest
    for pull requests; use this for a branch with no PR open yet, or to pin a known-good tag.

.PARAMETER Force
    Discard uncommitted changes in the checkout. Without it, a dirty tree stops the switch,
    because the usual reason for one is a hand-edit somebody still needs.

.EXAMPLE
    .\Set-SourceRef.ps1 -PullRequest 17
    Put the checkout on PR 17. Follow with Update-Server.ps1 -From Build to build it.

.EXAMPLE
    .\Set-SourceRef.ps1
    Return to the default branch after testing a PR.

.EXAMPLE
    .\Set-SourceRef.ps1 -GitRef v1.4.0

.NOTES
    Fetches are --depth 1, matching the shallow clone 2-Setup-NMSServer.ps1 makes. A ref that
    needs deeper history fails with the 'git fetch --unshallow' command to run.

    Read-only with respect to the server: it does not stop services, build, or touch the
    database. Run Update-Server.ps1 afterwards to actually roll the change out.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\NMS',

    [ValidateRange(1, 999999)]
    [int]    $PullRequest,

    [string] $GitRef,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pinning two different sources in one command is a typo. Catch it before touching git.
if ($PullRequest -and $GitRef) {
    throw '-PullRequest and -GitRef are mutually exclusive. Pass one or neither.'
}

$SrcRoot = Join-Path $InstallRoot 'src'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is not on PATH. Run 1-Install-Prerequisites.ps1, then open a new shell.'
}
if (-not (Test-Path (Join-Path $SrcRoot '.git'))) {
    throw "$SrcRoot is not a git checkout. Run 2-Setup-NMSServer.ps1 first - cloning is its job, not this script's."
}

function Write-Step { param([string] $Text) Write-Host "  -> $Text" -ForegroundColor Gray }
function Write-Ok   { param([string] $Text) Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }

function Invoke-Git {
    <#
        Runs git and returns its exit code, with the output in $script:GitOutput.

        $ErrorActionPreference = 'Stop' is actively wrong for native commands. PowerShell 5.1
        turns anything on stderr into an ErrorRecord and 'Stop' escalates it to terminating
        even when the command succeeded - and git narrates fetch progress on stderr on every
        run. PS 7.4+ does the same for any non-zero exit. Every exit code here is checked
        explicitly, so relax the preference for the duration of the call.
    #>
    param([Parameter(Mandatory)] [string[]] $Arguments, [switch] $Quiet)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $script:GitOutput = @(& git -C $SrcRoot @Arguments 2>&1)
        if (-not $Quiet) {
            $script:GitOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-GitLine {
    <#
        First line of git's stdout, with stderr dropped. Invoke-Git merges stderr via 2>&1 and
        PS 5.1 wraps those lines in ErrorRecords, so a plain "select the first line" can hand
        back a git warning instead of the value. These reads decide what gets reported as the
        source that was built, so they must not be able to report a warning as a branch name.
    #>
    $script:GitOutput |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        Select-Object -First 1
}

function Get-DefaultBranch {
    # Read from origin/HEAD, which a --depth 1 clone normally sets. Falls back to main, which
    # is what this repo uses; a wrong guess surfaces as a checkout failure, not as a silent
    # build of the wrong branch.
    if ((Invoke-Git -Quiet @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')) -eq 0) {
        $h = Get-GitLine
        if ($h) { return ($h -replace '^origin/', '') }
    }
    return 'main'
}

function Assert-CleanTree {
    if ($Force) { return }
    if ((Invoke-Git -Quiet @('status', '--porcelain')) -ne 0) {
        throw 'git status failed; refusing to switch refs on a checkout in an unknown state.'
    }
    $dirty = @($script:GitOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and "$_".Trim() })
    if ($dirty.Count) {
        $shown = ($dirty | Select-Object -First 10) -join [Environment]::NewLine
        throw @"
$SrcRoot has uncommitted changes, so switching refs would discard them:

$shown

Commit or stash them, or re-run with -Force to overwrite.
"@
    }
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host '  Set source ref' -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host "Checkout: $SrcRoot"

Assert-CleanTree

if ($PullRequest) {
    # Fetched into refs/nms/... rather than straight to refs/heads/pr/N, because git refuses
    # to fetch into the branch that is currently checked out - which is exactly the re-run
    # case, picking up new commits on a PR already being built. 'checkout -B' then resets the
    # branch in place instead of failing on "branch already exists".
    Write-Step "Fetching pull request $PullRequest ..."
    $code = Invoke-Git @('fetch', '--force', '--depth', '1', 'origin', "+refs/pull/$PullRequest/head:refs/nms/pr/$PullRequest")
    if ($code -ne 0) {
        throw @"
Could not fetch pull request $PullRequest from origin (git exit $code).

Check the number, and that the PR is against this repository:
  git -C "$SrcRoot" ls-remote origin "refs/pull/$PullRequest/head"

Nothing was checked out. The checkout has NOT fallen back to the default branch.
"@
    }
    $code = Invoke-Git @('checkout', '--force', '-B', "pr/$PullRequest", "refs/nms/pr/$PullRequest")
    if ($code -ne 0) { throw "Could not check out pull request $PullRequest (git exit $code)." }
    $label = "PR #$PullRequest"
}
elseif ($GitRef) {
    Write-Step "Fetching ref $GitRef ..."
    $code = Invoke-Git @('fetch', '--force', '--depth', '1', 'origin', "+${GitRef}:refs/nms/ref")
    if ($code -eq 0) {
        $target = 'refs/nms/ref'
    } else {
        # Not a branch or tag. Try it as a bare commit, which only works where the host allows
        # it (uploadpack.allowReachableSHA1InWant).
        Write-Step 'Not a branch or tag; trying it as a commit ...'
        $code = Invoke-Git @('fetch', '--force', '--depth', '1', 'origin', $GitRef)
        if ($code -ne 0) {
            throw @"
Could not fetch "$GitRef" from origin (git exit $code).

It is not a branch or tag on origin, and origin would not serve it as a commit. If it is a
commit older than this shallow clone, deepen the checkout first:
  git -C "$SrcRoot" fetch --unshallow

Nothing was checked out. The checkout has NOT fallen back to the default branch.
"@
        }
        $target = 'FETCH_HEAD'
    }
    $code = Invoke-Git @('checkout', '--force', '--detach', $target)
    if ($code -ne 0) { throw "Could not check out `"$GitRef`" (git exit $code)." }
    $label = "ref $GitRef"
}
else {
    # No pin. Return to the default branch, so a box cannot keep building a PR after someone
    # stops asking for one, and fast-forward it.
    $branch = ''
    if ((Invoke-Git -Quiet @('rev-parse', '--abbrev-ref', 'HEAD')) -eq 0) { $branch = Get-GitLine }
    $default = Get-DefaultBranch

    if ($branch -ne $default) {
        Write-Warn "Checkout is on '$branch'; returning to '$default'."
    } else {
        Write-Step "Updating '$default' ..."
    }
    $code = Invoke-Git @('fetch', '--force', '--depth', '1', 'origin', "+refs/heads/${default}:refs/nms/default")
    if ($code -ne 0) { throw "Could not fetch '$default' from origin (git exit $code)." }
    $code = Invoke-Git @('checkout', '--force', '-B', $default, 'refs/nms/default')
    if ($code -ne 0) { throw "Could not check out '$default' (git exit $code)." }
    $label = "branch $default"
}

$sha = 'unknown'
if ((Invoke-Git -Quiet @('rev-parse', '--short', 'HEAD')) -eq 0) { $sha = Get-GitLine }
$subject = ''
if ((Invoke-Git -Quiet @('log', '-1', '--format=%s')) -eq 0) { $subject = Get-GitLine }

# Stated plainly and last, because building the wrong source is the one failure this script
# exists to prevent and it leaves no other trace.
Write-Host ''
Write-Ok "Checkout is on $label at $sha"
if ($subject) { Write-Step "Head commit: $subject" }
Write-Host ''
Write-Host "Next:  .\Update-Server.ps1 -From Build" -ForegroundColor Cyan
Write-Host ''
