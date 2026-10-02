#!/usr/bin/env python3
"""check-tf-plan.py — AC-1 of production-infrastructure-first-deploy, asserted mechanically.

Reads `terraform show -json <saved plan>` (the HUMAN saves the plan and its JSON locally —
SC-013: never uploaded anywhere) and fails on anything the first apply must not contain:

  1. every resource the plan creates or updates is named with the project prefix — the
     name-bearing attribute per resource type (`name`, `bucket`, `alarm_name`, `function_name`,
     `tags.Name`) starts with `trades-` or `trades/`;
  2. a budget (`aws_budgets_budget`) is present — with the host, in the same plan (IA-007);
  3. no Cost Explorer anomaly monitor / subscription (`aws_ce_anomaly_*`) — KHA's is the
     account's one (BR-9);
  4. no `EstimatedCharges` billing alarm (BR-9);
  5. no OIDC provider (`aws_iam_openid_connect_provider`) and no CI role — no role whose name
     carries `ci-` / `-ci` / `github` (BR-2, BR-24);
  6. no Route 53 zone or record (BR-22);
  7. no `kha-energy` string anywhere — EXCEPT (a) inside an IAM policy statement whose Effect
     is Deny: the boundary's HandsOffSibling statement must name the sibling to deny it
     (TM-1); and (b) the declared `sibling_project` variable itself, which exists to feed
     that Deny — its value in the plan's top-level `variables` map and its declaration
     (default / description) in the `configuration` section's variable blocks. Every other
     section a real `terraform show -json` emits is scanned: `planned_values`,
     `resource_changes`, `output_changes`, `prior_state` and `configuration` (a literal
     `constant_value` or a module-call argument carrying the name is a finding);
  8. every tagged resource carries `project = trades` (tags_all) — the budget filter and the
     HandsOffSibling boundary both key on it (IA-008).

Usage:
  terraform -chdir=terraform/environments/production show -json production.tfplan > production.tfplan.json
  scripts/checks/check-tf-plan.py production.tfplan.json
  scripts/checks/check-tf-plan.py --self-test        # the in-memory fixtures (part of `make quality`)

Standard library only; exit 0 = pass, 1 = findings, 2 = unreadable input.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, Iterable, List, Tuple

PROJECT = "trades"
SIBLING = "kha-energy"
SIBLING_VARIABLE = "sibling_project"   # the one root/module variable allowed to carry the name
NAME_PREFIXES = (f"{PROJECT}-", f"{PROJECT}/")
# The sections of `terraform show -json` scanned for the sibling's name besides planned_values.
PLAN_SECTIONS = ("variables", "output_changes", "resource_changes", "prior_state", "configuration")

# The attribute that names a resource of each type; a type absent here has no global name to
# check (route-table associations, lifecycle configurations, attachments, …).
NAME_ATTRIBUTES: Dict[str, str] = {
    "aws_iam_role": "name",
    "aws_iam_policy": "name",
    "aws_iam_instance_profile": "name",
    "aws_iam_role_policy": "name",
    "aws_ecr_repository": "name",
    "aws_s3_bucket": "bucket",
    "aws_sns_topic": "name",
    "aws_budgets_budget": "name",
    "aws_security_group": "name",
    "aws_cloudwatch_metric_alarm": "alarm_name",
    "aws_lambda_function": "function_name",
}
CI_ROLE_MARKERS = ("ci-", "-ci", "github", "oidc")


def walk_resources(plan: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    """Every resource under planned_values (root module and every child module)."""
    def walk(module: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
        for res in module.get("resources", []) or []:
            yield res
        for child in module.get("child_modules", []) or []:
            yield from walk(child)
    root = (plan.get("planned_values") or {}).get("root_module") or {}
    yield from walk(root)


def iter_strings(node: Any) -> Iterable[str]:
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from iter_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_strings(v)


def sibling_mentions(node: Any, path: Tuple[str, ...] = ()) -> Iterable[str]:
    """Every string under `node` carrying the sibling's name, skipping the declared
    `sibling_project` variable wherever a `variables` map holds it: the plan's top-level
    `variables` (`{"sibling_project": {"value": "kha-energy"}}`) and every `variables` block
    of `configuration` (root module and module calls, with `default` / `description`)."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == SIBLING_VARIABLE and path and path[-1] == "variables":
                continue
            yield from sibling_mentions(value, path + (key,))
    elif isinstance(node, list):
        for value in node:
            yield from sibling_mentions(value, path)
    elif isinstance(node, str) and SIBLING in node:
        yield node


