#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verification for
# seed-life-dashboard-hermes-agent (the four host-checkable structural prompts).

set -euo pipefail

SCAFFOLD_DIR="${HERMES_SCAFFOLD:-./hermes-agent}"
while [ $# -gt 0 ]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
DATA_DIR="${SCAFFOLD_DIR%/}/data"

ENV_FILE="${DATA_DIR%/}/.env"
LD_CONFIG="${DATA_DIR%/}/ld/config.json"
SKILLS_DIR="${DATA_DIR%/}/skills"

# ── v-secrets: DASHBOARD_ENDPOINT_URL + DASHBOARD_TOKEN present in data/.env,
#    well-shaped, checked WITHOUT printing either value. data/.env mode 600
#    where the host supports it.
[ -f "$ENV_FILE" ] || { echo "FAIL v-secrets: $ENV_FILE missing" >&2; exit 1; }
# Extract each value's RHS without echoing it: read the first matching line,
# strip the KEY= prefix. The values never reach a line we echo — we only test.
_ep=$(grep -m1 -E '^DASHBOARD_ENDPOINT_URL=' "$ENV_FILE" | sed 's/^DASHBOARD_ENDPOINT_URL=//') || true
_tok=$(grep -m1 -E '^DASHBOARD_TOKEN=' "$ENV_FILE" | sed 's/^DASHBOARD_TOKEN=//') || true
[ -n "$_ep" ]  || { echo "FAIL v-secrets: DASHBOARD_ENDPOINT_URL missing or empty in $ENV_FILE" >&2; exit 1; }
[ -n "$_tok" ] || { echo "FAIL v-secrets: DASHBOARD_TOKEN missing or empty in $ENV_FILE" >&2; exit 1; }
# mode 600 where stat supports it (GNU `-c`, BSD `-f`); skip silently if neither.
if _mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null); then
  [ "$_mode" = "600" ] || { echo "FAIL v-secrets: $ENV_FILE not mode 600 (is $_mode)" >&2; exit 1; }
fi
echo "OK   v-secrets"

# ── v-endpoint-shape / v-token-shape: whitespace-free; endpoint matches
#    http(s)://…/api/message. Never prints either value.
case "$_ep" in
  *[[:space:]]*) echo "FAIL v-endpoint-shape: DASHBOARD_ENDPOINT_URL contains whitespace" >&2; exit 1 ;;
esac
printf '%s' "$_ep" | grep -qE '^https?://[^[:space:]]+/api/message$' \
  || { echo "FAIL v-endpoint-shape: DASHBOARD_ENDPOINT_URL must be http(s)://…/api/message" >&2; exit 1; }
echo "OK   v-endpoint-shape"
case "$_tok" in
  *[[:space:]]*) echo "FAIL v-token-shape: DASHBOARD_TOKEN must be whitespace-free (RFC 6750 bearer)" >&2; exit 1 ;;
esac
echo "OK   v-token-shape"
unset _ep _tok

# ── v-ld-config: present, parses, passes the minimal structural gate. SAME gate
#    install-skills.sh enforces, so install + verify never drift. PII never
#    prints — only the failing invariant's name.
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
jq -e . "$LD_CONFIG" >/dev/null || { echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1; }
# mode 600 where stat supports it (GNU `-c`, BSD `-f`) — config is PII-bearing.
if _cmode=$(stat -c '%a' "$LD_CONFIG" 2>/dev/null || stat -f '%Lp' "$LD_CONFIG" 2>/dev/null); then
  [ "$_cmode" = "600" ] || { echo "FAIL v-ld-config: $LD_CONFIG not mode 600 (is $_cmode)" >&2; exit 1; }
