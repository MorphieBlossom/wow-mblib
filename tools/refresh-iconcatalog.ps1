# Refreshes src/OptModules/Icons/IconCatalog.lua in one pass:
#
#   1. Downloads parts/interface.csv from wowdev/wow-listfile and parses
#      the Interface/Icons/*.blp entries into a FileDataID -> name map.
#   2. Reads MBLib's debug dump out of a consumer addon's SavedVariables
#      (default: Meower's SV) -- specifically the ids list dumped by the
#      icon picker the last time it ran with debug mode on.
#   3. Writes IconCatalog.lua containing ONLY the entries whose ID is in
#      the dump (the picker's actually-visible subset), keyed by name
#      where the listfile knows it. If no dump is found the full icon
#      set is written instead -- useful for a first-time build before
#      any consumer addon has produced a dump.
#
# Run after each WoW patch to pick up new icons. The dump is always
# refreshed automatically on next login (the picker's PLAYER_LOGIN
# handler triggers when WoW's version changes), so the typical workflow
# is just: /reload after the popup, then run this script.
#
# Usage:
#   pwsh ./tools/refresh-iconcatalog.ps1
#   pwsh ./tools/refresh-iconcatalog.ps1 -SavedVarsPath "C:\Path\To\Meower.lua"

[CmdletBinding()]
param(
  # Mirror URL for the listfile partition. The community wow-listfile
  # repo splits the full file listing into category-scoped parts; we
  # only want interface because that's where Interface/Icons/*.blp lives.
  [string]$Source = "https://raw.githubusercontent.com/wowdev/wow-listfile/master/parts/interface.csv",

  # Path to the SavedVariables Lua file holding MBLib's icon dump.
  # Defaults to Meower's standard location under the retail client.
  # Pass explicitly when refreshing from another consumer's dump.
  [string]$SavedVarsPath,

  # Output path for the regenerated catalog. Defaults to the canonical
  # MBLib source location -- running from MBLib's repo root just works.
  [string]$OutPath = "src/OptModules/Icons/IconCatalog.lua",

  # When -ForceFull is set, the dump is ignored and the full ~32K-entry
  # interface listing is written. Useful for sanity checking what the
  # listfile contains relative to the current dump.
  [switch]$ForceFull
)

$ErrorActionPreference = "Stop"

# Resolve paths relative to the repo root (one level up from tools/).
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
  $OutPath = Join-Path $repoRoot $OutPath
}

# ===== Step 1: download + parse the listfile =====