def sibling_outside_deny(value: str) -> bool:
    """True when `value` carries the sibling's name anywhere but inside a Deny statement of an
    IAM policy document it encodes."""
    if SIBLING not in value:
        return False
    try:
        doc = json.loads(value)
    except (ValueError, TypeError):
        return True  # not a policy document — any occurrence is a finding
    if not isinstance(doc, dict) or "Statement" not in doc:
        return True
    statements = doc["Statement"]
    if isinstance(statements, dict):
        statements = [statements]
    for st in statements:
        if not isinstance(st, dict):
            return True
        text = json.dumps(st)
        if SIBLING in text and st.get("Effect") != "Deny":
            return True
    return False


def check(plan: Dict[str, Any]) -> List[str]:
    findings: List[str] = []
    resources = list(walk_resources(plan))
    if not resources:
        findings.append("the plan declares no resources at all (wrong file? an empty plan?)")
        return findings

    types = [r.get("type", "") for r in resources]
    if "aws_budgets_budget" not in types:
        findings.append("no aws_budgets_budget in the plan — the budget must ship in the same apply as the host (IA-007, BR-8)")
    for r in resources:
        t = r.get("type", "")
        addr = r.get("address", "?")
        values = r.get("values") or {}
        if t.startswith("aws_ce_anomaly"):
            findings.append(f"{addr}: a Cost Explorer anomaly resource — the account's monitor is KHA's (BR-9)")
        if t == "aws_cloudwatch_metric_alarm" and values.get("metric_name") == "EstimatedCharges":
            findings.append(f"{addr}: an EstimatedCharges billing alarm — KHA's account-wide alarm already covers this spend (BR-9)")
        if t == "aws_iam_openid_connect_provider":
            findings.append(f"{addr}: an OIDC provider — no CI role in stage 1, and the account's provider is KHA's (BR-2, BR-24)")
        if t == "aws_iam_role":
            name = str(values.get("name", "")).lower()
            if any(marker in name for marker in CI_ROLE_MARKERS):
                findings.append(f"{addr}: role {name!r} looks like a CI role — none exists in stage 1 (BR-24)")
        if t.startswith("aws_route53"):
            findings.append(f"{addr}: a Route 53 resource — the DNS module is the 10.9 go-live's (BR-22)")
        attr = NAME_ATTRIBUTES.get(t)
        if attr:
            name = values.get(attr)
            if isinstance(name, str) and not name.startswith(NAME_PREFIXES):
                findings.append(f"{addr}: {attr}={name!r} does not carry the {PROJECT}- / {PROJECT}/ prefix (BR-1)")
        tags = values.get("tags") or {}
        if isinstance(tags, dict) and isinstance(tags.get("Name"), str) and not tags["Name"].startswith(NAME_PREFIXES):
            findings.append(f"{addr}: tags.Name={tags['Name']!r} does not carry the {PROJECT}- prefix (BR-1)")
        tags_all = values.get("tags_all")
        if isinstance(tags_all, dict) and tags_all and tags_all.get("project") != PROJECT:
            findings.append(f"{addr}: tags_all.project={tags_all.get('project')!r}, expected {PROJECT!r} (IA-008; the budget filter keys on it)")
        for s in iter_strings(values):
            if sibling_outside_deny(s):
                findings.append(f"{addr}: carries {SIBLING!r} outside a Deny statement (BR-2)")
                break
    # the sibling's name anywhere else in the plan: the variables map (minus the declared
    # sibling variable), the outputs, the change set, the prior state and the configuration
    for section in PLAN_SECTIONS:
        for s in sibling_mentions(plan.get(section) or {}, (section,)):
            if sibling_outside_deny(s):
                findings.append(f"{section}: carries {SIBLING!r} outside a Deny statement and outside the {SIBLING_VARIABLE} variable (BR-2)")
                break
    return findings


# --- the self-test (observed failing on every run, not once) ----------------------------------

def _plan(resources: List[Dict[str, Any]]) -> Dict[str, Any]:
    return {"format_version": "1.2", "planned_values": {"root_module": {"resources": [], "child_modules": [{"address": "module.x", "resources": resources}]}}}


def _res(t: str, rname: str, **values: Any) -> Dict[str, Any]:
    v: Dict[str, Any] = {"tags_all": {"project": PROJECT, "environment": "production", "managed-by": "terraform"}}
    v.update(values)
    return {"address": f"module.x.{t}.{rname}", "type": t, "name": rname, "values": v}


