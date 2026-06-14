# Product context

This is a **SEED-convention repo**: `SEED.md` and `README.md` (RFC-2119
prose) are the authoritative artifacts; `ref/` is a single-operator
reference implementation of that prose. Review for **convention conformance
and prose↔ref drift**, not for product-scale hardening.

Operating point (org default):

- **Stage:** pre-PMF, early. Iteration speed > hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions,
  flags, parallel modes, and defensive edge-case handling sized for
  thousands of users are over-engineering here, not robustness.
- **Spec rigidity:** the SEED prose IS the contract; a handled edge case the
  spec never asked for is a cost, not a feature.

**This repo's `ref/` payload:** Bash install/verify harness plus the seven `ld-*` Hermes producer skills under `ref/team-skills/`. The skills are Python kiosk-POST wrappers over the shared `post_to_kiosk.py` helper (which reads the kiosk endpoint + bearer from the `DASHBOARD_*` env vars) plus RFC-2119 `SKILL.md` prose; the producers read Gmail / Google Calendar / Slack through the **plow-connectors door** (`ld-shared/references/connectors.md`), and `ld-calendar-nudge` notifies the owner over Plow Chat. The installer (`ref/install-skills.sh`) copies the skills into a seed-hermes scaffold's `data/skills/`, lands `data/.env` + `data/ld/config.json`, and registers one `hermes cron` job per producer. This repo is the source-of-truth for those skills — `ld-*` fixes land here.
