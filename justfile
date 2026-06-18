# Test runner for seed-life-dashboard-hermes-agent.
#
# This SEED owns six platform-specific ld-* producer skills (Python wrappers,
# LLM/connector-driven — Hermes cron replaces the Node scheduled-runner, so no
# JS tests). The shared ld-shared contract layer (post_to_kiosk + the wire/tile
# protocol + the ld-config template) lives in plow-pbc/life-dashboard-skills and
# is pulled here by ref/sync-ld-shared.sh, not vendored — so `test` syncs first.
# The recipe runs:
#   - bash -n on the install + verify + sync scripts
#   - py_compile on every ld-* Python file (wrappers + synced helper) + the
#     shared ld-config gate
#   - the shared ld-config gate's equivalence test (python3 gate == old jq gate)
#   - the shared post_to_kiosk helper tests (from the synced ld-shared)
#   - this seed's wrapper-contract test (each producer wrapper → right card)

test:
    # bash-parse checks first — fail fast on syntax errors.
    bash -n ref/install-skills.sh
    bash -n ref/verify.sh
    bash -n ref/sync-ld-shared.sh
    # Pull the shared contract layer (override the ref/source via
    # LD_SKILLS_REF / LD_SKILLS_REPO for dev/CI against an unmerged branch).
    bash ref/sync-ld-shared.sh
    # py_compile every ld-* Python file (wrappers + synced helper) + the gate.
    python3 -m py_compile ref/ld_config_gate.py $(find ref/team-skills -name '*.py')
    # The shared ld-config gate's equivalence test (matches the old jq gate
    # byte-for-byte; cross-checks against jq when present, spec-only on the Pi).
    python3 ref/test_ld_config_gate.py
    # Shared helper tests (both transports) + this seed's wrapper contracts.
    python3 ref/team-skills/ld-shared/scripts/test_post_to_kiosk.py
    python3 ref/team-skills/test_wrappers.py