def _real_shaped_plan(resources: List[Dict[str, Any]], **sections: Any) -> Dict[str, Any]:
    """A plan shaped like real `terraform show -json` output of this root (format 1.2): the
    top-level `variables` map carrying `sibling_project = kha-energy`, `planned_values` with
    outputs, `resource_changes` mirroring the planned values, `output_changes`, an empty
    `prior_state` (a first apply) and a `configuration` section whose variable blocks declare
    `sibling_project` (default + description) and whose module call references it."""
    plan: Dict[str, Any] = {
        "format_version": "1.2",
        "terraform_version": "1.14.1",
        "variables": {
            "project": {"value": PROJECT},
            "region": {"value": "eu-south-2"},
            "sibling_project": {"value": SIBLING},
        },
        "planned_values": {
            "outputs": {"registry": {"sensitive": False, "type": "string", "value": "123456789012.dkr.ecr.eu-south-2.amazonaws.com"}},
            "root_module": {"resources": [], "child_modules": [{"address": "module.x", "resources": resources}]},
        },
        "resource_changes": [
            {"address": r["address"], "module_address": "module.x", "mode": "managed", "type": r["type"], "name": r["name"],
             "provider_name": "registry.terraform.io/hashicorp/aws",
             "change": {"actions": ["create"], "before": None, "after": r["values"], "after_unknown": {"id": True}, "before_sensitive": False, "after_sensitive": {}}}
            for r in resources
        ],
        "output_changes": {"registry": {"actions": ["create"], "before": None, "after": "123456789012.dkr.ecr.eu-south-2.amazonaws.com", "after_unknown": False, "before_sensitive": False, "after_sensitive": False}},
        "prior_state": {"format_version": "1.0", "terraform_version": "1.14.1", "values": {"root_module": {}}},
        "configuration": {
            "provider_config": {"aws": {"name": "aws", "full_name": "registry.terraform.io/hashicorp/aws", "expressions": {"region": {"references": ["var.region"]}}}},
            "root_module": {
                "variables": {
                    "project": {"default": PROJECT},
                    "sibling_project": {"default": SIBLING, "description": "The other project sharing this account; every principal here carries a Deny on its resources (BR-2, TM-1)"},
                },
                "module_calls": {
                    "x": {
                        "source": "../../modules/access",
                        "expressions": {"sibling_project": {"references": ["var.sibling_project"]}},
                        "module": {
                            "variables": {"sibling_project": {"description": "The project sharing this account — the HandsOffSibling Deny names it"}},
                            "resources": [{"address": "aws_iam_policy.boundary", "mode": "managed", "type": "aws_iam_policy", "name": "boundary", "provider_config_key": "aws",
                                           "expressions": {"name": {"references": ["local.boundary_name"]}, "policy": {"references": ["local.sibling_arn_patterns", "var.sibling_project"]}}, "schema_version": 0}],
                        },
                    }
                },
            },
        },
    }
    for key, value in sections.items():
        plan[key] = value
    return plan


