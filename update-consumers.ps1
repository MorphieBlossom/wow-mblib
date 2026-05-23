# update-consumers.ps1
#
# Refresh MBLib in every sibling consumer addon under ../public/wow-* by
# invoking each consumer's own mblib-update.ps1. Lets you push a new MBLib
# release into the whole family in one command, from this repo.
#
# Each consumer's mblib-update.ps1 does the actual download+install (fetching
# the matching tagged release from GitHub). Consumers without mblib-update.ps1
# are skipped with a warning.
#
# Usage:
#   pwsh ./update-consumers.ps1                     # latest into each consumer
#   pwsh ./update-consumers.ps1 -Version 1.0.4      # pin to a specific version
#   pwsh ./update-consumers.ps1 -ConsumersRoot D:\path\to\public

[CmdletBinding()]
param(
  [string]$Version,
  [string]$ConsumersRoot = (Join-Path $PSScriptRoot "../../public")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConsumersRoot)) {
  throw "Consumers root not found: $ConsumersRoot"
}

$consumers = Get-ChildItem -Path $ConsumersRoot -Directory -Filter "wow-*"
if ($consumers.Count -eq 0) {
  Write-Warning "No wow-* consumer directories found under $ConsumersRoot"
  return
}

$updated = @()
$skipped = @()
$failed  = @()

foreach ($c in $consumers) {
  $script = Join-Path $c.FullName "mblib-update.ps1"
  if (-not (Test-Path $script)) {
    Write-Warning "$($c.Name): no mblib-update.ps1; skipping"
    $skipped += $c.Name
    continue
  }
  Write-Host ""
  Write-Host "=== $($c.Name) ===" -ForegroundColor Cyan
  Push-Location $c.FullName
  try {
    # Dot-call the consumer script in-process so this works under either
    # Windows PowerShell 5.1 (powershell.exe) or PowerShell Core (pwsh) —
    # we don't depend on `pwsh` being on PATH.
    if ($Version) {
      & $script -Version $Version
    } else {
      & $script
    }
    $updated += $c.Name
  } catch {
    Write-Warning "$($c.Name): $($_.Exception.Message)"
    $failed += $c.Name
  } finally {
    Pop-Location
  }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
if ($updated.Count -gt 0) { Write-Host "Updated: $($updated -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0) { Write-Host "Skipped: $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count  -gt 0) { Write-Host "Failed:  $($failed  -join ', ')" -ForegroundColor Red }
