$ErrorActionPreference = 'Stop'
$root = 'D:\Projects\send\entry\src\main\ets'
$base = (Resolve-Path $root).Path
$files = Get-ChildItem -LiteralPath $base -Recurse -Filter '*.ets' -File
$changed = 0
$skipped = 0
foreach ($f in $files) {
  if ($f.Name -eq 'LogCapture.ets') { continue }
  $rel = $f.FullName.Substring($base.Length + 1)
  $dir = Split-Path -Path $rel -Parent
  if ($dir -eq '.') { $dir = '' }
  $content = [System.IO.File]::ReadAllText($f.FullName)
  $orig = $content
  $new = $content.Replace('console.info(', 'Lg.i(')
  $new = $new.Replace('console.warn(', 'Lg.w(')
  $new = $new.Replace('console.error(', 'Lg.e(')
  $new = $new.Replace('console.debug(', 'Lg.d(')
  if ($new -eq $orig) { $skipped++; continue }
  if ($new -match 'common/LogCapture') {
    # import already present (e.g. EntryAbility) — nothing to add
  } else {
    $depth = 0
    if ($dir -ne '') { $depth = ($dir -split '[\\/]').Count }
    if ($depth -eq 0) { $relpath = './common/LogCapture' }
    else { $relpath = ('../' * $depth) + 'common/LogCapture' }
    $importLine = "import { LogCapture as Lg } from '$relpath';"
    if ($content.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }
    $new = $importLine + $nl + $new
  }
  [System.IO.File]::WriteAllText($f.FullName, $new)
  $changed++
}
Write-Output "changed=$changed skippedNoConsole=$skipped"
