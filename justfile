# Test runner for seed-life-dashboard-hermes-agent.
#
# This SEED owns source code (the ld-* producer skills) which carries the
# committed Python helper test. The `test` recipe runs:
#   - bash -n on the install + verify scripts
#   - py_compile on every ld-* Python file
#   - the ld-shared Python helper tests (post_to_kiosk shared module)
#
# The producers are LLM/connector-driven on Hermes — there is no Node
# scheduled-runner here (Hermes cron replaces it), so no JS tests.

test:
    # bash-parse checks first — fail fast on syntax errors.
    bash -n ref/install-skills.sh
    bash -n ref/verify.sh
    # py_compile every ld-* Python file (wrappers + shared helper).
    python3 -m py_compile $(find ref/team-skills -name '*.py')
    # The shared-helper test — the actual executable value this repo carries.
    python3 ref/team-skills/ld-shared/scripts/test_post_to_kiosk.py
