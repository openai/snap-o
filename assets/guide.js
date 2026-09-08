const escapeHtml = (value) =>
  value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#039;",
      })[character],
  );

if (window.Prism?.languages?.kotlin) {
  Prism.languages.insertBefore("kotlin", "function", {
    "class-name": /\b[A-Z][A-Za-z0-9_]*\b/,
  });
}

for (const code of document.querySelectorAll(".syntax-code")) {
  const source = code.textContent;
  const language = code.dataset.language;
  const emphasisLines = new Set(
    (code.dataset.emphasisLines || "")
      .split(",")
      .filter(Boolean)
      .map(Number),
  );
  const grammar = window.Prism?.languages?.[language];
  const highlightedCode = grammar
    ? Prism.highlight(source, grammar, language)
    : escapeHtml(source);

  code.dataset.copyText = source;
  if (emphasisLines.size === 0) {
    code.innerHTML = highlightedCode;
    continue;
  }

  code.innerHTML = highlightedCode
    .split("\n")
    .map((line, index) => {
      const emphasisClass = emphasisLines.has(index + 1)
        ? "code-line-emphasis"
        : "code-line-muted";
      return `<span class="code-line ${emphasisClass}">${line}</span>`;
    })
    .join("");
}

for (const button of document.querySelectorAll(".copy-button")) {
  button.addEventListener("click", async () => {
    const code = button.closest(".code-block").querySelector("code");
    await navigator.clipboard.writeText(code.dataset.copyText || code.innerText);
    button.textContent = "Copied";
    window.setTimeout(() => {
      button.textContent = "Copy";
    }, 1400);
  });
}

for (const tablist of document.querySelectorAll(".dependency-format-tabs")) {
  const tabs = [...tablist.querySelectorAll('[role="tab"]')];

  const activateTab = (activeTab, moveFocus = false) => {
    for (const tab of tabs) {
      const isActive = tab === activeTab;
      const panel = document.getElementById(tab.getAttribute("aria-controls"));
      tab.setAttribute("aria-selected", String(isActive));
      tab.tabIndex = isActive ? 0 : -1;
      panel.hidden = !isActive;
    }

    if (moveFocus) {
      activeTab.focus();
    }
  };

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => activateTab(tab));
    tab.addEventListener("keydown", (event) => {
      let nextIndex;

      if (event.key === "ArrowRight") {
        nextIndex = (index + 1) % tabs.length;
      } else if (event.key === "ArrowLeft") {
        nextIndex = (index - 1 + tabs.length) % tabs.length;
      } else if (event.key === "Home") {
        nextIndex = 0;
      } else if (event.key === "End") {
        nextIndex = tabs.length - 1;
      } else {
        return;
      }

      event.preventDefault();
      activateTab(tabs[nextIndex], true);
    });
  });
}

const sections = [...document.querySelectorAll(".guide-section")];
const jumpLinks = [...document.querySelectorAll(".quick-jump-link")];

if ("IntersectionObserver" in window && jumpLinks.length > 0) {
  const setCurrentSection = (id) => {
    for (const link of jumpLinks) {
      if (link.hash === `#${id}`) {
        link.setAttribute("aria-current", "location");
      } else {
        link.removeAttribute("aria-current");
      }
    }
  };

  const sectionObserver = new IntersectionObserver(
    (entries) => {
      const visibleSection = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];

      if (visibleSection) {
        setCurrentSection(visibleSection.target.id);
      }
    },
    { rootMargin: "-18% 0px -68%", threshold: 0 },
  );

  for (const section of sections) {
    sectionObserver.observe(section);
  }

  setCurrentSection(sections[0].id);
}

document.getElementById("year").textContent = new Date().getFullYear();
