# seed-life-dashboard-hermes-agent

## Purpose

A SEED that installs the seven `ld-*` "life-dashboard" producer skills into a
**seed-hermes Docker scaffold** and registers their schedules as Hermes cron
jobs:

- `ld-shared` — the shared `post_to_kiosk.py` POST helper (reads the kiosk
  endpoint + bearer from the `DASHBOARD_*` env vars) plus the
  `references/connectors.md` data-door convention all producers reuse.
- `ld-calendar-nudge` — half-hourly meeting reminders to the kiosk; messages
  the owner over Plow Chat when a meeting with other attendees is imminent.
- `ld-morning-triage` — daily morning priority alert (card 1), drawn from
  Gmail + Slack (Hermes is a container and cannot read iMessage).
- `ld-morning-updates` — daily morning affirmation (card 2).
- `ld-weekly-digest` — weekly calendar digest (card 4).
- `ld-weather` — daily weather card (card 3) from the National Weather Service.
- `ld-sports` — daily sports card (card 5) from ESPN's public scoreboard feed.

This repo is the source-of-truth for the seven `ld-*` skills — they live at
`ref/team-skills/` and are authored and fixed here. The install **copies** each
skill into `<scaffold>/data/skills/ld-*` (the container sees them at
`/opt/data/skills/ld-*`) and registers one `hermes cron` job per producer.

The producers read external data through the **plow-connectors** skill
installed by [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow)
— Google Calendar + Gmail + Slack through one helper, using the gateway's
existing Bearer token. That gateway also provides the `plow_chat` channel
`ld-calendar-nudge` notifies the owner over.

The producers need a `DASHBOARD_ENDPOINT_URL` (the full `/api/message` URL of
the household's Pi message API) + `DASHBOARD_TOKEN` (its bearer) to POST their
cards to. This SEED reads both from the environment and lands them in
`<scaffold>/data/.env` (mode 600) for the producers to consume from the
container environment.

**Required compatible viewer.** `ld-weather` (card 3) and `ld-sports` (card 5)
emit **self-contained HTML tiles** — each ships its own `<style>` — that the
viewer renders verbatim; the viewer carries no widget-specific CSS, so these
skills depend on the generic box-renderer
([`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer),
PR #40) and its shared theme tokens. Install/upgrade the viewer before (or
alongside) this SEED.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-hermes-agent`

The install is a **3-question install** — `LD_OWNER_NAME` (asked) plus the two
endpoint values the umbrella derives. The primary **calendar account is derived**
from the connected Plow Gmail connector (`plow_connector.py gmail status`), not
asked — so link Google to Plow first. With the inputs in the environment, the
install is one block:

```bash
export DASHBOARD_ENDPOINT_URL DASHBOARD_TOKEN LD_OWNER_NAME
bash ref/install-skills.sh --scaffold ./hermes-agent
```

It copies the `ld-*` skills into `data/skills/`, lands `DASHBOARD_*` into
`data/.env`, assembles `data/ld/config.json` from the owner name + the derived
calendar account, and registers the six producer crons (exec'd into the running
container; defer with `SKIP_CRON=1` and the umbrella runs them after
`docker compose up`).

The umbrella
[`seed-life-dashboard-hermes`](https://github.com/plow-pbc/seed-life-dashboard-hermes)
installs this SEED + its dependencies (`seed-hermes-plow`, the viewer,
durable-ssh) in one shot, minting `DASHBOARD_TOKEN` and deriving
`DASHBOARD_ENDPOINT_URL` before recursing into this SEED.

## License

MIT
