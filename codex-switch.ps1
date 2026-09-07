#Requires -Version 5.1
<#
  codex-switch.ps1  -  Codex (desktop app + CLI + IDE extension) account profile switcher for Windows
  (one account active at a time; the switch MOVES a single file, auth.json)

  Usage:
    codex-switch.ps1 <name>            switch to profile <name>, then launch the Codex app
    codex-switch.ps1 <name> -NoLaunch  switch only, do not launch
    codex-switch.ps1 -List             list profiles (with account e-mail / plan) and the active one
    codex-switch.ps1 -Status           show the active account, auth mode and token freshness
    codex-switch.ps1 -Menu             interactive menu: add / pick a profile by number
    codex-switch.ps1 -Stop             fully close the Codex app + every codex.exe (CLI, VS Code, helpers)
    codex-switch.ps1 -Version          print the tool version and exit

  Why a single file:
    Everything Codex keeps under CODEX_HOME (default %USERPROFILE%\.codex) is shared by the desktop
    app, the CLI and the VS Code extension, and none of it is tied to an account - session rollouts,
    the sqlite thread index, memories, plugins, skills, config - except auth.json. The desktop app
    shows whichever account app-server reads from auth.json. So a profile is just that file, and
    sessions / settings are naturally shared across accounts.

  Why MOVE and never copy:
    The ChatGPT refresh token inside auth.json is single-use: every refresh (at launch, every 8 days,
    or 5 minutes before the access token expires) rotates it and rewrites the file in place. A copy
    left behind is a token that will already have been used - restoring it kills the account until
    the user logs in again. Keeping exactly one auth.json per account, moved between the live path
    and the profile store, makes that mistake impossible.

  Why every Codex process must be stopped first:
    auth.json is not locked on disk, but Codex caches it in memory and never re-reads it on its own;
    the app also rewrites the file a few seconds after launch, and that write is a non-atomic
    truncate + rewrite. Swapping under a live process either has no effect or corrupts the file.

  Layout:
    Live      %USERPROFILE%\.codex\auth.json                 (= the active profile's credentials)
    Inactive  %USERPROFILE%\.codex-profiles\<name>\auth.json (absent for the active profile)
    Info      %USERPROFILE%\.codex-profiles\<name>\profile.json (e-mail / plan cache for listings)
    Marker    %USERPROFILE%\.codex-profiles\active.txt
    If CODEX_HOME is set, the store is "<CODEX_HOME>-profiles" next to it.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$ProfileName,
  [switch]$List,
  [switch]$Status,
  [switch]$NoLaunch,
  [switch]$Menu,
  [switch]$Stop,
  [switch]$Version
)

$ErrorActionPreference = 'Stop'

# Tool version. Kept in sync with the git tag / GitHub release, which is tagged "v$ScriptVersion".
$ScriptVersion = '1.0.0'

if ($Version) {
  Write-Host "codex-switch $ScriptVersion"
  return
}

# Codex refreshes the ChatGPT tokens when last_refresh is older than this many days. A profile
# that has been parked longer than that may still work (the refresh token itself lives longer)
# but is flagged in listings so a surprise re-login isn't a surprise.
$StaleAfterDays = 8

function Resolve-CodexPaths {
  $home_ = [Environment]::GetFolderPath('UserProfile')
  $codexHome = $null
  if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) {
    $codexHome = $env:CODEX_HOME.Trim()
    if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
      throw "CODEX_HOME is set to '$codexHome' but that folder does not exist. Codex itself refuses to start in that state; fix or unset CODEX_HOME."
    }
    $codexHome = (Get-Item -LiteralPath $codexHome).FullName
    $store = "$($codexHome.TrimEnd('\'))-profiles"
  } else {
    $codexHome = Join-Path $home_ '.codex'
    $store = Join-Path $home_ '.codex-profiles'
  }

  # The desktop app is optional: CLI-only installs (npm / standalone) are switched exactly the same
  # way, we just have nothing to launch afterwards.
  $aumid = $null
  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pkg) {
    try {
      $appId = @((Get-AppxPackageManifest $pkg).Package.Applications.Application)[0].Id
      $aumid = "$($pkg.PackageFamilyName)!$appId"
    } catch { $aumid = "$($pkg.PackageFamilyName)!App" }
  }

  [pscustomobject]@{
    Home    = $codexHome
    Auth    = Join-Path $codexHome 'auth.json'
    Config  = Join-Path $codexHome 'config.toml'
    Store   = $store
    Marker  = Join-Path $store 'active.txt'
    Lock    = Join-Path $store 'codex-switch.lock'
    Aumid   = $aumid
  }
}

