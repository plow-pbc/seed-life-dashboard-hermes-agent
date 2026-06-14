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

This SEED's five operator-supplied values: two endpoint inputs and three household facts it [assembles `config.json` from](#ld-config). All are `kind: input`, `phase: preflight` (collectible before install); the env-var name lives in `satisfy`. The installer unions all preflight inputs across the dependency tree and asks them ONCE up front — this SEED only DECLARES them. `family.timezone` is **autodetected** from the host (`readlink /etc/localtime` → IANA, fallback `America/Los_Angeles`) unless `LD_TIMEZONE` is already exported, in which case that value is used verbatim; it is therefore NOT an input.

`DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` are normally derived and exported by the umbrella SEED (`seed-life-dashboard-hermes`) before recursing into this SEED, so on an umbrella install they are never collected from the operator. On a standalone install they are collected as preflight inputs.

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| input | Full `/api/message` URL of the Pi message API (e.g. `http://rpi5screen:5174/api/message`) | preflight | `DASHBOARD_ENDPOINT_URL` | |
| input | Bearer the Pi message API validates | preflight | `DASHBOARD_TOKEN` | |
| input | Household owner's display name (how the dashboard refers to you) | preflight | `LD_OWNER_NAME` | |
| input | Owner's contact handle — an E.164 phone (`+15551234567`) or an email address | preflight | `LD_OWNER_IMESSAGE` | |
| input | Account that owns the primary calendar (e.g. `sam@example.com`) | preflight | `LD_CALENDAR_ACCOUNT` | |

The install target is the **seed-hermes scaffold dir**, supplied as `--scaffold <dir>` (default `./hermes-agent`); skills land under `<scaffold>/data/skills/`. Run the following block to install the skills, land the secrets + household config, and register the producer crons. All five inputs above MUST be in the environment when it runs — on first install the script assembles `ld-config` from them and exits non-zero if any is missing. The block is idempotent: re-running re-copies every skill, rewrites the two `data/.env` values, preserves a gate-passing `ld-config`, and skips already-present cron jobs.

```bash
set -euo pipefail
export DASHBOARD_ENDPOINT_URL DASHBOARD_TOKEN LD_OWNER_NAME LD_OWNER_IMESSAGE LD_CALENDAR_ACCOUNT   # all five from the Requirements above
# optional: `export LD_TIMEZONE=…` to override the host autodetect (see "ld-config is landed")
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install-skills.sh" --scaffold ./hermes-agent
```

## Objects

### `ld-*` skills

- This repo is the **source-of-truth** for the seven `ld-*` producer skills — they live under `ref/team-skills/ld-*/` and are authored and fixed here. There is no upstream the copies track; a fix to producer behavior lands in this repo.
- The seven skill directories `ld-{calendar-nudge,morning-triage,morning-updates,shared,weekly-digest,weather,sports}/` are installed by **copy** into `<scaffold>/data/skills/ld-*`; the container sees them at `/opt/data/skills/ld-*`. `ld-shared` is the shared `post_to_kiosk.py` POST helper (plus the `connectors.md` data-door convention); the other six are full producer skills with a `SKILL.md`.

### Dashboard secrets

- `DASHBOARD_ENDPOINT_URL` and `DASHBOARD_TOKEN` are written into `<scaffold>/data/.env` (mode 600). The Hermes container exports `data/.env` into the producer environment, so `ld-shared/scripts/post_to_kiosk.py` reads both from `os.environ`. Hermes has no per-agent secrets mount; the connectors skill reads its bearer from env the same way.
  - `DASHBOARD_ENDPOINT_URL` — the FULL message-API URL (e.g. `http://rpi5screen:5174/api/message`). Written verbatim — no `/api/message` append. `http://` is allowed: the Pi endpoint rides the household LAN/tailnet.
  - `DASHBOARD_TOKEN` — the bearer the Pi message API validates. Written verbatim.
- Validation (performed BEFORE any write): both must be non-empty and **entirely whitespace-free** — one shared predicate — and `DASHBOARD_ENDPOINT_URL` must begin with `http://` or `https://` AND end with `/api/message` (fail-fast on the old base-URL shape). `ref/verify.sh` re-asserts the same predicates post-install.

