#!/bin/sh
# Behaviour tests for hsctl against a fake Headscale v0.29 API.
# Usage: test/run.sh [path/to/sh]   (default: /bin/sh; pass busybox/dash to cross-check)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HSCTL="$HERE/../hsctl"
SHELL_UNDER_TEST="${1:-/bin/sh}"
PORT=18765
TMP="$(mktemp -d)"
LOG="$TMP/requests.jsonl"
: > "$LOG"

python3 -I "$HERE/fake_headscale.py" "$PORT" "$LOG" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
i=0
until curl -s -o /dev/null "http://127.0.0.1:$PORT/"; do
	i=$((i + 1)); [ $i -gt 50 ] && { echo "fake server never came up"; exit 1; }
	sleep 0.1
done

export HS_URL="http://127.0.0.1:$PORT"
export XDG_CONFIG_HOME="$TMP/config"
unset HEADSCALE_API_KEY HS_USER 2>/dev/null || true

pass=0 fail=0
# Decide modes from what hsctl can actually see, not from whether HSCTL_PATH is set.
hsctl_has() { PATH="${HSCTL_PATH:-$PATH}" command -v "$1" >/dev/null 2>&1; }
if hsctl_has jq || hsctl_has python3; then DECODER=1; else DECODER=; fi
skip() { printf '  skip %s (%s)\n' "$1" "$2"; }
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
# hsctl is invoked through an external wrapper, never a shell function: in
# bash-as-sh and ksh, "VAR=x func" leaves VAR set after the call, which leaked
# HSCTL_BACKEND etc. into later tests. HSCTL_PATH restricts only hsctl's PATH
# (e.g. no jq/python3) while the harness keeps its own tools.
RUN="$TMP/run-hsctl"
cat > "$RUN" <<EOF
#!/bin/sh
PATH="\${HSCTL_PATH:-\$PATH}" exec "$SHELL_UNDER_TEST" "$HSCTL" "\$@"
EOF
chmod 755 "$RUN"
last_req() { tail -n 1 "$LOG"; }
req_field() { last_req | python3 -I -c "import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

echo "hsctl tests (shell: $SHELL_UNDER_TEST)"

# --- no credentials -------------------------------------------------------
out="$("$RUN" users list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'hsctl login' \
	&& ok "missing API key fails and points to 'hsctl login'" \
	|| bad "missing API key fails and points to 'hsctl login'" "rc=$rc out=$out"

# --- login rejects a bad key and does not save it --------------------------
out="$(printf 'wrong-key\n' | "$RUN" login 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ ! -f "$XDG_CONFIG_HOME/hsctl/apikey" ] \
	&& ok "login rejects a bad key without saving it" \
	|| bad "login rejects a bad key without saving it" "rc=$rc out=$out"

# --- login saves a good key with 600 perms ---------------------------------
out="$(printf 'test-api-key-123\n' | "$RUN" login 2>&1)"; rc=$?
perms="$(ls -l "$XDG_CONFIG_HOME/hsctl/apikey" 2>/dev/null | cut -c1-10)"
[ $rc -eq 0 ] && [ "$perms" = "-rw-------" ] \
	&& ok "login verifies and saves the key as 600" \
	|| bad "login verifies and saves the key as 600" "rc=$rc perms=$perms out=$out"

# --- the exact command the user tried, with a user NAME ---------------------
out="$("$RUN" preauthkeys create --user asik --reusable --expiration 90d 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$out" = "hskey-abcdef0123456789" ] \
	&& ok "create prints only the key on stdout" \
	|| bad "create prints only the key on stdout" "rc=$rc out=$out"
[ "$(req_field 'r["method"]+" "+r["path"]')" = "POST /api/v1/preauthkey" ] \
	&& ok "create POSTs /api/v1/preauthkey" || bad "create POSTs /api/v1/preauthkey" "$(last_req)"
[ "$(req_field 'r["body"]["user"]')" = "1" ] \
	&& ok "user name 'asik' resolved to numeric id 1" || bad "user name 'asik' resolved to numeric id 1" "$(last_req)"
[ "$(req_field 'r["body"]["reusable"]')" = "True" ] \
	&& ok "--reusable sent as JSON true" || bad "--reusable sent as JSON true" "$(last_req)"