def self_test() -> int:
    budget = _res("aws_budgets_budget", "monthly", name="trades-production-monthly")
    deny_doc = json.dumps({"Version": "2012-10-17", "Statement": [{"Sid": "HandsOffSibling", "Effect": "Deny", "Action": "*", "Resource": ["arn:aws:s3:::*kha-energy*"]}]})
    allow_doc = json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": ["arn:aws:s3:::kha-energy-production-backups/*"]}]})
    real_resources = [budget, _res("aws_iam_role", "host", name="trades-production-host"), _res("aws_iam_policy", "boundary", name="trades-production-boundary", description="hands off the sibling project's resources", policy=deny_doc)]
    real_ok = _real_shaped_plan(real_resources)
    real_variables_leak = _real_shaped_plan(real_resources)
    real_variables_leak["variables"]["notes"] = {"value": "copied from kha-energy"}
    real_configuration_leak = _real_shaped_plan(real_resources)
    real_configuration_leak["configuration"]["root_module"]["module_calls"]["x"]["expressions"]["sibling_project"] = {"constant_value": SIBLING}
    real_description_leak = _real_shaped_plan([budget, _res("aws_iam_policy", "boundary", name="trades-production-boundary", description="hands off kha-energy.", policy=deny_doc)])
    real_output_leak = _real_shaped_plan(real_resources)
    real_output_leak["output_changes"]["note"] = {"actions": ["create"], "before": None, "after": "shared with kha-energy", "after_unknown": False}
    cases: List[Tuple[str, Dict[str, Any], bool]] = [
        ("REAL SHAPE: variables.sibling_project = kha-energy, configuration variable blocks, resource_changes, outputs, prior_state → OK", real_ok, True),
        ("REAL SHAPE: another variable's value carries the sibling → FAIL", real_variables_leak, False),
        ("REAL SHAPE: a module-call argument is the literal sibling (configuration constant_value) → FAIL", real_configuration_leak, False),
        ("REAL SHAPE: the boundary's description names the sibling (a plain attribute) → FAIL", real_description_leak, False),
        ("REAL SHAPE: an output carries the sibling → FAIL", real_output_leak, False),
        ("clean plan: budget + prefixed names + deny-only sibling mention → OK",
         _plan([budget, _res("aws_iam_role", "host", name="trades-production-host"), _res("aws_iam_policy", "boundary", name="trades-production-boundary", policy=deny_doc), _res("aws_ecr_repository", "r", name="trades/trades-backend")]), True),
        ("no budget → FAIL", _plan([_res("aws_iam_role", "host", name="trades-production-host")]), False),
        ("anomaly monitor → FAIL", _plan([budget, _res("aws_ce_anomaly_monitor", "m", name="trades-services")]), False),
        ("EstimatedCharges alarm → FAIL", _plan([budget, _res("aws_cloudwatch_metric_alarm", "b", alarm_name="trades-estimated-charges", metric_name="EstimatedCharges")]), False),
        ("OIDC provider → FAIL", _plan([budget, _res("aws_iam_openid_connect_provider", "gh", url="https://token.actions.githubusercontent.com")]), False),
        ("CI role → FAIL", _plan([budget, _res("aws_iam_role", "ci", name="trades-production-ci-apply")]), False),
        ("Route 53 zone → FAIL", _plan([budget, _res("aws_route53_zone", "z", name="trades-zone")]), False),
        ("unprefixed name → FAIL", _plan([budget, _res("aws_sns_topic", "t", name="host-alerts")]), False),
        ("sibling string in an Allow statement → FAIL", _plan([budget, _res("aws_iam_role_policy", "p", name="trades-x", policy=allow_doc)]), False),
        ("sibling string in a plain attribute → FAIL", _plan([budget, _res("aws_s3_bucket", "b", bucket="trades-production-backups-1", tags={"Name": "trades-backups", "note": "copied from kha-energy"})]), False),
        ("wrong project tag → FAIL", _plan([budget, _res("aws_sns_topic", "t", name="trades-production-host-alerts", tags_all={"project": "kha-energy"})]), False),
        ("empty plan → FAIL", _plan([]), False),
        ("CPUCreditBalance alarm (not billing) → OK", _plan([budget, _res("aws_cloudwatch_metric_alarm", "c", alarm_name="trades-production-cpu-credit-balance-low", metric_name="CPUCreditBalance")]), True),
    ]
    failed = 0
    for label, plan, expect_ok in cases:
        findings = check(plan)
        ok = not findings
        verdict = "✓" if ok == expect_ok else "✗"
        if ok != expect_ok:
            failed += 1
        print(f"  {verdict} {label}" + ("" if ok == expect_ok else f" — got {'OK' if ok else findings}"))
    if failed:
        print(f"✗ check-tf-plan self-test: {failed} case(s) did not behave as expected", file=sys.stderr)
        return 1
    print(f"→ check-tf-plan self-test: OK ({len(cases)} cases)")
    return 0


def main(argv: List[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(argv[0], encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"✗ check-tf-plan: cannot read {argv[0]}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(plan, dict) or "planned_values" not in plan:
        print(f"✗ check-tf-plan: {argv[0]} is not `terraform show -json` output (no planned_values)", file=sys.stderr)
        return 2
    findings = check(plan)
    if findings:
        print(f"✗ check-tf-plan: {len(findings)} finding(s) — AC-1 not met:", file=sys.stderr)
        for f in findings:
            print(f"  - {f}", file=sys.stderr)
        return 1
    n = sum(1 for _ in walk_resources(plan))
    print(f"→ check-tf-plan: OK — {n} resources, every name {PROJECT}-prefixed, budget present, no anomaly monitor / billing alarm / OIDC / CI role / Route 53, {SIBLING!r} only inside Deny statements")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
