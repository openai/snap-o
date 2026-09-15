"""Check release smoke coverage and keep full authoring validation as the default."""

from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("validate_authoring", Path(__file__).parents[1] / "validate_authoring.py")
authoring = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(authoring)


class AuthoringModeTest(unittest.TestCase):
    def validate(self, mode=None, invalid_sdk=False):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            output = Path(directory)
            mocks = {name: stack.enter_context(patch.object(authoring, name)) for name in (
                "run", "verify_maven", "plugin_jar", "verify_sdk", "node_free_environment",
                "verify_host_dependency", "verify_host_upgrades", "verify_frontend_modes", "verify_example",
            )}
            mocks["verify_maven"].return_value = ["example:core:1.0.0"]
            mocks["verify_sdk"].return_value = b"validated SDK"
            mocks["node_free_environment"].return_value = {"PATH": "/synthetic/no-node"}
            args = ["--output", str(output)]
            if mode:
                args.extend(["--mode", mode])
            if invalid_sdk:
                mocks["verify_sdk"].side_effect = AssertionError("Missing SDK files")
                with self.assertRaisesRegex(AssertionError, "Missing SDK"):
                    authoring.main(args)
                self.assertFalse((output / "report.json").exists())
                return
            with redirect_stdout(io.StringIO()):
                authoring.main(args)
            for name in ("verify_maven", "verify_sdk", "verify_host_dependency", "verify_example"):
                mocks[name].assert_called_once()
            report = json.loads((output / "report.json").read_text())
            calls = mocks["run"].call_args_list
            commands = [call.args[0] for call in calls]
            assemblies = [call for call in calls if ":app:assembleDebug" in call.args[0]]
            self.assertIn(":app:assembleRelease", assemblies[0].args[0])
            self.assertEqual(assemblies[0].kwargs["env"]["PATH"], "/synthetic/no-node")
            self.assertFalse(report["published"])
            self.assertTrue(all("publishToMavenCentral" not in command for command in commands))
            return report, commands, mocks

    def test_smoke_checks_packages_and_both_apks_without_claiming_full_coverage(self):
        report, commands, mocks = self.validate("release-smoke")
        self.assertEqual(len(commands), 3)
        self.assertEqual(report["mode"], "release-smoke")
        self.assertNotIn("configurationCacheReused", report)
        self.assertEqual(report["frontendModes"], ["managed-node-without-path"])
        mocks["verify_host_upgrades"].assert_not_called()
        mocks["verify_frontend_modes"].assert_not_called()

    def test_default_preserves_full_suite(self):
        report, commands, mocks = self.validate()
        self.assertEqual(report["mode"], "full")
        self.assertTrue(report["configurationCacheReused"])
        self.assertIn(["npm", "test"], commands)
        self.assertTrue(any(":app:lintRelease" in command for command in commands))
        self.assertTrue(any("test" in command and "validatePlugins" in command for command in commands))
        mocks["verify_host_upgrades"].assert_called_once()
        mocks["verify_frontend_modes"].assert_called_once()

    def test_smoke_rejects_invalid_packaged_sdk(self):
        self.validate("release-smoke", invalid_sdk=True)


if __name__ == "__main__":
    unittest.main()