[ "$(req_field 'r["auth"]')" = "Bearer test-api-key-123" ] \
	&& ok "saved key sent as Bearer token" || bad "saved key sent as Bearer token" "$(last_req)"

# expiration ~90 days out, RFC3339 UTC
delta="$(req_field '__import__("datetime").datetime.strptime(r["body"]["expiration"],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=__import__("datetime").timezone.utc).timestamp()-__import__("time").time()')"
python3 -I -c "import sys; d=float(sys.argv[1]); sys.exit(0 if abs(d-90*86400)<120 else 1)" "$delta" \
	&& ok "--expiration 90d becomes RFC3339 ~90 days ahead" \
	|| bad "--expiration 90d becomes RFC3339 ~90 days ahead" "delta=$delta $(last_req)"

# --- numeric user id passes straight through, no lookup ---------------------
before="$(wc -l < "$LOG")"
"$RUN" preauthkeys create --user 7 >/dev/null 2>&1
after="$(wc -l < "$LOG")"
[ $((after - before)) -eq 1 ] && [ "$(req_field 'r["body"]["user"]')" = "7" ] \
	&& ok "numeric --user skips the name lookup" \
	|| bad "numeric --user skips the name lookup" "requests=$((after - before)) $(last_req)"

# --- defaults: single-use, 1h, ephemeral flag, tags -------------------------
"$RUN" preauthkeys create --user asik --ephemeral --tags tag:router,tag:infra >/dev/null 2>&1
[ "$(req_field 'r["body"].get("reusable", False)')" = "False" ] \
	&& ok "reusable defaults to false (matches headscale CLI)" || bad "reusable defaults to false" "$(last_req)"
[ "$(req_field 'r["body"]["ephemeral"]')" = "True" ] \
	&& ok "--ephemeral sent" || bad "--ephemeral sent" "$(last_req)"
[ "$(req_field '",".join(r["body"]["aclTags"])')" = "tag:router,tag:infra" ] \
	&& ok "--tags split into aclTags array" || bad "--tags split into aclTags array" "$(last_req)"
delta="$(req_field '__import__("datetime").datetime.strptime(r["body"]["expiration"],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=__import__("datetime").timezone.utc).timestamp()-__import__("time").time()')"
python3 -I -c "import sys; d=float(sys.argv[1]); sys.exit(0 if abs(d-3600)<120 else 1)" "$delta" \
	&& ok "expiration defaults to 1h (matches headscale CLI)" || bad "expiration defaults to 1h" "delta=$delta"

# --- unknown user name is a clear error, no key request ---------------------
before="$(wc -l < "$LOG")"
out="$("$RUN" preauthkeys create --user nobody 2>&1)"; rc=$?
after="$(wc -l < "$LOG")"
[ $rc -ne 0 ] && echo "$out" | grep -q "nobody" && [ $((after - before)) -eq 1 ] \
	&& ok "unknown user fails before requesting a key" \
	|| bad "unknown user fails before requesting a key" "rc=$rc reqs=$((after - before)) out=$out"

# --- bad duration -----------------------------------------------------------
out="$("$RUN" preauthkeys create --user asik --expiration soon 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "duration" \
	&& ok "invalid --expiration rejected" || bad "invalid --expiration rejected" "rc=$rc out=$out"

# --- list / expire / nodes / users ------------------------------------------
out="$("$RUN" preauthkeys list 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "42" && echo "$out" | grep -q "asik" \
	&& ok "preauthkeys list shows id and user" || bad "preauthkeys list shows id and user" "rc=$rc out=$out"
# Columns: id user reusable ephemeral used expiration aclTags
row="$(echo "$out" | awk '$1 == "42" {print $3 "|" $4 "|" $5 "|" $6}')"
if [ -z "$DECODER" ]; then skip "preauthkeys list puts each value in its column" "raw JSON without jq/python3"
else [ "$row" = "true|false|false|2027-01-07T00:00:00Z" ] \
	&& ok "preauthkeys list puts each value in its column" \
	|| bad "preauthkeys list puts each value in its column" "row=$row out=$out"; fi

