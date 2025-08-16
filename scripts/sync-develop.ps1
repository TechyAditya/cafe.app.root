<#
Synopsis: Bulk create/switch/push a target branch (default: develop) in all git submodules, then create/update & push the same target branch in the root repo.

Usage examples (run from repo root):
    # Use defaults: target branch 'develop' branched from 'main'
    powershell -ExecutionPolicy Bypass -File .\scripts\sync-develop.ps1

    # Specify a feature branch sourced from main
    powershell -File .\scripts\sync-develop.ps1 -TargetBranch feature/inventory -SubmoduleBaseBranch main -RootBaseBranch main

    # Rebase target branch onto latest main everywhere & auto commit dirty submodules
    powershell -File .\scripts\sync-develop.ps1 -TargetBranch develop -Rebase -AutoCommitSubmoduleChanges -AutoCommitMessage "chore: refresh develop across modules"

    # Preview only
    powershell -File .\scripts\sync-develop.ps1 -TargetBranch release/1.2 -DryRun -Verbose

Params:
    -TargetBranch: The branch to create/update/push in submodules & root (default: develop)
    -SubmoduleBaseBranch: Source branch used when creating the target in submodules (default: main)
    -RootBaseBranch: Source branch used when creating the target in the root repo (default: main)
    -AutoCommitSubmoduleChanges: Auto stage/commit uncommitted changes inside each submodule before branch operations.
    -AutoCommitMessage: Commit message for auto commits (submodules + root if needed).
    -Rebase: Rebase target branch on top of its base branch (fetching latest) instead of merging.
    -SkipRootPush: Update submodules only; skip pushing the root target branch.
    -DryRun: Describe actions without performing mutating git commands.
    -Verbose: PowerShell built-in for extra logging.

Behavior:
    1. Initialize & sync submodules.
    2. For each submodule: fetch, create target branch from SubmoduleBaseBranch if missing, else update (rebase/merge), then push.
    3. Root repo: create/update same target branch from RootBaseBranch if missing, then stage submodule pointer updates & push (unless skipped).
    4. Supports dry-run preview.

Edge Cases handled:
    - Target branch absent locally & remotely
    - Detached HEAD states in submodules
    - Dirty working trees (optional auto commit or warning)
    - Missing remote base branch
    - Idempotent repeated runs

Requires: git available in PATH.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$SubmoduleBaseBranch = 'main',
    [string]$RootBaseBranch = 'main',
    [string]$TargetBranch = 'develop',
    [switch]$AutoCommitSubmoduleChanges,
    [string]$AutoCommitMessage = 'chore: sync develop branches',
    [switch]$Rebase,
    [switch]$SkipRootPush,
    [switch]$DryRun,
    [switch]$NoGitmodulesBranchUpdate
)

function Invoke-Git {
    param([string]$Arguments, [switch]$AllowFail)
    Write-Verbose "git $Arguments"
    if ($DryRun) { Write-Host "[DRYRUN] git $Arguments"; return }
    # TODO: enhance argument parsing for quoted segments if needed
    $argList = $Arguments -split ' '
    $global:LAST_GIT_OUTPUT = & git @argList 2>&1
    $exit = $LASTEXITCODE
    $global:LAST_GIT_EXIT = $exit
    foreach ($item in $global:LAST_GIT_OUTPUT) {
        $text = ($item | Out-String).TrimEnd()
        if ($text) { Write-Host $text }
    }
    if (-not $AllowFail -and $exit -ne 0) {
        $joined = (@($global:LAST_GIT_OUTPUT) | ForEach-Object { ($_ | Out-String).TrimEnd() }) -join "`n"
        throw "Git command failed ($exit): git $Arguments`n$joined"
    }
}

function Get-SubmodulePaths {
    if (-not (Test-Path .gitmodules)) { return @() }
    $lines = git config --file .gitmodules --get-regexp path 2>$null
    if (-not $lines) { return @() }
    return $lines | ForEach-Object { ($_ -split ' ')[1] }
}

function Ensure-BranchExists {
    param(
        [string]$Branch,
        [string]$BaseBranch,
        [switch]$IsRoot
    )
    # Detect local branch accurately
    git show-ref --verify --quiet "refs/heads/$Branch" 2>$null
    if ($LASTEXITCODE -eq 0) { return 'exists' }

    # Fetch base branch from origin (tolerate absence locally)
    Invoke-Git "fetch origin $BaseBranch" -AllowFail

    # Prefer creating from origin/BaseBranch if remote exists
    git ls-remote --exit-code origin $BaseBranch 2>$null 1>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git "checkout -b $Branch origin/$BaseBranch"
    }
    else {
        # Fallback: ensure local base exists
        if (-not (git rev-parse --verify $BaseBranch 2>$null)) { throw "Base branch $BaseBranch not found locally or on origin in repo $(Get-Location)" }
        Invoke-Git "checkout -b $Branch $BaseBranch"
    }
    return 'created'
}

