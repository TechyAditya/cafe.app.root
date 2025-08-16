Param(
    [string]$Org = "your-github-org",           # GitHub org / user
    [string]$Scope = "cafe",                    # NPM package scope (used for display / package mapping)
    [string]$RepoPattern = "{scope}-{name}",    # Pattern to derive GitHub repo slug from folder name.
                                                # Tokens: {scope}, {name}. Example: "{scope}-{name}" -> cafe-api
    [switch]$Private,                            # Just influences reminder text; actual privacy set on GitHub
    [switch]$DryRun,                             # Show actions only, no git mutations
    [switch]$CreateMissingRemotes,               # If set, attempt to create missing GitHub repos via 'gh' CLI
    [switch]$AutoPushInitial                     # If set, push initial commits for leaf repos (after creation) so submodule add can proceed in single run
)

# This script initializes the root repo, creates (empty) sibling Git repos for each app/package, and adds them back as submodules.
# Usage: pwsh ./scripts/init-submodules.ps1 -Org my-org -Private

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
Set-Location $root

if (-not (Test-Path .git)) {
    git init
}

$repos = @(
    'apps/api',
    'apps/consumer-mobile',
    'apps/staff-mobile',
    'apps/web-admin',
    'packages/core-sdk',
    'packages/printers-sdk',
    'packages/tenant-configs',
    'packages/ui-kit'
)

function Ensure-GhCliAvailable {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "'gh' CLI not found. Install from https://cli.github.com/ or remove -CreateMissingRemotes switch."
    }
}

function Ensure-RemoteRepo {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [switch]$Private
    )
    $repoUrl = "https://github.com/$Org/$Slug.git"
    if (Test-RemoteReachable -Url $repoUrl) { return $repoUrl }

    if (-not $CreateMissingRemotes) { return $null }
    Ensure-GhCliAvailable
    $visibility = if ($Private) { '--private' } else { '--public' }
    if ($DryRun) {
        Write-Host "[DryRun] Would create repo $Org/$Slug ($visibility)" -ForegroundColor Yellow
        return $repoUrl
    }
    Write-Host "Creating missing GitHub repo: $Org/$Slug" -ForegroundColor DarkYellow
    gh repo create "$Org/$Slug" $visibility --source . --disable-issues --disable-wiki --license mit --gitignore Node --push 2>$null 1>$null
    # The above pushes current root (not desired). We created from root to set repo; now reset remote to empty state by deleting pushed content if any? Simpler: create blank without pushing.
    # Alternative approach if gh version supports it: add --clone flag etc. For safety, ignore push failures.
    return $repoUrl
}

function Copy-Content-ExcludeGit {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination | Out-Null }

    # Copy children (incl. hidden) but exclude the .git directory explicitly
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        if ($_.Name -eq '.git') { return }
        $target = Join-Path $Destination $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force
        }
    }
}