"$RUN" preauthkeys expire 42 >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(req_field 'r["method"]+" "+r["path"]+" "+str(r["body"]["id"])')" = "POST /api/v1/preauthkey/expire 42" ] \
	&& ok "preauthkeys expire <id> POSTs the id" || bad "preauthkeys expire <id> POSTs the id" "rc=$rc $(last_req)"

out="$("$RUN" nodes list 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "axt1800" && echo "$out" | grep -q "100.64.0.44" \
	&& ok "nodes list shows name and IP" || bad "nodes list shows name and IP" "rc=$rc out=$out"
# Columns: id givenName user ipAddresses online approvedRoutes
row="$(echo "$out" | awk '$2 == "nas" {print $5 "|" $6}')"
if [ -z "$DECODER" ]; then skip "false booleans print as 'false' and columns stay aligned" "raw JSON without jq/python3"
else [ "$row" = "false|10.0.0.90/32" ] \
	&& ok "false booleans print as 'false' and columns stay aligned" \
	|| bad "false booleans print as 'false' and columns stay aligned" "nas row online|routes=$row out=$out"; fi
row="$(echo "$out" | awk '$1 == "9" {print NF "|" $6}')"
if [ -z "$DECODER" ]; then skip "empty route list still fills its column" "raw JSON without jq/python3"
else [ "$row" = "6|-" ] && ok "empty route list still fills its column" \
	|| bad "empty route list still fills its column" "fields|routes=$row"; fi

out="$("$RUN" users list 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "asik" && echo "$out" | grep -q "guest" \
	&& ok "users list shows users" || bad "users list shows users" "rc=$rc out=$out"

# --- env var key overrides saved key ----------------------------------------
out="$(HEADSCALE_API_KEY=wrong-key "$RUN" users list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "401\|unauthor" \
	&& ok "HEADSCALE_API_KEY overrides saved key; 401 is reported" \
	|| bad "HEADSCALE_API_KEY overrides saved key; 401 is reported" "rc=$rc out=$out"

# --- API key never appears in curl's argv (visible in ps) --------------------
mkdir -p "$TMP/spybin"
cat > "$TMP/spybin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$TMP/curl_argv"
exec "$(command -v curl)" "\$@"
EOF
chmod 755 "$TMP/spybin/curl"
HSCTL_PATH="$TMP/spybin:${HSCTL_PATH:-$PATH}" "$RUN" users list >/dev/null 2>&1
if [ ! -s "$TMP/curl_argv" ]; then
	bad "API key is not passed in curl argv" "spy curl never ran"
elif grep -q 'test-api-key-123' "$TMP/curl_argv"; then
	bad "API key is not passed in curl argv" "$(cat "$TMP/curl_argv")"
else
	ok "API key is not passed in curl argv"
fi
grep -q 'test-api-key-123' "$HSCTL" && bad "key not hardcoded in script" || ok "key not hardcoded in script"

# --- unknown command ---------------------------------------------------------
out="$("$RUN" frobnicate 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "usage" \
	&& ok "unknown command prints usage and fails" || bad "unknown command prints usage and fails" "rc=$rc out=$out"

# ============================================================================
# Mint backend: scoped token for the Friday sidecar at /friday/mesh. Fresh
# config dir so no API key is present.
# ============================================================================
echo "mint backend"
export HEADSCALE_MINT_URL="http://127.0.0.1:$PORT/friday/mesh"
export XDG_CONFIG_HOME="$TMP/config-mint"

out="$(printf 'wrong-token\n' | "$RUN" login --mint 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ ! -f "$XDG_CONFIG_HOME/hsctl/minttoken" ] \
	&& ok "login --mint rejects a bad token without saving it" \
	|| bad "login --mint rejects a bad token without saving it" "rc=$rc out=$out"

out="$(printf 'test-mint-token-456\n' | "$RUN" login --mint 2>&1)"; rc=$?
perms="$(ls -l "$XDG_CONFIG_HOME/hsctl/minttoken" 2>/dev/null | cut -c1-10)"
[ $rc -eq 0 ] && [ "$perms" = "-rw-------" ] && [ ! -f "$XDG_CONFIG_HOME/hsctl/apikey" ] \
	&& ok "login --mint verifies and saves the token as 600" \
	|| bad "login --mint verifies and saves the token as 600" "rc=$rc perms=$perms out=$out"

