#Requires -Version 5.1
<#
  tools/test-stop.ps1  -  self-check for the fallback order in Stop-Codex (codex-switch.ps1)

  Stop-Codex ends the desktop app through the package terminate call and must never reach a
  one-by-one kill of package processes without going through the re-registration first: killing
  them one at a time races the MSIX container teardown and can leave Codex unable to start. This
  drives every way the package route can end - it works, it fails at once, it reports success but a
  process survives, it fails on the retry - and checks the order of what happens.

  Only Stop-Codex is lifted out of the script (by AST, so the real source is what runs). Process
  detection, the package call and the re-registration are replaced by stand-ins, and a throwaway
  ping.exe plays the package process. No Codex process is touched.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-stop.ps1
#>
param([string]$Script = (Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-switch.ps1'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
$src = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                       $n.Name -eq 'Stop-Codex' }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
if ($src -notmatch 'function Stop-Codex') { throw "could not lift Stop-Codex out of $Script" }
Invoke-Expression $src

function Fail([string]$m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# Stand-ins. Every call is logged in order, so a test can check what came before what.
function Get-CodexProcesses { @(Get-CimInstance Win32_Process -Filter "ProcessId=$($script:dummy.Id)") }
function Test-InCodexPackage($proc) { $true }
function Stop-CodexPackageProcesses {
  $script:log.Add('package')
  $r = $script:packageResults[[Math]::Min($script:packageCalls, $script:packageResults.Count - 1)]
  $script:packageCalls++
  if ($r -eq 'kills') { Microsoft.PowerShell.Management\Stop-Process -Id $script:dummy.Id -Force; return $true }
  return ($r -eq 'ok')        # 'ok' = reports success but ends nothing; 'fails' = returns $false
}
function Invoke-CodexPackageShutdown { $script:log.Add('register'); return $true }
function Stop-Process { param([int]$Id, [switch]$Force, $ErrorAction)
  if ($Id -eq $script:dummy.Id) { $script:log.Add('kill') }
  Microsoft.PowerShell.Management\Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Invoke-Case([string]$name, [string[]]$packageResults, [string]$expected) {
  $script:dummy = Start-Process ping -ArgumentList '-t', '127.0.0.1' -PassThru -WindowStyle Hidden
  $script:log = New-Object 'System.Collections.Generic.List[string]'
  $script:packageResults = $packageResults; $script:packageCalls = 0
  try {
    $n = Stop-Codex 6>$null
    $got = $script:log -join ' > '
    if ($got -ne $expected) { Fail "${name}: expected [$expected], got [$got]" }
    if ($n -ne 1) { Fail "${name}: Stop-Codex returned $n, expected 1" }
    if (Get-Process -Id $script:dummy.Id -ErrorAction SilentlyContinue) { Fail "${name}: the process is still running" }
    Write-Host "ok  $name  [$got]"
  } finally {
    Microsoft.PowerShell.Management\Stop-Process -Id $script:dummy.Id -Force -ErrorAction SilentlyContinue
  }
}

Invoke-Case 'package call ends it'                    @('kills')         'package'
Invoke-Case 'package call fails at once'              @('fails')         'package > register > kill'
Invoke-Case 'reports success, process survives twice' @('ok')            'package > package > register > kill'
Invoke-Case 'first call ok, retry fails'              @('ok', 'fails')   'package > package > register > kill'

Write-Host 'all checks passed' -ForegroundColor Green