Write-Host "Downloading $Source ..."
$tmp = New-TemporaryFile
try {
  # Force TLS 1.2 (Windows PS 5.1 default is too low for GitHub) and
  # use WebClient -- Invoke-WebRequest aborts mid-stream on the larger
  # listfile responses.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $client = New-Object System.Net.WebClient
  $client.Headers["User-Agent"] = "MBLib-refresh-iconcatalog"
  try {
    $client.DownloadFile($Source, $tmp)
  } finally {
    $client.Dispose()
  }

  $sizeMB = [math]::Round((Get-Item $tmp).Length / 1MB, 2)
  Write-Host ("Downloaded {0} MB. Parsing..." -f $sizeMB)

  # Stream-parse line by line (~10 MB raw, comfortably small but
  # ReadLines is the idiomatic choice). Each line is
  # "FileDataID;FilePath"; we keep only paths under interface/icons/.
  $idToName = New-Object 'System.Collections.Generic.Dictionary[int,string]'
  $pattern  = '^interface/icons/(.+)\.blp$'
  foreach ($line in [System.IO.File]::ReadLines($tmp)) {
    $sep = $line.IndexOf(';')
    if ($sep -lt 1) { continue }
    $idStr = $line.Substring(0, $sep)
    $path  = $line.Substring($sep + 1).ToLowerInvariant()
    if ($path -match $pattern) {
      $idInt = 0
      if ([int]::TryParse($idStr, [ref]$idInt)) {
        $idToName[$idInt] = $matches[1]
      }
    }
  }
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host ("Listfile has {0} icon entries." -f $idToName.Count)

# ===== Step 2: read the dump (when present) and decide what to write =====

$keepSet = $null   # nil -> "no dump, write full listfile"

if (-not $ForceFull) {
  # Auto-locate the SavedVariables file if the caller didn't pass one.
  if (-not $SavedVarsPath) {
    $wowRoot     = Join-Path ${env:PROGRAMFILES(X86)} "World of Warcraft"
    $accountsDir = Join-Path $wowRoot "_retail_\WTF\Account"
    if (Test-Path $accountsDir) {
      $candidates = Get-ChildItem -Path $accountsDir -Filter "Meower.lua" -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
      if ($candidates) {
        $SavedVarsPath = $candidates[0].FullName
        Write-Host "Auto-located SV: $SavedVarsPath"
      }
    }
  }

  if ($SavedVarsPath -and (Test-Path $SavedVarsPath)) {
    Write-Host "Reading dump from $SavedVarsPath ..."
    $sv = Get-Content -Raw -Path $SavedVarsPath

    # Walk a chain of nested ["key"] = { ... } blocks tracking braces
    # to handle nested tables. Regex alone can't match balanced groups.
    function Get-LuaTableField {
      param([string]$Source, [string[]]$Keys)
      $body = $Source
      foreach ($key in $Keys) {
        $p = '(?ms)\["' + [regex]::Escape($key) + '"\]\s*=\s*\{'
        $m = [regex]::Match($body, $p)
        if (-not $m.Success) { return $null }
        $start = $m.Index + $m.Length
        $depth = 1
        $end   = -1
        for ($i = $start; $i -lt $body.Length; $i++) {
          $ch = $body[$i]
          if     ($ch -eq '{') { $depth++ }
          elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
        }
        if ($end -lt 0) { return $null }
        $body = $body.Substring($start, $end - $start)
      }
      return $body
    }

    # MBLib stores the dump at _MBLib.iconDump, namespaced inside the
    # consumer's SavedVariables. Older Meower builds wrote a flat
    # DebugIconCatalog table at the top level -- we tolerate that as a
    # fallback during migration.
    $idsBody = Get-LuaTableField -Source $sv -Keys @("_MBLib", "iconDump", "ids")
    if (-not $idsBody) {
      $idsBody = Get-LuaTableField -Source $sv -Keys @("DebugIconCatalog", "ids")
    }
    if (-not $idsBody) {
      # Very-old format: a flat array under DebugIconCatalog.
      $idsBody = Get-LuaTableField -Source $sv -Keys @("DebugIconCatalog")
    }

    if ($idsBody) {
      $keepSet = New-Object 'System.Collections.Generic.HashSet[int]'
      foreach ($m in [regex]::Matches($idsBody, '\d+')) {
        [void]$keepSet.Add([int]$m.Value)
      }
      if ($keepSet.Count -eq 0) { $keepSet = $null }
    }

    # Surface the 'missing' list for visibility -- these are IDs the
    # picker saw but our previous catalog had no name for. If the
    # listfile we just downloaded now has them, the next dump cycle
    # will report 0 missing.
    $missingBody = Get-LuaTableField -Source $sv -Keys @("_MBLib", "iconDump", "missing")
    if ($missingBody) {
      $missingCount = ([regex]::Matches($missingBody, '\d+')).Count
      if ($missingCount -gt 0) {
        Write-Host ("Dump notes {0} FileDataIDs the previous catalog was missing -- they'll be picked up from the fresh listfile in this run." -f $missingCount) -ForegroundColor Yellow
      }
    }
  }
}

if (-not $keepSet) {
  Write-Host "No dump found -- writing the full listfile-derived catalog (no prune)."
} else {
  Write-Host ("Pruning to {0} FileDataIDs from the dump." -f $keepSet.Count)
}

# ===== Step 3: build and write IconCatalog.lua =====

# Decide which entries to write. When pruning, iterate the dump's ids
# so we always include them even if the listfile lacks a name (catalog
# stores an empty string in that case -- the IconPicker handles missing
# names gracefully).
$entries = New-Object System.Collections.Generic.List[object]
$missingAfter = 0
if ($keepSet) {
  foreach ($id in $keepSet) {
    $name = ""
    if ($idToName.ContainsKey($id)) {
      $name = $idToName[$id]
    } else {
      $missingAfter++
    }
    $entries.Add([pscustomobject]@{ Id = $id; Name = $name })
  }
} else {
  foreach ($kv in $idToName.GetEnumerator()) {
    $entries.Add([pscustomobject]@{ Id = $kv.Key; Name = $kv.Value })
  }
}

# Stable sort by name (then id) so successive regenerations produce
# minimal diffs. Empty names sort to the front; that's fine for diffs.
$sorted = $entries | Sort-Object Name, Id

Write-Host "Writing $OutPath ..."
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("-- AUTO-GENERATED by tools/refresh-iconcatalog.ps1.")
[void]$sb.AppendLine("-- Do not edit by hand. Regenerate to pick up new icons after a patch.")
[void]$sb.AppendLine("-- Source: wowdev/wow-listfile (community-maintained).")
[void]$sb.AppendLine("local _, addon = ...")
[void]$sb.AppendLine("addon.MBLib = addon.MBLib or {}")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- Flat array of { FileDataID, lowercased icon name } pairs. The picker")
[void]$sb.AppendLine("-- iterates linearly for substring search; sorted by name for stable diffs.")
[void]$sb.AppendLine("addon.MBLib.IconCatalog = {")
foreach ($e in $sorted) {
  # Names are mostly ASCII / underscore-safe but the listfile occasionally
  # surfaces braces and other oddities -- escape backslash + quote.
  $name = $e.Name -replace '\\', '\\\\' -replace '"', '\"'
  [void]$sb.AppendLine('  { ' + $e.Id + ', "' + $name + '" },')
}
[void]$sb.AppendLine("}")

[System.IO.File]::WriteAllText($OutPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
$outSize = [math]::Round((Get-Item $OutPath).Length / 1KB, 1)
Write-Host ("Wrote {0} entries to {1} ({2} KB)." -f $sorted.Count, $OutPath, $outSize) -ForegroundColor Green

if ($missingAfter -gt 0) {
  Write-Warning ("{0} FileDataIDs from the dump are still missing names in the listfile partition. They may belong to a category we don't pull from (parts/spells.csv, parts/item.csv, etc.) -- extend the script if these matter." -f $missingAfter)
}

Write-Host "Next: commit the regenerated file + re-vendor into consumer addons via mblib-update.ps1."