out="$("$RUN" preauthkeys create --user asik --reusable --expiration 7d 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$out" = "hskey-mint-0011223344" ] \
	&& ok "mint create prints only the key" || bad "mint create prints only the key" "rc=$rc out=$out"
[ "$(req_field 'r["method"]+" "+r["path"]')" = "POST /friday/mesh/preauth" ] \
	&& ok "mint create POSTs /friday/mesh/preauth" || bad "mint create POSTs /friday/mesh/preauth" "$(last_req)"
[ "$(req_field 'r["body"]["expiration"]+" "+str(r["body"]["reusable"])')" = "7d True" ] \
	&& ok "mint create sends expiration and reusable" || bad "mint create sends expiration and reusable" "$(last_req)"
[ "$(req_field 'r["auth"]')" = "Bearer test-mint-token-456" ] \
	&& ok "mint token sent as Bearer" || bad "mint token sent as Bearer" "$(last_req)"

"$RUN" preauthkeys create >/dev/null 2>&1
[ "$(req_field 'r["body"]["expiration"]+" "+str(r["body"]["reusable"])')" = "1h False" ] \
	&& ok "mint create defaults to 1h single-use" || bad "mint create defaults to 1h single-use" "$(last_req)"

before="$(wc -l < "$LOG")"
out="$("$RUN" preauthkeys create --expiration 90d 2>&1)"; rc=$?
after="$(wc -l < "$LOG")"
[ $rc -ne 0 ] && echo "$out" | grep -q "7d" && echo "$out" | grep -q "apikey\|API key" && [ "$after" = "$before" ] \
	&& ok "mint rejects 90d locally, names the allowed values and the API key route" \
	|| bad "mint rejects 90d locally, names the allowed values and the API key route" "rc=$rc reqs=$((after - before)) out=$out"

for flag in "--ephemeral" "--tags tag:x" "--user guest"; do
	before="$(wc -l < "$LOG")"
	# shellcheck disable=SC2086
	out="$("$RUN" preauthkeys create $flag 2>&1)"; rc=$?
	after="$(wc -l < "$LOG")"
	[ $rc -ne 0 ] && [ "$after" = "$before" ] \
		&& ok "mint rejects '$flag' it cannot honour, before any request" \
		|| bad "mint rejects '$flag' it cannot honour, before any request" "rc=$rc reqs=$((after - before)) out=$out"
done

out="$("$RUN" nodes list 2>&1)"; rc=$?
esc="$(printf '\033')"
[ $rc -eq 0 ] && echo "$out" | grep -q "axt1800" && echo "$out" | grep -q '"quoted"' \
	&& [ "$(echo "$out" | wc -l | tr -d ' ')" -ge 3 ] && ! echo "$out" | grep -q "$esc" \
	&& ok "mint nodes list decodes newlines and quotes, strips ANSI" \
	|| bad "mint nodes list decodes newlines and quotes, strips ANSI" "rc=$rc out=$out"

"$RUN" register hskey-authreq-AbC_12-x >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(req_field 'r["path"]+" "+r["body"]["auth_id"]')" = "/friday/mesh/register hskey-authreq-AbC_12-x" ] \
	&& ok "register posts the auth id" || bad "register posts the auth id" "rc=$rc $(last_req)"

"$RUN" register "headscale auth register --auth-id hskeu-authreq-ZZ9 --user asik" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(req_field 'r["body"]["auth_id"]')" = "hskey-authreq-ZZ9" ] \
	&& ok "register extracts the id from a pasted command and fixes the hskeu- typo" \
	|| bad "register extracts the id from a pasted command and fixes the hskeu- typo" "rc=$rc $(last_req)"

before="$(wc -l < "$LOG")"
out="$("$RUN" register "no id here" 2>&1)"; rc=$?
after="$(wc -l < "$LOG")"
[ $rc -ne 0 ] && [ "$after" = "$before" ] \
	&& ok "register without an authreq id fails before any request" \
	|| bad "register without an authreq id fails before any request" "rc=$rc out=$out"

