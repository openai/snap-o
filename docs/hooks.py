"""Adapt MkDocs HTML to Snap-O's existing guide and homepage layouts."""

from bs4 import BeautifulSoup
from mkdocs.exceptions import PluginError


def decorate(soup):
    for paragraph in soup.find_all("p"):
        if not paragraph.get("class"):
            paragraph["class"] = ["prose"]

    for tag, class_name in (("ol", "verify-list"), ("ul", "check-list")):
        for listing in soup.find_all(tag):
            if not listing.get("class"):
                listing["class"] = [class_name]

    for item in soup.select("ol.verify-list > li"):
        # Keep inline elements together in the text column beside the step number.
        tag = "div" if item.find(["p", "ul", "ol", "pre", "div"]) else "span"
        content = soup.new_tag(tag)
        for child in list(item.contents):
            content.append(child.extract())
        item.append(content)

    for table in soup.find_all("table"):
        table["class"] = ["config-table"]
        table.wrap(soup.new_tag("div", attrs={"class": "table-scroll"}))

    for details in soup.find_all("details"):
        body = soup.new_tag("div", attrs={"class": "details-body"})
        for child in list(details.contents):
            if child.name != "summary":
                body.append(child.extract())
        details.append(body)

    for code in soup.select("pre > code"):
        classes = code.get("class", [])
        language = next((c.removeprefix("language-") for c in classes if c.startswith("language-")), "text")
        label = code.attrs.pop("title", language)
        code["class"] = ["syntax-code"]
        code["data-language"] = language
        # Fenced Markdown adds a final newline; the published copy buttons did not.
        code.string = code.get_text().removesuffix("\n")
        head = soup.new_tag("div", attrs={"class": "code-head"})
        caption = soup.new_tag("span")
        caption.string = label
        button = soup.new_tag("button", attrs={"class": "copy-button", "type": "button"})
        button.string = "Copy"
        head.extend([caption, button])
        wrapper = soup.new_tag("div", attrs={"class": "code-block"})
        code.parent.wrap(wrapper)
        wrapper.insert(0, head)

    for group in soup.select(".dependency-tabs"):
        tablist = soup.new_tag("div", attrs={
            "class": "dependency-format-tabs", "role": "tablist",
            "aria-label": group["data-label"],
        })
        panels = group.select(":scope > [data-tab]")
        if not panels:
            raise PluginError("A dependency tab group must contain panels")
        for index, panel in enumerate(panels):
            identifier = panel["id"]
            button_id = identifier.removesuffix("-panel") + "-tab"
            button = soup.new_tag("button", attrs={
                "class": "dependency-format-tab", "id": button_id,
                "type": "button", "role": "tab", "aria-controls": identifier,
                "aria-selected": "true" if index == 0 else "false",
                "tabindex": "0" if index == 0 else "-1",
            })
            button.string = panel.attrs.pop("data-tab")
            tablist.append(button)
            panel["class"] = ["dependency-format-panel"]
            panel["role"] = "tabpanel"
            panel["aria-labelledby"] = button_id
            if index:
                panel["hidden"] = ""
        group.insert(0, tablist)
        group.unwrap()


def on_page_context(context, page, config, nav):
    soup = BeautifulSoup(page.content, "html.parser")
    decorate(soup)
    titles = soup.find_all("h1", recursive=False)
    if len(titles) != 1:
        raise PluginError(f"{page.file.src_uri}: expected one top-level # title")
    title = str(titles[0].extract())
    introduction = []
    sections = []
    current = None
    for node in list(soup.contents):
        if node.name == "h2":
            current = {
                "id": node.attrs.pop("id"),
                "step": node.attrs.pop("data-step", ""),
                "nav": node.attrs.pop("data-nav", node.get_text()),
                "heading": str(node), "nodes": [],
            }
            sections.append(current)
        elif current is None:
            introduction.append(node)
        else:
            current["nodes"].append(node)
    note = ""
    if page.meta["layout"] == "home":
        notes = [node for node in introduction if node.name and "note" in node.get("class", [])]
        note = "".join(str(node) for node in notes)
        introduction = [node for node in introduction if node not in notes]
    for section in sections:
        nodes = section.pop("nodes")
        if page.meta["layout"] == "home":
            content = "".join(
                node.decode_contents() if node.name == "p" and node.select_one("a.section-link") else str(node)
                for node in nodes if str(node).strip()
            )
            # The homepage aligns a feature's description and link in one column.
            section["body"] = "<div>" + content + "</div>" if "section-link" in content else content
        else:
            section["body"] = "".join(str(node) for node in nodes)
    context.update(
        title=title,
        introduction="".join(map(str, introduction)),
        sections=sections,
        note=note,
    )
    return context
