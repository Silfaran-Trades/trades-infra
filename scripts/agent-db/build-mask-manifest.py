#!/usr/bin/env python3
"""Build deploy/agent-db/mask-manifest.txt from trades-docs/pii-inventory.md (IA-010).

production-infrastructure-first-deploy BR-27 / AC-14 / TM-3. Python 3 standard library only.

The framework's view generator (deploy/agent-db/generate-masked-views.sh) reads a MASK
MANIFEST — one line per exposed table, `schema.table: col[,col…]` — not the inventory. This
converter turns the inventory's `service | table | column` rows into that manifest, with the
explicit legacy-service-to-schema map the spec records, and it is FAIL-CLOSED: an unknown
service aborts the conversion naming the row, and a table with no inventory row gets no view.

Rules (spec § Technical Details, "The agent's masked database role"):
  * a row whose `service` is `trades-backend (<Bundle> bundle)` takes its `table` cell as
    already schema-qualified;
  * a legacy `<name>-service` row maps through LEGACY_SERVICE_SCHEMAS below; a bare table is
    qualified with that schema, an already-qualified one is kept;
  * `media-service` rows, `channel:` rows and infrastructure rows (`trades-infra`, `proxy`) are
    skipped (the media database is not exposed; channels are not tables);
  * a `column` cell that is not a bare identifier (a derived value, a description in prose) is
    skipped — with two conservative widenings, both in the over-masking direction, which is the
    safe one: (1) a cell that is a `/`- or `,`-separated list is EXPANDED item by item, and a
    table cell that is such a list is expanded the same way; (2) an item of the shape
    `identifier (note)` masks the identifier UNLESS the note says the value is not a stored
    column (`derived`, `not stored`, `not persisted`, `not a column`, `transient`), in which
    case that item is skipped. Within a list, kept items are masked and skipped items are
    reported — a row never exposes a column just because a sibling item was prose;
  * an unknown `service` value ABORTS the conversion (exit 2), naming the row;
  * every inventoried column of a table is listed as sensitive, so the generator omits it.
  Every skipped row is reported on stderr with its reason — the operator sees exactly what the
  generator will NOT mask.

Usage:
  build-mask-manifest.py <pii-inventory.md> <mask-manifest.txt>       # write
  build-mask-manifest.py <pii-inventory.md> --check <mask-manifest.txt>   # drift: exit 1 on diff
"""

from __future__ import annotations

import re
import sys
from typing import Dict, List, Optional, Sequence, Tuple

LEGACY_SERVICE_SCHEMAS: Dict[str, str] = {
    "identity-service": "identity",
    "company-service": "company",
    "catalog-service": "catalog",
    "profile-service": "profile",
    "demand-service": "demand",
    "chat-service": "chat",
    "comms-service": "comms",
    "contracts-service": "contracts",
    "payments-service": "payments",
    "labor-service": "labor",
    "service-orders-service": "serviceorders",
    "incidents-service": "incidents",
    "leakcontrol-service": "leakcontrol",
}

# Services whose rows are not tables of the exposed database.
SKIPPED_SERVICE_PREFIXES: Tuple[str, ...] = ("media-service", "trades-infra", "proxy")

BUNDLE_SERVICE_RE = re.compile(r"^trades-backend \((?P<bundle>[A-Za-z]+) bundle\)$")
IDENTIFIER_RE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
ANNOTATED_RE = re.compile(r"^(?P<ident>[a-z_][a-z0-9_]{0,62})\s*\((?P<note>.*)\)$")
NOT_A_COLUMN_WORDS = ("derived", "not stored", "not persisted", "not a column", "transient")
QUALIFIED_RE = re.compile(r"^(?P<schema>[a-z_][a-z0-9_]{0,62})\.(?P<table>[a-z_][a-z0-9_]{0,62})$")


class ConversionError(Exception):
    """An inventory row the converter refuses to interpret (fail-closed)."""


def strip_backticks(cell: str) -> str:
    return cell.strip().strip("`").strip()