for c in "users list" "preauthkeys list" "preauthkeys expire 42"; do
	# shellcheck disable=SC2086
	out="$("$RUN" $c 2>&1)"; rc=$?
	[ $rc -ne 0 ] && echo "$out" | grep -q "API key" \
		&& ok "mint-only '$c' explains it needs an API key" \
		|| bad "mint-only '$c' explains it needs an API key" "rc=$rc out=$out"
done

: > "$TMP/curl_argv"
HSCTL_PATH="$TMP/spybin:${HSCTL_PATH:-$PATH}" "$RUN" nodes list >/dev/null 2>&1
if [ ! -s "$TMP/curl_argv" ]; then
	bad "mint token is not passed in curl argv" "spy curl never ran"
elif grep -q 'test-mint-token-456' "$TMP/curl_argv"; then
	bad "mint token is not passed in curl argv" "$(cat "$TMP/curl_argv")"
else
	ok "mint token is not passed in curl argv"
fi

# --- both configured: full API key wins, HSCTL_BACKEND forces either ----------
cp "$TMP/config/hsctl/apikey" "$XDG_CONFIG_HOME/hsctl/apikey"
"$RUN" preauthkeys create --user asik >/dev/null 2>&1
[ "$(req_field 'r["path"]')" = "/api/v1/preauthkey" ] \
	&& ok "with both credentials the API key is used" || bad "with both credentials the API key is used" "$(last_req)"
HSCTL_BACKEND=mint "$RUN" preauthkeys create >/dev/null 2>&1
[ "$(req_field 'r["path"]')" = "/friday/mesh/preauth" ] \
	&& ok "HSCTL_BACKEND=mint forces the mint" || bad "HSCTL_BACKEND=mint forces the mint" "$(last_req)"
out="$(HSCTL_BACKEND=bogus "$RUN" nodes list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "HSCTL_BACKEND" \
	&& ok "invalid HSCTL_BACKEND is rejected" || bad "invalid HSCTL_BACKEND is rejected" "rc=$rc out=$out"

# --- nothing configured names both login routes -------------------------------
out="$(XDG_CONFIG_HOME="$TMP/config-empty" "$RUN" nodes list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "^hsctl: no credentials;" \
	&& echo "$out" | grep -q "'hsctl login --mint'" && echo "$out" | grep -q "'hsctl login' (full API key)" \
	&& ok "no credentials points to both 'hsctl login --mint' and 'hsctl login'" \
	|| bad "no credentials points to both 'hsctl login --mint' and 'hsctl login'" "rc=$rc out=$out"

# ============================================================================
# Hardening (from the security audit)
# ============================================================================
echo "hardening"
export XDG_CONFIG_HOME="$TMP/config"   # holds the valid API key
CTRL="$(printf '\033\007')"
has_ctrl() { printf '%s' "$1" | grep -q "[$CTRL]"; }

# A newline in an env token must not become extra curl config directives
# (url/output/upload-file would let it write or exfiltrate files).
echo "victim-secret" > "$TMP/victim"
before="$(wc -l < "$LOG")"
nl='
'
out="$(HEADSCALE_API_KEY="abc${nl}upload-file = \"$TMP/victim\"${nl}output = \"$TMP/pwned\"" "$RUN" users list 2>&1)"; rc=$?
after="$(wc -l < "$LOG")"
[ $rc -ne 0 ] && [ "$after" = "$before" ] && [ ! -e "$TMP/pwned" ] && echo "$out" | grep -qi "unexpected characters" \
	&& ok "token with a newline is refused before curl runs" \
	|| bad "token with a newline is refused before curl runs" "rc=$rc reqs=$((after - before)) out=$out"

out="$(HEADSCALE_MINT_TOKEN='tok"en' HSCTL_BACKEND=mint "$RUN" nodes list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "unexpected characters" \
	&& ok "token with a quote is refused" || bad "token with a quote is refused" "rc=$rc out=$out"

