#Requires -Version 5.1
<#
  tools/build-release.ps1  -  package the downloadable release archive

  Produces  dist/codex-switch-<version>.zip  containing a single top-level folder
  (codex-switch-<version>/) so that extracting it can't scatter loose files into
  someone's Downloads folder. Every .cmd helper resolves codex-switch.ps1 through
  %~dp0, so the payload must stay flat inside that one folder.

  Usage:
    tools\build-release.ps1                 version taken from $ScriptVersion in codex-switch.ps1
    tools\build-release.ps1 -Version 1.2.3  explicit version; must match $ScriptVersion
    tools\build-release.ps1 -OutputDir out  write somewhere other than dist\

  NOTE: this file is intentionally pure ASCII. Two shipped files have Korean names
  (the start-here launcher and the Korean manual), and Windows PowerShell 5.1 decodes a
  BOM-less UTF-8 .ps1 as the legacy ANSI codepage - hardcoding those names here would
  corrupt them and break the build. They are picked up by pattern instead.

  Deliberately excluded from the archive:
    examples\   author's personal one-time migration, not for general use
    tools\      build tooling
    .github\    CI configuration
    .gitignore  repo-only
#>

[CmdletBinding()]
param(
  [string]$Version,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }

$mainScript = Join-Path $repoRoot 'codex-switch.ps1'
if (-not (Test-Path $mainScript)) { throw "codex-switch.ps1 not found at $mainScript." }

# $ScriptVersion in codex-switch.ps1 is the single source of truth for the version.
$match = Select-String -Path $mainScript -Pattern '^\s*\$ScriptVersion\s*=\s*''([^'']+)''' |
  Select-Object -First 1
if (-not $match) { throw "Could not find `$ScriptVersion in $mainScript." }
$declared = $match.Matches[0].Groups[1].Value

if ($Version) {
  # Accept a raw git tag like "v1.0.0" so CI can pass the tag name straight through.
  $Version = $Version -replace '^[vV]', ''
  if ($Version -ne $declared) {
    throw ("Version mismatch: requested '$Version' but codex-switch.ps1 declares '$declared'. " +
           "Update `$ScriptVersion (and CHANGELOG.md) so the tag and the script agree, then rebuild.")
  }
} else {
  $Version = $declared
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$') {
  throw "Version '$Version' is not valid semver (expected e.g. 1.0.0)."
}

# Everything a user needs lives in the repo root: the script, the .cmd helpers (including the
# Korean start-here launcher), the docs (including the Korean manual), and the licence.
$rootFiles = @(Get-ChildItem -LiteralPath $repoRoot -File | Where-Object {
  $_.Extension -in @('.cmd', '.md', '.ps1') -or $_.Name -eq 'LICENSE'
})

# Guards: a rename or a missing file must fail the build loudly, not ship a broken archive.
$required = @('codex-switch.ps1', '1-main.cmd', '2-work.cmd', 'list.cmd', 'menu.cmd', 'status.cmd',
              'stop.cmd', 'README.md', 'CHANGELOG.md', 'LICENSE')
$names    = @($rootFiles | ForEach-Object { $_.Name })
$missing  = @($required | Where-Object { $names -notcontains $_ })
if ($missing.Count) { throw "Missing release file(s): $($missing -join ', ')" }

# The two Korean-named files can't be listed literally (see NOTE above), so assert by shape:
# one extra .cmd beyond the six ASCII helpers, and one extra .md beyond README + CHANGELOG.
$nonAsciiCmd = @($rootFiles | Where-Object { $_.Extension -eq '.cmd' -and $_.Name -cmatch '[^\x00-\x7F]' })
$nonAsciiDoc = @($rootFiles | Where-Object { $_.Extension -eq '.md'  -and $_.Name -cmatch '[^\x00-\x7F]' })
if (-not $nonAsciiCmd.Count) { throw "The start-here launcher (Korean-named .cmd) is missing from $repoRoot." }
if (-not $nonAsciiDoc.Count) { throw "The Korean manual (Korean-named .md) is missing from $repoRoot." }

$name    = "codex-switch-$Version"
$zipPath = Join-Path $OutputDir "$name.zip"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Entries are added one at a time with an explicit "<name>/<file>" entry name instead of using
# ZipFile::CreateFromDirectory. CreateFromDirectory on .NET Framework builds entry names with
# Path.DirectorySeparatorChar, so on Windows it writes backslashes - which the ZIP spec does not
# allow. Explorer tolerates them, but strict extractors (macOS Archive Utility, most unzip
# implementations) then produce a single flat file literally named "codex-switch-x.y.z\run.cmd"
# instead of a folder. Naming the entries ourselves keeps the archive portable.
#
# entryNameEncoding is deliberately left at its default (null): that is what makes ZipArchive
# store a non-ASCII name as UTF-8 *and* set the general-purpose language-encoding (EFS) bit,
# which is how extractors know to decode it as UTF-8. Passing an explicit UTF8Encoding writes
# the same bytes but leaves that bit clear, so the Korean filenames would come out mangled.
Add-Type -AssemblyName System.IO.Compression          # ZipArchive, ZipArchiveMode
Add-Type -AssemblyName System.IO.Compression.FileSystem # ZipFileExtensions
$archive = $null
$stream  = $null
try {
  $stream  = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite)
  $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
  foreach ($file in ($rootFiles | Sort-Object Name)) {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $file.FullName,
      "$name/$($file.Name)",
      [System.IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
  }
} catch {
  if ($archive) { $archive.Dispose(); $archive = $null }
  if ($stream)  { $stream.Dispose();  $stream  = $null }
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
  throw
} finally {
  if ($archive) { $archive.Dispose() }
  if ($stream)  { $stream.Dispose() }
}

# Regression guards on the bytes we just wrote: no backslash separators anywhere, and the UTF-8
# flag set on every non-ASCII name. Both are silent-corruption failures if they ever regress.
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$checked  = 0
for ($i = 0; $i -lt $zipBytes.Length - 46; $i++) {
  if ($zipBytes[$i] -ne 0x50 -or $zipBytes[$i+1] -ne 0x4B -or $zipBytes[$i+2] -ne 0x01 -or $zipBytes[$i+3] -ne 0x02) { continue }
  $flags     = [BitConverter]::ToUInt16($zipBytes, $i + 8)
  $nameLen   = [BitConverter]::ToUInt16($zipBytes, $i + 28)
  $nameBytes = $zipBytes[($i + 46)..($i + 46 + $nameLen - 1)]
  $entryName = [System.Text.Encoding]::UTF8.GetString($nameBytes)
  if ($nameBytes -contains 0x5C) { throw "Archive entry '$entryName' uses a backslash separator." }
  if (($nameBytes | Where-Object { $_ -gt 0x7F }) -and -not ($flags -band 0x800)) {
    throw "Archive entry '$entryName' has a non-ASCII name but the UTF-8 flag is not set."
  }
  $checked++
}
if ($checked -ne $rootFiles.Count) {
  throw "Expected $($rootFiles.Count) central-directory entries in the archive but found $checked."
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath "$zipPath.sha256" -Encoding Ascii

$sizeKb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host ''
Write-Host "Built codex-switch $Version" -ForegroundColor Green
Write-Host "  archive : $zipPath  ($sizeKb KB)"
Write-Host "  sha256  : $hash"
Write-Host "  entries : $($rootFiles.Count) file(s) inside $name/"
foreach ($file in ($rootFiles | Sort-Object Name)) { Write-Host "            $($file.Name)" }
Write-Host ''
