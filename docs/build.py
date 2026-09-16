#!/usr/bin/env python3
"""Builds the documentation site from the repository.

    python3 docs/build.py

Every page is a fragment in docs/_src/ wrapped in the shared chrome from
_shared.py. The fragments hold the writing; everything that is a fact about
the code is filled in here, from the code, so the site cannot claim a number
nobody measured or show a sample that no longer compiles:

    {{version}}        the newest release tag
    {{month}}          when the site was built
    {{tests}}          test functions in Tests/
    {{products}}       library products in Package.swift
    {{bench_chart}}    the speed column of Benchmarks/RESULTS.md, drawn
    {{bench_table}}    the whole of it, as a table, with its notes
    {{snippet:name}}   a sample cut from Tests/LatheDocSnippetsTests, which
                       the test build compiles

A fragment names its page with two comments on its first lines:

    <!-- title: … -->
    <!-- description: … -->
"""
import datetime
import html
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _shared import head, footer  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
SOURCES = DOCS / "_src"
SNIPPETS = ROOT / "Tests" / "LatheDocSnippetsTests" / "Snippets.swift"
RESULTS = ROOT / "Benchmarks" / "RESULTS.md"


# MARK: - Facts

def facts():
    try:
        tag = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        version = tag.lstrip("v")
    except (subprocess.CalledProcessError, FileNotFoundError):
        version = "dev"
    tests = sum(
        len(re.findall(r"^\s*@Test\b", path.read_text(), re.M))
        + len(re.findall(r"^\s*func test\w*\(", path.read_text(), re.M))
        for path in (ROOT / "Tests").rglob("*.swift"))
    products = len(re.findall(r"\.library\(\s*name:", (ROOT / "Package.swift").read_text()))
    month = datetime.date.today().strftime("%B %Y")
    return {"version": version, "tests": f"{tests:,}", "products": str(products), "month": month}


# MARK: - Samples

KEYWORDS = {"let", "var", "try", "await", "async", "func", "import", "return", "for", "in",
            "if", "else", "guard", "throws", "print", "struct", "enum", "case"}


def snippets():
    text = SNIPPETS.read_text()
    found = {}
    for match in re.finditer(r"// snippet: (\w+)\n(.*?)\n\s*// end", text, re.S):
        lines = match.group(2).split("\n")
        indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
        found[match.group(1)] = "\n".join(l[indent:] for l in lines)
    return found


def highlight(code):
    out = []
    for line in code.split("\n"):
        body, comment = line, ""
        if "//" in line:
            index = line.index("//")
            body, comment = line[:index], line[index:]
        parts = re.split(r'("[^"]*")', body)
        body = "".join(
            f'<span class="s">{html.escape(part)}</span>' if index % 2 else
            re.sub(r"\b(" + "|".join(sorted(KEYWORDS)) + r")\b", r'<span class="k">\1</span>',
                   html.escape(part))
            for index, part in enumerate(parts))
        if comment:
            body += f'<span class="c">{html.escape(comment)}</span>'
        out.append(body)
    return "<pre><code>" + "\n".join(out) + "</code></pre>"


# MARK: - Benchmarks

def read_results():
    """The table, the notes and the versions out of RESULTS.md."""
    if not RESULTS.exists():
        return None
    text = RESULTS.read_text()
    rows = []
    for line in text.splitlines():
        if not line.startswith("|") or line.startswith("|---") or "| task |" in line:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) == 8:
            rows.append(cells)
    notes = []
    for line in text.splitlines():
        match = re.match(r"- \*\*(.+?)\*\* — (.+)", line)
        if match:
            notes.append((match.group(1), match.group(2)))
    versions, collecting = [], False
    for line in text.splitlines():
        if line.startswith("### Versions"):
            collecting = True
            continue
        if collecting:
            if line.startswith("###"):
                break
            if line.startswith("- "):
                versions.append(line[2:].strip())
    return {"rows": rows, "notes": notes, "versions": versions}


def markup(cell):
    cell = html.escape(cell, quote=False)
    cell = re.sub(r"\*\*(.+?)\*\*", r'<span class="win">\1</span>', cell)
    cell = re.sub(r"\*(.+?)\*", r"<em>\1</em>", cell)
    cell = re.sub(r"`(.+?)`", r"<code>\1</code>", cell)
    return cell.replace("⚠︎", '<span class="warn">⚠︎</span>')


