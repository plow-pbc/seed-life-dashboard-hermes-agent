#!/usr/bin/env bash
#
# seed-life-dashboard-hermes-agent — install the ld-* producer skills into a
# seed-hermes scaffold's data/skills/, land the kiosk endpoint+token into
# data/.env, assemble + land the household ld-config at data/ld/config.json,
# and register the producers' Hermes cron jobs.
#
# Curl/shell installer in the shape of seed-hermes-plow's install_connectors.sh:
# it does NOT call `hermes`, `git`, or a Python installer on the host — the only
# `hermes` invocations are `hermes cron ...` run INSIDE the container via
# `docker compose exec`. It does not start the container.
#
# Idempotent: re-running re-copies every skill, rewrites the two data/.env
# values, preserves a gate-passing operator-edited ld-config, and skips cron
# jobs that already exist. The ld-config is ASSEMBLED from the three operator
# inputs (LD_OWNER_NAME / LD_OWNER_IMESSAGE / LD_CALENDAR_ACCOUNT) on first
# install only.
#
# Input validation + ld-config write happen BEFORE the cron registration so no
# scheduled producer is activated until the runtime config + credentials it
# depends on are known-good.

set -euo pipefail

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
# The compose service the producers run in. The seed-hermes scaffold owns
# compose.yaml; its service name is not fixed by this SEED, so it is overridable.
HERMES_SERVICE="${HERMES_SERVICE:-hermes-agent}"

usage() {
  cat <<EOF
Usage: ref/install-skills.sh [--scaffold ./hermes-agent]

Installs the ld-* producer skills into <scaffold>/data/skills/, lands
data/.env (DASHBOARD_*) + data/ld/config.json, and registers the producers'
Hermes cron jobs (skip with SKIP_CRON=1; override the compose service with
HERMES_SERVICE=<name>).

Required env inputs (collected up front by the umbrella installer):
  DASHBOARD_ENDPOINT_URL  full /api/message URL of the Pi message API
  DASHBOARD_TOKEN         bearer the Pi message API validates
  LD_OWNER_NAME           household owner's display name
  LD_OWNER_IMESSAGE       owner's contact handle (E.164 phone or email)
  LD_CALENDAR_ACCOUNT     account owning the primary calendar
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

DATA_DIR="${SCAFFOLD_DIR%/}/data"

# 1. Required tools. No lsof/pgrep — there is no plowd port to discover.
for tool in jq python3; do
  command -v "$tool" >/dev/null \
    || { echo "missing required tool: $tool" >&2; exit 1; }
done

SEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SKILLS_SRC="$SEED_ROOT/ref/team-skills"
[ -d "$SKILLS_SRC" ] || { echo "no $SKILLS_SRC — incomplete checkout?" >&2; exit 1; }

# 2. Validate the two umbrella/operator-supplied endpoint inputs UPFRONT so a
#    malformed value aborts before anything is written. DASHBOARD_ENDPOINT_URL
#    is the FULL message-API URL (e.g. http://rpi5screen:5174/api/message) —
#    written verbatim, no path append. http:// is allowed: the Pi endpoint
#    rides the household LAN/tailnet.
ENDPOINT_URL="${DASHBOARD_ENDPOINT_URL:?DASHBOARD_ENDPOINT_URL not set — full /api/message URL of the Pi backend}"
: "${DASHBOARD_TOKEN:?DASHBOARD_TOKEN not set — bearer the Pi message API validates}"
case "$ENDPOINT_URL" in
  http://*|https://*) ;;
  *) echo "DASHBOARD_ENDPOINT_URL is not http(s)://" >&2; exit 1 ;;
esac
case "$ENDPOINT_URL" in
  */api/message) ;;
  *) echo "DASHBOARD_ENDPOINT_URL must be the FULL message-API URL ending in /api/message" >&2; exit 1 ;;
esac
# One shared rule: neither value may contain ANY whitespace (RFC 6750 bearer
# tokens and URLs are both whitespace-free; the :? guards reject empty).
case "$ENDPOINT_URL$DASHBOARD_TOKEN" in
  *[[:space:]]*) echo "DASHBOARD_ENDPOINT_URL/DASHBOARD_TOKEN must contain no whitespace" >&2; exit 1 ;;
esac