def split_list(cell: str) -> List[str]:
    """A `/`- or `,`-separated list of items, split OUTSIDE parentheses only (a note such as
    `draft (location_lat / location_lng keys)` is one item); backticks stripped per item."""
    items: List[str] = []
    depth = 0
    current: List[str] = []
    for ch in cell.strip():
        if ch == "(":
            depth += 1
        elif ch == ")" and depth > 0:
            depth -= 1
        if ch in "/," and depth == 0:
            items.append("".join(current))
            current = []
            continue
        current.append(ch)
    items.append("".join(current))
    return [strip_backticks(item) for item in items if item.strip()]


def parse_rows(markdown: str) -> List[Tuple[int, List[str]]]:
    """Every table row of the inventory as (line number, cells); header and rule rows dropped."""
    rows: List[Tuple[int, List[str]]] = []
    header_seen = False
    for lineno, line in enumerate(markdown.splitlines(), start=1):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not header_seen:
            header_seen = True  # the column header
            continue
        if cells and set(cells[0]) <= set("-: "):
            continue  # the markdown rule row
        rows.append((lineno, cells))
    return rows


def resolve_schema(service: str, lineno: int) -> Optional[str]:
    """The schema a row's bare table lives in; None = qualified already (bundle row); raises on
    an unknown service; '' is never returned."""
    if BUNDLE_SERVICE_RE.match(service):
        return None
    if service in LEGACY_SERVICE_SCHEMAS:
        return LEGACY_SERVICE_SCHEMAS[service]
    raise ConversionError(
        f"line {lineno}: unknown service {service!r} — add it to LEGACY_SERVICE_SCHEMAS or fix the "
        "inventory row; the conversion is fail-closed and stops here"
    )


def is_skipped_service(service: str) -> bool:
    return any(service.startswith(prefix) for prefix in SKIPPED_SERVICE_PREFIXES)


def qualify_tables(table_cell: str, schema: Optional[str]) -> Optional[List[str]]:
    """The schema.table names a row's table cell denotes, or None when the cell is prose."""
    items = split_list(table_cell)
    if not items:
        return None
    out: List[str] = []
    for item in items:
        if item.startswith("channel:"):
            return None
        m = QUALIFIED_RE.match(item)
        if m:
            out.append(item)
            continue
        if IDENTIFIER_RE.match(item):
            if schema is None:
                # a bundle row must carry a qualified table (the spec's shape)
                return None
            out.append(f"{schema}.{item}")
            continue
        return None  # a parenthetical, a sentence, a transient note — prose
    return out


def column_of_item(item: str) -> Tuple[Optional[str], Optional[str]]:
    """(column, skip reason) for one item of a column cell: a bare identifier, or
    `identifier (note)` whose note does not say the value is not a stored column."""
    if IDENTIFIER_RE.match(item):
        return item, None
    m = ANNOTATED_RE.match(item)
    if m:
        note = m.group("note").lower()
        if any(word in note for word in NOT_A_COLUMN_WORDS):
            return None, f"{item!r}: the note says it is not a stored column"
        return m.group("ident"), None
    return None, f"{item!r}: not a bare identifier"


def columns_of(column_cell: str) -> Tuple[List[str], List[str]]:
    """(the column identifiers a column cell denotes, the items skipped with reasons)."""
    kept: List[str] = []
    skipped: List[str] = []
    for item in split_list(column_cell):
        col, reason = column_of_item(item)
        if col is not None:
            kept.append(col)
        else:
            skipped.append(reason or item)
    return kept, skipped


