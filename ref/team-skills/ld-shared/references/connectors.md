# Data access on Hermes — the plow-connectors door

All ld- producers read external data through ONE helper installed by
seed-hermes-plow's install_connectors.sh:

    python3 /opt/data/skills/plow-connectors/plow_connector.py <connector> <action> '<json>'

- `<connector>` is `gmail` or `slack`. Google Calendar actions live under the
  `gmail` connector (`calendar.events.list`, `calendar.list`,
  `calendar.freebusy`).
- `status` is the only GET; every other action takes a JSON body.
- It authenticates with the gateway's existing bearer (PLOW_CONNECTOR_TOKEN
  else PLOW_CHAT_TOKEN) — there is nothing to log in to.
- A connector reporting `connected:false` is not linked; the producer SHOULD
  skip that source for this run (do not fail the whole card).

Producers MUST NOT assume iMessage access — Hermes is a container and cannot
read the Mac's Messages DB. The triage alert's human-message source is Gmail
+ Slack.