# 3. Copy every ld-* skill into <scaffold>/data/skills/. The container sees
#    them at /opt/data/skills/ld-* (the whole ./data:/opt/data mount).
SKILLS_DEST="${DATA_DIR%/}/skills"
mkdir -p "$SKILLS_DEST"
SKILL_NAMES="ld-shared ld-calendar-nudge ld-morning-triage ld-morning-updates ld-weekly-digest ld-weather ld-sports"
for skill in $SKILL_NAMES; do
  [ -d "$SKILLS_SRC/$skill" ] || { echo "missing skill: $skill" >&2; exit 1; }
done
for skill in $SKILL_NAMES; do
  rm -rf "${SKILLS_DEST:?}/$skill"
  cp -R "$SKILLS_SRC/$skill" "$SKILLS_DEST/$skill"
done

# 4. Land DASHBOARD_ENDPOINT_URL + DASHBOARD_TOKEN into data/.env (mode 600)
#    WITHOUT echoing either value. The producers read both from the container
#    environment. Update-in-place: strip any prior DASHBOARD_* lines, append
#    the current ones, then atomic-rename. Values flow through env into the
#    python writer's stdin region — never argv. We re-export the validated
#    $ENDPOINT_URL so the bytes written are the ones validation passed.
ENV_FILE="${DATA_DIR%/}/.env"
mkdir -p "$DATA_DIR"
ENV_TMP=$(mktemp "${DATA_DIR%/}/.env.XXXXXX")
# Preserve any non-DASHBOARD_* lines the gateway activation wrote (PLOW_CHAT_*).
if [ -f "$ENV_FILE" ]; then
  grep -v -E '^(DASHBOARD_ENDPOINT_URL|DASHBOARD_TOKEN)=' "$ENV_FILE" > "$ENV_TMP" || true
fi
DASHBOARD_ENDPOINT_URL="$ENDPOINT_URL" python3 - "$ENV_TMP" <<'PY'
import os, sys
# Append the two values read from the environment (never argv) to the env file.
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(f'DASHBOARD_ENDPOINT_URL={os.environ["DASHBOARD_ENDPOINT_URL"]}\n')
    f.write(f'DASHBOARD_TOKEN={os.environ["DASHBOARD_TOKEN"]}\n')
PY
chmod 600 "$ENV_TMP"
mv "$ENV_TMP" "$ENV_FILE"
# Clear the secrets from the environment after landing them — the ld-config
# assembly + cron child below have no use for these values.
unset DASHBOARD_ENDPOINT_URL DASHBOARD_TOKEN

# 5. Assemble + land ld-config from the three operator inputs on first install
#    ONLY; preserve a gate-passing operator-edited config on re-runs. A landed
#    file that still FAILS the gate is re-assembled. The gate is the SEED's
#    single definition of "installed" — install and ref/verify.sh share it.
LD_CONFIG_DIR="${DATA_DIR%/}/ld"
LD_CONFIG="$LD_CONFIG_DIR/config.json"
mkdir -p "$LD_CONFIG_DIR"

