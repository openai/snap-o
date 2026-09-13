import json
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
DISPATCHER = REPOSITORY / "app-macos/cli/snapo"


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "Snap-O.app/Contents/MacOS"
        self.bundle.mkdir(parents=True)
        self.dispatcher = self.bundle / "snapo"
        shutil.copy2(DISPATCHER, self.dispatcher)

    def run_cli(self, *arguments):
        return subprocess.run(
            [str(self.dispatcher), *arguments], cwd=self.root,
            capture_output=True, text=True, timeout=10,
        )

    def write_tool(self, name, body):
        executable = self.bundle / f"snapo-{name}"
        executable.write_text("#!/usr/bin/env python3\n" + body)
        executable.chmod(0o755)
        return executable

    def test_help_does_not_require_tools(self):
        for arguments in ((), ("--help",), ("-h",)):
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("network|tweaks", result.stdout)

    def test_rejects_unknown_tools_and_old_ungrouped_commands(self):
        for tool in ("other", "list", "intercept", "../network"):
            with self.subTest(tool=tool):
                result = self.run_cli(tool)
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown tool", result.stderr)

    def test_dispatch_preserves_arguments_output_and_exit_status(self):
        for tool in ("network", "tweaks"):
            with self.subTest(tool=tool):
                self.write_tool(tool, "import json, sys\n"
                                "print(json.dumps(sys.argv[1:]))\n"
                                "print('tool diagnostic', file=sys.stderr)\n"
                                "sys.exit(23)\n")
                arguments = ["set", "Motion/Curve", '{"x1":0.25}', "", "--help"]
                result = self.run_cli(tool, *arguments)
                self.assertEqual(json.loads(result.stdout), arguments)
                self.assertEqual(result.stderr, "tool diagnostic\n")
                self.assertEqual(result.returncode, 23)

    def test_symlink_resolves_tools_beside_real_dispatcher(self):
        self.write_tool("network", "print('bundled network')\n")
        link = self.root / "snapo"
        link.symlink_to(self.dispatcher)
        self.dispatcher = link
        result = self.run_cli("network")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "bundled network\n")

    def test_missing_or_unexecutable_tool_has_readable_error(self):
        result = self.run_cli("network")
        self.assertEqual(result.returncode, 127)
        self.assertIn("cannot run", result.stderr)
        executable = self.write_tool("network", "pass\n")
        executable.chmod(0o644)
        result = self.run_cli("network")
        self.assertEqual(result.returncode, 126)
        self.assertIn("cannot run", result.stderr)

    def test_tool_replaces_dispatcher_and_receives_signals(self):
        self.write_tool("network", "import os, signal\n"
                        "print(os.getpid(), flush=True)\n"
                        "signal.pause()\n")
        with subprocess.Popen(
            [str(self.dispatcher), "network"], stdout=subprocess.PIPE, text=True,
        ) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], "tool did not start")
                self.assertEqual(int(process.stdout.readline()), process.pid)
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
            finally:
                if process.poll() is None:
                    process.kill()

    def test_copied_bundle_dispatches_real_tools_without_checkout(self):
        for tool, skill in (("network", "snap-o-network-inspector"), ("tweaks", "snap-o-tweaks")):
            shutil.copy2(REPOSITORY / "skills" / skill / "scripts" / f"snapo-{tool}", self.bundle)
            with self.subTest(tool=tool):
                result = self.run_cli(tool, "--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"snapo-{tool}", result.stdout)
        routes = self.root / "routes.py"
        shutil.copy2(REPOSITORY / "examples/routes.py", routes)
        result = self.run_cli("network", "intercept", str(routes), "--check")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
