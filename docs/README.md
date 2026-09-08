# Documentation sources

The Markdown files in this directory generate the public [Snap-O documentation](https://openai.github.io/snap-o/).
Edit these sources instead of editing HTML on `gh-pages`.

The initial conversion uses `gh-pages` commit `15c0bb59d8e4ddeabda655ebdfa5392541f23cb8`.
Its guide text, code examples, dependency versions, page URLs, and existing section anchors are preserved.
The CLI and macOS usage guides were added during the README cleanup.

## Build and preview

Use Python 3.10 or later. From the repository root:

```bash
python3 -m venv docs/.venv
docs/.venv/bin/python -m pip install -r docs/requirements.txt
docs/.venv/bin/mkdocs build --strict
docs/.venv/bin/mkdocs serve
```

Open [localhost:8000/snap-o/](http://localhost:8000/snap-o/). MkDocs reloads the preview when sources change.
`mkdocs build --strict` writes the site to `site/` and fails on broken Markdown links or anchors.
Building and previewing do not publish anything.

Run the theme integration tests with:

```bash
docs/.venv/bin/python -m unittest discover -s docs/tests -v
```

## Pages

| Source | Site path |
| --- | --- |
| [index.md](index.md) | `/snap-o/` |
| [network-inspector.md](network-inspector.md) | `/snap-o/network-inspector.html` |
| [network-intercept.md](network-intercept.md) | `/snap-o/network-intercept.html` |
| [tweaks.md](tweaks.md) | `/snap-o/tweaks.html` |
| [tweaks-protocol.md](tweaks-protocol.md) | `/snap-o/tweaks-protocol.html` |
| [cli.md](cli.md) | `/snap-o/cli.html` |
| [usage.md](usage.md) | `/snap-o/usage.html` |

## Writing pages

Each page starts with YAML metadata between `---` lines. This sets its layout, browser title, description, styles, and breadcrumbs.
Add new pages to `nav` in the root `mkdocs.yml`. Its `exclude_docs` setting keeps this README, build dependencies, and tests out of the site.

Use ordinary Markdown for headings, paragraphs, links, lists, and tables.
Use one `#` heading for the page title and `##` headings for its main sections.
The build generates the section layout and navigation from those headings.

Preserve explicit section IDs so existing links keep working:

```markdown
## Add the Android dependency {#install data-step="2"}
```

`data-step` supplies an optional step number. `data-nav` supplies a shorter navigation label when needed.
Link to other source files, such as `network-intercept.md#first-request`; the build changes these to HTML links.
Use full GitHub URLs when linking to repository files outside `docs/`.
Breadcrumbs in YAML metadata use the output path, such as `network-inspector.html`.

Code blocks use a language, an optional caption, and optional highlighted line numbers:

````markdown
``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3" }
dependencies {
    debugImplementation(libs.snapo.network.okhttp3)
    releaseImplementation(libs.snapo.network.okhttp3.noop)
}
```
````

The build adds copy buttons and syntax-highlighting markup. Code examples are not executed during the build.

Expandable sections use `<details markdown="1">` and `<summary>` around Markdown content.
Dependency tabs use small HTML wrappers around Markdown blocks:

```html
<div class="dependency-tabs" data-label="Dependency format" markdown="1">
<div id="example-catalog-panel" data-tab="Version catalog" markdown="1">

Markdown content for the first tab.

</div>
<div id="example-direct-panel" data-tab="Direct dependency" markdown="1">

Markdown content for the second tab.

</div>
</div>
```

The first tab is selected initially. Keep panel IDs unique and stable.
The build generates the tab buttons, accessibility attributes, and keyboard navigation targets.

## Theme and publishing

The root `mkdocs.yml` configures the build, navigation, validation, and `.html` URLs.
`docs-theme/` owns the Jinja templates; `docs/assets/` contains the styles, scripts, and images.
`docs/hooks.py` adapts rendered Markdown to the existing numbered sections, code captions, and dependency tabs.
MkDocs handles Markdown rendering, page discovery, links, asset copying, and live preview.

Pull requests and pushes run the strict build and documentation tests without publishing.
Follow the [release instructions](../release/README.md#release-notes-and-website) when choosing documentation for released features.

### Publish an update

Once the workflow is on the default branch:

1. Open **Actions → Publish documentation → Run workflow** on GitHub.
2. Leave the workflow branch on `main`. Enter the tag, branch, or full commit SHA to build in `source_ref`.
3. Choose a revision that contains the MkDocs sources and documents only released functionality.
4. Run the workflow and check its summary for the source SHA, `gh-pages` commit, and site URL.

The workflow builds and tests the selected revision with read-only repository permissions.
A separate job copies the generated files into the latest `gh-pages` checkout, commits, and pushes.
It preserves `appcast.xml`, release files, and old pages absent from the new build.
It explicitly requests a GitHub Pages build and waits for the published commit.

Keep **Settings → Pages → Source** set to **Deploy from a branch**, with `gh-pages` and `/ (root)`.
The workflow uses `GITHUB_TOKEN` with `contents: write` and `pages: write`; no extra token is needed.
Repository rules must allow the workflow to push to `gh-pages`.

If a release updates `gh-pages` during publication, the push fails without overwriting it. Rerun the workflow with a fresh checkout.
If the push succeeds but the Pages build fails, rerun the same source revision to retry publication.
The workflow never edits the update feed; appcast updates remain part of the release process.
Renamed or removed pages stay on `gh-pages` until deliberately removed or replaced with redirects.
Do not use `mkdocs gh-deploy`: it replaces the branch contents and would remove the Sparkle update feed.
