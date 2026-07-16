"""Current-file freeze checks for approved publication sources."""

from pathlib import Path

from approved_body_helpers import ApprovedCommitCase, ROOT_ID


class ApprovedCurrentSourceTests(ApprovedCommitCase):
    def test_loads_approved_sources_and_allows_root_substitution(self) -> None:
        expected, report = self.render()
        self.assertEqual([], report.errors)
        self.assertEqual({ROOT_ID, "BO-001"}, set(expected.bodies))
        self.assertEqual(
            {ROOT_ID: "Root", "BO-001": "BO-001"},
            expected.titles,
        )

    def test_rejects_current_ticket_document_drift(self) -> None:
        self.ticket_document.write_text("# BO-001 drifted\n", encoding="utf-8")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn(
            "current BO-001 document must exactly match its approved source",
            "\n".join(report.errors),
        )

    def test_rejects_current_root_document_drift(self) -> None:
        self.root_document.write_text("# Root drifted\n", encoding="utf-8")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn(
            "current root document must exactly match its approved source",
            "\n".join(report.errors),
        )

    def test_missing_current_documents_fail_closed(self) -> None:
        for path, label in (
            (self.ticket_document, "current BO-001 document is absent"),
            (self.root_document, "current root document is absent"),
        ):
            with self.subTest(path=path):
                source = path.read_bytes()
                path.unlink()
                try:
                    expected, report = self.render()
                    self.assertIsNone(expected)
                    self.assertIn(label, "\n".join(report.errors))
                finally:
                    path.write_bytes(source)

    def test_rejects_unsafe_and_symlinked_current_paths(self) -> None:
        for path in ("../root.md", "./pack/root.md", "pack/../root.md", "/tmp/root.md", "."):
            with self.subTest(path=path):
                expected, report = self.render(path)
                self.assertIsNone(expected)
                self.assertIn(
                    "must be a safe repository-relative path", "\n".join(report.errors),
                )

        source = self.ticket_document.read_bytes()
        self.ticket_document.unlink()
        self.ticket_document.symlink_to(self.root_document)
        try:
            expected, report = self.render()
            self.assertIsNone(expected)
            self.assertIn("current BO-001 document must not be a symlink", "\n".join(report.errors))
        finally:
            self.ticket_document.unlink()
            self.ticket_document.write_bytes(source)

    def test_rejects_unreadable_current_document(self) -> None:
        self.ticket_document.write_bytes(b"\xff")
        expected, report = self.render()
        self.assertIsNone(expected)
        self.assertIn("current BO-001 document must be readable UTF-8", "\n".join(report.errors))


if __name__ == "__main__":
    import unittest

    unittest.main()
