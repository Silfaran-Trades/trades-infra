"""Unit tests for scripts/agent-db/build-mask-manifest.py (Python 3 standard library only).

production-infrastructure-first-deploy AC-14 / TM-3 — the converter that turns
trades-docs/pii-inventory.md into the mask manifest the agent's masked views are generated from:

  * a `trades-backend (<Bundle> bundle)` row keeps its schema-qualified table;
  * a legacy `<name>-service` row maps through the explicit service table (bare tables
    qualified, already-qualified ones kept);
  * `media-service`, `channel:`, infrastructure (`trades-infra`, `proxy`) and non-identifier
    column rows are skipped, each with a NOTE;
  * an unknown service ABORTS the conversion naming the row (fail-closed), from the library
    and from the CLI (exit 2, no manifest written).

Run: python3 -m unittest discover -s scripts/agent-db/tests -v   (from the trades-infra root)
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "build-mask-manifest.py"

_spec = importlib.util.spec_from_file_location("build_mask_manifest", SCRIPT)
assert _spec is not None and _spec.loader is not None
bmm = importlib.util.module_from_spec(_spec)
sys.modules["build_mask_manifest"] = bmm
_spec.loader.exec_module(bmm)

HEADER = (
    "| service | table | column | tier | legal_basis | purpose | retention | retention_job | processors | dsar_export | rtbf_action |\n"
    "|---|---|---|---|---|---|---|---|---|---|---|\n"
)


def row(service: str, table: str, column: str) -> str:
    return f"| {service} | {table} | {column} | Internal-PII | contract | purpose | account_lifetime | n/a | none | yes | anonymize |\n"


def inventory(*rows: str) -> str:
    return "# PII inventory\n\nSome prose.\n\n" + HEADER + "".join(rows)


class BundleRowsTest(unittest.TestCase):
    def test_a_bundle_row_keeps_its_qualified_table(self) -> None:
        manifest, notes = bmm.build_manifest(
            inventory(
                row("trades-backend (Profile bundle)", "profile.profile_evidences", "referee_email"),
                row("trades-backend (Profile bundle)", "profile.profile_evidences", "referee_name"),
            )
        )
        self.assertEqual({"profile.profile_evidences": ["referee_email", "referee_name"]}, manifest)
        self.assertEqual([], notes)

    def test_a_bundle_row_with_a_bare_table_is_skipped_not_guessed(self) -> None:
        manifest, notes = bmm.build_manifest(
            inventory(
                row("trades-backend (Profile bundle)", "profile_evidences", "referee_email"),
            )
        )
        self.assertEqual({}, manifest)
        self.assertEqual(1, len(notes))
        self.assertIn("table cell is not a bare table", notes[0])

    def test_columns_are_sorted_and_deduplicated_per_table(self) -> None:
        manifest, _ = bmm.build_manifest(
            inventory(
                row("trades-backend (Chat bundle)", "chat.messages", "body"),
                row("trades-backend (Chat bundle)", "chat.messages", "attachment_name"),
                row("trades-backend (Chat bundle)", "chat.messages", "body"),
            )
        )
        self.assertEqual({"chat.messages": ["attachment_name", "body"]}, manifest)


class LegacyServiceRowsTest(unittest.TestCase):
    def test_every_legacy_service_maps_through_the_explicit_table(self) -> None:
        expected = {
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
        self.assertEqual(expected, bmm.LEGACY_SERVICE_SCHEMAS)
        for service, schema in expected.items():
            with self.subTest(service=service):
                manifest, _ = bmm.build_manifest(inventory(row(service, "some_table", "email")))
                self.assertEqual({f"{schema}.some_table": ["email"]}, manifest)

    def test_a_legacy_row_with_an_already_qualified_table_is_kept(self) -> None:
        manifest, _ = bmm.build_manifest(inventory(row("identity-service", "identity.users", "first_name")))
        self.assertEqual({"identity.users": ["first_name"]}, manifest)

    def test_a_legacy_row_with_a_table_list_is_expanded(self) -> None:
        manifest, _ = bmm.build_manifest(inventory(row("comms-service", "`recipients` / `outbox`", "email_address")))
        self.assertEqual({"comms.outbox": ["email_address"], "comms.recipients": ["email_address"]}, manifest)


class SkippedRowsTest(unittest.TestCase):
    def assert_skipped(self, markdown: str, reason_fragment: str) -> None:
        manifest, notes = bmm.build_manifest(markdown)
        self.assertEqual({}, manifest, "a skipped row must produce no manifest line")
        self.assertEqual(1, len(notes))
        self.assertIn(reason_fragment, notes[0])

    def test_media_service_rows_are_skipped(self) -> None:
        self.assert_skipped(inventory(row("media-service", "media_objects", "original_filename")), "media-service row")

    def test_channel_rows_are_skipped_whether_in_the_service_or_the_table_cell(self) -> None:
        self.assert_skipped(inventory(row("channel:database-dumps", "n/a", "all")), "channel row")
        self.assert_skipped(inventory(row("trades-infra", "channel:captured-mail", "message body")), "channel row")

    def test_infrastructure_rows_are_skipped(self) -> None:
        self.assert_skipped(inventory(row("trades-infra", "/srv/trades/log-archive", "client_ip")), "trades-infra row")
        self.assert_skipped(inventory(row("proxy (Caddy)", "access log", "remote_ip")), "proxy row")

    def test_a_prose_column_cell_is_skipped_with_a_note(self) -> None:
        manifest, notes = bmm.build_manifest(
            inventory(
                row("trades-backend (Profile bundle)", "profile.profile_scores", "ranking score + 6 sub-scores"),
            )
        )
        self.assertEqual({}, manifest)
        self.assertEqual(1, len(notes))
        self.assertIn("not a bare identifier", notes[0])

    def test_a_derived_annotated_column_is_skipped_and_a_stored_one_kept(self) -> None:
        manifest, notes = bmm.build_manifest(
            inventory(
                row("trades-backend (Demand bundle)", "demand.demands", "distance_km (derived at read time)"),
                row("trades-backend (Demand bundle)", "demand.demands", "location (lat/lng of the site)"),
            )
        )
        self.assertEqual({"demand.demands": ["location"]}, manifest)
        self.assertEqual(1, len(notes))
        self.assertIn("not a stored column", notes[0])

    def test_a_column_list_masks_kept_items_and_reports_prose_siblings(self) -> None:
        manifest, notes = bmm.build_manifest(
            inventory(
                row("trades-backend (Labor bundle)", "labor.direct_hires", "`role_title` / `notes` / free text in prose"),
            )
        )
        self.assertEqual({"labor.direct_hires": ["notes", "role_title"]}, manifest)
        self.assertEqual(1, len(notes))
        self.assertIn("free text in prose", notes[0])

    def test_a_row_with_fewer_than_three_cells_is_skipped(self) -> None:
        manifest, notes = bmm.build_manifest("| service | table | column |\n|---|---|---|\n| identity-service | users |\n")
        self.assertEqual({}, manifest)
        self.assertIn("fewer than three cells", notes[0])


class UnknownServiceTest(unittest.TestCase):
    def test_an_unknown_service_aborts_naming_the_row(self) -> None:
        markdown = inventory(
            row("identity-service", "users", "email"),
            row("billing-service", "invoices", "billing_name"),
        )
        with self.assertRaises(bmm.ConversionError) as caught:
            bmm.build_manifest(markdown)
        message = str(caught.exception)
        expected_line = markdown.splitlines().index(row("billing-service", "invoices", "billing_name").rstrip("\n")) + 1
        self.assertIn(f"line {expected_line}", message)
        self.assertIn("'billing-service'", message)
        self.assertIn("fail-closed", message)

    def test_a_bundle_name_outside_the_expected_shape_is_unknown(self) -> None:
        with self.assertRaises(bmm.ConversionError):
            bmm.build_manifest(inventory(row("trades-backend (Profile)", "profile.profiles", "bio")))

    def test_the_cli_exits_2_naming_the_row_and_writes_no_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "pii-inventory.md"
            target = Path(tmp) / "mask-manifest.txt"
            source.write_text(inventory(row("unknown-service", "things", "email")), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(source), str(target)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(2, result.returncode)
            self.assertIn("ERROR: build-mask-manifest: line 7: unknown service 'unknown-service'", result.stderr)
            self.assertFalse(target.exists(), "an aborted conversion must not leave a manifest behind")


class CliRoundTripTest(unittest.TestCase):
    def test_write_then_check_is_clean_and_a_hand_edit_is_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "pii-inventory.md"
            target = Path(tmp) / "mask-manifest.txt"
            source.write_text(
                inventory(
                    row("identity-service", "users", "email"),
                    row("trades-backend (Chat bundle)", "chat.messages", "body"),
                    row("media-service", "media_objects", "original_filename"),
                ),
                encoding="utf-8",
            )
            write = subprocess.run([sys.executable, str(SCRIPT), str(source), str(target)], capture_output=True, text=True, check=False)
            self.assertEqual(0, write.returncode, write.stderr)
            content = target.read_text(encoding="utf-8")
            self.assertIn("chat.messages: body\n", content)
            self.assertIn("identity.users: email\n", content)
            self.assertNotIn("media_objects", content, "a media-service row never reaches the manifest")
            self.assertIn("NOTE: build-mask-manifest: line 9: media-service row", write.stderr)

            check = subprocess.run(
                [sys.executable, str(SCRIPT), str(source), "--check", str(target)], capture_output=True, text=True, check=False
            )
            self.assertEqual(0, check.returncode, check.stderr)

            target.write_text(content + "identity.refresh_tokens: ip_address\n", encoding="utf-8")
            drift = subprocess.run(
                [sys.executable, str(SCRIPT), str(source), "--check", str(target)], capture_output=True, text=True, check=False
            )
            self.assertEqual(1, drift.returncode)
            self.assertIn("drifted", drift.stderr)


class CommittedManifestTest(unittest.TestCase):
    """The committed manifest is the converter's output: no hand edit, every line well formed."""

    def test_every_committed_line_is_a_qualified_table_with_identifier_columns(self) -> None:
        manifest_path = SCRIPT.parent.parent.parent / "deploy" / "agent-db" / "mask-manifest.txt"
        if not manifest_path.exists():
            self.skipTest("deploy/agent-db/mask-manifest.txt not present")
        lines = [line for line in manifest_path.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")]
        self.assertGreater(len(lines), 0)
        for line in lines:
            with self.subTest(line=line):
                table, _, columns = line.partition(": ")
                self.assertRegex(table, bmm.QUALIFIED_RE)
                self.assertFalse(table.startswith("media."), "the media database is never exposed")
                for column in columns.split(","):
                    self.assertRegex(column, bmm.IDENTIFIER_RE)


if __name__ == "__main__":
    unittest.main()
