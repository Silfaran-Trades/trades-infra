#!/usr/bin/env python3
"""AS-021 backstop: no High-risk ZAP alert on the scanned host passes unaccepted.

Run by `make dast-baseline` after `zap-baseline.py` (inside the same digest-pinned ZAP image,
so no host interpreter is involved), over the FULL JSON report the scan writes with `-J`.

Why this exists. zap-baseline.py's exit code is driven by the committed profile: a rule pinned
to FAIL exits 1, a rule pinned to WARN exits 2 — unless `-I` is passed, which the Makefile does
so the deliberately-noisy triage-only WARN lines stay report-only. Every rule NOT listed in
the profile defaults to WARN. So a High-risk alert from a rule the profile never enumerated
(a passive check ZAP ships in a future image, or an existing rule assessed High on this
target) would exit 0 like a clean scan. AS-021 says "HIGH findings block the release unless
accepted in decisions.md"; the profile's FAIL list enforces "these rules never regress",
which is not the same guarantee. This check closes the gap from the report itself:

  * every alert on the TARGET host (scheme://host[:port] of the URL that was scanned — the
    same scope the classic summary counts; alerts on other hosts the client spider's browser
    reached are reported, not gated) with `riskcode` >= 3 (High) fails the run,
  * unless the profile carries an `IGNORE` line for that rule id whose reason cites an ADR
    (`ADR-NNN`) or `decisions.md` — the acceptance AS-021 names. A WARN line never accepts a
    High; an OUTOFSCOPE line never accepts a High (it scopes the summary, it records no
    decision). An accepted High is printed with its citation, never silently dropped.

Fail-closed: a missing or unparsable report, or a report holding no site for the target,
exits 2 — absence of evidence is not a pass.

Exit codes: 0 no unaccepted High · 1 unaccepted High alert(s) · 2 usage / report error.

    check-zap-high-alerts.py --report security/reports/zap-baseline.json \
        --target https://api.example.com/api/health --profile security/zap-baseline.yaml
    check-zap-high-alerts.py --self-test     # in-memory fixtures: the gate observed failing
"""

import argparse
import json
import os
import re
import sys
from urllib.parse import urlsplit

HIGH = 3  # ZAP riskcode: 0 Informational, 1 Low, 2 Medium, 3 High
ACCEPTANCE_CITATION = re.compile(r"ADR-\d+|decisions\.md")
DEFAULT_PORTS = {"http": "80", "https": "443"}


def origin_of(url):
    """scheme://host[:port], default port dropped, lowercased — how a ZAP site is named."""
    parts = urlsplit(url.strip())
    if not parts.scheme or not parts.hostname:
        raise ValueError("not an absolute URL: %r" % url)
    scheme = parts.scheme.lower()
    host = parts.hostname.lower()
    port = str(parts.port) if parts.port else None
    if port and DEFAULT_PORTS.get(scheme) == port:
        port = None
    return "%s://%s%s" % (scheme, host, ":" + port if port else "")


def accepted_rules(profile_lines):
    """rule id -> reason, for every IGNORE line whose reason carries an ADR / decisions.md citation."""
    accepted = {}
    for line in profile_lines:
        if line.startswith("#") or not line.strip():
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 2 or cols[1] != "IGNORE":
            continue
        reason = "\t".join(cols[2:])
        if ACCEPTANCE_CITATION.search(reason):
            accepted[cols[0].strip()] = reason.strip()
    return accepted


def evaluate(report, target, profile_lines, out=sys.stdout):
    """Returns the exit code. `report` is the parsed JSON document, `profile_lines` the profile text."""
    try:
        origin = origin_of(target)
    except ValueError as exc:
        print("✗ %s" % exc, file=out)
        return 2

    sites = report.get("site") if isinstance(report, dict) else None
    if not isinstance(sites, list):
        print("✗ the report carries no `site` list — not a ZAP JSON report; refusing to pass", file=out)
        return 2

    target_sites = []
    for site in sites:
        try:
            if origin_of(site.get("@name", "")) == origin:
                target_sites.append(site)
        except ValueError:
            continue
    if not target_sites:
        print("✗ the report holds no site for %s — the scan did not reach the target; refusing to pass on absence" % origin, file=out)
        return 2

    accepted = accepted_rules(profile_lines)
    inspected = 0
    violations = []
    accepted_hits = []
    for site in target_sites:
        for alert in site.get("alerts", []) or []:
            inspected += 1
            try:
                risk = int(alert.get("riskcode", -1))
            except (TypeError, ValueError):
                risk = -1
            if risk < HIGH:
                continue
            rule = str(alert.get("pluginid", "?"))
            if rule in accepted:
                accepted_hits.append((rule, alert, accepted[rule]))
            else:
                violations.append((rule, alert))

    for rule, alert, reason in accepted_hits:
        print("ACCEPTED High [%s] %s — IGNORE line: %s" % (rule, alert.get("alert", "?"), reason), file=out)

    for rule, alert in violations:
        instances = alert.get("instances", []) or []
        print("✗ HIGH [%s] %s (%s) x %d on %s — not accepted: no IGNORE line citing an ADR / decisions.md in the profile"
              % (rule, alert.get("alert", "?"), alert.get("riskdesc", "?"), len(instances), origin), file=out)
        for inst in instances[:3]:
            print("\t%s" % inst.get("uri", "?"), file=out)

    if violations:
        print("→ AS-021 High backstop: FAIL — %d unaccepted High-risk rule(s) on %s (fix it, or accept it in decisions.md AND an IGNORE line)"
              % (len(violations), origin), file=out)
        return 1
    print("→ AS-021 High backstop: OK — %d alert(s) on %s inspected, %d High, %d accepted by an ADR-cited IGNORE line"
          % (inspected, origin, len(accepted_hits), len(accepted_hits)), file=out)
    return 0