# ---------------------------------------------------------------------------------------------
# Process detection / shutdown
# ---------------------------------------------------------------------------------------------

# Every process that is Codex: the MSIX desktop app (its exe is ChatGPT.exe under
# WindowsApps\OpenAI.Codex_*), the codex.exe binaries it materialises under %LOCALAPPDATA%\OpenAI\Codex
# and CODEX_HOME\bin, the node / node_repl / pwsh runtimes, the VS Code extension's bundled
# codex.exe, npm-installed CLIs (node.exe running codex.js + the vendored codex.exe), and any
# codex.exe a user started in a terminal. Roots are matched on each process's OWN image path,
# never derived from one "main" PID, so a leftover helper or an orphaned CLI is still found.
# Descendants of every root are swept via the parent map.
#
# Deliberately NOT matched: the regular ChatGPT app (package OpenAI.ChatGPT-Desktop) - its exe is
# also called ChatGPT.exe, which is why matching by image name instead of path would kill it.
# Our own process and its ancestors are never returned, so running this from a terminal that Codex
# itself spawned cannot make the script kill its own shell.
function Get-CodexProcesses {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  if (-not $all) { return @() }
  $byId = @{}; $children = @{}
  foreach ($p in $all) {
    $id = [int]$p.ProcessId; $pp = [int]$p.ParentProcessId
    $byId[$id] = $p
    if (-not $children.ContainsKey($pp)) { $children[$pp] = New-Object 'System.Collections.Generic.List[int]' }
    $children[$pp].Add($id)
  }
  # Protect ourselves and the chain of shells we were launched from.
  $protected = New-Object 'System.Collections.Generic.HashSet[int]'
  $cur = $PID
  while ($cur -and $byId.ContainsKey($cur) -and $protected.Add($cur)) { $cur = [int]$byId[$cur].ParentProcessId }

  $local = $env:LOCALAPPDATA
  $userp = [Environment]::GetFolderPath('UserProfile')
  $pathPats = @(
    '*\WindowsApps\OpenAI.Codex_*',
    (Join-Path $local 'OpenAI\Codex\*'),
    (Join-Path $userp '.cache\codex-runtimes\*'),
    (Join-Path $CX.Home 'bin\*'),
    (Join-Path $CX.Home '.sandbox-bin\*'),
    '*\.vscode\extensions\openai.chatgpt-*',
    '*\node_modules\@openai\codex*'
  )
  $namePats = @('codex.exe', 'codex-app-server.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe',
                'codex-windows-sandbox-setup.exe', 'codex-responses-api-proxy.exe')

  $seen  = New-Object 'System.Collections.Generic.HashSet[int]'
  $queue = New-Object 'System.Collections.Generic.Queue[int]'
  foreach ($p in $all) {
    $id = [int]$p.ProcessId
    if ($protected.Contains($id)) { continue }
    $path = [string]$p.ExecutablePath
    $name = [string]$p.Name
    $isRoot = $false
    if ($path) { foreach ($pat in $pathPats) { if ($path -like $pat) { $isRoot = $true; break } } }
    if (-not $isRoot -and $namePats -contains $name.ToLowerInvariant()) { $isRoot = $true }
    # npm shim: node.exe running .../@openai/codex/bin/codex.js
    if (-not $isRoot -and $name -ieq 'node.exe' -and [string]$p.CommandLine -like '*\@openai\codex*codex.js*') { $isRoot = $true }
    if ($isRoot -and $seen.Add($id)) { [void]$queue.Enqueue($id) }
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if (-not $protected.Contains($id)) { $out.Add($byId[$id]) }
    if ($children.ContainsKey($id)) {
      foreach ($c in $children[$id]) { if (-not $protected.Contains($c) -and $seen.Add($c)) { [void]$queue.Enqueue($c) } }
    }
  }
  return $out.ToArray()   # ToArray, not @($out): @() on a List[object] throws in PS 5.1
}