function Update-TargetBranch {
    param(
        [string]$BaseBranch,
        [switch]$IsRoot
    )
    $branch = $TargetBranch
    $state = Ensure-BranchExists -Branch $branch -BaseBranch $BaseBranch -IsRoot:$IsRoot
    if ($state -eq 'exists') {
        Invoke-Git 'fetch --all --prune' -AllowFail
        if ($Rebase) { Invoke-Git "checkout $branch"; Invoke-Git "fetch origin $BaseBranch" -AllowFail; Invoke-Git "rebase origin/$BaseBranch" }
        else { Invoke-Git "checkout $branch"; Invoke-Git "fetch origin $BaseBranch" -AllowFail; Invoke-Git "merge --no-edit origin/$BaseBranch" -AllowFail }
    }
    else { Write-Host "Created $branch from $BaseBranch" }
    # set upstream if missing
    $up = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if (-not $up) { Invoke-Git "push -u origin $branch" } else { Invoke-Git "push origin $branch" -AllowFail }
}

function Commit-IfNeeded {
    param(
        [string]$Message
    )
    $status = git status --porcelain
    if ($status) {
        if ($AutoCommitSubmoduleChanges) {
            Invoke-Git 'add -A'
            Invoke-Git "commit -m `"$Message`"" -AllowFail
        }
        else {
            Write-Warning "Uncommitted changes present in $(Get-Location). Re-run with -AutoCommitSubmoduleChanges to auto commit."            
        }
    }
}

Write-Host "== sync-target: starting (TargetBranch=$TargetBranch, DryRun=$DryRun, Rebase=$Rebase) =="

# Optionally update .gitmodules branch mapping to TargetBranch
if (-not $NoGitmodulesBranchUpdate -and (Test-Path .gitmodules)) {
    try {
        $gmContent = Get-Content .gitmodules -Raw -ErrorAction Stop
        $updated = [regex]::Replace($gmContent, '(?ms)(\[submodule "[^"]+"\]\s+path\s*=\s*[^\n]+\n\s*url\s*=\s*[^\n]+)(?:\n\s*branch\s*=\s*[^\n]+)?', { param($m) "$($m.Groups[1].Value)`n`tbranch = $TargetBranch" })
        if ($updated -ne $gmContent) {
            if ($DryRun) { Write-Host "[DRYRUN] Would update .gitmodules branch entries to $TargetBranch" }
            else {
                Set-Content .gitmodules $updated -Encoding UTF8
                Write-Host ".gitmodules branch entries updated to '$TargetBranch'" -ForegroundColor Yellow
            }
        } else { Write-Verbose ".gitmodules already aligned to $TargetBranch" }
    } catch { Write-Warning "Failed updating .gitmodules: $($_.Exception.Message)" }
}

# 1. Ensure submodules are initialized
if (-not (Test-Path .git)) { throw 'Run this script from the root of the root repository.' }

Invoke-Git 'submodule sync --recursive'
Invoke-Git 'submodule update --init --recursive'

$submodules = Get-SubmodulePaths
if (-not $submodules) { Write-Host 'No submodules detected.' }
else { Write-Host "Found $($submodules.Count) submodules" }

foreach ($path in $submodules) {
    Write-Host "-- Processing submodule: $path" -ForegroundColor Cyan
    if (-not (Test-Path $path)) { Write-Warning "Missing path $path"; continue }
    Push-Location $path
    try {
        Invoke-Git 'fetch --all --prune' -AllowFail
        # handle detached HEAD
        $headRef = git symbolic-ref -q HEAD 2>$null
        if (-not $headRef) { Write-Host 'Detached HEAD detected; staying as-is until checkout.' }
        Commit-IfNeeded -Message $AutoCommitMessage
    Update-TargetBranch -BaseBranch $SubmoduleBaseBranch
    }
    finally { Pop-Location }
}

# 2. Root repository develop
Write-Host '-- Updating root repository develop' -ForegroundColor Cyan
Commit-IfNeeded -Message $AutoCommitMessage
Update-TargetBranch -BaseBranch $RootBaseBranch -IsRoot

# 3. Stage & commit submodule pointer updates
Write-Host '-- Committing submodule pointer updates in root' -ForegroundColor Cyan
Invoke-Git 'add .gitmodules' -AllowFail
$submodules | ForEach-Object { Invoke-Git "add $_" -AllowFail }
Invoke-Git 'add -u' -AllowFail
$rootStatus = git status --porcelain
if ($rootStatus) {
    Invoke-Git "commit -m `"$AutoCommitMessage (root)`"" -AllowFail
}
else { Write-Host 'No root changes to commit.' }

if (-not $SkipRootPush) { Invoke-Git "push origin $TargetBranch" -AllowFail }
else { Write-Host 'SkipRootPush set; not pushing root.' }

# Ensure root branch tracks origin/TargetBranch
try {
    $currentRootBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($currentRootBranch -eq $TargetBranch) {
        $currentUpstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
        if (-not $currentUpstream -or $currentUpstream -ne "origin/$TargetBranch") {
            Write-Host "Setting upstream of $TargetBranch to origin/$TargetBranch" -ForegroundColor Yellow
            Invoke-Git "branch -u origin/$TargetBranch $TargetBranch" -AllowFail
        }
    }
} catch { Write-Warning "Failed to set upstream tracking: $($_.Exception.Message)" }

Write-Host '== sync-target: complete ==' -ForegroundColor Green

if ($DryRun) { Write-Host 'Dry run mode: no changes were pushed.' -ForegroundColor Yellow }
