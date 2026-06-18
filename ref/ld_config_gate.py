#!/usr/bin/env python3
"""Shared minimal structural gate for the life-dashboard ld-config.

This is the SINGLE definition of "installed" for the ld-config. BOTH
ref/install-skills.sh (the install-time + pre-cron gate) and ref/verify.sh
(the v-ld-config assertion) invoke it as:

    python3 ref/ld_config_gate.py <config.json>

so the structural contract lives in ONE place and install + verify can never
drift. It runs ON THE PI, where jq is deliberately not provisioned but python3
is guaranteed present on Debian — this replaces the jq filter both scripts used
to carry verbatim.

Contract (byte-identical to the jq gate it replaces — see ref/test_ld_config_gate.py
for the equivalence proof against jq):
  - Prints the failing invariant name(s) to stdout, joined by "; ".
  - Empty stdout == PASS. Never prints PII (the owner name / calendar account).
  - Prints exactly "not valid JSON" (and nothing else) when the file does not
    parse as JSON OR when the structure would make the jq filter itself error
    (indexing a non-object, or testing a non-string field) — jq's gate ran with
    `2>/dev/null || echo "not valid JSON"`, collapsing both into that one line.

The four checks, matching the original jq filter exactly:
  1. family.owner.name must contain a non-whitespace char  (jq: (.family.owner.name // "") | test("\\S"))
  2. calendar.sources must be a non-empty array            (jq: (type) == "array" and length >= 1)
  3. no calendar.sources[].account may be blank            (jq: select(((.account // "") | test("\\S")) | not))
  4. no string value anywhere may be a leftover placeholder (jq: .. | strings | test("^\\[[A-Z][A-Z0-9_]*\\]$"))
"""
import json
import re
import sys

_PLACEHOLDER_RE = re.compile(r"^\[[A-Z][A-Z0-9_]*\]$")
# jq's test("\\S") is PCRE \S (any non-whitespace); Python's \S is the same
# class, and re.search finds it anywhere in the string, matching jq's test().
_NONBLANK_RE = re.compile(r"\S")


class GateError(Exception):
    """A structural shape that would make the jq filter itself error.

    jq ran the gate as `jq -r '...' file 2>/dev/null || echo "not valid JSON"`,
    so a filter-level error (indexing a non-object with `.foo`, or applying
    test() to a non-string) collapsed to the same "not valid JSON" line as a
    JSON parse failure. We raise this for those shapes and map it identically.
    """


def _index(value, key):
    """jq `.key` — null/missing → null; non-object → error (caught as 'not valid JSON')."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(key)
    # jq errors on `.key` applied to a string/number/array/bool.
    raise GateError("cannot index non-object")


def _coalesce(value):
    """jq `value // ""` — null/false become ""; everything else passes through."""
    if value is None or value is False:
        return ""
    return value


def _test_nonblank(value):
    """jq `(value // "") | test("\\S")` — errors (caught) when value is non-string after //."""
    coalesced = _coalesce(value)
    if not isinstance(coalesced, str):
        # jq's test() raises on a number/object/array — collapses to 'not valid JSON'.
        raise GateError("test() on non-string")
    return bool(_NONBLANK_RE.search(coalesced))


def _all_strings(node):
    """jq `.. | strings` — every string reachable by recursive descent."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from _all_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _all_strings(v)


def gate(config):
    """Return the "; "-joined failures for a parsed config (empty == pass).

    Raises GateError for shapes the jq filter would have errored on; the caller
    maps that to "not valid JSON".
    """
    failures = []

    # 1. family.owner.name non-blank
    name = _index(_index(_index(config, "family"), "owner"), "name")
    if not _test_nonblank(name):
        failures.append("family.owner.name is blank")

    # 2. calendar.sources is a non-empty array
    sources = _index(_index(config, "calendar"), "sources")
    if not (isinstance(sources, list) and len(sources) >= 1):
        failures.append("calendar.sources is not a non-empty array")

    # 3. no calendar.sources[].account is blank. jq's `.calendar.sources[]?`
    #    iterates only when sources is an array; each element's `.account` errors
    #    if the element is not an object (caught as 'not valid JSON').
    if isinstance(sources, list):
        for src in sources:
            if not _test_nonblank(_index(src, "account")):
                failures.append("a calendar.sources[].account is blank")
                break

    # 4. no leftover [UPPER_SNAKE] placeholder anywhere
    if any(_PLACEHOLDER_RE.match(s) for s in _all_strings(config)):
        failures.append("an unfilled [UPPER_SNAKE] placeholder remains")

    return "; ".join(failures)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: ld_config_gate.py <config.json>\n")
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            config = json.load(f)
        failures = gate(config)
    except (OSError, ValueError, GateError):
        # jq's gate emitted "not valid JSON" on any read/parse/filter failure.
        print("not valid JSON")
        return 0
    if failures:
        print(failures)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
