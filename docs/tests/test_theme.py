"""Check Snap-O's theme integration with MkDocs."""

import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from urllib.parse import unquote, urlsplit

from bs4 import BeautifulSoup
import markdown
from mkdocs.commands.build import build
from mkdocs.config import load_config

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("docs_hooks", ROOT / "docs/hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


class DocumentationThemeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.output = Path(cls.directory.name)
        config = load_config(str(ROOT / "mkdocs.yml"), site_dir=str(cls.output), strict=True)
        build(config)
        cls.pages = {p.name: BeautifulSoup(p.read_text(), "html.parser") for p in cls.output.glob("*.html")}

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_public_urls_and_excluded_sources(self):
        expected = {"index", "network-inspector", "network-intercept", "tweaks", "tweaks-protocol", "cli", "usage"}
        self.assertEqual(expected, {Path(name).stem for name in self.pages})
        self.assertTrue((self.output / ".nojekyll").is_file())
        for name in ("appcast.xml", "hooks.py", "requirements.txt", "README.html", "tests", ".venv"):
            self.assertFalse((self.output / name).exists(), name)

    def test_template_links_and_tab_targets(self):
        # MkDocs validates Markdown links; this covers links and IDs added by the theme.
        for name, soup in self.pages.items():
            with self.subTest(page=name):
                ids = [node["id"] for node in soup.select("[id]")]
                self.assertEqual(len(ids), len(set(ids)), "duplicate IDs")
                for node in soup.select("[href], [src]"):
                    for attribute in ("href", "src"):
                        if not node.has_attr(attribute):
                            continue
                        url = urlsplit(node[attribute])
                        if url.scheme or url.netloc:
                            continue
                        target = self.output / unquote(url.path or name)
                        self.assertTrue(target.is_file(), (name, node[attribute]))
                        if url.fragment and target.suffix == ".html":
                            self.assertIsNotNone(self.pages[target.name].find(id=unquote(url.fragment)), node[attribute])
                for node in soup.select("[aria-controls], [aria-labelledby]"):
                    for attribute in ("aria-controls", "aria-labelledby"):
                        for identifier in node.get(attribute, "").split():
                            self.assertIn(identifier, ids)

    def test_list_styles_apply_to_lists(self):
        soup = self.pages["network-inspector.html"]
        self.assertIsNotNone(soup.select_one("ol.verify-list > li > span > strong"))
        self.assertIsNotNone(soup.select_one("ul.check-list > li"))
        self.assertFalse(soup.select("li.verify-list, li.check-list"))

    def test_nested_code_tabs_and_escaping(self):
        body = '''# Example

A short introduction.

## Dependencies {#install data-step="2" data-nav="Install"}

<details markdown="1">
<summary>OkHttp</summary>

<div class="dependency-tabs" data-label="Dependency format" markdown="1">
<div id="example-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2" }
val x = "<tag>&value"
val y = 2
```

</div>
<div id="example-direct-panel" data-tab="Direct dependency" markdown="1">

Direct dependency content.

</div>
</div>
</details>
'''
        page = SimpleNamespace(
            content=markdown.markdown(body, extensions=["extra", "toc"]),
            meta={"layout": "guide"}, file=SimpleNamespace(src_uri="example.md"),
        )
        context = hooks.on_page_context({}, page, None, None)
        section = context["sections"][0]
        self.assertEqual(("install", "2", "Install"), (section["id"], section["step"], section["nav"]))
        soup = BeautifulSoup(section["body"], "html.parser")
        code = soup.select_one("details .code-block code")
        self.assertEqual('val x = "<tag>&value"\nval y = 2', code.get_text())
        self.assertIsNone(code.find("tag"))
        self.assertEqual("2", code["data-emphasis-lines"])
        self.assertEqual("app/build.gradle.kts", soup.select_one(".code-head span").get_text())
        self.assertEqual("example-catalog-panel", soup.select_one('[role="tab"][aria-selected="true"]')["aria-controls"])
        self.assertTrue(soup.find(id="example-direct-panel").has_attr("hidden"))


if __name__ == "__main__":
    unittest.main()
