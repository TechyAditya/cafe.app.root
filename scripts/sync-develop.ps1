<#
Synopsis: Bulk create/switch/push develop branches in all git submodules, then push root develop.

Usage examples (run from repo root):
  powershell -ExecutionPolicy Bypass -File .\scripts\sync-develop.ps1
  powershell -File .\scripts\sync-develop.ps1 -SubmoduleBaseBranch main -RootBaseBranch main -Rebase -AutoCommitSubmoduleChanges -AutoCommitMessage "feat: bootstrap develop branches"
  powershell -File .\scripts\sync-develop.ps1 -DryRun

Params:
  -SubmoduleBaseBranch: Branch to branch from when creating submodule develop (default: main)
  -RootBaseBranch: Branch to branch from when creating root develop (default: main)
  -AutoCommitSubmoduleChanges: If set, stages & commits uncommitted changes inside each submodule before switching branches.
  -AutoCommitMessage: Commit message used for submodules (and root) when auto committing.
  -Rebase: If set, rebases develop on top of base branch instead of merging (if develop already exists).
  -SkipRootPush: If set, does not push the root develop branch (only submodules).
  -DryRun: Show what would happen without executing mutating git commands.
  -Verbose: Built-in PowerShell switch for additional logs.

Behavior:
  1. Ensures submodules are initialized & updated.
  2. For each submodule: fetch, create develop if missing (from SubmoduleBaseBranch), optionally rebase/merge, push develop.
  3. Creates root develop if missing (from RootBaseBranch), stages updated submodule SHAs & .gitmodules, commits & pushes.
  4. Honors -DryRun to preview actions.

Edge Cases handled:
  - Missing submodule develop branch
  - Uncommitted changes (optional auto commit)
  - Detached HEAD state
  - Upstream not set
  - Idempotent re-runs

Requires: git available in PATH.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$SubmoduleBaseBranch = 'main',
    [string]$RootBaseBranch = 'main',
    [switch]$AutoCommitSubmoduleChanges,
    [string]$AutoCommitMessage = 'chore: sync develop branches',
    [switch]$Rebase,
    [switch]$SkipRootPush,
    [switch]$DryRun
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

function Update-Develop {
    param(
        [string]$BaseBranch,
        [switch]$IsRoot
    )
    $target = 'develop'
    $state = Ensure-BranchExists -Branch $target -BaseBranch $BaseBranch -IsRoot:$IsRoot
    if ($state -eq 'exists') {
        Invoke-Git 'fetch --all --prune' -AllowFail
        if ($Rebase) { Invoke-Git "checkout $target"; Invoke-Git "fetch origin $BaseBranch" -AllowFail; Invoke-Git "rebase origin/$BaseBranch" }
        else { Invoke-Git "checkout $target"; Invoke-Git "fetch origin $BaseBranch" -AllowFail; Invoke-Git "merge --no-edit origin/$BaseBranch" -AllowFail }
    }
    else { Write-Host "Created $target from $BaseBranch" }
    # set upstream if missing
    $up = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if (-not $up) { Invoke-Git "push -u origin $target" } else { Invoke-Git "push origin $target" -AllowFail }
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

Write-Host "== sync-develop: starting (DryRun=$DryRun, Rebase=$Rebase) =="

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
        Update-Develop -BaseBranch $SubmoduleBaseBranch
    }
    finally { Pop-Location }
}

# 2. Root repository develop
Write-Host '-- Updating root repository develop' -ForegroundColor Cyan
Commit-IfNeeded -Message $AutoCommitMessage
Update-Develop -BaseBranch $RootBaseBranch -IsRoot

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

if (-not $SkipRootPush) { Invoke-Git 'push origin develop' -AllowFail }
else { Write-Host 'SkipRootPush set; not pushing root.' }

Write-Host '== sync-develop: complete ==' -ForegroundColor Green

if ($DryRun) { Write-Host 'Dry run mode: no changes were pushed.' -ForegroundColor Yellow }
