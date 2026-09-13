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
            if args[:2] == ["auth", "status"]:
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

    def run_preflight(self, base="5.1.0", ref="HEAD", android_base=None):
        return subprocess.run(
            ["bash", str(PREFLIGHT), "--snapo-dir", str(self.repo),
             "--ref", ref, "--candidate", "6.0.0", "--mac-base", base,
             "--android-base", base if android_base is None else android_base],
            env=self.env, capture_output=True, text=True,
        )

    def report(self, base="5.1.0", ref="HEAD", android_base=None):
        result = self.run_preflight(base, ref, android_base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_reports_manifest_protocols_and_exact_client_versions(self):
        for _, path, _ in DECLARATIONS:
            candidate = self.repo / path
            if candidate.exists():
                candidate.unlink()
        self.write("snapo-link-android/network/src/main/res/xml/snapo_network_inspector.xml", '<inspector protocolVersion="3" />\n')
        self.write("snapo-link-android/tweaks-core/src/main/res/xml/snapo_tweaks_inspector.xml", '<inspector protocolVersion="7" />\n')
        self.write("inspectors/network/src/features/network-inspector/lib/protocol.ts", 'export const supportedProtocolVersion = 3;\n')
        self.write("inspectors/tweaks/src/features/tweaks-inspector/protocol.ts", 'export const supportedProtocolVersion = 7;\n')
        self.write("scripts/snapo", "NETWORK_PROTOCOL_VERSION = 3\nTWEAKS_PROTOCOL_VERSION = 7\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED:", report)
        for declaration in ('protocolVersion="3"', 'protocolVersion="7"',
                            'const supportedProtocolVersion = 7', 'NETWORK_PROTOCOL_VERSION = 3',
                            'TWEAKS_PROTOCOL_VERSION = 7', 'modifiedTweakProtocolVersion = 4'):
            self.assertIn(declaration, report)

    def test_reports_gradle_metadata_and_apk_frontend_versions(self):
        (self.repo / DECLARATIONS[0][1]).unlink()
        (self.repo / DECLARATIONS[1][1]).unlink()
        self.write("snapo-link-android/network/build.gradle.kts", "snapoInspector {\n    protocolVersion = 3\n}\n")
        self.write("snapo-link-android/network/frontend/src/features/network-inspector/lib/protocol.ts", "export const supportedProtocolVersion = 3;\n")
        self.write("snapo-link-android/tweaks-core/build.gradle.kts", "snapoInspector {\n    protocolVersion = 7\n}\n")
        self.write("snapo-link-android/tweaks-core/frontend/src/features/tweaks-inspector/protocol.ts", "export const supportedProtocolVersion = 7;\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED:", report)
        self.assertIn("protocolVersion = 3", report)
        self.assertIn("network/frontend/src/features/network-inspector/lib/protocol.ts", report)
        self.assertIn("protocolVersion = 7", report)
        self.assertIn("frontend/src/features/tweaks-inspector/protocol.ts", report)
        self.assertIn("const supportedProtocolVersion = 7", report)

    def test_reports_versions_after_tool_rename(self):
        (self.repo / DECLARATIONS[0][1]).unlink()
        (self.repo / DECLARATIONS[1][1]).unlink()
        self.write("snapo-link-android/network/build.gradle.kts", "snapoTool {\n    protocolVersion = 3\n}\n")
        self.write("snapo-link-android/network/frontend/src/features/network-tool/lib/protocol.ts", "export const supportedProtocolVersion = 3;\n")
        self.write("snapo-link-android/tweaks-core/build.gradle.kts", "snapoTool {\n    protocolVersion = 7\n}\n")
        self.write("snapo-link-android/tweaks-core/frontend/src/features/tweaks-tool/protocol.ts", "export const supportedProtocolVersion = 7;\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED:", report)
        self.assertIn("protocolVersion = 3", report)
        self.assertIn("network/frontend/src/features/network-tool/lib/protocol.ts", report)
        self.assertIn("protocolVersion = 7", report)
        self.assertIn("frontend/src/features/tweaks-tool/protocol.ts", report)
        self.assertIn("const supportedProtocolVersion = 7", report)

    def test_reports_versions_after_plugins_directory_move(self):
        (self.repo / DECLARATIONS[0][1]).unlink()
        (self.repo / DECLARATIONS[1][1]).unlink()
        self.write("plugins/network/build.gradle.kts", "snapoTool {\n    protocolVersion = 3\n}\n")
        self.write("plugins/network/frontend/src/features/network-tool/lib/protocol.ts", "export const supportedProtocolVersion = 3;\n")
        self.write("plugins/tweaks-core/build.gradle.kts", "snapoTool {\n    protocolVersion = 7\n}\n")
        self.write("plugins/tweaks-core/frontend/src/features/tweaks-tool/protocol.ts", "export const supportedProtocolVersion = 7;\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED:", report)
        self.assertIn("plugins/network/build.gradle.kts", report)
        self.assertIn("plugins/tweaks-core/build.gradle.kts", report)
        self.assertIn("protocolVersion = 3", report)
        self.assertIn("network/frontend/src/features/network-tool/lib/protocol.ts", report)
        self.assertIn("protocolVersion = 7", report)
        self.assertIn("frontend/src/features/tweaks-tool/protocol.ts", report)
        self.assertIn("const supportedProtocolVersion = 7", report)

    def test_reports_versions_after_plugin_implementation_grouping(self):
        (self.repo / DECLARATIONS[0][1]).unlink()
        (self.repo / DECLARATIONS[1][1]).unlink()
        self.write("plugins/implementations/network/core/build.gradle.kts", "snapoTool {\n    protocolVersion = 3\n}\n")
        self.write("plugins/implementations/network/frontend/src/features/network-tool/lib/protocol.ts", "export const supportedProtocolVersion = 3;\n")
        self.write("plugins/implementations/tweaks/core/build.gradle.kts", "snapoTool {\n    protocolVersion = 7\n}\n")
        self.write("plugins/implementations/tweaks/frontend/src/features/tweaks-tool/protocol.ts", "export const supportedProtocolVersion = 7;\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED:", report)
        self.assertIn("plugins/implementations/network/core/build.gradle.kts", report)
        self.assertIn("plugins/implementations/tweaks/core/build.gradle.kts", report)
        self.assertIn("protocolVersion = 3", report)
        self.assertIn("network/frontend/src/features/network-tool/lib/protocol.ts", report)
        self.assertIn("protocolVersion = 7", report)
        self.assertIn("frontend/src/features/tweaks-tool/protocol.ts", report)
        self.assertIn("const supportedProtocolVersion = 7", report)

    def test_reports_extracted_android_runtime_for_protocol_review(self):
        runtime = "snapo-link-android/inspector-runtime/src/main/java/com/openai/snapo/inspector/InspectorHttpRequest.kt"
        self.write(runtime, "package com.openai.snapo.inspector\n")
        self.commit()

        report = self.report()
        comparison = report.split("Android servers protocol comparison:", 1)[1]
        comparison = comparison.split("Mac/web/CLI clients protocol comparison:", 1)[0]
        self.assertIn(runtime, comparison)
        self.assertIn("REVIEW REQUIRED", comparison)

    def test_reports_example_frontend_for_client_protocol_review(self):
        frontend = "snapo-link-android/example/example-tool/frontend/src/snapshot.ts"
        self.write(frontend, "export const protocolVersion = 1;\n")
        self.commit()
        comparison = self.report().split("Mac/web/CLI clients protocol comparison:", 1)[1]
        self.assertIn(frontend, comparison)
        self.assertIn("REVIEW REQUIRED", comparison)

    def test_reports_structured_curve_protocol_transition(self):
        old_path = DECLARATIONS[1][1]
        (self.repo / old_path).unlink()
        core_path = old_path.replace("/tweaks/", "/tweaks-core/", 1)
        self.write(core_path, "internal const val TweaksProtocolVersion: Int = 5\n")
        self.write("contracts/tweaks/README.md", "Curve values have numeric x1, y1, x2, y2 fields.\n")
        self.commit()
        report = self.report()
        self.assertIn("TweaksProtocolVersion: Int = 4", report)
        self.assertIn("TweaksProtocolVersion: Int = 5", report)
        self.assertIn(core_path, report)
        self.assertIn("REVIEW REQUIRED", report)

    def test_reports_all_changed_files_from_each_public_base(self):
        self.write("docs/release-note.md", "Release note\n")
        self.commit()
        self.git("tag", "5.2.0")
        scheme = "snapo-app-mac/Snap-O.xcodeproj/xcshareddata/xcschemes/Snap-O.xcscheme"
        self.write(scheme, "Archive configuration\n")
        self.write("custom-build/input.txt", "Build input\n")
        self.commit()
        self.write("uncommitted.txt", "Local edit\n")

        report = self.report(android_base="5.2.0")
        mac_files = report.split("Changed files since macOS base 5.1.0:\n", 1)[1].split("\n\n", 1)[0]
        android_files = report.split("Changed files since Android base 5.2.0:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(mac_files, "  A\tcustom-build/input.txt\n"
                         "  A\tdocs/release-note.md\n"
                         f"  A\t{scheme}")
        self.assertEqual(android_files, "  A\tcustom-build/input.txt\n"
                         f"  A\t{scheme}")
        self.assertNotIn("Recommendation:", report)

    def test_malformed_committed_build_number_is_rejected(self):
        for build in ("", "20260903", "20260903.0", "20260903.000", "2026093.00", "20260903.xx"):
            with self.subTest(build=build):
                self.write("VERSION", f"VERSION = 6.0.0\nBUILD_NUMBER = {build}\n")
                self.commit()
                result = self.run_preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must use YYYYMMDD.NN", result.stderr)
                self.assertNotIn("Preflight complete", result.stdout)

    def test_version_values_trim_only_surrounding_whitespace(self):
        for version, build, error in (
            ("6.0.0", "20260903.00", None),
            ("6.0 .0", "20260903.00", "must use MAJOR.MINOR.PATCH"),
            ("6.0.0", "20260903. 00", "must use YYYYMMDD.NN"),
        ):
            with self.subTest(version=version, build=build):
                self.write("VERSION", f"VERSION = \t{version}\t \nBUILD_NUMBER = \t{build}\t \n")
                self.commit()
                result = self.run_preflight()
                if error:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(error, result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("Source VERSION/build: 6.0.0 / 20260903.00", result.stdout)

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

    def test_reports_tweaks_version_before_and_after_core_extraction(self):
        _, old_path, declaration = DECLARATIONS[1]
        new_path = old_path.replace("/tweaks/", "/tweaks-core/", 1)
        self.write(new_path, self.baseline[old_path])
        (self.repo / old_path).unlink()
        self.commit()

        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        self.assertEqual(report.count(declaration), 2)
        self.assertIn(f"{old_path}:1:{declaration}", report)
        self.assertIn(f"{new_path}:1:{declaration}", report)

    def test_reports_versions_and_native_changes_after_inspector_package_move(self):
        for index, package in ((3, "network"), (4, "tweaks")):
            _, old_path, declaration = DECLARATIONS[index]
            new_path = old_path.replace("snapo-network-inspector-web/", f"inspectors/{package}/", 1)
            self.write(new_path, self.baseline[old_path])
            (self.repo / old_path).unlink()
        native = "snapo-app-mac/Snap-O/Inspectors/InspectorHTTPService.swift"
        self.write(native, "struct InspectorHTTPService {}\n")
        self.commit()

        report = self.report()
        comparison = report.split("Mac/web/CLI clients protocol comparison:", 1)[1]
        self.assertNotIn("UNRESOLVED", comparison)
        for index, package in ((3, "network"), (4, "tweaks")):
            _, old_path, declaration = DECLARATIONS[index]
            new_path = old_path.replace("snapo-network-inspector-web/", f"inspectors/{package}/", 1)
            self.assertIn(f"{old_path}:1:{declaration}", comparison)
            self.assertIn(f"{new_path}:1:{declaration}", comparison)
        self.assertIn(native, comparison)

    def test_reports_protocols_after_repository_reorganization(self):
        for _, path, _ in DECLARATIONS:
            (self.repo / path).unlink(missing_ok=True)
        declarations = {
            "plugins/network/android/core/build.gradle.kts": "protocolVersion = 3",
            "plugins/tweaks/android/core/build.gradle.kts": "protocolVersion = 7",
            "plugins/network/frontend/src/features/network-tool/lib/protocol.ts": "const supportedProtocolVersion = 3;",
            "plugins/tweaks/frontend/src/features/tweaks-tool/protocol.ts": "const supportedProtocolVersion = 7;",
            "cli/snapo": "NETWORK_PROTOCOL_VERSION = 3\nTWEAKS_PROTOCOL_VERSION = 7",
        }
        for path, content in declarations.items():
            self.write(path, content + "\n")
        for path in ("app-macos/Snap-O/Device/ToolDiscovery.swift", "sdk/runtime/src/Changed.kt", "plugin-reader/src/Changed.java"):
            self.write(path, "// fixture\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        for path in declarations:
            self.assertIn(path, report)
        self.assertIn("app-macos/Snap-O/Device/ToolDiscovery.swift", report)
        self.assertIn("sdk/runtime/src/Changed.kt", report)
        self.assertIn("plugin-reader/src/Changed.java", report)

    def test_reports_protocols_after_tool_directory_rename(self):
        for _, path, _ in DECLARATIONS:
            (self.repo / path).unlink(missing_ok=True)
        declarations = {
            "tools/network/android/core/src/main/java/com/openai/snapo/network/NetworkToolHttp.kt": "internal const val NetworkProtocolVersion = 4",
            "tools/tweaks/android/core/src/main/java/com/openai/snapo/tweaks/internal/TweakHttpServer.kt": "internal const val TweaksProtocolVersion = 8",
            "tools/network/frontend/src/features/network-tool/lib/protocol.ts": "const supportedProtocolVersion = 4;",
            "tools/tweaks/frontend/src/features/tweaks-tool/protocol.ts": "const supportedProtocolVersion = 8;",
            "skills/snap-o-network-inspector/scripts/snapo-network": "NETWORK_PROTOCOL_VERSION = 4",
            "skills/snap-o-tweaks/scripts/snapo-tweaks": "TWEAKS_PROTOCOL_VERSION = 8",
        }
        for path, content in declarations.items():
            self.write(path, content + "\n")
        for path in ("app-macos/Snap-O/Device/ToolDiscovery.swift", "tool-sdk/runtime/src/Changed.kt", "tool-reader/src/Changed.java"):
            self.write(path, "// fixture\n")
        self.commit()
        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        for path in declarations:
            self.assertIn(path, report)
        self.assertIn("app-macos/Snap-O/Device/ToolDiscovery.swift", report)
        self.assertIn("tool-sdk/runtime/src/Changed.kt", report)
        self.assertIn("tool-reader/src/Changed.java", report)

    def test_reports_removed_swift_network_client(self):
        label, path, declaration = DECLARATIONS[2]
        (self.repo / path).unlink()
        self.commit()

        report = self.report()
        self.assertNotIn("UNRESOLVED", report)
        self.assertEqual(report.count(f"    {label}:\n"), 1)
        self.assertEqual(report.count(declaration), 1)
        self.assertIn("Swift Network client: absent; review the Web Network client below.", report)
        self.assertEqual(report.count("    Web Network supported version:\n"), 2)

    def test_each_missing_declaration_is_unresolved_despite_other_matches(self):
        debug = "snapo-link-android/network/frontend/src/features/network-inspector/lib/debug.ts"
        for label, missing_path, declaration in DECLARATIONS:
            with self.subTest(label=label):
                for path, content in self.baseline.items():
                    self.write(path, content)
                self.write(missing_path, self.baseline[missing_path].replace(declaration + "\n", ""))
                self.write(debug, "const supportedProtocolVersion = 1;\n")
                self.commit()
                report = self.report()
                self.assertEqual(report.count("UNRESOLVED:"), 1)
                self.assertIn(f"UNRESOLVED: {label} not found in", report)
                unresolved = next(line for line in report.splitlines() if f"UNRESOLVED: {label}" in line)
                self.assertIn(missing_path, unresolved)
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