### ld-config

- The household-state file at `<scaffold>/data/ld/config.json`, mode 600 (container path `/opt/data/ld/config.json`). Holds the family facts, calendar accounts, and per-skill prefs that every `ld-*` producer reads at its first invocation.
- On first install, the SEED ASSEMBLES this file from the declared [inputs](#requirements) (the action's prose is in [ld-config is landed](#ld-config-is-landed)). It mirrors the shape of the repo-local example (`ref/team-skills/ld-shared/references/config.example.json`) — `family.owner.{name,imessage}`, an autodetected `family.timezone`, one `calendar.sources[0]` (`calendar_id: "primary"`), and real defaults for the `calendar_nudge` lookaheads — with every `[UPPER_SNAKE]` placeholder filled and optional sections (partner, extra calendars, long-lead) omitted. The `morning_triage.exclude` block carries `slack_handles` + `email_addresses` (Hermes triages Gmail + Slack, not iMessage). Single-parent / single-calendar is the default; an operator who wants more edits the landed file directly.
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

- On first install, the install action ASSEMBLES `<scaffold>/data/ld/config.json` (mode 600) from the declared [inputs](#requirements) and lands it via mktemp + rename inside the destination dir. The assembled JSON mirrors the repo-local example's shape: `family.owner.{name,imessage}` from `LD_OWNER_NAME` / `LD_OWNER_IMESSAGE`, one `calendar.sources` entry with `account` from `LD_CALENDAR_ACCOUNT` and `calendar_id: "primary"`, the autodetected `family.timezone`, and the example's real `calendar_nudge` lookahead defaults. The agent MAY express the assembly with a small inline `jq` filter; the [minimal structural gate](#minimal-structural-gate) is what MUST hold, not a specific command.
- **family.timezone is autodetected from the host, not an input.** The IANA zone is everything after the last `/zoneinfo/` in `readlink /etc/localtime`, falling back to `America/Los_Angeles` when detection yields nothing — this is one inline `readlink` + parse. The ONE override: when `LD_TIMEZONE` is already exported, the installer uses that value verbatim (validating it is a real IANA zone) and skips the autodetect. The install is one-shot/non-interactive, so there is no targeted conflict confirmation — to set a non-host zone, export `LD_TIMEZONE` before the [install block](#requirements).
- **PII never leaks.** The operator inputs (owner name/handle, calendar account) are personal-context-secret. They MUST NOT be echoed to stdout, MUST NOT be written anywhere in the SEED tree, and MUST reach `jq` only **through the environment, read inside the filter via jq's `env` builtin — never `--arg`/argv**. Only the non-PII `family.timezone` MAY be passed via `--arg`. The assembled config is JSON-validated AND run through the [minimal structural gate](#minimal-structural-gate) BEFORE the atomic `mv`; a blank input or a gate failure FAILS LOUD, non-zero, with nothing landed.
- Re-runs MUST NOT overwrite an existing config that PASSES the [minimal structural gate](#minimal-structural-gate). The ONE exception: when the existing file FAILS the gate, the action re-assembles from the inputs through the same validation path.
- After landing (or detecting a gate-passing existing) `ld-config`, the install action MUST gate the cron registration on the [minimal structural gate](#minimal-structural-gate). If the gate fails, the action MUST exit NON-ZERO with a loud "NOT installed" message BEFORE registering crons, NAMING the failing invariant (never the PII values). The [`ld-config` verify check](#verification) cross-checks the same gate at verify time. Single source of truth for "installed": `ld-config` passes the gate.

### minimal structural gate

- The structural gate is deliberately MINIMAL — it checks only the invariants that distinguish a USABLE filled config from an unedited template or a blank-filled one:
  - `family.owner.{name,imessage}` are present and **non-blank**.
  - `calendar.sources` is a **non-empty array**, and each source's `account` is **non-blank**.
  - **No string value is left as a bare `[UPPER_SNAKE]` placeholder** (whole-string anchored).
- The gate lives inline as a few `jq` lines in [`ref/verify.sh`](ref/verify.sh) (the `v-ld-config` check) and the same inline check in the install action. It does NOT re-check the autodetected timezone, and does NOT duplicate each producer's per-field runtime requirements.

### Producer crons are registered

- All six producer skills run as **Hermes cron jobs** — one per producer — created by the installer. There is no `plow-scheduled-runner` and no Plow `cron action=add`: `hermes cron` is host-drivable, so the installer registers each job directly by execing into the running container (`docker compose exec -T <service> hermes cron create '<schedule>' --prompt "<prompt>"`). The schedule + prompt for each job are the values in each skill's `SKILL.md § Scheduling`:
  - **`ld-morning-updates`** — `0 7 * * *`, posts the morning affirmation as card 2.
  - **`ld-morning-triage`** — `5 7 * * *`, posts the morning priority alert as card 1.
  - **`ld-weather`** — `0 6 * * *`, posts the weather tile as card 3.
  - **`ld-sports`** — `0 6 * * *`, posts the sports tile as card 5.
  - **`ld-weekly-digest`** — `0 17 * * 0`, posts the week-ahead digest as card 4.
  - **`ld-calendar-nudge`** — `20,50 * * * *`, posts a meeting reminder (card 1) + messages the owner over Plow Chat when a meeting qualifies.
- Registration is idempotent: the installer checks `hermes cron list` and skips a job that already exists. It requires the container to be up; when it is not (or `SKIP_CRON=1` is set), the installer prints the exact `docker compose exec … hermes cron create …` lines for the operator — the umbrella runs them after `docker compose up`.

## Verification

1. **Dashboard secrets present and well-shaped.** Does `<scaffold>/data/.env` contain `DASHBOARD_ENDPOINT_URL` matching `http(s)://…/api/message` and `DASHBOARD_TOKEN` as a bare RFC 6750 bearer — both whitespace-free — with `data/.env` mode 600 where the host supports it, checked WITHOUT printing either value? Expected: yes.
2. **ld-config present, well-formed, mode 600, and passes the structural gate.** Does `<scaffold>/data/ld/config.json` exist, parse as JSON, sit at mode 600 (where the host supports it; it is PII-bearing), AND pass the [minimal structural gate](#minimal-structural-gate)? Expected: yes — a gate-passing config is the SEED's single source of truth for "install complete." The timezone is NOT re-checked here. The values are PII, so only the check name prints.
3. **Skills installed.** Do all seven `ld-*` markers exist under `<scaffold>/data/skills/` — each producer's `SKILL.md` (or, for `ld-shared`, `scripts/post_to_kiosk.py`)? Expected: yes.
4. **Endpoint+token are syntactically usable.** Does one of the bundled `post_*.py` wrappers invoked with `--dry-run` and the two `DASHBOARD_*` env vars set produce a redacted-body output line (proving the env resolves and the wrapper executes)? Expected: yes.

A deterministic bash implementation of checks 1–4 lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **Hermes compose service name + `hermes cron list` field form — to be confirmed against a live scaffold.** The seed-hermes scaffold owns `compose.yaml`; its service name is not fixed by this SEED, so the installer takes it from `HERMES_SERVICE` (default `hermes-agent`). The installer's idempotency dedups on a word-exact match of each job name against `hermes cron list`, failing loud if that list call errors; the live service name and the exact `hermes cron list` field layout are to be confirmed against a live scaffold's output. The file-set + config + `.env` path is testable independently with `SKIP_CRON=1`.
- **Bundled vs registry-pulled.** The skills' source lives in this repo; v1 ships them by copying into the scaffold's `data/skills/`. A signed-skill registry would replace the copy step eventually (the source would still live here). v2 candidate.

## Non-Goals

- Not Hermes itself — that's [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow).
- Not macOS-only. Runs wherever the seed-hermes Docker scaffold runs (Linux or macOS).
- Not a signed-skill registry pull. Copying the `ld-*` sources into `data/skills/` is the v1 delivery mechanism.