def strip_tags(text):
    return re.sub(r"<[^>]+>", "", text)


def bench_chart(data, limit=None):
    """The speed column, drawn — the same numbers as the table.

    Square-rooted for drawing only: one row is over a hundred times and the
    rest are single digits, and on a linear scale every other bar would be a
    sliver. The figure on each bar is the real ratio. Slower rows are drawn
    too, in grey; a chart of only the wins would be advertising.
    """
    if not data:
        return ""
    parsed = []
    for cells in data["rows"]:
        match = re.search(r"([\d.]+)\s*×\s*(faster|slower)", cells[4].replace("**", ""))
        if match:
            parsed.append((cells[0], cells[1], float(match.group(1)), match.group(2) == "faster"))
    if limit:
        parsed = sorted(parsed, key=lambda p: (not p[3], -p[2]))[:limit]
    widest = max(p[2] for p in parsed)
    bars = []
    for task, tool, factor, faster in parsed:
        width = max((factor / widest) ** 0.5 * 100, 3)
        label = f"{factor:g}× {'faster' if faster else 'slower'}"
        bars.append(
            f'<div class="bar-row"><div class="name">{strip_tags(markup(task))}</div>'
            f'<div class="bar-track"><div class="bar-fill{"" if faster else " muted"}" '
            f'style="width:{width:.1f}%">{label}</div></div>'
            f'<div class="value">vs {strip_tags(markup(tool))}</div></div>')
    return f'<div class="bars">{"".join(bars)}</div>'


def bench_table(data):
    if not data:
        return ('<p class="prose">This page is generated from <code>Benchmarks/RESULTS.md</code>, '
                'which the benchmark suite writes. It has not been run yet, and inventing a table '
                'is what this page exists to avoid.</p>')
    header = ("<tr><th>Task</th><th>Compared with</th><th>Lathe</th><th>Tool</th>"
              "<th>Speed</th><th>CPU</th><th>Size</th><th>Quality</th></tr>")
    rows = "".join(
        "<tr>" + "".join(
            f'<td class="{"num" if i >= 2 else ""}">{markup(c)}</td>' for i, c in enumerate(cells))
        + "</tr>"
        for cells in data["rows"])
    notes = "".join(f"<li><b>{markup(t)}</b> — {markup(n)}</li>" for t, n in data["notes"])
    versions = "".join(f"<li>{markup(v)}</li>" for v in data["versions"])
    return f'''<div class="tablewrap"><table>
<thead>{header}</thead><tbody>{rows}</tbody></table></div>
<div class="two-up">
  <div class="prose">
    <p class="kicker">What each row is showing</p>
    <ul>{notes}</ul>
  </div>
  <div class="prose">
    <p class="kicker">Measured on</p>
    <ul>{versions}</ul>
  </div>
</div>'''


# MARK: - Pages

def render(source, facts, samples, data):
    text = source.read_text()
    title = re.search(r"<!-- title: (.+?) -->", text).group(1)
    description = re.search(r"<!-- description: (.+?) -->", text).group(1)
    body = re.sub(r"<!-- (title|description): .+? -->\n?", "", text)

    def fill(match):
        key = match.group(1)
        if key.startswith("snippet:"):
            name = key.split(":", 1)[1]
            if name not in samples:
                raise SystemExit(f"{source.name}: no sample named {name!r} in {SNIPPETS.name}")
            return highlight(samples[name])
        if key == "bench_chart":
            return bench_chart(data)
        if key == "bench_teaser":
            return bench_chart(data, limit=6)
        if key == "bench_table":
            return bench_table(data)
        if key in facts:
            return facts[key]
        raise SystemExit(f"{source.name}: unknown placeholder {{{{{key}}}}}")

    body = re.sub(r"\{\{([\w:]+)\}\}", fill, body)
    page = source.name
    return head(title, description, page, facts) + body + footer(facts)


def main():
    known = facts()
    samples = snippets()
    data = read_results()
    for source in sorted(SOURCES.glob("*.html")):
        (DOCS / source.name).write_text(render(source, known, samples, data))
        print(f"wrote docs/{source.name}")
    print(f"Lathe {known['version']}, {known['tests']} tests, {known['products']} products, "
          f"{len(samples)} samples, {len(data['rows']) if data else 0} benchmark rows")


if __name__ == "__main__":
    main()
