#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verification for
# seed-life-dashboard-hermes-agent (the four host-checkable structural prompts).

set -euo pipefail

# The shared ld-config gate, materialized under ref/team-skills/ld-shared by the
# ld-shared sync (homed in plow-pbc/life-dashboard-skills). install + verify call
# the SAME python3 gate so they can never drift (and the Pi needs no jq). verify
# runs AFTER install (which syncs ld-shared), so the file is present; if verify is
# run standalone before any install, fail loud rather than a confusing
# python file-not-found.
SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LD_CONFIG_GATE="$SEED_ROOT/ref/team-skills/ld-shared/scripts/ld_config_gate.py"
[ -f "$LD_CONFIG_GATE" ] \
  || { echo "FAIL: ld-config gate missing at $LD_CONFIG_GATE — ld-shared not synced. Run ref/install-skills.sh first (it syncs ld-shared)." >&2; exit 1; }

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

# ── v-ld-config: present, parses, passes the minimal structural gate. The gate
#    is the SHARED python3 ld-shared/scripts/ld_config_gate.py install-skills.sh
#    runs, so install + verify never drift (and the Pi needs no jq). The gate prints
#    "not valid JSON" on a parse failure and the failing invariant's name(s)
#    otherwise; PII never prints.
[ -f "$LD_CONFIG" ] || { echo "FAIL v-ld-config: $LD_CONFIG missing" >&2; exit 1; }
# mode 600 where stat supports it (GNU `-c`, BSD `-f`) — config is PII-bearing.
if _cmode=$(stat -c '%a' "$LD_CONFIG" 2>/dev/null || stat -f '%Lp' "$LD_CONFIG" 2>/dev/null); then
  [ "$_cmode" = "600" ] || { echo "FAIL v-ld-config: $LD_CONFIG not mode 600 (is $_cmode)" >&2; exit 1; }
fi
GATE=$(python3 "$LD_CONFIG_GATE" "$LD_CONFIG")
if [ "$GATE" = "not valid JSON" ]; then
  echo "FAIL v-ld-config: $LD_CONFIG is not valid JSON" >&2; exit 1
fi
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

# ── v-exec: every installed producer wrapper must carry the executable bit so
#    the documented "run the helper by absolute path" invocation works. install
#    copies skills with `cp -R` (mode-preserving), so a wrapper committed 100644
#    lands non-executable on the Pi and the direct exec below (and the real
#    producers) would hit `Permission denied` (exit 126). Assert +x on all of
#    them — this is the contract the executable-bit fix guarantees.
#    (ld-shared's post_to_kiosk.py is the imported helper module, not a
#    path-invoked producer, so it is excluded — it ships 100644 by design.)
shopt -s nullglob
declare -a wrappers=()
for w in "$SKILLS_DIR"/ld-*/scripts/post_*.py; do
  case "$w" in */ld-shared/*) continue ;; esac
  wrappers+=("$w")
done
shopt -u nullglob
[ "${#wrappers[@]}" -ge 1 ] \
  || { echo "FAIL v-exec: no producer wrappers found under $SKILLS_DIR" >&2; exit 1; }
for w in "${wrappers[@]}"; do
  [ -x "$w" ] || { echo "FAIL v-exec: $w is not executable (needs mode +x)" >&2; exit 1; }
done
echo "OK   v-exec (${#wrappers[@]} wrappers +x)"

# ── v-dry-run: invoke one installed wrapper with --dry-run + the DASHBOARD_*
#    env vars set, assert the redacted-body line. Proves the env resolves and
#    the wrapper executes; it does NOT post over the network. We run the
#    INSTALLED copy under data/skills/ so a broken install fails verify. The
#    executable-bit contract is asserted independently by v-exec above, so this
#    check rebinds the wrapper's handoff to an isolated mktemp input rather than
#    its hardcoded shared /tmp path (avoids clobbering a real producer's handoff
#    or failing on a foreign-owned pre-existing file). The endpoint/token here
#    are dummy values used only to satisfy the wrapper's read.
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
