#!/bin/bash
#
#   tools/test-codex-switch.sh  -  self-check for the macOS build
#
#   Exercises the parts that can lose a login if they are wrong: the switch itself (stash ->
#   activate), the rollback when activation fails, the id_token decode and name validation.
#   Everything runs against a throwaway CODEX_HOME; no Codex process is touched and no real
#   credential is read (stop_codex / launch_codex are stubbed after sourcing).
#
#   Run:  bash tools/test-codex-switch.sh

set -euo pipefail

cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/.codex"
mkdir -p "$CODEX_HOME"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A fake auth.json whose id_token carries readable claims. Not a credential: the signature is the
# literal "s" and the payload is plain base64url of the claims below.
make_auth() {  # <file> <email> <plan>
  local payload
  payload=$(printf '{"email":"%s","https://api.openai.com/auth":{"chatgpt_plan_type":"%s","chatgpt_account_id":"acct-123"}}' "$2" "$3" |
    base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<JSON
{
  "auth_mode": "chatgpt",
  "last_refresh": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "tokens": { "id_token": "h.$payload.s", "access_token": "a", "refresh_token": "r", "account_id": "acct-123" }
}
JSON
}

CODEX_SWITCH_LIB=1 . ./codex-switch.sh
stop_codex()   { printf '0'; }   # nothing is killed in a test run
launch_codex() { return 0; }
resolve_paths
mkdir -p "$CX_STORE"

# --- first run adopts the existing login, and reads the account out of the id_token -----------
make_auth "$CX_AUTH" me@gmail.com plus
adopt_existing_login
[ "$(get_active)" = main ]     || fail "first run should adopt the existing login as 'main'"
read_auth_identity "$CX_AUTH"
[ "$ID_EMAIL" = me@gmail.com ] || fail "id_token e-mail not decoded (got '$ID_EMAIL')"
[ "$ID_PLAN" = plus ]          || fail "plan not decoded (got '$ID_PLAN')"
[ "$ID_ACCT" = acct-123 ]      || fail "account id not decoded (got '$ID_ACCT')"

# --- switching to a new profile parks the login and leaves nothing live -----------------------
live_sum=$(shasum "$CX_AUTH" | cut -d' ' -f1)
( do_switch work 0 ) > /dev/null
[ ! -e "$CX_AUTH" ]                || fail "a new profile must leave no live auth.json"
[ -f "$CX_STORE/main/auth.json" ]  || fail "the outgoing login was not stashed"
[ "$(get_active)" = work ]         || fail "marker not updated"
grep -q '"email": "me@gmail.com"' "$CX_STORE/main/profile.json" || fail "profile.json kept no label"

# --- and back: the same bytes return, and exactly one copy exists ------------------------------
( do_switch main 0 ) > /dev/null
[ "$(shasum "$CX_AUTH" | cut -d' ' -f1)" = "$live_sum" ] || fail "auth.json changed across a round trip"
[ ! -e "$CX_STORE/main/auth.json" ] || fail "a copy was left behind: the active profile must hold none"
[ "$(get_active)" = main ]          || fail "marker not restored"

# --- a failed activation must put the previous login back --------------------------------------
make_auth "$CX_STORE/bad/auth.json" other@gmail.com pro
chmod 500 "$CX_STORE/bad"                       # mv cannot unlink out of a read-only directory
( do_switch bad 0 ) > /dev/null 2>&1 && fail "a failed activation should exit non-zero" || true
chmod 700 "$CX_STORE/bad"
[ -f "$CX_AUTH" ]                                        || fail "rollback did not restore the live auth.json"
[ "$(shasum "$CX_AUTH" | cut -d' ' -f1)" = "$live_sum" ] || fail "rollback restored the wrong file"
[ "$(get_active)" = main ]                               || fail "rollback did not restore the marker"
[ ! -e "$CX_LOCK" ]                                      || fail "the lock outlived a failed switch"

# --- a lock left by a run that was killed must not block the next one --------------------------
printf '%s' "$$" > "$CX_LOCK"                   # this shell is alive: a real operation in progress
( acquire_lock ) 2>/dev/null && fail "a lock held by a live run must be refused" || true
printf '99999999' > "$CX_LOCK"                  # an owner that cannot be alive: killed mid-run
( acquire_lock ) || fail "a lock from a killed run must be reclaimed"
rm -f "$CX_LOCK"

# --- a listing row keeps its fields even when the label is empty -------------------------------
mkdir -p "$CX_STORE/old"                      # a profile that was never logged in: no label, one note
row=$(emit_row old "$(get_active)")
[ "$(printf '%s' "$row" | awk -F'\037' '{ print $4 }')" = 'logged out - log in after launch' ] ||
  fail "an empty label shifted the row fields (row: $(printf '%s' "$row" | tr '\037' '|'))"

# --- names that would escape the store are refused ---------------------------------------------
for bad in '' . .. a/b 'has space' '../../etc' "$(printf 'x%.0s' $(seq 1 65))"; do
  if ( assert_valid_name "$bad" ) 2>/dev/null; then fail "accepted invalid profile name '$bad'"; fi
done

# --- a keyring credential store is refused instead of silently doing nothing --------------------
printf 'cli_auth_credentials_store = "keyring"\n' > "$CX_CONFIG"
( assert_file_credential_store ) 2>/dev/null && fail "keyring credential store should be refused" || true
printf 'cli_auth_credentials_store = "file"\n' > "$CX_CONFIG"
assert_file_credential_store || fail "the default file store must be accepted"

printf 'all checks passed\n'
