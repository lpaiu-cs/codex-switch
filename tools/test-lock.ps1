#Requires -Version 5.1
<#
  tools/test-lock.ps1  -  self-check for the cross-process lock in codex-switch.ps1

  The lock is the one piece of the Windows build whose failure mode is "the tool stops working
  entirely": the script kills Codex, and the AppX container shutdown can take the console the
  script runs in down with it, so a lock that has to be deleted on the way out gets orphaned by a
  run that never gets to clean up. This exercises exactly that - a holder killed outright must not
  block the next run - plus the case it must still refuse, a holder that is alive.

  Only the two lock functions are lifted out of the script (by AST, so the real source is what
  runs); nothing else is executed and no Codex process is touched.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-lock.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'codex-switch.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$src = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                       $n.Name -in 'Acquire-Lock', 'Release-Lock' }, $true) |
        ForEach-Object { $_.Extent.Text }) -join "`n"
if ($src -notmatch 'Acquire-Lock' -or $src -notmatch 'Release-Lock') { throw "could not lift the lock functions out of $script" }
Invoke-Expression $src

function Fail([string]$m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-switch-lock-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $CX = @{ Lock = Join-Path $tmp 'codex-switch.lock' }

  # --- a lock held by a live run is refused ----------------------------------------------------
  $held = Acquire-Lock
  try { Acquire-Lock | Out-Null; Fail 'a lock held by a live run must be refused' }
  catch { if ($_.Exception.Message -notlike '*operation is in progress*') { Fail "wrong error for a held lock: $($_.Exception.Message)" } }

  # --- releasing it hands it straight to the next run -------------------------------------------
  Release-Lock $held
  $again = Acquire-Lock
  Release-Lock $again

  # --- and the regression: a holder killed outright must not block anything ---------------------
  $child = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "`$f=[System.IO.File]::Open('$($CX.Lock)',[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None); Write-Host ready; Start-Sleep 60")
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 10) {
    Start-Sleep -Milliseconds 100
    try { $probe = Acquire-Lock; Release-Lock $probe } catch { break }   # child has it
  }
  try { $probe = Acquire-Lock; Release-Lock $probe; Fail 'the child never took the lock - test did not exercise anything' } catch { }
  Stop-Process -Id $child.Id -Force
  $child.WaitForExit(10000) | Out-Null
  try { $probe = Acquire-Lock; Release-Lock $probe }
  catch { Fail "a lock whose owner was killed still blocks the next run: $($_.Exception.Message)" }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'all checks passed' -ForegroundColor Green
