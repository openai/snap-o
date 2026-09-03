"""Offline protocol-report regression tests: python3 -m unittest discover -s release/tests -v."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


PREFLIGHT = Path(__file__).resolve().parents[1] / "preflight.sh"
DECLARATIONS = [
    (
        "Android Network protocol version",
        "snapo-link-android/network/src/main/java/com/openai/snapo/network/SnapOProtocol.kt",
        "internal const val NetworkProtocolVersion: Int = 1",
    ),
    (
        "Android Tweaks protocol version",
        "snapo-link-android/tweaks/src/main/java/com/openai/snapo/tweaks/internal/TweakHttpServer.kt",
        "internal const val TweaksProtocolVersion: Int = 4",
    ),
    (
        "Swift Network supported version",
        "snapo-app-mac/SnapODeviceClient/Sources/SnapODeviceClient/NetworkProtocol.swift",
        "public static let supportedVersion = 1",
    ),
    (
        "Web Network supported version",
        "snapo-network-inspector-web/src/features/network-inspector/lib/protocol.ts",
        "export const supportedProtocolVersion = 1;",
    ),
    (
        "Web Tweaks modified-state/reset feature threshold",
        "snapo-network-inspector-web/src/features/tweaks-inspector/TweaksInspectorApp.tsx",
        "const modifiedTweakProtocolVersion = 4;",
    ),
    (
        "CLI Tweaks minimum-version checks",
        "scripts/snapo",
        "if protocol_version < 1:",
    ),
    (
        "CLI Tweaks explicit-reset feature threshold",
        "scripts/snapo",
        "explicit_resets = protocol_version >= 4",
    ),
]


class ProtocolReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.repo = root / "openai" / "snap-o"
        self.repo.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
        )
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Preflight Test")
        self.git("config", "user.email", "preflight@example.invalid")
        self.git("config", "commit.gpgSign", "false")
        self.git("remote", "add", "origin", str(self.repo))
        self.write("VERSION", "VERSION = 6.0.0\nBUILD_NUMBER = 20260903.00\n")
        self.baseline = {}
        for _, path, declaration in DECLARATIONS:
            self.baseline[path] = self.baseline.get(path, "") + declaration + "\n"
        for path, content in self.baseline.items():
            self.write(path, content)
        self.commit()
        self.git("tag", "5.1.0")

        # Only GitHub responses are stubbed; the full preflight reads real Git refs/files.
        gh = bin_dir / "gh"
        gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import sys

            args = sys.argv[1:]
            request = " ".join(args)
            if args[:2] == ["run", "list"] and args[args.index("--repo") + 1] != "openai/snap-o":
                raise SystemExit("Source checks must only query the source repository")
            if args[:2] in (["auth", "status"], ["run", "list"]):
                pass
            elif "releases/latest" in request:
                if ".assets[]" not in request:
                    print("5.1.0\\t2026-09-01T00:00:00Z\\thttps://example.invalid/release")
            elif "contents/appcast.xml?ref=gh-pages" in request:
                print("<sparkle:shortVersionString>5.1.0</sparkle:shortVersionString>")
                print("<sparkle:version>20260901.00</sparkle:version>")
            else:
                raise SystemExit(f"Unexpected GitHub request: {args}")
            '''))
        gh.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, env=self.env, stderr=subprocess.STDOUT, text=True
        )

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")

    def run_preflight(self, base="5.1.0", ref="HEAD"):
        return subprocess.run(
            ["bash", str(PREFLIGHT), "--snapo-dir", str(self.repo),
             "--ref", ref, "--candidate", "6.0.0", "--mac-base", base, "--android-base", base],
            env=self.env, capture_output=True, text=True,
        )

    def report(self, base="5.1.0", ref="HEAD"):
        result = self.run_preflight(base, ref)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_cli_change_counts_as_macos_source(self):
        self.write("scripts/snapo", self.baseline["scripts/snapo"] + "# CLI change\n")
        self.commit()
        report = self.report()
        self.assertIn("macOS source files changed since 5.1.0: 1\n", report)
        self.assertIn("Recommendation: run the macOS source build/tests", report)

    def test_malformed_committed_build_number_is_rejected(self):
        for build in ("", "20260903", "20260903.0", "20260903.000", "2026093.00", "20260903.xx"):
            with self.subTest(build=build):
                self.write("VERSION", f"VERSION = 6.0.0\nBUILD_NUMBER = {build}\n")
                self.commit()
                result = self.run_preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must use YYYYMMDD.NN", result.stderr)
                self.assertNotIn("Preflight complete", result.stdout)

    def test_local_version_edits_do_not_affect_source_validation(self):
        for content in ("VERSION = invalid\nBUILD_NUMBER = invalid\n", None):
            with self.subTest(content=content):
                if content is None:
                    (self.repo / "VERSION").unlink()
                else:
                    self.write("VERSION", content)
                report = self.report()
                self.assertIn("Source VERSION/build: 6.0.0 / 20260903.00", report)
                local_values = "<missing> / <missing>" if content is None else "invalid / invalid"
                self.assertIn(f"Local VERSION/build:  {local_values}", report)

    def test_missing_committed_version_is_rejected(self):
        (self.repo / "VERSION").unlink()
        self.commit()
        self.write("VERSION", "VERSION = 6.0.0\nBUILD_NUMBER = 20260903.00\n")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Preflight complete", result.stdout)

    def test_reports_all_versions_and_feature_thresholds_at_both_refs(self):
        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        for label, _, declaration in DECLARATIONS:
            self.assertEqual(report.count(f"    {label}:\n"), 2)
            self.assertEqual(report.count(declaration), 2)

    def test_each_missing_declaration_is_unresolved_despite_other_matches(self):
        debug = "snapo-network-inspector-web/src/features/network-inspector/lib/debug.ts"
        for label, missing_path, declaration in DECLARATIONS:
            with self.subTest(label=label):
                for path, content in self.baseline.items():
                    self.write(path, content)
                self.write(missing_path, self.baseline[missing_path].replace(declaration + "\n", ""))
                self.write(debug, "const supportedProtocolVersion = 1;\n")
                self.commit()
                report = self.report()
                self.assertEqual(report.count("UNRESOLVED:"), 1)
                self.assertIn(f"UNRESOLVED: {label} not found in {missing_path}", report)
                for other_label, _, other_declaration in DECLARATIONS:
                    if other_label != label:
                        self.assertEqual(report.count(other_declaration), 2)

    def test_reports_changed_values_from_candidate(self):
        for path, content in self.baseline.items():
            self.write(path, content.replace("1", "2").replace("4", "5"))
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        for _, _, declaration in DECLARATIONS:
            self.assertEqual(report.count(declaration), 1)
            self.assertEqual(report.count(declaration.replace("1", "2").replace("4", "5")), 1)

    def test_selected_ref_is_used_instead_of_current_main(self):
        for path, content in self.baseline.items():
            self.write(path, content.replace("1", "2").replace("4", "5"))
        self.commit()
        report = self.report(ref="5.1.0")
        for _, _, declaration in DECLARATIONS:
            self.assertEqual(report.count(declaration), 2)
            self.assertNotIn(declaration.replace("1", "2").replace("4", "5"), report)

    def test_missing_base_is_unresolved(self):
        report = self.report(base="missing-public-tag")
        self.assertEqual(report.count("UNRESOLVED:"), 2)
        self.assertIn("supply the public base and fetch missing refs", report)


if __name__ == "__main__":
    unittest.main()