def run(report_path, target, profile_path, out=sys.stdout):
    if not os.path.isfile(report_path):
        print("✗ report %s missing — zap-baseline.py wrote nothing; refusing to pass on absence" % report_path, file=out)
        return 2
    try:
        with open(report_path, encoding="utf-8") as fh:
            report = json.load(fh)
    except (OSError, ValueError) as exc:
        print("✗ report %s unreadable: %s" % (report_path, exc), file=out)
        return 2
    try:
        with open(profile_path, encoding="utf-8") as fh:
            profile_lines = fh.readlines()
    except OSError as exc:
        print("✗ profile %s unreadable: %s" % (profile_path, exc), file=out)
        return 2
    return evaluate(report, target, profile_lines, out=out)


# --- self-test: the gate observed failing, on every `make quality` --------------------------

def _report(*sites):
    return {"@programName": "ZAP", "site": list(sites)}


def _site(name, *alerts):
    return {"@name": name, "alerts": list(alerts)}


def _alert(rule, riskcode, name="Fixture alert", uris=("https://x/",)):
    return {"pluginid": rule, "riskcode": str(riskcode), "riskdesc": "High (High)" if riskcode == 3 else "Medium (High)",
            "alert": name, "instances": [{"uri": u} for u in uris]}


SELF_TEST_CASES = [
    # (description, report, target, profile lines, expected exit)
    ("High on the target, rule absent from the profile → FAIL",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test/api/health", [], 1),
    ("High on the target, rule pinned WARN → FAIL (WARN never accepts a High)",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test/", ["99999\tWARN\t(triage)\n"], 1),
    ("High on the target, IGNORE line WITHOUT an ADR / decisions.md citation → FAIL",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test/", ["99999\tIGNORE\t(noisy)\n"], 1),
    ("High on the target, IGNORE line citing an ADR → OK, printed as accepted",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test/", ["99999\tIGNORE\t(accepted — ADR-999)\n"], 0),
    ("High on the target, OUTOFSCOPE line only → FAIL (scope is not acceptance)",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test/", ["99999\tOUTOFSCOPE\t^https://api\\.\n"], 1),
    ("High on ANOTHER host in the same report, target clean → OK (target-origin scope)",
     _report(_site("https://app.trades.test", _alert("10038", 2)), _site("https://api.trades.test", _alert("99999", 3))),
     "https://app.trades.test/", [], 0),
    ("Only Medium/Low on the target → OK",
     _report(_site("https://api.trades.test", _alert("10038", 2), _alert("10037", 1))), "https://api.trades.test/api/health", [], 0),
    ("Target on a non-default port, site named with it → matched, High → FAIL",
     _report(_site("https://app.trades.test:8443", _alert("99999", 3))), "https://app.trades.test:8443/", [], 1),
    ("Default port spelled out in the target → still matched → FAIL",
     _report(_site("https://api.trades.test", _alert("99999", 3))), "https://api.trades.test:443/api/health", [], 1),
    ("Report holds no site for the target → error (fail-closed on absence)",
     _report(_site("https://api.trades.test", _alert("10038", 2))), "https://media.trades.test/", [], 2),
    ("Not a ZAP report (no `site` list) → error",
     {"hello": "world"}, "https://api.trades.test/", [], 2),
    ("Target is not an absolute URL → error",
     _report(_site("https://api.trades.test")), "api.trades.test", [], 2),
]


class _Sink:
    def write(self, _):
        pass


def self_test():
    failed = 0
    for description, report, target, profile_lines, expected in SELF_TEST_CASES:
        got = evaluate(report, target, profile_lines, out=_Sink())
        mark = "ok " if got == expected else "✗  "
        if got != expected:
            failed += 1
        print("%s exit %d (expected %d) — %s" % (mark, got, expected, description))
    # the missing-report path of run()
    got = run("/nonexistent/zap-baseline.json", "https://api.trades.test/", "/nonexistent/profile", out=_Sink())
    mark = "ok " if got == 2 else "✗  "
    if got != 2:
        failed += 1
    print("%s exit %d (expected 2) — report file missing → error (fail-closed on absence)" % (mark, got))
    total = len(SELF_TEST_CASES) + 1
    if failed:
        print("→ check-zap-high-alerts self-test: FAIL (%d of %d cases)" % (failed, total))
        return 1
    print("→ check-zap-high-alerts self-test: OK (%d cases; the gate fails where it must)" % total)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--report", help="the ZAP JSON report zap-baseline.py wrote with -J")
    parser.add_argument("--target", help="the URL that was scanned (its origin is the gated host)")
    parser.add_argument("--profile", help="the committed profile (security/zap-baseline.yaml)")
    parser.add_argument("--self-test", action="store_true", help="run the in-memory fixture cases and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not (args.report and args.target and args.profile):
        parser.print_usage()
        print("✗ --report, --target and --profile are all required")
        return 2
    return run(args.report, args.target, args.profile)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