fi
GATE=$(jq -r '
  [ if ((.family.owner.name    // "") | test("\\S")) then empty else "family.owner.name is blank" end,
    if ((.calendar.sources | type) == "array" and (.calendar.sources | length) >= 1)
      then empty else "calendar.sources is not a non-empty array" end,
    if ([.calendar.sources[]? | select(((.account // "") | test("\\S")) | not)] | length) == 0
      then empty else "a calendar.sources[].account is blank" end,
    if ([.. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$"))] | length) == 0
      then empty else "an unfilled [UPPER_SNAKE] placeholder remains" end
  ] | join("; ")
' "$LD_CONFIG")
if [ -n "$GATE" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG does not pass the install gate: $GATE" >&2
  echo "Fix the config (or re-run install with LD_OWNER_NAME set + Google linked in Plow — the calendar account is derived from the Plow Gmail connector) before verifying." >&2
  exit 1
fi
echo "OK   v-ld-config"

# ── v-skills: all seven ld-* markers present under data/skills/. ld-shared is a
#    helper module (no SKILL.md); the other six are full skills with SKILL.md.
declare -a probes=(
  "ld-shared/scripts/post_to_kiosk.py"
  "ld-calendar-nudge/SKILL.md"
  "ld-morning-triage/SKILL.md"
  "ld-morning-updates/SKILL.md"
  "ld-weekly-digest/SKILL.md"
  "ld-weather/SKILL.md"
  "ld-sports/SKILL.md"
)
[ -d "$SKILLS_DIR" ] || { echo "FAIL v-skills: $SKILLS_DIR missing" >&2; exit 1; }
for p in "${probes[@]}"; do
  [ -f "$SKILLS_DIR/$p" ] \
    || { echo "FAIL v-skills: $SKILLS_DIR/$p missing" >&2; exit 1; }
done
echo "OK   v-skills ($SKILLS_DIR)"

# ── v-dry-run: invoke one installed wrapper with --dry-run + the DASHBOARD_*
#    env vars set, assert the redacted-body line. Proves the env resolves and
#    the wrapper executes; it does NOT post over the network. We run the
#    INSTALLED copy under data/skills/ so a broken install fails verify. The
#    endpoint/token here are dummy values used only to satisfy the wrapper's
#    read — the real values stay in data/.env, never read or printed here.
WRAPPER="$SKILLS_DIR/ld-morning-updates/scripts/post_message.py"
[ -f "$WRAPPER" ] || { echo "FAIL v-dry-run: $WRAPPER missing" >&2; exit 1; }
DRY_INPUT=$(mktemp)
DRY_OUT=$(mktemp)
trap 'rm -f "$DRY_INPUT" "$DRY_OUT"' EXIT
echo "hello from verify" > "$DRY_INPUT"
DRY_RC=0
WRAPPER="$WRAPPER" DRY_INPUT="$DRY_INPUT" \
DASHBOARD_ENDPOINT_URL="http://verify.invalid/api/message" \
DASHBOARD_TOKEN="verify-dryrun-token" \
python3 - >"$DRY_OUT" 2>&1 <<'PY' || DRY_RC=$?
import os, sys, importlib.util
# Load a REAL wrapper so its CARD/BODY_TYPE assignments are load-bearing.
spec = importlib.util.spec_from_file_location("post_message", os.environ["WRAPPER"])
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)
ptk = wrapper.post_to_kiosk
# Rebind ONLY the message-text handoff path (the wrapper hardcodes /tmp/...);
# endpoint + token resolve from the DASHBOARD_* env vars above.
ptk.MESSAGE_FILE = os.environ["DRY_INPUT"]
sys.argv = ["post_message.py", "--dry-run"]
try:
    ptk.main()
except SystemExit as e:
    if e.code not in (None, 0):
        raise
PY
if [ "$DRY_RC" != "0" ]; then
  echo "FAIL v-dry-run: wrapper exited non-zero ($DRY_RC)" >&2
  head -20 "$DRY_OUT" >&2
  exit 1
fi
grep -qE '<redacted, [0-9]+ chars>' "$DRY_OUT" \
  || { echo "FAIL v-dry-run: no redacted-body output line in $DRY_OUT" >&2; head -20 "$DRY_OUT" >&2; exit 1; }
echo "OK   v-dry-run"

echo "tree conforms"
