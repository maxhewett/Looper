"""Build the Looper GitHub Pages site from its static assets and repository docs."""

import argparse
import re
import shutil
from html import escape
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit, urlunsplit

from markdown import Markdown
from markdown.extensions import Extension
from markdown.treeprocessors import Treeprocessor

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
GITHUB = "https://github.com/maxhewett/Looper"
PAGES = {
    "index.html": ("Getting started", "website/guides/getting-started.md"),
    "deployment.html": ("Jamf deployment", "Deployment/README.md"),
    "architecture.html": ("Inside Looper", "website/guides/architecture.md"),
}


DEPLOYMENT_FILES = {
    "Looper-Lab.mobileconfig": ("Profile", "Essential sounds, preload and background-item approvals."),
    "Looper-Notifications.mobileconfig": ("Profile", "Silent banners for signed-in lab users."),
    "Looper-Managed-Login-Items.mobileconfig": ("Profile", "Helper and login-item approvals for custom rollouts."),
    "Jamf-Looper.schema.json": ("JSON", "Preference fields for Jamf’s custom settings editor."),
}


def attachment_panel():
    links = []
    for name, (kind, description) in DEPLOYMENT_FILES.items():
        links.append(f'<a download href="../downloads/{name}"><i aria-hidden="true">{kind}</i>'
                     f'<span><strong>{name}</strong><small>{description}</small></span></a>')
    links.append(f'<a href="{GITHUB}/releases/download/v1.0/Looper-1.0.pkg">'
                 '<i aria-hidden="true">PKG</i><span><strong>Looper-1.0.pkg</strong>'
                 '<small>Signed installer for the lab Macs.</small></span></a>')
    return '<aside class="attachments" aria-label="Deployment downloads"><h2>Downloads</h2>' + "".join(links) + '</aside>'


class RepositoryLinks(Treeprocessor):
    def __init__(self, md, source):
        super().__init__(md)
        self.source = source

    def run(self, root):
        for element in root.iter():
            attribute = {"a": "href", "img": "src"}.get(element.tag)
            if attribute is None or attribute not in element.attrib:
                continue
            target = urlsplit(element.get(attribute))
            if target.scheme or target.netloc or not target.path or target.path.startswith("/"):
                continue
            path = (self.source.parent / unquote(target.path)).resolve().relative_to(REPO)
            wiki_page = next((page for page, (_, doc) in PAGES.items() if path.as_posix() == doc), None)
            if wiki_page:
                url = wiki_page
            else:
                area = "raw" if element.tag == "img" else ("tree" if (REPO / path).is_dir() else "blob")
                url = f"{GITHUB}/{area}/main/{quote(path.as_posix())}"
            element.set(attribute, urlunsplit((*urlsplit(url)[:3], target.query, target.fragment)))


class RepositoryExtension(Extension):
    def __init__(self, source):
        super().__init__()
        self.source = source

    def extendMarkdown(self, md):
        md.treeprocessors.register(RepositoryLinks(md, self.source), "repository-links", 5)


def render_guide(filename, title, source):
    renderer = Markdown(
        extensions=["fenced_code", "tables", "toc", RepositoryExtension(source)],
        extension_configs={"toc": {"toc_depth": "2-6"}},
    )
    content = source.read_text(encoding="utf-8")
    if filename == "deployment.html":
        intro, _, rest = content.partition("## Packaging")
        _, _, policies = rest.partition("## Jamf/MDM deployment")
        content = intro + "## Configure the pilot Macs" + policies
        content = re.sub(r"^   ", "", content, flags=re.M)
    body = renderer.convert(content)
    body = re.sub(r"(<table>.*?</table>)", r'<div class="table-wrap" tabindex="0" role="region" aria-label="Documentation table">\1</div>', body, flags=re.S)
    toc = renderer.toc
    current = ' aria-current="page"'
    navigation = "".join(
        f'<a href="{link}"{current if filename == link else ""}>{label}</a>'
        for link, (label, _) in PAGES.items()
    )
    screenshots = {
        "index.html": (
            "library.png",
            "Looper Library showing installed and missing sound packs",
            "Open Library to check which packages are installed, missing or available to download.",
        ),
        "deployment.html": (
            "deployment.png",
            "Looper Settings showing the Deployment export controls",
            "Use Settings → Deployment on a reference Mac to export a configuration profile.",
        ),
    }
    screenshot = ""
    if filename in screenshots:
        image, alt, caption = screenshots[filename]
        screenshot = f"""
        <figure class="app-shot">
          <a href="../assets/{image}"><img src="../assets/{image}" alt="{alt}" width="2744" height="1744" loading="lazy"></a>
          <figcaption>{caption}</figcaption>
        </figure>
        """
    introduction, heading_end, sections = body.partition("</h1>")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} · Looper Wiki</title>
<link rel="icon" href="../assets/looper-icon.png">
<script src="../assets/site.js"></script>
<link rel="stylesheet" href="../assets/site.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="shell nav">
  <a class="brand" href="../"><img src="../assets/looper-icon.png" alt="" width="36" height="36">Looper</a>
  <nav aria-label="Primary"><a href="../#features">Features</a><a href="./" aria-current="page">Wiki</a><a href="{GITHUB}"><span class="mark github"></span>GitHub</a><select id="theme" aria-label="Appearance" title="Appearance" hidden><option value="auto">System</option><option value="light">Light</option><option value="dark">Dark</option></select></nav>
</header>
<main class="shell docs{' deployment-doc' if filename == 'deployment.html' else ''}" id="main">
  <nav class="doc-nav" aria-label="Wiki"><p class="eyebrow">Wiki</p>{navigation}</nav>
  <article class="doc-body">
    {introduction}{heading_end}
    <details class="contents"><summary>On this page</summary>{toc}</details>
    {screenshot}
    {sections}
  </article>
  {attachment_panel() if filename == "deployment.html" else ""}
</main>
<footer class="shell footer"><span class="platform"><span class="mark swift"></span>Built with Swift for macOS</span><a href="{GITHUB}/blob/main/{quote(source.relative_to(REPO).as_posix())}">View source document</a></footer>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New directory for the generated site")
    output = parser.parse_args().output
    output.mkdir(parents=True)
    shutil.copy2(SITE / "index.html", output)
    shutil.copytree(SITE / "assets", output / "assets")
    (output / ".nojekyll").touch()
    downloads = output / "downloads"
    downloads.mkdir()
    for name in DEPLOYMENT_FILES:
        shutil.copy2(REPO / "Deployment" / name, downloads)
    wiki = output / "wiki"
    wiki.mkdir()
    for filename, (title, source) in PAGES.items():
        (wiki / filename).write_text(render_guide(filename, title, REPO / source), encoding="utf-8")


if __name__ == "__main__":
    main()
