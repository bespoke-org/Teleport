#!/usr/bin/env python3
"""Exercise bump staging and changelog handling without network downloads."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
FILES = (
    "scripts/bump-xray.sh", "scripts/fetch-xray.sh",
    "teleport/HelperInstallation/BundledArtifactPolicy.swift",
    "README.md", "THIRD_PARTY_NOTICES.md",
)
RELEASE = "## [0.6.0] - 2026-11-06\n### Fixed\n- Existing release note.\n"
INTRO = "# Changelog\n\nKeep this introduction.\n\n"


class BumpXrayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, target)
        (self.root / "teleport/Resources").mkdir()
        # Keep the fetcher's version declaration contract; replace network and
        # Mach-O operations so these tests only exercise the bump orchestrator.
        fetch = self.root / "scripts/fetch-xray.sh"
        fetch.write_text('''#!/usr/bin/env bash
VERSION="${1:-v26.10.21}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cat > "$root/teleport/Resources/xray" <<'XRAY'
#!/bin/sh
echo 'Xray 26.10.31 (Xray, Penetrates Everything.) a4a3dff (go1.27.3 darwin/arm64)'
XRAY
chmod +x "$root/teleport/Resources/xray"
''')
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        lipo = bin_dir / "lipo"
        lipo.write_text('#!/bin/sh\ncp "$3" "$5"\n')
        lipo.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", DRY_RUN="false")
        self.changelog = self.root / "CHANGELOG.md"

    def run_bump(self, dry_run=False):
        result = subprocess.run(
            ["bash", str(self.root / "scripts/bump-xray.sh"), "v26.10.31"],
            env=dict(self.env, DRY_RUN=str(dry_run).lower()),
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_creates_missing_unreleased_and_is_idempotent(self):
        self.changelog.write_text(INTRO + RELEASE)
        self.run_bump()
        expected = INTRO + "## [Unreleased]\n### Changed\n- Bundled Xray runtime updated to 26.10.31.\n\n" + RELEASE
        self.assertEqual(self.changelog.read_text(), expected)
        self.assertEqual(self.run_bump().stdout, "")
        self.assertEqual(self.changelog.read_text(), expected)

    def test_preserves_existing_unreleased_notes(self):
        self.changelog.write_text(INTRO + "## [Unreleased]\n### Fixed\n- Pending fix.\n\n" + RELEASE)
        self.run_bump()
        text = self.changelog.read_text()
        self.assertEqual(text.count("## [Unreleased]"), 1)
        self.assertIn("### Changed\n- Bundled Xray runtime updated to 26.10.31.\n\n### Fixed\n- Pending fix.", text)
        self.assertTrue(text.endswith(RELEASE))

    def test_dry_run_leaves_all_files_untouched(self):
        self.changelog.write_text(INTRO + RELEASE)
        before = {name: (self.root / name).read_bytes() for name in (*FILES, "CHANGELOG.md")}
        self.assertIn("Would update Xray", self.run_bump(dry_run=True).stdout)
        for name, contents in before.items():
            self.assertEqual((self.root / name).read_bytes(), contents, name)
        self.assertFalse((self.root / "teleport/Resources/xray").exists())


if __name__ == "__main__":
    unittest.main()
