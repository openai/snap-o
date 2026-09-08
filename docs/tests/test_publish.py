"""Exercise documentation publication against a local Git remote."""

from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/publish-docs.sh"
SOURCE_SHA = "a" * 40


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], text=True, stderr=subprocess.STDOUT,
    ).strip()


class DocumentationPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.remote = root / "remote.git"
        self.publication = root / "publication"
        self.site = root / "site"
        self.site.mkdir()
        git(root, "init", "--bare", str(self.remote))
        git(root, "init", "-b", "gh-pages", str(self.publication))
        git(self.publication, "config", "user.name", "Test Publisher")
        git(self.publication, "config", "user.email", "publisher@example.com")
        self.preserved = {
            "appcast.xml": "<rss><channel/></rss>\n",
            "releases/example.dmg": "synthetic release fixture\n",
            "old-guide.html": "Existing public page\n",
        }
        for name, content in self.preserved.items():
            path = self.publication / name
            path.parent.mkdir(exist_ok=True)
            path.write_text(content)
        (self.publication / "index.html").write_text("Old homepage\n")
        git(self.publication, "add", ".")
        git(self.publication, "commit", "-m", "Initial publication")
        git(self.publication, "remote", "add", "origin", str(self.remote))
        git(self.publication, "push", "origin", "gh-pages")
        (self.site / "index.html").write_text("New homepage\n")
        (self.site / ".nojekyll").touch()
        (self.site / "assets").mkdir()
        (self.site / "assets/guide.css").write_text("body { color: black; }\n")

    def publish(self):
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.site), str(self.publication), SOURCE_SHA],
            capture_output=True, text=True,
        )

    def test_publish_preserves_release_files_and_repeat_is_noop(self):
        result = self.publish()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        for name, content in self.preserved.items():
            self.assertEqual(content, (self.publication / name).read_text())
        self.assertEqual("New homepage\n", git(self.remote, "show", "gh-pages:index.html") + "\n")
        self.assertEqual("", git(self.remote, "show", "gh-pages:.nojekyll"))
        first_commit = git(self.remote, "rev-parse", "gh-pages")
        self.assertEqual(0, self.publish().returncode)
        self.assertEqual(first_commit, git(self.remote, "rev-parse", "gh-pages"))

    def test_rejects_feed_and_symlink_in_artifact_before_copying(self):
        for name in ("appcast.xml", "assets/linked.css"):
            with self.subTest(path=name):
                path = self.site / name
                if name.endswith(".xml"):
                    path.write_text("Unexpected feed replacement")
                else:
                    path.symlink_to(self.site / "index.html")
                result = self.publish()
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Unexpected documentation artifact", result.stderr)
                self.assertEqual("Old homepage\n", (self.publication / "index.html").read_text())
                self.assertEqual("", git(self.publication, "status", "--porcelain"))
                path.unlink()

    def test_concurrent_release_rejects_push_without_losing_feed(self):
        other = Path(self.directory.name) / "release"
        git(other.parent, "clone", "--branch", "gh-pages", str(self.remote), str(other))
        (other / "appcast.xml").write_text("<rss><channel><title>New release</title></channel></rss>\n")
        git(other, "add", "appcast.xml")
        git(other, "-c", "user.name=Release Publisher", "-c", "user.email=release@example.com",
            "commit", "-m", "Publish a release")
        git(other, "push", "origin", "gh-pages")
        release_commit = git(self.remote, "rev-parse", "gh-pages")
        result = self.publish()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(release_commit, git(self.remote, "rev-parse", "gh-pages"))
        self.assertIn("New release", git(self.remote, "show", "gh-pages:appcast.xml"))


if __name__ == "__main__":
    unittest.main()