# The minimal structural gate, inline. Prints the failing invariant(s) (never
# the PII values) to stdout; empty output == PASS. Same checks ref/verify.sh's
# v-ld-config enforces, so install + verify never drift.
ld_config_gate() {  # ld_config_gate FILE -> prints failures (empty == pass)
  jq -r '
    [ if ((.family.owner.name     // "") | test("\\S")) then empty else "family.owner.name is blank" end,
      if ((.family.owner.imessage // "") | test("\\S")) then empty else "family.owner.imessage is blank" end,
      if ((.calendar.sources | type) == "array" and (.calendar.sources | length) >= 1)
        then empty else "calendar.sources is not a non-empty array" end,
      if ([.calendar.sources[]? | select(((.account // "") | test("\\S")) | not)] | length) == 0
        then empty else "a calendar.sources[].account is blank" end,
      if ([.. | strings | select(test("^\\[[A-Z][A-Z0-9_]*\\]$"))] | length) == 0
        then empty else "an unfilled [UPPER_SNAKE] placeholder remains" end
    ] | join("; ")
  ' "$1" 2>/dev/null || echo "not valid JSON"
}

NEED_ASSEMBLE=0
if [ ! -f "$LD_CONFIG" ]; then
  NEED_ASSEMBLE=1
elif [ -n "$(ld_config_gate "$LD_CONFIG")" ]; then
  NEED_ASSEMBLE=1
fi

if [ "$NEED_ASSEMBLE" = "1" ]; then
  # All three inputs are REQUIRED to assemble — a missing one fails loud
  # rather than landing a partial config.
  for v in LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT; do
    eval "val=\${$v:-}"
    case "$val" in
      *[![:space:]]*) ;;  # contains a non-whitespace char (matches the jq gate's \S)
      *) echo "$v is unset or blank — the installer must collect the three LD_* inputs before assembling ld-config" >&2; exit 1 ;;
    esac
  done

  # Timezone: honor a pre-exported LD_TIMEZONE; otherwise autodetect from
  # readlink /etc/localtime, falling back to America/Los_Angeles. Non-PII, so
  # it is the ONLY value passed to jq via --arg.
  if [ -z "${LD_TIMEZONE:-}" ]; then
    TZLINK=$(readlink /etc/localtime 2>/dev/null || true)
    case "$TZLINK" in
      */zoneinfo/*) LD_TIMEZONE=${TZLINK##*/zoneinfo/} ;;
      *) LD_TIMEZONE="" ;;
    esac
    [ -n "$LD_TIMEZONE" ] || LD_TIMEZONE="America/Los_Angeles"
  elif [ ! -f "/usr/share/zoneinfo/$LD_TIMEZONE" ]; then
    echo "LD_TIMEZONE '$LD_TIMEZONE' is not a valid IANA zone — fix the export and re-run." >&2
    exit 1
  fi

  # Assemble. The PII values (owner name/handle, calendar account) reach jq
  # ONLY through the environment, read inside the filter via the `env` builtin
  # — NEVER on argv. Only the non-PII timezone is passed via --arg.
  TMP=$(mktemp "$LD_CONFIG_DIR/.config.json.XXXXXX")
  LD_OWNER_NAME="$LD_OWNER_NAME" \
  LD_OWNER_IMESSAGE="$LD_OWNER_IMESSAGE" \
  LD_CALENDAR_ACCOUNT="$LD_CALENDAR_ACCOUNT" \
  jq -n --arg tz "$LD_TIMEZONE" '
    {
      family: { owner: { name: env.LD_OWNER_NAME, imessage: env.LD_OWNER_IMESSAGE }, timezone: $tz },
      calendar: { sources: [ { account: env.LD_CALENDAR_ACCOUNT, calendar_id: "primary", name: "Personal" } ] },
      morning_updates: { review_window_hours: 24 },
      weekly_digest: { length: "", long_lead: [] },
      morning_triage: { ranking_instructions: "", exclude: { slack_handles: [], email_addresses: [] } },
      calendar_nudge: { lookahead_virtual_minutes: 30, lookahead_in_person_minutes: 60 },
      weather: { location: "Mountain View", lat: 37.386, lon: -122.083 },
      sports: { followed: [
        { abbr: "sf", sport: "baseball", league: "mlb" },
        { abbr: "lad", sport: "baseball", league: "mlb" },
        { abbr: "gsw", sport: "basketball", league: "nba" }
      ] }
    }
  ' > "$TMP"
  chmod 600 "$TMP"
  FAILS=$(ld_config_gate "$TMP")
  if [ -n "$FAILS" ]; then
    rm -f "$TMP"
    echo "assembled ld-config did NOT pass the structural gate: $FAILS" >&2
    echo "NOT installed — no config landed." >&2
    exit 1
  fi
  mv "$TMP" "$LD_CONFIG"
  echo "ld-config assembled + landed at $LD_CONFIG (timezone: $LD_TIMEZONE)." >&2
else
  # Preserve path: a gate-passing operator-edited config is kept verbatim, but
  # re-assert mode 600 — it is PII-bearing and a prior run (or a manual edit)
  # could have left a looser mode that verify would otherwise let pass.
  chmod 600 "$LD_CONFIG"
fi

# The three operator inputs arrive EXPORTED in this script's environment. Clear
# them now — before the cron child below — so owner PII is not inherited.
unset LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT

# Pre-cron gate: refuse to register producer crons unless the landed config
# passes the structural gate. NAMES the failing invariant, never the PII.
FAILS=$(ld_config_gate "$LD_CONFIG")
if [ -n "$FAILS" ]; then
  echo "" >&2
  echo "ld-config at $LD_CONFIG does NOT pass the structural gate: $FAILS" >&2
  echo "NOT installed — crons NOT registered. Re-run with the three LD_* inputs set." >&2
  exit 1
fi

echo "" >&2
echo "Skills installed:" >&2
echo "  ld-* skills copied into $SKILLS_DEST/" >&2
echo "  DASHBOARD_ENDPOINT_URL, DASHBOARD_TOKEN landed in $ENV_FILE (mode 600)" >&2
echo "  ld-config resolved at $LD_CONFIG" >&2

# 6. Register the producers' Hermes cron jobs by execing into the running
#    container, one per producer, idempotently (check `hermes cron list`
#    first). Requires the container up. SKIP_CRON=1 makes the file-set path
#    testable without a running container (the umbrella runs the crons after
#    `docker compose up`). One job per producer; the schedule + prompt are the
#    per-skill SKILL.md § Scheduling values.
#
# job-name|schedule|prompt
CRON_JOBS='ld-morning-updates|0 7 * * *|Run the ld-morning-updates affirmation producer now: compose the morning affirmation and post it to the kiosk as card 2, type affirmation.
ld-morning-triage|5 7 * * *|Run the ld-morning-triage producer now: surface the one most-important unaddressed inbound across Gmail and Slack from the last 36h and post it to the kiosk as card 1, type alert.
ld-weather|0 6 * * *|Run the ld-weather producer now: fetch the forecast and post the self-contained weather HTML tile to the kiosk as card 3, type weather.
ld-sports|0 6 * * *|Run the ld-sports producer now: fetch results and post the self-contained sports HTML tile to the kiosk as card 5, type sports.
ld-weekly-digest|0 17 * * 0|Run the ld-weekly-digest producer now: compose the week-ahead digest and post it to the kiosk as card 4, type digest.
ld-calendar-nudge|20,50 * * * *|Run the ld-calendar-nudge producer now: if a meeting with other attendees starts within the lookahead window, post a kiosk reminder and message the owner over Plow Chat.'

if [ "${SKIP_CRON:-0}" = "1" ]; then
  echo "" >&2
  echo "SKIP_CRON=1 — skills + config + .env landed; crons NOT registered." >&2
  echo "Register them after the container is up (the umbrella does this):" >&2
  printf '%s\n' "$CRON_JOBS" | while IFS='|' read -r name sched prompt; do
    echo "  docker compose -f $SCAFFOLD_DIR/compose.yaml exec -T $HERMES_SERVICE hermes cron create '$sched' --prompt \"$prompt\"" >&2
  done
  exit 0
fi

command -v docker >/dev/null \
  || { echo "missing required tool: docker (needed to register crons; re-run with SKIP_CRON=1 to defer)" >&2; exit 1; }
COMPOSE="$SCAFFOLD_DIR/compose.yaml"
[ -f "$COMPOSE" ] || { echo "no compose.yaml at $COMPOSE — is the seed-hermes scaffold present?" >&2; exit 1; }

# Snapshot existing jobs once so we register each missing one idempotently. A
# failed `hermes cron list` must abort — an empty snapshot would silently
# re-register every job, duplicating crons. Each job name appears in its
# listed prompt as a discrete token, so dedup on a WORD match (grep -w), never
# a substring: a substring of a longer/stale job must not count as present.
EXISTING=$(docker compose -f "$COMPOSE" exec -T "$HERMES_SERVICE" hermes cron list) \
  || { echo "FAIL: 'hermes cron list' errored — refusing to register (would duplicate jobs)" >&2; exit 1; }
printf '%s\n' "$CRON_JOBS" | while IFS='|' read -r name sched prompt; do
  if printf '%s\n' "$EXISTING" | grep -qwF "$name"; then
    echo "  cron already present: $name" >&2; continue
  fi
  docker compose -f "$COMPOSE" exec -T "$HERMES_SERVICE" \
    hermes cron create "$sched" --prompt "$prompt" \
    || { echo "FAIL: could not register cron $name" >&2; exit 1; }
  echo "  cron registered: $name ($sched)" >&2
done

echo "" >&2
echo "All six producer crons registered (or already present)." >&2
