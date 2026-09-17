#!/bin/bash
#
#   codex-switch.sh  -  Codex (desktop app + CLI + IDE extension) account profile switcher for macOS
#   (one account active at a time; the switch MOVES a single file, auth.json)
#
#   Usage:
#     ./codex-switch.sh <name>              switch to profile <name>, then launch the Codex app
#     ./codex-switch.sh <name> --no-launch  switch only, do not launch
#     ./codex-switch.sh --list              list profiles (with account e-mail / plan) and the active one
#     ./codex-switch.sh --status            show the active account, auth mode and token freshness
#     ./codex-switch.sh --menu              interactive menu: add / pick a profile by number
#     ./codex-switch.sh --stop              fully close the Codex app + every codex process
#     ./codex-switch.sh --version           print the tool version and exit
#
#   This is the macOS counterpart of codex-switch.ps1: same store layout, same move-never-copy
#   rule, same commands. Everything OS-shaped is different, and only that:
#     - the desktop app is a bundle (com.openai.codex), resolved by bundle id and launched with
#       `open`, not an MSIX package activated through shell:AppsFolder
#     - processes are found with ps and closed with SIGTERM then SIGKILL; macOS has no AppX
#       container, so none of the package-shutdown / wedged-stub repair from the Windows script
#       applies here
#     - the profile store is protected with chmod instead of icacls (Codex already writes
#       auth.json as 0600 on Unix)
#   Why a profile is exactly one file, and why it is moved rather than copied: docs/DESIGN.md.
#
#   Layout (CODEX_HOME is honoured; the store is then "<CODEX_HOME>-profiles"):
#     Live      ~/.codex/auth.json                  = the active profile's credentials
#     Inactive  ~/.codex-profiles/<name>/auth.json  (absent for the active profile)
#     Info      ~/.codex-profiles/<name>/profile.json  e-mail / plan cache for listings
#     Marker    ~/.codex-profiles/active.txt

set -euo pipefail

# Tool version. Kept in sync with $ScriptVersion in codex-switch.ps1, which is what the release
# build reads; tools/build-release.ps1 fails if the two ever drift apart.
SCRIPT_VERSION='1.1.0'

# Codex refreshes the ChatGPT tokens when last_refresh is older than this many days. A profile
# parked for longer may still work (the refresh token itself lives longer) but is flagged in
# listings so a surprise re-login isn't a surprise.
STALE_AFTER_DAYS=8

# The Codex desktop app. On macOS it installs as "ChatGPT.app" - so does the regular ChatGPT app,
# whose bundle id is com.openai.chat. Everything here matches on the bundle id, never the name.
CODEX_BUNDLE_ID='com.openai.codex'

SELF=${BASH_SOURCE[0]}

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_CYAN=$'\033[36m';  C_DIM=$'\033[90m';    C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_OFF=''
fi

die()  { printf '%s\n' "${C_RED}$*${C_OFF}" >&2; exit 1; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_OFF}"; }
note() { printf '%s\n' "${C_DIM}$*${C_OFF}"; }

# ---------------------------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------------------------

bundle_id() { /usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true; }

# The desktop app is optional: CLI-only installs (Homebrew / npm / standalone) switch exactly the
# same way, we just have nothing to launch afterwards.
find_codex_app() {
  local p
  for p in /Applications/ChatGPT.app /Applications/Codex.app \
           "$HOME/Applications/ChatGPT.app" "$HOME/Applications/Codex.app"; do
    if [ "$(bundle_id "$p")" = "$CODEX_BUNDLE_ID" ]; then printf '%s' "$p"; return 0; fi
  done
  # Installed somewhere else: ask Spotlight, and confirm the hit really carries that bundle id.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$(bundle_id "$p")" = "$CODEX_BUNDLE_ID" ]; then printf '%s' "$p"; return 0; fi
  done <<<"$(mdfind "kMDItemCFBundleIdentifier == '$CODEX_BUNDLE_ID'" 2>/dev/null || true)"
  return 0
}