def build_manifest(markdown: str) -> Tuple[Dict[str, List[str]], List[str]]:
    """(manifest: schema.table → sorted unique columns, notes: skipped rows with reasons)."""
    manifest: Dict[str, List[str]] = {}
    notes: List[str] = []
    for lineno, cells in parse_rows(markdown):
        if len(cells) < 3:
            notes.append(f"line {lineno}: fewer than three cells — skipped")
            continue
        service, table_cell, column_cell = cells[0], cells[1], cells[2]
        if service.startswith("channel:") or table_cell.startswith("channel:") or "channel:" in table_cell:
            notes.append(f"line {lineno}: channel row ({service}) — not a table, skipped")
            continue
        if is_skipped_service(service):
            notes.append(f"line {lineno}: {service.split(' ')[0]} row — not in the exposed database, skipped")
            continue
        schema = resolve_schema(service, lineno)  # raises on an unknown service
        tables = qualify_tables(table_cell, schema)
        if tables is None:
            notes.append(f"line {lineno}: table cell is not a bare table ({table_cell[:60]!r}) — skipped")
            continue
        columns, skipped_items = columns_of(column_cell)
        for reason in skipped_items:
            notes.append(f"line {lineno}: column item skipped on {', '.join(tables)} — {reason}")
        if not columns:
            continue
        for table in tables:
            existing = manifest.setdefault(table, [])
            for col in columns:
                if col not in existing:
                    existing.append(col)
    for table in manifest:
        manifest[table].sort()
    return manifest, notes


def render(manifest: Dict[str, List[str]], source_name: str) -> str:
    lines = [
        "# mask manifest — the generating input of the mask schema (IA-010, BR-27).",
        "#",
        f"# GENERATED by scripts/agent-db/build-mask-manifest.py from {source_name} — DO NOT EDIT BY HAND.",
        "# A wrong or stale row is fixed in pii-inventory.md and the manifest regenerated",
        "# (`make mask-manifest`); `make mask-manifest-check` fails on drift.",
        "# Read by deploy/agent-db/generate-masked-views.sh.",
        "#",
        "# Format:  <schema>.<table>: <masked-col>[,<masked-col>...]",
        "#",
        "# FAIL-CLOSED, both enforced by the generator:",
        "#   1. a table with NO line here gets NO view — and, holding no grant on its base schema, is",
        "#      invisible to ai_readonly (every table without a PII row in the inventory:",
        "#      shared.messenger_messages, identity.password_reset_tokens, public.phinxlog, the catalog",
        "#      taxonomy tables, …). The agent lane sees the inventoried tables and nothing else.",
        "# A row of the inventory whose table cell lists several tables applies EVERY column of that",
        "# row to EVERY table listed (over-masking is the safe direction); a column that exists on only",
        "# one of them aborts the generator — write one row per table in that case.",
        "#   2. a column named here that no longer exists in the live table ABORTS the regeneration —",
        "#      a rename must not silently re-expose the renamed column.",
        "# Beyond this file, the generator omits every credential-shaped column it finds in the live",
        "# table (password, token, secret, apikey, credential, hash) — credentials are not PII-tier",
        "# inventory rows, and an agent never reads hash material.",
        "",
    ]
    by_schema: Dict[str, List[str]] = {}
    for table in sorted(manifest):
        by_schema.setdefault(table.split(".", 1)[0], []).append(table)
    for schema in sorted(by_schema):
        lines.append(f"# --- {schema} ---")
        for table in by_schema[schema]:
            lines.append(f"{table}: {','.join(manifest[table])}")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main(argv: Sequence[str]) -> int:
    args = list(argv)
    check = False
    if "--check" in args:
        check = True
        args.remove("--check")
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    source, target = args
    with open(source, encoding="utf-8") as fh:
        markdown = fh.read()
    try:
        manifest, notes = build_manifest(markdown)
    except ConversionError as exc:
        print(f"ERROR: build-mask-manifest: {exc}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"NOTE: build-mask-manifest: {note}", file=sys.stderr)
    rendered = render(manifest, "trades-docs/pii-inventory.md")
    tables = len(manifest)
    columns = sum(len(cols) for cols in manifest.values())
    if check:
        try:
            with open(target, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            print(f"ERROR: build-mask-manifest: {target} does not exist — run without --check to generate it", file=sys.stderr)
            return 1
        if current != rendered:
            print(f"ERROR: build-mask-manifest: {target} drifted from {source} — regenerate it (make mask-manifest)", file=sys.stderr)
            return 1
        print(f"mask manifest up to date: {target} ({tables} tables, {columns} masked columns; {len(notes)} rows skipped)")
        return 0
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(rendered)
    print(f"mask manifest written: {target} ({tables} tables, {columns} masked columns; {len(notes)} rows skipped — see NOTE lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
