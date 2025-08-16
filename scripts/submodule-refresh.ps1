# switch-submodules.ps1
# Run from the superproject root. Requires Git in PATH.
param(
  [string]$DefaultBranch = "main"
)

Write-Host "Deinitializing, syncing, and updating submodules..." -ForegroundColor Cyan
& git submodule deinit -f --all
& git submodule sync --recursive
& git submodule update --init --recursive --progress

function Set-SubmoduleBranches {
  param([string]$RepoRoot)

  $gitmodules = Join-Path $RepoRoot ".gitmodules"
  if (-not (Test-Path $gitmodules)) { return }

  # Example line from git config:
  # submodule.libs/foo.path libs/foo
  $lines = & git -C $RepoRoot config -f .gitmodules --get-regexp "submodule\..*\.path" 2>$null
  if (-not $lines) { return }

  foreach ($line in $lines) {
    if ($line -match 'submodule\.([^.]+)\.path\s+(.*)$') {
      $name    = $matches[1]
      $relPath = $matches[2]

      $branch = (& git -C $RepoRoot config -f .gitmodules --get "submodule.$name.branch" 2>$null | Select-Object -First 1)
      if ([string]::IsNullOrWhiteSpace($branch)) { $branch = $DefaultBranch }

      $subPath = Join-Path $RepoRoot $relPath
      if (-not (Test-Path $subPath)) {
        Write-Warning "[$name] path not found: $subPath"
        continue
      }

      Write-Host "[$name] -> target branch '$branch' ($subPath)" -ForegroundColor Yellow
      & git -C $subPath fetch origin 2>$null | Out-Null

      # Try: create/reset branch tracking origin/<branch>, then fallback to existing local branch
      & git -C $subPath switch -C $branch --track "origin/$branch" 2>$null | Out-Null
      $code = $LASTEXITCODE
      if ($code -ne 0) {
        & git -C $subPath switch $branch 2>$null | Out-Null
        $code = $LASTEXITCODE
      }
      if ($code -ne 0) {
        Write-Warning "[$name] no branch '$branch' (remote or local). Leaving detached."
      } else {
        # Optional: show brief status
        & git -C $subPath status -sb
      }

      # Recurse into nested submodules defined by this submodule (if any)
      Set-SubmoduleBranches -RepoRoot $subPath
    }
  }
}

Write-Host "Switching submodules to their configured branches (or '$DefaultBranch')..." -ForegroundColor Cyan
Set-SubmoduleBranches -RepoRoot (Get-Location).Path

Write-Host "Done." -ForegroundColor Green