resolve_paths() {
  if [ -n "${CODEX_HOME:-}" ]; then
    [ -d "$CODEX_HOME" ] || die "CODEX_HOME is set to '$CODEX_HOME' but that folder does not exist. Codex itself refuses to start in that state; fix or unset CODEX_HOME."
    CX_HOME=$(cd "$CODEX_HOME" && pwd -P)
    CX_STORE="${CX_HOME%/}-profiles"
  else
    CX_HOME="$HOME/.codex"
    CX_STORE="$HOME/.codex-profiles"
  fi
  CX_AUTH="$CX_HOME/auth.json"
  CX_CONFIG="$CX_HOME/config.toml"
  CX_MARKER="$CX_STORE/active.txt"
  CX_LOCK="$CX_STORE/codex-switch.lock"
  CX_APP=$(find_codex_app)
}

# ---------------------------------------------------------------------------------------------
# Process detection / shutdown
# ---------------------------------------------------------------------------------------------

# pid, ppid and the executable path of every process, one per line, normalised to single spaces
# (the path is last and may itself contain spaces - "Codex (Renderer).app/..." does).
ps_snapshot() {
  ps -Ao pid=,ppid=,comm= 2>/dev/null |
    awk '{ p = $1; q = $2; $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); print p, q, $0 }' || true
}