function Stop-Codex {
  # Success is verified against concrete PIDs, not against whether detection can still see them:
  # once a parent exits a surviving child could drop out of a fresh scan and fake an "all closed".
  $tracked = @{}
  for ($i = 0; $i -lt 30; $i++) {
    foreach ($p in @(Get-CodexProcesses)) { $tracked[[int]$p.ProcessId] = $p.Name }
    $alive = @($tracked.Keys | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if (-not $alive.Count) { return $tracked.Count }
    foreach ($procId in $alive) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 200
  }
  $alive = @($tracked.Keys | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  if ($alive.Count) {
    $list = ($alive | ForEach-Object { "$($tracked[$_]) (PID $_)" }) -join ', '
    throw "Codex is still running and could not be closed: $list. Close it manually, then retry."
  }
  return $tracked.Count
}

# ---------------------------------------------------------------------------------------------
# Profiles, identity, guards
# ---------------------------------------------------------------------------------------------

# Guard against path traversal / reserved names: a profile name becomes a folder under the store.
function Assert-ValidProfileName([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $name -eq '.' -or $name -eq '..') {
    throw "Invalid profile name '$name'. Use 1-64 characters: letters, digits, dot, dash, underscore (no spaces or path separators)."
  }
  $reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" })
  if ($reserved -contains $name.ToUpperInvariant()) {
    throw "Invalid profile name '$name'. That is a reserved Windows device name."
  }
}

function Get-Active {
  if (Test-Path -LiteralPath $CX.Marker) {
    $v = Get-Content -LiteralPath $CX.Marker -Raw -ErrorAction SilentlyContinue
    if ($v) { $v = $v.Trim() }
    if ($v) { return $v }
  }
  return $null
}
function Set-Active([string]$name) {
  Set-Content -LiteralPath $CX.Marker -Value $name -NoNewline -Encoding Ascii
}

# Cross-process guard so two overlapping switches can't both move auth.json.
function Acquire-Lock {
  $existing = Get-Item -LiteralPath $CX.Lock -Force -ErrorAction SilentlyContinue
  if ($existing -and ((Get-Date) - $existing.LastWriteTime).TotalMinutes -gt 5) {
    Remove-Item -LiteralPath $CX.Lock -Force -ErrorAction SilentlyContinue  # stale lock from a crashed run
  }
  try { New-Item -ItemType File -Path $CX.Lock -ErrorAction Stop | Out-Null }
  catch { throw "Another codex-switch operation is in progress (lock: $($CX.Lock)). If it is stale, delete that file and retry." }
  return $CX.Lock
}
function Release-Lock([string]$lock) {
  if ($lock) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
}

# The profile store holds plaintext bearer tokens. Codex only sets 0600 on Unix, nothing on
# Windows, so tighten the store to the current user (+ SYSTEM) ourselves. Best effort: a failure
# here must never block a switch.
function Protect-Store {
  try {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $CX.Store /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" 2>&1 | Out-Null
  } catch { }
}

# Codex can be told to keep credentials in the OS keyring / an age-encrypted secrets store instead
# of auth.json. In that mode there is no file to move, and the keyring slot is keyed by the
# CODEX_HOME path - every profile would collide on one entry. Refuse rather than pretend.
function Assert-FileCredentialStore {
  if (-not (Test-Path -LiteralPath $CX.Config)) { return }
  $m = Select-String -LiteralPath $CX.Config -Pattern '^\s*cli_auth_credentials_store\s*=\s*"?([A-Za-z]+)"?' | Select-Object -First 1
  if (-not $m) { return }
  $mode = $m.Matches[0].Groups[1].Value.ToLowerInvariant()
  if ($mode -ne 'file') {
    throw "config.toml sets cli_auth_credentials_store = `"$mode`". codex-switch only works with the default file store (auth.json). Remove that line or set it to `"file`", log in again, then retry."
  }
}

function ConvertFrom-Base64Url([string]$s) {
  $s = $s.Replace('-', '+').Replace('_', '/')
  switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
  return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

# What account does this auth.json hold? Read locally from the id_token JWT claims - no network,
# no quota. Returns $null when the file is missing or unreadable.
function Read-AuthIdentity([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $a = $raw | ConvertFrom-Json
  } catch { return [pscustomobject]@{ Mode = 'unreadable'; Email = ''; Plan = ''; AccountId = ''; LastRefresh = $null } }
  $mode = [string]$a.auth_mode
  $email = ''; $plan = ''; $acct = ''
  if ($a.tokens -and $a.tokens.id_token) {
    try {
      $parts = ([string]$a.tokens.id_token).Split('.')
      $claims = (ConvertFrom-Base64Url $parts[1]) | ConvertFrom-Json
      $email = [string]$claims.email
      $authc = $claims.'https://api.openai.com/auth'
      if ($authc) { $plan = [string]$authc.chatgpt_plan_type; $acct = [string]$authc.chatgpt_account_id }
      if (-not $acct -and $a.tokens.account_id) { $acct = [string]$a.tokens.account_id }
      if (-not $mode) { $mode = 'chatgpt' }
    } catch { }
  } elseif ($a.OPENAI_API_KEY) {
    if (-not $mode) { $mode = 'apikey' }
    $k = [string]$a.OPENAI_API_KEY
    if ($k.Length -gt 8) { $email = "API key ...$($k.Substring($k.Length - 5))" } else { $email = 'API key' }
  }
  $lr = $null
  if ($a.last_refresh) { try { $lr = [DateTime]::Parse([string]$a.last_refresh, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { } }
  [pscustomobject]@{ Mode = $mode; Email = $email; Plan = $plan; AccountId = $acct; LastRefresh = $lr }
}

function Save-ProfileInfo([string]$name, $identity, [bool]$loggedOut) {
  $dir = Join-Path $CX.Store $name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $info = [ordered]@{
    email       = ''; plan = ''; accountId = ''; authMode = ''
    lastRefresh = $null
    loggedOut   = $loggedOut
    savedAt     = (Get-Date).ToUniversalTime().ToString('o')
  }
  if ($identity) {
    $info.email = $identity.Email; $info.plan = $identity.Plan; $info.accountId = $identity.AccountId; $info.authMode = $identity.Mode
    if ($identity.LastRefresh) { $info.lastRefresh = $identity.LastRefresh.ToString('o') }
  } else {
    # keep the previous label so a logged-out profile still says whose it was
    $prev = Get-ProfileInfo $name
    if ($prev) { $info.email = $prev.email; $info.plan = $prev.plan; $info.accountId = $prev.accountId; $info.authMode = $prev.authMode }
  }
  ($info | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $dir 'profile.json') -Encoding UTF8
}
function Get-ProfileInfo([string]$name) {
  $f = Join-Path (Join-Path $CX.Store $name) 'profile.json'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# One row per profile for -List / -Menu. The active profile is described from the live auth.json,
# inactive ones from their stored auth.json (or the cached profile.json if they are logged out).
function Get-ProfileRows {
  $active = Get-Active
  $names = New-Object System.Collections.Generic.List[string]
  if ($active) { $names.Add($active) }
  Get-ChildItem -LiteralPath $CX.Store -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -ne $active) { $names.Add($_.Name) }
  }
  $rows = foreach ($n in @($names | Sort-Object -Unique)) {
    $isActive = ($n -eq $active)
    if ($isActive) { $authPath = $CX.Auth } else { $authPath = Join-Path (Join-Path $CX.Store $n) 'auth.json' }
    $id = Read-AuthIdentity $authPath
    $label = ''; $note = ''
    if ($id) {
      if ($id.Mode -eq 'unreadable') { $note = 'auth.json unreadable' }
      else {
        $label = $id.Email
        if ($id.Plan) { $label += "  ($($id.Plan))" }
        if ($id.LastRefresh -and ((Get-Date).ToUniversalTime() - $id.LastRefresh).TotalDays -gt $StaleAfterDays) { $note = 'may need re-login' }
      }
    } else {
      $info = Get-ProfileInfo $n
      if ($info -and $info.email) { $label = [string]$info.email }
      $note = 'logged out - log in after launch'
    }
    [pscustomobject]@{ Name = $n; Active = $isActive; Label = $label; Note = $note }
  }
  return @($rows)
}

function Format-ProfileRow($row, [string]$prefix) {
  $line = "{0}{1}" -f $prefix, $row.Name.PadRight(12)
  if ($row.Label) { $line += "  $($row.Label)" }
  if ($row.Note)  { $line += "  [$($row.Note)]" }
  if ($row.Active) { $line += '  [active]' }
  return $line
}

# ---------------------------------------------------------------------------------------------

$CX = Resolve-CodexPaths
New-Item -ItemType Directory -Force -Path $CX.Store | Out-Null

# --- Stop: close the desktop app and every codex process. Side-effect free (no file moves). ---
if ($Stop) {
  $lock = Acquire-Lock
  try {
    $n = Stop-Codex
    Write-Host "Codex is stopped ($n process(es) closed: desktop app, CLI sessions, helpers)." -ForegroundColor Green
  } finally { Release-Lock $lock }
  return
}

# First-ever run: an existing login has no marker yet -> it becomes profile 'main'.
if (-not (Get-Active) -and (Test-Path -LiteralPath $CX.Auth)) {
  New-Item -ItemType Directory -Force -Path (Join-Path $CX.Store 'main') | Out-Null
  Set-Active 'main'
  Save-ProfileInfo 'main' (Read-AuthIdentity $CX.Auth) $false
  Protect-Store
}

# --- Status: who is logged in right now ---
if ($Status) {
  $active = Get-Active
  $id = Read-AuthIdentity $CX.Auth
  Write-Host ""
  Write-Host "CODEX_HOME : $($CX.Home)"
  Write-Host "Profile    : " -NoNewline
  Write-Host ($(if ($active) { $active } else { '(none)' })) -ForegroundColor Green
  if (-not $id) {
    Write-Host "Account    : not logged in (no auth.json)" -ForegroundColor Yellow
  } elseif ($id.Mode -eq 'unreadable') {
    Write-Host "Account    : auth.json exists but could not be parsed" -ForegroundColor Red
  } else {
    Write-Host "Account    : $($id.Email)"
    if ($id.Plan)      { Write-Host "Plan       : $($id.Plan)" }
    if ($id.AccountId) { Write-Host "Account id : $($id.AccountId)" }
    Write-Host "Auth mode  : $($id.Mode)"
    if ($id.LastRefresh) {
      $age = (Get-Date).ToUniversalTime() - $id.LastRefresh
      $flag = ''
      if ($age.TotalDays -gt $StaleAfterDays) { $flag = '  (older than the refresh interval - Codex will refresh on next start)' }
      Write-Host ("Refreshed  : {0:yyyy-MM-dd HH:mm} UTC, {1:N1} day(s) ago{2}" -f $id.LastRefresh, $age.TotalDays, $flag)
    }
  }
  Write-Host ("Codex app  : {0}" -f $(if ($CX.Aumid) { "installed ($($CX.Aumid))" } else { 'not installed (CLI-only mode)' }))
  Write-Host ""
  return
}

# --- Interactive menu ---
if ($Menu) {
  while ($true) {
    $rows = @(Get-ProfileRows)
    $active = Get-Active
    Write-Host "`n=== codex-switch ===" -ForegroundColor Cyan
    Write-Host "Active: " -NoNewline
    $act = @($rows | Where-Object { $_.Active })
    if ($act.Count) { Write-Host ("{0}  {1}" -f $act[0].Name, $act[0].Label) -ForegroundColor Green }
    else { Write-Host ($(if ($active) { "$active (not logged in)" } else { '(none)' })) -ForegroundColor Green }
    Write-Host ""
    for ($i = 0; $i -lt $rows.Count; $i++) {
      Write-Host (Format-ProfileRow $rows[$i] ("  {0}) " -f ($i + 1)))
    }
    Write-Host "  N) Add new profile (log in with another account)"
    Write-Host "  Q) Quit"
    Write-Host ""
    Write-Host "  Switching closes the Codex app and any codex CLI sessions (terminal / VS Code)." -ForegroundColor DarkGray
    $choice = Read-Host "`nSelect"

    if ($choice -match '^[Qq]$' -or [string]::IsNullOrWhiteSpace($choice)) { return }

    if ($choice -match '^[Nn]$') {
      $newName = Read-Host "New profile name"
      try { Assert-ValidProfileName $newName }
      catch { Write-Host $_.Exception.Message -ForegroundColor Red; continue }
      if (@($rows | Where-Object { $_.Name -eq $newName }).Count) { Write-Host "Profile '$newName' already exists - pick it from the list instead." -ForegroundColor Red; continue }
      $target = $newName
    } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $rows.Count) {
      $target = $rows[[int]$choice - 1].Name
    } else {
      Write-Host "Invalid choice." -ForegroundColor Red
      continue
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $target
    return
  }
}

# --- List ---
if ($List -or -not $ProfileName) {
  $rows = @(Get-ProfileRows)
  $active = Get-Active
  Write-Host "`nActive profile: " -NoNewline
  Write-Host ($(if ($active) { $active } else { '(none)' })) -ForegroundColor Green
  Write-Host "`nProfiles:"
  if (-not $rows.Count) { Write-Host "  (none yet - log in to Codex once, or run: codex-switch <name>)" }
  foreach ($r in $rows) {
    $mark = if ($r.Active) { '* ' } else { '  ' }
    Write-Host (Format-ProfileRow $r "  $mark")
  }
  Write-Host "`nSwitch with:  codex-switch <name>   (unknown name = new empty profile, log in after launch)`n"
  return
}

# --- Switch (move auth.json) ---
Assert-ValidProfileName $ProfileName
$lock = Acquire-Lock
try {
  Assert-FileCredentialStore
  $n = Stop-Codex
  if ($n) { Write-Host "[stop] closed $n Codex process(es)." -ForegroundColor DarkGray }

  $active = Get-Active
  if ($active -ne $ProfileName) {
    $stashed = $null
    # 1) Stash: move the live auth.json into the outgoing profile's folder.
    if (Test-Path -LiteralPath $CX.Auth) {
      if (-not $active) { $active = 'main' }
      $outDir = Join-Path $CX.Store $active
      New-Item -ItemType Directory -Force -Path $outDir | Out-Null
      $dest = Join-Path $outDir 'auth.json'
      if (Test-Path -LiteralPath $dest) {
        # Inconsistent state (a copy already parked while the profile was active). Keep it as a
        # dated backup rather than guessing which one is the live token; the live file wins.
        $bak = Join-Path $outDir ("auth.json.bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
        Move-Item -LiteralPath $dest -Destination $bak
        Write-Host "[stash] '$active' already had an auth.json; kept it as $(Split-Path $bak -Leaf)." -ForegroundColor DarkYellow
      }
      Save-ProfileInfo $active (Read-AuthIdentity $CX.Auth) $false
      Move-Item -LiteralPath $CX.Auth -Destination $dest
      $stashed = @{ Name = $active; Path = $dest }
    } elseif ($active) {
      # Logged out under this profile (codex logout, or never logged in). Nothing to stash.
      Save-ProfileInfo $active $null $true
      Write-Host "[stash] '$active' has no login to keep (logged out)." -ForegroundColor DarkYellow
    }
    try {
      # 2) Activate: move the target's auth.json into place, or start an empty profile.
      $tgtDir = Join-Path $CX.Store $ProfileName
      $src = Join-Path $tgtDir 'auth.json'
      New-Item -ItemType Directory -Force -Path $tgtDir | Out-Null
      if (Test-Path -LiteralPath $src) {
        Move-Item -LiteralPath $src -Destination $CX.Auth
      } else {
        Write-Host "[new profile] '$ProfileName' has no login yet - sign in with the other account when Codex opens." -ForegroundColor Yellow
        Write-Host "              (If your browser is already signed in to ChatGPT, sign out there first or use a private window.)" -ForegroundColor Yellow
        Save-ProfileInfo $ProfileName $null $true
      }
      Set-Active $ProfileName
    } catch {
      # Activation failed: put the outgoing profile's credentials back so nobody is left logged out.
      if ($stashed -and -not (Test-Path -LiteralPath $CX.Auth) -and (Test-Path -LiteralPath $stashed.Path)) {
        Move-Item -LiteralPath $stashed.Path -Destination $CX.Auth
        Set-Active $stashed.Name
        Write-Host "[rollback] switch failed; restored '$($stashed.Name)' as the active profile." -ForegroundColor Yellow
      }
      throw
    }
  }
  Protect-Store

  $id = Read-AuthIdentity $CX.Auth
  $who = ''
  if ($id -and $id.Email) { $who = "  ($($id.Email))" }
  Write-Host "Active profile -> '$ProfileName'$who" -ForegroundColor Green

  if (-not $NoLaunch) {
    if ($CX.Aumid) {
      Start-Process "shell:AppsFolder\$($CX.Aumid)"
      Write-Host "Launching Codex..." -ForegroundColor Green
    } else {
      Write-Host "Codex desktop app not installed - run 'codex' in a terminal to use this account." -ForegroundColor DarkGray
    }
  }
} finally {
  Release-Lock $lock
}
