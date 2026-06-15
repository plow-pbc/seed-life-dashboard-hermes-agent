# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

API / per-machine state:

- A **seed-hermes Docker scaffold** (a host `compose.yaml`, a whole `./data:/opt/data` mount, `HERMES_HOME=/opt/data` in the container) with the container running. The `plow_chat` gateway AND the `plow-connectors` skill from `https://github.com/plow-pbc/seed-hermes-plow` MUST be installed into that scaffold: the producers read Gmail / Google Calendar / Slack through the connectors skill, and `ld-calendar-nudge` notifies the owner over the chat gateway.
- The two env inputs `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` must be set before install (see [Requirements](#requirements)). They point at the household's Pi message API; this SEED does NOT deploy any relay — the umbrella SEED (`seed-life-dashboard-hermes`) derives and exports both values before recursing into this SEED.

Software:

- `https://github.com/plow-pbc/seed-hermes-plow` — provides the Docker Hermes scaffold, the `plow_chat` gateway (its activation lands `PLOW_CHAT_*` into the scaffold's `data/.env`), and the `plow-connectors` skill the producers read external data through (replaces `seed-plow-app`).
- `https://github.com/plow-pbc/seed-life-dashboard-viewer` — an HTML-capable kiosk viewer is a REQUIRED runtime. `ld-weather` (card 3) and `ld-sports` (card 5) post **self-contained HTML tiles** (each ships its own `<style>`) that the viewer renders verbatim; the viewer holds no widget CSS, so these skills depend only on the generic box-renderer (PR #40) and its shared theme tokens the producer styles reference. (The optional producer `title` field the alert/affirmation skills use to hide their eyebrows is viewer PR #43.) Installed against an older viewer that does not render card HTML, those two cards display literal markup tags — install/upgrade the viewer before this SEED.
- System tools: `curl`, `tar`, `jq`, `python3`, `docker` (the installer execs `hermes cron` inside the container via `docker compose exec`). No install needed.

### Requirements

This SEED's three operator-supplied values: two endpoint inputs and one household fact (`LD_OWNER_NAME`) it [assembles `config.json` from](#ld-config). All are `kind: input`, `phase: preflight` (collectible before install); the env-var name lives in `satisfy`. The installer unions all preflight inputs across the dependency tree and asks them ONCE up front — this SEED only DECLARES them. The **primary calendar account is DERIVED**, not asked: the installer reads it from the connected Plow Gmail connector (`plow_connector.py gmail status` → the default `.account`), so linking Google to Plow is the prerequisite — there is no `LD_CALENDAR_ACCOUNT` input. `family.timezone` is **autodetected** from the host (`readlink /etc/localtime` → IANA, fallback `America/Los_Angeles`) unless `LD_TIMEZONE` is already exported, in which case that value is used verbatim; it is therefore NOT an input.

`DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` are normally derived and exported by the umbrella SEED (`seed-life-dashboard-hermes`) before recursing into this SEED, so on an umbrella install they are never collected from the operator. On a standalone install they are collected as preflight inputs.

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| input | Full `/api/message` URL of the Pi message API (e.g. `http://rpi5screen:5174/api/message`) | preflight | `DASHBOARD_ENDPOINT_URL` | |
| input | Bearer the Pi message API validates | preflight | `DASHBOARD_TOKEN` | |
| input | Household owner's display name (how the dashboard refers to you) | preflight | `LD_OWNER_NAME` | |

The install target is the **seed-hermes scaffold dir**, supplied as `--scaffold <dir>` (default `./hermes-agent`); skills land under `<scaffold>/data/skills/`. Run the following block to install the skills, land the secrets + household config, and register the producer crons. All three inputs above MUST be in the environment when it runs, AND Google MUST be linked in Plow (the calendar account is derived from the connector) — on first install the script assembles `ld-config` from `LD_OWNER_NAME` + the derived account and exits non-zero if `LD_OWNER_NAME` is missing or the connector is unlinked. The block is idempotent: re-running re-copies every skill, rewrites the two `data/.env` values, preserves a gate-passing `ld-config`, and skips already-present cron jobs.

```bash
set -euo pipefail
export DASHBOARD_ENDPOINT_URL DASHBOARD_TOKEN LD_OWNER_NAME   # the three inputs from the Requirements above
# optional: `export LD_TIMEZONE=…` to override the host autodetect (see "ld-config is landed")
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-skills.sh" --scaffold ./hermes-agent
```

## Objects

### `ld-*` skills

- This repo is the **source-of-truth** for the seven `ld-*` producer skills — they live under `ref/team-skills/ld-*/` and are authored and fixed here. There is no upstream the copies track; a fix to producer behavior lands in this repo.
- The seven skill directories `ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest,weather,sports}/` are installed by **copy** into `<scaffold>/data/skills/ld-*`; the container sees them at `/opt/data/skills/ld-*`. `ld-shared` is the shared `post_to_kiosk.py` POST helper (plus the `connectors.md` data-door convention); the other six are full producer skills with a `SKILL.md`.

### Dashboard secrets

- `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` are written into `<scaffold>/data/.env` (mode 600). The Hermes container exports `data/.env` into the producer environment, so `ld-shared/scripts/post_to_kiosk.py` reads both from `os.environ`. Hermes has no per-agent secrets mount; the connectors skill reads its bearer from env the same way.
- **Env-loader runtime contract (deliberate assumption).** The producers read `DASHBOARD_*` (and `TZ`, per [Cron timezone](#cron-timezone)) from the *process environment*, which the Hermes runtime populates by loading the scaffold's `data/.env` into each gateway/cron session — the SAME mechanism the `plow-connectors` skill relies on to read `PLOW_CHAT_TOKEN`. This SEED does not re-load `data/.env` itself; it relies on that documented runtime contract. `ref/verify.sh`'s `v-dry-run` check exercises the wrapper with these vars injected directly, mirroring that environment so the wrapper's env-read path is exercised host-side without a running container.
  - `DASHBOARD_ENDPOINT_URL` — the FULL message-API URL (e.g. `http://rpi5screen:5174/api/message`). Written verbatim — no `/api/message` append. `http://` is allowed: the Pi endpoint rides the household LAN/tailnet.
  - `DASHBOARD_TOKEN` — the bearer the Pi message API validates. Written verbatim.
- Validation (performed BEFORE any write): both must be non-empty and **entirely whitespace-free** — one shared predicate — and `DASHBOARD_ENDPOINT_URL` must begin with `http://` or `https://` AND end with `/api/message` (fail-fast on the old base-URL shape). It MUST NOT contain URL **userinfo** (`scheme://user:pass@host/…`) — credentials in the URL would later surface in `post_to_kiosk.py --dry-run` / error output, so the installer rejects an `@` in the authority at the boundary (the single enforcement point; `post_to_kiosk.py` reads the already-validated value unchanged). `ref/verify.sh` re-asserts the same predicates post-install.

### Cron timezone

- **Hermes cron schedules fire in the container's timezone.** `hermes cron create '<sched>'` takes no per-job tz flag, so a schedule like `0 7 * * *` fires at 07:00 in whatever timezone the container's clock is set to — NOT automatically `family.timezone`. To make the two agree, the installer writes `TZ=<family.timezone>` into `<scaffold>/data/.env` (same mode-600 update-in-place mechanism as the `DASHBOARD_*` values), reading the value from the now-landed `ld-config`. The Hermes runtime loads `data/.env` into each gateway/cron session, so the container — and therefore cron + every producer it fires — runs in the household timezone. The producers ALSO key their own date windows off `family.timezone` read from the config (independent of `TZ`), so a producer computes correct local timestamps even before the container clock is considered; `TZ` is what aligns the *cron fire time* with that same zone.

### ld-config

- The household-state file at `<scaffold>/data/ld/config.json`, mode 600 (container path `/opt/data/ld/config.json`). Holds the family facts, calendar accounts, and per-skill prefs that every `ld-*` producer reads at its first invocation.
- On first install, the SEED ASSEMBLES this file from the declared [input](#requirements) (`LD_OWNER_NAME`) plus the **calendar account derived from the connected Plow Gmail connector** (the action's prose is in [ld-config is landed](#ld-config-is-landed)). It carries the **full canonical section shape** of the repo-local example (`ref/team-skills/ld-shared/references/config.example.json`) so every `ld-*` producer finds the section it reads on first run — `family.owner.name` + autodetected `family.timezone`, one `calendar.sources[0]` (`calendar_id: "primary"`), `morning_updates`, `weekly_digest` (`length: ""`, `long_lead: []`), `morning_triage` (`ranking_instructions: ""`, empty exclude lists), `calendar_nudge` (the example's real lookahead defaults), and `weather` / `sports` demo defaults from the example. Every `[UPPER_SNAKE]` placeholder is filled with a real empty/default value (the gate rejects bare placeholders); only the optional extras (partner, `people`, extra calendar sources, populated `long_lead`) are omitted. The `morning_triage.exclude` block carries `slack_handles` + `email_addresses` (Hermes triages Gmail + Slack, not iMessage). Single-parent / single-calendar is the default; an operator who wants more edits the landed file directly.
- Re-runs preserve an existing config that passes the structural gate — the operator's edits are canonical. The ONE exception: a landed file that still FAILS the gate (a corrupted edit) is re-assembled from the inputs through the same validation path.

## Actions

### Skills are installed

- The install action MUST copy every `ref/team-skills/ld-*` directory into `<scaffold>/data/skills/ld-*` (a plain recursive copy — there is no marketplace POST, no `plow-local-token`, and no atomic-swap-with-rollback over a plowd transaction). Re-running re-copies each skill in place.
- **Order matters:** [dashboard secrets are landed](#dashboard-secrets-are-landed) and [ld-config is landed](#ld-config-is-landed) MUST run BEFORE the producer crons are registered. Registering a producer before the runtime config + credentials it reads are present produces a quiet partial install — the producer runs but fails at its first scheduled tick.

### Dashboard secrets are landed

- The install action MUST read `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` from the environment (failing fast if either is absent or invalid) and write both into `<scaffold>/data/.env` at mode 600 via tempfile + atomic rename, **without echoing either value** — values flow through the environment and a tempfile, never on argv. Any prior `DASHBOARD_*` lines are stripped and the current ones appended, preserving other `data/.env` lines (e.g. the `PLOW_CHAT_*` the gateway activation wrote).
- `DASHBOARD_ENDPOINT_URL` is written VERBATIM — it is already the full `/api/message` URL; no path is appended.
- The install action MUST validate both inputs per the [Dashboard secrets](#dashboard-secrets) predicates BEFORE any write. A malformed input must fail fast — never land a partial install where producers run against unknown credentials.

### ld-config is landed

- On first install, the install action ASSEMBLES `<scaffold>/data/ld/config.json` (mode 600) from the declared [input](#requirements) plus the derived calendar account, and lands it via mktemp + rename inside the destination dir. The assembled JSON carries the **full canonical section shape** of the repo-local example so every producer finds the section it reads: `family.owner.name` from `LD_OWNER_NAME` + the autodetected `family.timezone`, one `calendar.sources` entry whose `account` is **DERIVED from the connected Plow Gmail connector** (`plow_connector.py gmail status` → the default `.account`) with `calendar_id: "primary"`, plus `morning_updates`, `weekly_digest` (empty `length` / `long_lead`), `morning_triage` (empty `ranking_instructions` / exclude lists), `calendar_nudge` (the example's real lookahead defaults), and `weather` / `sports` demo defaults from the example. Every value is a real default — no bare `[UPPER_SNAKE]` placeholders (the gate rejects them). The agent MAY express the assembly with a small inline `jq` filter; the [minimal structural gate](#minimal-structural-gate) is what MUST hold, not a specific command.
- **The primary calendar account is DERIVED, not asked.** Before assembling, the install action reads the connected default Gmail account from the Plow connector skill the umbrella (`seed-hermes-plow`) already landed: it sources `PLOW_CHAT_BASE_URL` + `PLOW_CONNECTOR_TOKEN` (else `PLOW_CHAT_TOKEN`) from `data/.env` (never echoing the token), runs `plow_connector.py gmail status`, and takes the top-level `.account` when `.connected` is true. If the connector skill is absent, the creds are missing, the call errors, or the status reports `connected:false` / no `.account`, the action FAILS LOUD non-zero with an actionable "link Google to Plow, then re-run" message — it MUST NOT fall back to a blank account. The derivation only runs when `ld-config` needs assembling (first install / failed-gate); a preserved gate-passing config keeps the operator's existing account.
- **family.timezone is autodetected from the host, not an input.** The IANA zone is everything after the last `/zoneinfo/` in `readlink /etc/localtime`, falling back to `America/Los_Angeles` when detection yields nothing — this is one inline `readlink` + parse. The ONE override: when `LD_TIMEZONE` is already exported, the installer uses that value verbatim (validating it is a real IANA zone) and skips the autodetect. The install is one-shot/non-interactive, so there is no targeted conflict confirmation — to set a non-host zone, export `LD_TIMEZONE` before the [install block](#requirements).
- **PII never leaks.** The owner name input and the derived calendar account are personal-context-secret. They MUST NOT be echoed to stdout, MUST NOT be written anywhere in the SEED tree, and MUST reach `jq` only **through the environment, read inside the filter via jq's `env` builtin — never `--arg`/argv**. The Plow connector token used to derive the account is likewise never echoed — it is passed to `plow_connector.py` through the environment. Only the non-PII `family.timezone` MAY be passed via `--arg`. The assembled config is JSON-validated AND run through the [minimal structural gate](#minimal-structural-gate) BEFORE the atomic `mv`; a blank input or a gate failure FAILS LOUD, non-zero, with nothing landed.
- Re-runs MUST NOT overwrite an existing config that PASSES the [minimal structural gate](#minimal-structural-gate). The ONE exception: when the existing file FAILS the gate, the action re-assembles from the inputs through the same validation path.
- After landing (or detecting a gate-passing existing) `ld-config`, the install action MUST gate the cron registration on the [minimal structural gate](#minimal-structural-gate). If the gate fails, the action MUST exit NON-ZERO with a loud "NOT installed" message BEFORE registering crons, NAMING the failing invariant (never the PII values). The [`ld-config` verify check](#verification) cross-checks the same gate at verify time. Single source of truth for "installed": `ld-config` passes the gate.

### minimal structural gate

- The structural gate is deliberately MINIMAL — it checks only the invariants that distinguish a USABLE filled config from an unedited template or a blank-filled one:
  - `family.owner.name` is present and **non-blank**.
  - `calendar.sources` is a **non-empty array**, and each source's `account` is **non-blank** (the derived Gmail account).
  - **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (whole-string anchored).
- The gate lives inline as a few `jq` lines in [`ref/verify.sh`](ref/verify.sh) (the `v-ld-config` check) and the same inline check in the install action. It does NOT re-check the autodetected timezone, and does NOT duplicate each producer's per-field runtime requirements.

### Producer crons are registered

- All six producer skills run as **Hermes cron jobs** — one per producer — created by the installer. There is no `plow-scheduled-runner` and no Plow `cron action=add`: `hermes cron` is host-drivable, so the installer registers each job directly by execing into the running container (`docker compose exec -T <service> hermes cron create '<schedule>' "<prompt>" --name '<job-name>' </dev/null`). The schedule + prompt for each job are the values in each skill's `SKILL.md § Scheduling`:
  - **`ld-morning-updates`** — `0 7 * * *`, posts the morning affirmation as card 2.
  - **`ld-morning-triage`** — `5 7 * * *`, posts the morning priority alert as card 1.
  - **`ld-weather`** — `0 6 * * *`, posts the weather tile as card 3.
  - **`ld-sports`** — `0 6 * * *`, posts the sports tile as card 5.
  - **`ld-weekly-digest`** — `0 17 * * 0`, posts the week-ahead digest as card 4.
  - **`ld-calendar-nudge`** — `20,50 * * * *`, posts a meeting reminder (card 1) + messages the owner over Plow Chat when a meeting qualifies.
- Registration is idempotent: the installer checks `hermes cron list` and skips a job that already exists. It requires the container to be up; when it is not (or `SKIP_CRON=1` is set), the installer prints the exact `docker compose exec … hermes cron create …` lines for the operator — the umbrella runs them after `docker compose up`.

## Verification

1. **Dashboard secrets present and well-shaped.** Does `<scaffold>/data/.env` contain `DASHBOARD_ENDPOINT_URL` matching `http(s)://…/api/message` and `DASHBOARD_TOKEN` as a bare RFC 6750 bearer — both whitespace-free — with `data/.env` mode 600 where the host supports it, checked WITHOUT printing either value? Expected: yes.
2. **ld-config present, well-formed, mode 600, and passes the structural gate.** Does `<scaffold>/data/ld/config.json` exist, parse as JSON, sit at mode 600 (where the host supports it; it is PII-bearing), AND pass the [minimal structural gate](#minimal-structural-gate)? The assembled file carries the full canonical section shape (`family`, `calendar`, `morning_updates`, `weekly_digest`, `morning_triage`, `calendar_nudge`, `weather`, `sports`) with empty/default values, not just `family` + `calendar`. Expected: yes — a gate-passing config is the SEED's single source of truth for "install complete." The timezone is NOT re-checked here. The values are PII, so only the check name prints.
3. **Skills installed.** Do all seven `ld-*` markers exist under `<scaffold>/data/skills/` — each producer's `SKILL.md` (or, for `ld-shared`, `scripts/post_to_kiosk.py`)? Expected: yes.
4. **Endpoint+token are syntactically usable.** Does one of the bundled `post_*.py` wrappers invoked with `--dry-run` and the two `DASHBOARD_*` env vars set produce a redacted-body output line (proving the env resolves and the wrapper executes)? Expected: yes.

A deterministic bash implementation of checks 1–4 lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **Bundled vs registry-pulled.** The skills' source lives in this repo; v1 ships them by copying into the scaffold's `data/skills/`. A signed-skill registry would replace the copy step eventually (the source would still live here). v2 candidate.

## Non-Goals

- Not Hermes itself — that's [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow).
- Not macOS-only. Runs wherever the seed-hermes Docker scaffold runs (Linux or macOS).
- Not a signed-skill registry pull. Copying the `ld-*` sources into `data/skills/` is the v1 delivery mechanism.