# Is this executable path a Codex process? Judged per process on its OWN path, so a leftover
# helper or an orphaned CLI is found even when its parent is long gone.
#
# Deliberately NOT matched: the regular ChatGPT desktop app (com.openai.chat), which also installs
# as ChatGPT.app - that is exactly why the app is resolved by bundle id and matched by path.
is_codex_path() {
  local path=$1 base=${1##*/}
  case "$base" in
    codex|codex-app-server|codex-code-mode-host|codex-command-runner|codex-responses-api-proxy)
      return 0 ;;
  esac
  case "$path" in
    "$CX_HOME"/*)                              return 0 ;;  # bin/, .sandbox-bin/, computer-use/, plugin hosts
    "$HOME"/.cache/codex-runtimes/*)           return 0 ;;
    */.vscode*/extensions/openai.chatgpt-*/*)  return 0 ;;  # VS Code / Cursor extension's app-server
    */node_modules/@openai/codex*/*)           return 0 ;;  # npm install
    *"/Codex Framework.framework/"*)           return 0 ;;  # the app's renderers / services, wherever the bundle lives
  esac
  if [ -n "$CX_APP" ]; then
    case "$path" in "$CX_APP"/*) return 0 ;; esac
  fi
  return 1
}

# Every Codex pid: the roots above, then their descendants swept through the parent map. This
# script's own process and the shells it was started from are never returned, so running it from
# a terminal Codex itself spawned cannot kill the shell out from under it.
codex_pids() {
  local snap protected seen queue out cur pid ppid path child line bundles bundle

  snap=$(ps_snapshot)

  protected=' '
  cur=$$
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    case "$protected" in *" $cur "*) break ;; esac
    protected="$protected$cur "
    cur=$(awk -v p="$cur" '$1 == p { print $2; exit }' <<<"$snap")
  done

  seen=' '; queue=''; bundles=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%% *};  line=${line#* }
    ppid=${line%% *}; path=${line#* }
    case "$protected" in *" $pid "*) continue ;; esac
    case "$seen"      in *" $pid "*) continue ;; esac
    if is_codex_path "$path"; then
      seen="$seen$pid "; queue="$queue $pid"
      # Remember which .app a match came out of. A helper is matched on its framework path even
      # when the bundle sits somewhere unexpected, and the app's main process is that helper's
      # PARENT - so the descendant sweep alone would leave it running.
      case "$path" in
        */Contents/*)
          bundle=${path%%/Contents/*}
          case "$bundle" in *.app) bundles="$bundles$bundle"$'\n' ;; esac
          ;;
      esac
    fi
  done <<<"$snap"

  while IFS= read -r bundle; do
    [ -n "$bundle" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pid=${line%% *};  line=${line#* }
      ppid=${line%% *}; path=${line#* }
      case "$protected" in *" $pid "*) continue ;; esac
      case "$seen"      in *" $pid "*) continue ;; esac
      case "$path"      in "$bundle"/*) seen="$seen$pid "; queue="$queue $pid" ;; esac
    done <<<"$snap"
  done <<<"$(printf '%s' "$bundles" | sort -u)"

  # The npm shim is a node process running .../@openai/codex/bin/codex.js; its own image path is
  # just node, so it is matched on the command line instead.
  for pid in $(pgrep -f '@openai/codex.*codex\.js' 2>/dev/null || true); do
    case "$protected" in *" $pid "*) continue ;; esac
    case "$seen"      in *" $pid "*) continue ;; esac
    seen="$seen$pid "; queue="$queue $pid"
  done

  out=''
  while [ -n "${queue// /}" ]; do
    set -- $queue; pid=$1; shift; queue="$*"
    out="$out $pid"
    for child in $(awk -v p="$pid" '$2 == p { print $1 }' <<<"$snap"); do
      case "$protected" in *" $child "*) continue ;; esac
      case "$seen"      in *" $child "*) continue ;; esac
      seen="$seen$child "; queue="$queue $child"
    done
  done
  printf '%s' "${out# }"
}

# Close Codex and prove it. Success is verified against the concrete pids we saw, not against
# whether a fresh scan can still find them: once a parent exits, a surviving child can drop out of
# detection and fake an "all closed". SIGTERM first so the desktop app can flush its state, then
# SIGKILL for whatever is still standing after ~2 seconds. Prints how many processes were closed.
stop_codex() {
  local tracked=' ' alive pid round
  for round in $(seq 1 40); do
    for pid in $(codex_pids); do
      case "$tracked" in *" $pid "*) ;; *) tracked="$tracked$pid " ;; esac
    done
    alive=''
    for pid in $tracked; do
      if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
    done
    if [ -z "${alive// /}" ]; then printf '%s' "$(printf '%s' "$tracked" | wc -w | tr -d ' ')"; return 0; fi
    if [ "$round" -le 10 ]; then kill $alive 2>/dev/null || true
    else                        kill -9 $alive 2>/dev/null || true; fi
    sleep 0.2
  done
  die "Codex is still running and could not be closed (PID(s):$alive). Close it manually, then retry."
}

launch_codex() {
  [ -n "$CX_APP" ] || return 0
  open -b "$CODEX_BUNDLE_ID" 2>/dev/null || open -a "$CX_APP" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------------------------
# Profiles, identity, guards
# ---------------------------------------------------------------------------------------------

# Guard against path traversal: a profile name becomes a folder under the store.
assert_valid_name() {
  local name=${1:-}
  case "$name" in
    .|..) die "Invalid profile name '$name'." ;;
  esac
  [[ $name =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
    die "Invalid profile name '$name'. Use 1-64 characters: letters, digits, dot, dash, underscore (no spaces or path separators)."
}

get_active() { [ -f "$CX_MARKER" ] && tr -d ' \t\r\n' < "$CX_MARKER" || true; }
set_active() { printf '%s' "$1" > "$CX_MARKER"; }

# Cross-process guard so two overlapping switches can't both move auth.json. `set -o noclobber`
# makes the redirect an O_EXCL create, which is the atomic part. The lock holds the owner's pid so
# a run that is killed outright - its EXIT trap never fires - leaves a lock the next run can see is
# dead, instead of one that refuses every retry until a timeout nobody knows about has passed.
# ponytail: pid liveness, not a real advisory lock - a recycled pid can hold it for one run; reach
# for flock/shlock only if that ever actually bites.
acquire_lock() {
  if [ -e "$CX_LOCK" ]; then
    local owner; owner=$(cat "$CX_LOCK" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      die "Another codex-switch operation is in progress (pid $owner, lock: $CX_LOCK). Wait for it to finish, then retry."
    fi
    rm -f "$CX_LOCK"   # owner is gone: stale lock from a crashed run
  fi
  if ( set -o noclobber; printf '%s' "$$" > "$CX_LOCK" ) 2>/dev/null; then
    trap 'rm -f "$CX_LOCK"' EXIT INT TERM
  else
    die "Another codex-switch operation is in progress (lock: $CX_LOCK). If it is stale, delete that file and retry."
  fi
}

# The store holds plaintext bearer tokens. Codex writes auth.json 0600 and mv preserves that, so
# only the directory needs tightening. Best effort: a failure here must never block a switch.
protect_store() { chmod 700 "$CX_STORE" 2>/dev/null || true; }

# Codex can be told to keep credentials in the macOS Keychain instead of auth.json. In that mode
# there is no file to move, and the keychain entry is keyed by the CODEX_HOME path - every profile
# would collide on one entry. Refuse rather than pretend.
assert_file_credential_store() {
  [ -f "$CX_CONFIG" ] || return 0
  local mode
  mode=$(sed -n 's/^[[:space:]]*cli_auth_credentials_store[[:space:]]*=[[:space:]]*"\{0,1\}\([A-Za-z]*\).*/\1/p' "$CX_CONFIG" | head -1)
  [ -n "$mode" ] || return 0
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  [ "$mode" = file ] ||
    die "config.toml sets cli_auth_credentials_store = \"$mode\". codex-switch only works with the default file store (auth.json). Remove that line or set it to \"file\", log in again, then retry."
}