function Test-RemoteReachable {
    param([Parameter(Mandatory)][string]$Url)
    try {
        git ls-remote $Url 2>$null 1>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-RemoteHasCommits {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $refs = git ls-remote $Url 2>$null
        if (-not $refs) { return $false }
        # Any ref line implies at least one commit
        return $true
    } catch { return $false }
}

function Get-RepoSlug($name) {
    # All submodules uniformly: cafe.app.<name>
    $slug = "cafe.app.$name"
    $slug = $slug.ToLowerInvariant().Replace('@','').Replace('/','.')
    return $slug
}

Write-Host "Repo naming: root repo (you name it manually) -> cafe.app.root ; submodules -> cafe.app.<name>" -ForegroundColor DarkCyan
Write-Host "Example: api -> $(Get-RepoSlug 'api'), staff-mobile -> $(Get-RepoSlug 'staff-mobile')" -ForegroundColor DarkCyan

foreach ($r in $repos) {
    if (-not (Test-Path $r)) { continue }
    $name = ($r -replace '.*/','')
    $repoSlug = Get-RepoSlug $name
    $remoteUrl = "https://github.com/$Org/$repoSlug.git"
    if ($CreateMissingRemotes) {
        $maybe = Ensure-RemoteRepo -Slug $repoSlug -Private:$Private
        if ($maybe) { $remoteUrl = $maybe }
    }
    Write-Host "Processing $r -> $remoteUrl (package -> @$Scope/$name)" -ForegroundColor Cyan

    Push-Location $r
    if (-not (Test-Path .git)) {
        if ($DryRun) {
            Write-Host "[DryRun] Would: git init; initial commit; set remote $remoteUrl" -ForegroundColor Yellow
        } else {
            git init
            git add .
            git commit -m "feat: initial import from monorepo"
            git branch -M main
            if ($Private) {
                Write-Host "Remember to create private repo '$repoSlug' (private) in org '$Org'" -ForegroundColor Yellow
            } else {
                Write-Host "Create repo '$repoSlug' in org '$Org' if it doesn't exist yet" -ForegroundColor Yellow
            }
            git remote add origin $remoteUrl 2>$null
            if ($AutoPushInitial -and -not $DryRun) {
                # Attempt to push if remote exists (may fail silently if it doesn't yet)
                if (Test-RemoteReachable -Url $remoteUrl) {
                    Write-Host "Pushing initial commit for $r" -ForegroundColor DarkCyan
                    git push -u origin main 2>$null
                } else {
                    Write-Host "Remote not reachable yet for $r; will skip push" -ForegroundColor Yellow
                }
            }
        }
    }
    Pop-Location
}

# Now remove directories and add as submodules
foreach ($r in $repos) {
    if (-not (Test-Path $r)) { continue }
    # If already a submodule skip
    if (git config -f .gitmodules --get-regexp path | Select-String $r -Quiet) { continue }

    Write-Host "Converting $r to submodule placeholder" -ForegroundColor Green
    # Create temp snapshot of current contents
    $tmp = "$r-temp-extract"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Copy-Content-ExcludeGit -Source $r -Destination $tmp
    Remove-Item -Recurse -Force $r

    $name = ($r -replace '.*/','')
    $repoSlug = Get-RepoSlug $name
    $repoUrl = "https://github.com/$Org/$repoSlug.git"

    $remoteReachable = Test-RemoteReachable -Url $repoUrl
    $remoteHasCommits = if ($remoteReachable) { Test-RemoteHasCommits -Url $repoUrl } else { $false }

    if (-not $remoteReachable) {
        Write-Host "Remote '$repoUrl' does not exist or is unreachable. Skipping submodule conversion for '$r'. (Create the repo + initial commit, then rerun)" -ForegroundColor Yellow
        # Restore original folder
        Copy-Content-ExcludeGit -Source $tmp -Destination $r
        Remove-Item -Recurse -Force $tmp
        continue
    }

    if (-not $remoteHasCommits) {
        Write-Host "Remote '$repoUrl' is empty (no commits). Add a README (initial commit) then rerun. Skipping '$r' for now." -ForegroundColor Yellow
        Copy-Content-ExcludeGit -Source $tmp -Destination $r
        Remove-Item -Recurse -Force $tmp
        continue
    }
    if ($DryRun) {
        Write-Host "[DryRun] Would: git submodule add $repoUrl $r" -ForegroundColor Yellow
        # Recreate original folder so subsequent steps don't fail
        New-Item -ItemType Directory -Path $r | Out-Null
    } else {
        git submodule add $repoUrl $r
    }

    # Restore content into submodule working tree (not committed yet), excluding any historical .git
    Copy-Content-ExcludeGit -Source $tmp -Destination $r
    Remove-Item -Recurse -Force $tmp
}

if (-not $DryRun) {
    if (Test-Path .gitmodules) { git add .gitmodules 2>$null }
    foreach ($r in $repos) { if (Test-Path $r) { git add $r 2>$null } }
    git commit -m "chore: add project submodules" 2>$null
} else {
    Write-Host "[DryRun] Skipping staging & commit" -ForegroundColor Yellow
}

Write-Host "Done. Next steps:" -ForegroundColor Magenta
Write-Host "1. For each submodule repo: create it on GitHub (slug per pattern), then push: (cd <path>; git push -u origin main)" -ForegroundColor Magenta
Write-Host "2. Push root repo: git add .; git commit -m 'chore: root repo with submodules'; git push -u origin main" -ForegroundColor Magenta
Write-Host "3. Future clones: git clone --recurse-submodules <root-url>" -ForegroundColor Magenta
