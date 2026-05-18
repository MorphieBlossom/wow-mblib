[CmdletBinding()]
param(
  # Optional. Path to a consumer addon's source root (e.g. ../../public/wow-hovername/src). When provided,
  # the built library is also copied into <SyncTo>/Libraries/MBLib for local dev iteration.
  [string]$SyncTo
)

# --- Settings ---
$srcDir      = "./src"
$buildDir    = "./build"
$projectName = "MBLib"
$commonDocs  = @("./LICENSE", "./README.md")
$tocPath     = Join-Path $srcDir "$projectName.toc"

# --- Prep ---
if (!(Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }
if (!(Test-Path $tocPath))  { Write-Error "TOC not found: $tocPath"; exit 1 }

# Read version from the TOC
$versionPattern = '^\s*##\s*Version\s*:\s*(.+)$'
$version = (Select-String -Path $tocPath -Pattern $versionPattern -AllMatches |
            Select-Object -First 1 -ExpandProperty Matches |
            ForEach-Object { $_.Groups[1].Value.Trim() })
if ([string]::IsNullOrWhiteSpace($version)) { $version = "0.0.0" }

# --- Stage ---
$tempDir  = Join-Path $buildDir ("Temp_" + $projectName)
$addonDir = Join-Path $tempDir $projectName

if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $addonDir | Out-Null

try {
  Copy-Item -Path (Join-Path $srcDir "*") -Destination $addonDir -Recurse

  foreach ($doc in $commonDocs) {
    if (Test-Path $doc) { Copy-Item -Path $doc -Destination $addonDir -Force }
  }

  # --- Sync to a consumer's source tree (optional dev workflow) ---
  if ($SyncTo) {
    if (!(Test-Path $SyncTo)) {
      Write-Warning "SyncTo path does not exist: $SyncTo"
    } else {
      $consumerLibs = Join-Path $SyncTo "Libraries"
      $consumerMBLib = Join-Path $consumerLibs $projectName
      if (Test-Path $consumerMBLib) { Remove-Item $consumerMBLib -Recurse -Force }
      if (!(Test-Path $consumerLibs)) { New-Item -ItemType Directory -Path $consumerLibs | Out-Null }
      Copy-Item -Path $addonDir -Destination $consumerLibs -Recurse
      Write-Host "Synced $projectName v$version into $consumerMBLib" -ForegroundColor Green
    }
  }

  # --- Package ---
  $zipName = "$projectName-v$version.zip"
  $zipPath = Join-Path $buildDir $zipName
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

  Compress-Archive -Path (Join-Path $tempDir "*") -DestinationPath $zipPath -Force

  Write-Host ""
  Write-Host "Output:" -ForegroundColor Cyan
  Write-Host " - $zipName"
}
finally {
  if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
}