# plutil reads JSON as happily as plists and is on every Mac, so no jq / python dependency.
jget() { plutil -extract "$1" raw -o - -- "$2" 2>/dev/null || true; }

b64url_decode() {
  local s=${1//-/+}
  s=${s//_//}
  case $((${#s} % 4)) in 2) s="$s==" ;; 3) s="$s=" ;; esac
  printf '%s' "$s" | base64 -D 2>/dev/null || true
}

# One string field out of a compact JSON blob (the decoded JWT payload is a single line).
json_str() { printf '%s' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

# What account does this auth.json hold? Read locally from the id_token JWT claims - no network,
# no quota. Sets ID_*; returns 1 when the file is missing.
read_auth_identity() {
  local path=$1 token claims key
  ID_MODE=''; ID_EMAIL=''; ID_PLAN=''; ID_ACCT=''; ID_LR=''
  [ -f "$path" ] || return 1
  # -convert parses JSON (plutil -lint only understands plists) and -o /dev/null leaves the
  # file alone, so this is just a "does it still parse" check.
  if ! plutil -convert json -o /dev/null -- "$path" 2>/dev/null; then ID_MODE='unreadable'; return 0; fi
  ID_MODE=$(jget auth_mode "$path")
  token=$(jget tokens.id_token "$path")
  if [ -n "$token" ]; then
    claims=$(b64url_decode "$(printf '%s' "$token" | cut -d. -f2)")
    ID_EMAIL=$(json_str email "$claims")
    ID_PLAN=$(json_str chatgpt_plan_type "$claims")
    ID_ACCT=$(json_str chatgpt_account_id "$claims")
    [ -n "$ID_ACCT" ] || ID_ACCT=$(jget tokens.account_id "$path")
    [ -n "$ID_MODE" ] || ID_MODE='chatgpt'
  else
    key=$(jget OPENAI_API_KEY "$path")
    if [ -n "$key" ]; then
      [ -n "$ID_MODE" ] || ID_MODE='apikey'
      if [ ${#key} -gt 8 ]; then ID_EMAIL="API key ...${key: -5}"; else ID_EMAIL='API key'; fi
    fi
  fi
  ID_LR=$(jget last_refresh "$path")
  return 0
}

# Codex writes last_refresh as RFC 3339 UTC ("2026-09-09T12:44:59.479106Z").
iso_epoch() {
  local t=${1%%.*}
  t=${t%Z}; t=${t%%+*}
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$t" '+%s' 2>/dev/null || true
}
days_since() {
  local epoch now
  epoch=$(iso_epoch "$1"); [ -n "$epoch" ] || return 1
  now=$(date '+%s')
  printf '%s' $(( (now - epoch) / 86400 ))
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
get_profile_field() { jget "$2" "$CX_STORE/$1/profile.json"; }

# <name> <logged-out 0|1>, described by the current ID_* values. A logged-out profile keeps the
# labels it had, so the listing can still say whose account it was.
save_profile_info() {
  local name=$1 out=$2 dir email plan acct mode lr lr_json
  dir="$CX_STORE/$name"; mkdir -p "$dir"
  email=$ID_EMAIL; plan=$ID_PLAN; acct=$ID_ACCT; mode=$ID_MODE; lr=$ID_LR
  if [ "$out" = 1 ]; then
    email=$(get_profile_field "$name" email)
    plan=$(get_profile_field "$name" plan)
    acct=$(get_profile_field "$name" accountId)
    mode=$(get_profile_field "$name" authMode)
    lr=''
  fi
  if [ -n "$lr" ]; then lr_json="\"$(json_escape "$lr")\""; else lr_json='null'; fi
  cat > "$dir/profile.json" <<JSON
{
  "email": "$(json_escape "$email")",
  "plan": "$(json_escape "$plan")",
  "accountId": "$(json_escape "$acct")",
  "authMode": "$(json_escape "$mode")",
  "lastRefresh": $lr_json,
  "loggedOut": $(if [ "$out" = 1 ]; then echo true; else echo false; fi),
  "savedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
}

# One row per profile for --list / --menu: name, active flag, label, note, separated by US
# (\037), not tab: bash gives IFS whitespace special treatment, so `IFS=$'\t' read` collapses
# the empty label of a logged-out profile and shifts every field after it. The
# active profile is described from the live auth.json, inactive ones from their stored copy (or
# the cached profile.json when they are logged out).
emit_row() {
  local n=$1 active=$2 auth label='' note='' age
  if [ "$n" = "$active" ]; then auth=$CX_AUTH; else auth="$CX_STORE/$n/auth.json"; fi
  if read_auth_identity "$auth"; then
    if [ "$ID_MODE" = unreadable ]; then
      note='auth.json unreadable'
    else
      label=$ID_EMAIL
      [ -z "$ID_PLAN" ] || label="$label  ($ID_PLAN)"
      if [ -n "$ID_LR" ]; then
        age=$(days_since "$ID_LR" || true)
        if [ -n "$age" ] && [ "$age" -gt "$STALE_AFTER_DAYS" ]; then note='may need re-login'; fi
      fi
    fi
  else
    label=$(get_profile_field "$n" email)
    note='logged out - log in after launch'
  fi
  printf '%s\037%s\037%s\037%s\n' "$n" "$([ "$n" = "$active" ] && echo 1 || echo 0)" "$label" "$note"
}

profile_rows() {
  local active d n
  active=$(get_active)
  {
    if [ -n "$active" ] && [ ! -d "$CX_STORE/$active" ]; then printf '%s\n' "$active"; fi
    for d in "$CX_STORE"/*/; do
      [ -d "$d" ] || continue
      n=${d%/}; printf '%s\n' "${n##*/}"
    done
  } | while IFS= read -r n; do emit_row "$n" "$active"; done
}

format_row() {  # <prefix> <name> <active> <label> <note>
  local line
  line=$(printf '%s%-12s' "$1" "$2")
  [ -z "$4" ] || line="$line  $4"
  [ -z "$5" ] || line="$line  [$5]"
  [ "$3" = 1 ] && line="$line  [active]" || true
  printf '%s\n' "$line"
}

# First-ever run: an existing login has no marker yet -> it becomes profile 'main'.
adopt_existing_login() {
  [ -z "$(get_active)" ] && [ -f "$CX_AUTH" ] || return 0
  mkdir -p "$CX_STORE/main"
  set_active main
  read_auth_identity "$CX_AUTH" || true
  save_profile_info main 0
  protect_store
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------

cmd_stop() {
  acquire_lock
  local n
  n=$(stop_codex)
  printf '%s\n' "${C_GREEN}Codex is stopped ($n process(es) closed: desktop app, CLI sessions, helpers).${C_OFF}"
}

cmd_status() {
  local active age flag
  active=$(get_active)
  printf '\n'
  printf 'CODEX_HOME : %s\n' "$CX_HOME"
  printf 'Profile    : %s\n' "${C_GREEN}${active:-(none)}${C_OFF}"
  if ! read_auth_identity "$CX_AUTH"; then
    printf 'Account    : %s\n' "${C_YELLOW}not logged in (no auth.json)${C_OFF}"
  elif [ "$ID_MODE" = unreadable ]; then
    printf 'Account    : %s\n' "${C_RED}auth.json exists but could not be parsed${C_OFF}"
  else
    printf 'Account    : %s\n' "$ID_EMAIL"
    [ -z "$ID_PLAN" ] || printf 'Plan       : %s\n' "$ID_PLAN"
    [ -z "$ID_ACCT" ] || printf 'Account id : %s\n' "$ID_ACCT"
    printf 'Auth mode  : %s\n' "$ID_MODE"
    if [ -n "$ID_LR" ]; then
      age=$(days_since "$ID_LR" || true)
      flag=''
      if [ -n "$age" ] && [ "$age" -gt "$STALE_AFTER_DAYS" ]; then
        flag='  (older than the refresh interval - Codex will refresh on next start)'
      fi
      printf 'Refreshed  : %s UTC, %s day(s) ago%s\n' \
        "$(TZ=UTC date -r "$(iso_epoch "$ID_LR")" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$ID_LR")" \
        "${age:-?}" "$flag"
    fi
  fi
  printf 'Codex app  : %s\n\n' "$([ -n "$CX_APP" ] && printf '%s' "installed ($CX_APP)" || printf '%s' 'not installed (CLI-only mode)')"
}

cmd_list() {
  local active rows n a label note
  active=$(get_active)
  printf '\nActive profile: %s\n' "${C_GREEN}${active:-(none)}${C_OFF}"
  printf '\nProfiles:\n'
  rows=$(profile_rows)
  if [ -z "$rows" ]; then
    printf '  (none yet - log in to Codex once, or run: codex-switch.sh <name>)\n'
  else
    while IFS=$'\037' read -r n a label note; do
      [ -n "$n" ] || continue
      format_row "  $([ "$a" = 1 ] && echo '* ' || echo '  ')" "$n" "$a" "$label" "$note"
    done <<<"$rows"
  fi
  printf '\nSwitch with:  ./codex-switch.sh <name>   (unknown name = new empty profile, log in after launch)\n\n'
}

cmd_menu() {
  local rows active n a label note i choice target names count
  while true; do
    rows=$(profile_rows)
    active=$(get_active)
    printf '\n%s\n' "${C_CYAN}=== codex-switch ===${C_OFF}"
    printf 'Active: '
    if [ -n "$rows" ] && awk -F'\037' '$2 == 1 { found = 1 } END { exit !found }' <<<"$rows"; then
      printf '%s\n' "${C_GREEN}$(awk -F'\037' '$2 == 1 { print $1 "  " $3; exit }' <<<"$rows")${C_OFF}"
    else
      printf '%s\n' "${C_GREEN}$([ -n "$active" ] && printf '%s' "$active (not logged in)" || printf '%s' '(none)')${C_OFF}"
    fi
    printf '\n'
    names=''
    i=0
    while IFS=$'\037' read -r n a label note; do
      [ -n "$n" ] || continue
      i=$((i + 1)); names="$names $n"
      format_row "$(printf '  %d) ' "$i")" "$n" "$a" "$label" "$note"
    done <<<"$rows"
    count=$i
    printf '  N) Add new profile (log in with another account)\n'
    printf '  Q) Quit\n\n'
    note '  Switching closes the Codex app and any codex CLI sessions (terminal / VS Code).'
    printf '\nSelect: '
    read -r choice || return 0

    case "$choice" in
      ''|[Qq]) return 0 ;;
      [Nn])
        printf 'New profile name: '
        read -r target || return 0
        if ! ( assert_valid_name "$target" ) 2>/dev/null; then
          printf '%s\n' "${C_RED}Invalid profile name '$target'. Use 1-64 characters: letters, digits, dot, dash, underscore.${C_OFF}"
          continue
        fi
        if printf '%s' " $names " | grep -q " $target "; then
          printf '%s\n' "${C_RED}Profile '$target' already exists - pick it from the list instead.${C_OFF}"
          continue
        fi
        ;;
      *[!0-9]*|'') printf '%s\n' "${C_RED}Invalid choice.${C_OFF}"; continue ;;
      *)
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
          printf '%s\n' "${C_RED}Invalid choice.${C_OFF}"; continue
        fi
        target=$(awk -F'\037' -v i="$choice" 'NR == i { print $1 }' <<<"$rows")
        ;;
    esac
    bash "$SELF" "$target"
    return 0
  done
}

# Switch = close Codex, move the live auth.json into the outgoing profile, move the target's in.
do_switch() {
  local target=$1 launch=$2
  local active stashed_name='' stashed_path='' dir dest src bak n who
  assert_valid_name "$target"
  acquire_lock
  assert_file_credential_store

  n=$(stop_codex)
  [ "$n" = 0 ] || note "[stop] closed $n Codex process(es)."

  active=$(get_active)
  if [ "$active" != "$target" ]; then
    # 1) Stash: move the live auth.json into the outgoing profile's folder.
    if [ -f "$CX_AUTH" ]; then
      [ -n "$active" ] || active=main
      dir="$CX_STORE/$active"; mkdir -p "$dir"; dest="$dir/auth.json"
      if [ -e "$dest" ]; then
        # Inconsistent state (a copy parked while the profile was active). Keep it as a dated
        # backup rather than guessing which one is the live token; the live file wins.
        bak="$dir/auth.json.bak-$(date '+%Y%m%d-%H%M%S')"
        mv "$dest" "$bak"
        warn "[stash] '$active' already had an auth.json; kept it as ${bak##*/}."
      fi
      read_auth_identity "$CX_AUTH" || true
      save_profile_info "$active" 0
      mv "$CX_AUTH" "$dest"
      stashed_name=$active; stashed_path=$dest
    elif [ -n "$active" ]; then
      # Logged out under this profile (codex logout, or never logged in). Nothing to stash.
      read_auth_identity "$CX_AUTH" || true
      save_profile_info "$active" 1
      warn "[stash] '$active' has no login to keep (logged out)."
    fi

    # 2) Activate: move the target's auth.json into place, or start an empty profile.
    dir="$CX_STORE/$target"; src="$dir/auth.json"; mkdir -p "$dir"
    if [ -f "$src" ]; then
      if ! mv "$src" "$CX_AUTH" 2>/dev/null; then
        # Activation failed: put the outgoing profile's credentials back so nobody is left
        # logged out.
        if [ -n "$stashed_name" ] && [ ! -e "$CX_AUTH" ] && [ -f "$stashed_path" ]; then
          mv "$stashed_path" "$CX_AUTH"
          set_active "$stashed_name"
          warn "[rollback] switch failed; restored '$stashed_name' as the active profile."
        fi
        die "Could not activate '$target': moving $src into place failed."
      fi
    else
      warn "[new profile] '$target' has no login yet - sign in with the other account when Codex opens."
      warn "              (If your browser is already signed in to ChatGPT, sign out there first or use a private window.)"
      save_profile_info "$target" 1
    fi
    set_active "$target"
  fi
  protect_store

  who=''
  if read_auth_identity "$CX_AUTH" && [ -n "$ID_EMAIL" ]; then who="  ($ID_EMAIL)"; fi
  printf '%s\n' "${C_GREEN}Active profile -> '$target'$who${C_OFF}"

  if [ "$launch" = 1 ]; then
    if [ -n "$CX_APP" ]; then
      printf '%s\n' "${C_GREEN}Launching Codex...${C_OFF}"
      launch_codex || warn "[launch] could not open $CX_APP - start Codex from Launchpad."
    else
      note "Codex desktop app not installed - run 'codex' in a terminal to use this account."
    fi
  fi
}

usage() {
  cat <<USAGE
codex-switch $SCRIPT_VERSION - switch ChatGPT accounts for Codex on macOS

  ./codex-switch.sh <name>              switch to <name>, then launch the Codex app
  ./codex-switch.sh <name> --no-launch  switch only (CLI users)
  ./codex-switch.sh --menu              interactive numbered menu
  ./codex-switch.sh --list              list profiles (e-mail / plan) and the active one
  ./codex-switch.sh --status            active account, auth mode, last token refresh
  ./codex-switch.sh --stop              fully close the Codex app + every codex process
  ./codex-switch.sh --version           print this copy's version

Switching to a name that doesn't exist creates an empty profile - log in after launch.
CODEX_HOME is honoured; the profile store then lives at <CODEX_HOME>-profiles.
USAGE
}

main() {
  local action='' target='' launch=1 arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help)      usage; return 0 ;;
      -v|--version)   printf 'codex-switch %s\n' "$SCRIPT_VERSION"; return 0 ;;
      -l|--list)      action=list ;;
      -s|--status)    action=status ;;
      -m|--menu)      action=menu ;;
      --stop)         action=stop ;;
      -n|--no-launch) launch=0 ;;
      -*)             die "Unknown option '$arg'. Run --help." ;;
      *)              [ -z "$target" ] || die "Only one profile name at a time."; target=$arg ;;
    esac
  done

  [ "$(uname -s)" = Darwin ] || die "codex-switch.sh is the macOS build. On Windows use codex-switch.ps1."

  resolve_paths
  mkdir -p "$CX_STORE"

  if [ "$action" = stop ]; then cmd_stop; return 0; fi

  adopt_existing_login

  case "$action" in
    status) cmd_status ;;
    menu)   cmd_menu ;;
    list)   cmd_list ;;
    *)      if [ -n "$target" ]; then do_switch "$target" "$launch"; else cmd_list; fi ;;
  esac
}

# Sourced with CODEX_SWITCH_LIB=1 by tools/test-codex-switch.sh, which exercises the functions
# above against a throwaway CODEX_HOME instead of a real one.
if [ "${CODEX_SWITCH_LIB:-}" = 1 ]; then return 0; fi

main "$@"