before="$(wc -l < "$LOG")"
out="$(printf 'bad\\r\\nX: y\n' | XDG_CONFIG_HOME="$TMP/config-login" "$RUN" login 2>&1)"; rc=$?
after="$(wc -l < "$LOG")"
[ $rc -ne 0 ] && [ "$after" = "$before" ] && [ ! -e "$TMP/config-login/hsctl/apikey" ] \
	&& ok "login refuses and does not save a malformed credential" \
	|| bad "login refuses and does not save a malformed credential" "rc=$rc reqs=$((after - before)) out=$out"

# Credentials only go to https or loopback unless explicitly overridden.
out="$(HS_URL=http://hs.example.invalid "$RUN" users list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "non-https" \
	&& ok "plain-http URL is refused" || bad "plain-http URL is refused" "rc=$rc out=$out"
out="$(HS_URL=http://100.64.0.44 "$RUN" users list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "non-https" \
	&& ok "plain-http tailnet IP is refused too (CGNAT range is not proof of WireGuard)" \
	|| bad "plain-http tailnet IP is refused too" "rc=$rc out=$out"
out="$(HSCTL_ALLOW_HTTP=1 HS_URL=http://hs.example.invalid "$RUN" users list 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "cannot reach" \
	&& ok "HSCTL_ALLOW_HTTP=1 lets plain http through" || bad "HSCTL_ALLOW_HTTP=1 lets plain http through" "rc=$rc out=$out"

# The user's ~/.curlrc must not apply (trace-ascii would write the token to disk).
mkdir -p "$TMP/curlhome"
echo "trace-ascii = \"$TMP/trace.txt\"" > "$TMP/curlhome/.curlrc"
CURL_HOME="$TMP/curlhome" "$RUN" users list >/dev/null 2>&1
[ ! -e "$TMP/trace.txt" ] && ok "~/.curlrc is ignored" \
	|| bad "~/.curlrc is ignored" "trace written: $(grep -c Bearer "$TMP/trace.txt") Bearer lines"

# Server-controlled text (node names) must not carry terminal escapes.
out="$("$RUN" nodes list 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "axt1800" && echo "$out" | grep -q "evil" && ! has_ctrl "$out" \
	&& ok "api nodes list strips ESC/BEL from node names" \
	|| bad "api nodes list strips ESC/BEL from node names" "rc=$rc out=$(printf '%s' "$out" | od -c | head -3)"
out="$(HSCTL_BACKEND=mint HEADSCALE_MINT_TOKEN=test-mint-token-456 "$RUN" nodes list 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "evil" && ! has_ctrl "$out" \
	&& ok "mint nodes list strips OSC/BEL, not just colour codes" \
	|| bad "mint nodes list strips OSC/BEL, not just colour codes" "rc=$rc"
out="$(HSCTL_BACKEND=mint HEADSCALE_MINT_TOKEN=test-mint-token-456 "$RUN" nodes list 2>&1)"
[ "$(echo "$out" | wc -l | tr -d ' ')" -ge 4 ] \
	&& ok "sanitising keeps the newlines" || bad "sanitising keeps the newlines" "$out"

# Ctrl-C at the interactive login prompt must not leave terminal echo off.
out="$(XDG_CONFIG_HOME="$TMP/config-tty" python3 -I "$HERE/tty_interrupt.py" "$SHELL_UNDER_TEST" "$HSCTL" 2>&1)" \
	&& ok "Ctrl-C at the login prompt restores terminal echo" \
	|| bad "Ctrl-C at the login prompt restores terminal echo" "$out"

# Non-ASCII arrives as \uXXXX. jq/python decode it; the sed-only path (OpenWrt)
# cannot, so it must at least be unambiguous rather than look like raw JSON.
if [ -n "$DECODER" ]; then want='müller'; else want='m\[U+00[Ff][Cc]\]ller'; fi
out="$(HSCTL_BACKEND=mint HEADSCALE_MINT_TOKEN=test-mint-token-456 "$RUN" nodes list 2>&1)"
echo "$out" | grep -q "$want" && ! echo "$out" | grep -q 'u00fc' \
	&& ok "non-ASCII node names render (decoded, or [U+XXXX] without jq/python)" \
	|| bad "non-ASCII node names render (decoded, or [U+XXXX] without jq/python)" "want=$want out=$(echo "$out" | grep ller)"

echo
echo "passed: $pass  failed: $fail"
[ $fail -eq 0 ]
