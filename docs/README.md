# Documentation sources

The Markdown files in this directory generate the public [Snap-O documentation](https://openai.github.io/snap-o/).
Edit these sources instead of editing HTML on `gh-pages`.

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

Run the documentation tests with:

```bash
docs/.venv/bin/python -m unittest discover -s docs/tests -v
```

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

## Theme

`mkdocs.yml` configures the build. Templates live in `docs/theme/`; styles, scripts, and images live in `docs/assets/`.
`docs/hooks.py` handles numbered sections, code captions, and dependency tabs.

`assets/theme.css` defines the homepage's dark palette, space background, and footer.
Guides use the original light palette in `assets/guide.css` and their page styles.
`theme/robot.html`, `assets/robot.css`, and `assets/robot.js` provide the shared robot and its click animation.
Guides show the robot above page navigation when the viewport is at least 1200 pixels wide.
Space artwork uses WebP images. The robot and rocket have twice their maximum display resolution for sharp rendering on Retina screens.

The homepage uses `assets/planet.js` for procedural cloud bands, atmosphere, and nebula shading.
Warped noise creates the planet's blue-teal wisps, with upper-right lighting based on the original artwork.
Fine cloud detail fades below pixel size to limit shimmer during rotation. The sky shading comes from the Snap-O robot viewer.
The globe follows the original WebP's silhouette and responsive CSS placement, with one rotation every four minutes.
Cloud wisps drift and small storms curl gently through a separate four-minute cycle, starting one minute in.
Its color fades toward the page background using the artwork's directional mask and responsive opacity.
Drawing is limited to 30 frames per second and a buffer of at most 2560 × 1536 pixels.
The nebula and stars render once per resize. The animated pass only draws the visible part of the planet.
The opaque surface hides the nebula and stars. Only the atmosphere blends with the sky.
Rendering pauses in hidden tabs. Reduced motion, data-saving mode, and graphics failures keep the original `assets/space-planet.webp` image.
No surface texture, graphics library, or JavaScript build step is required.
