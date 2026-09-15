#!/usr/bin/env python3
"""Regenerates the pages that are derived from files in the repository.

The benchmark table is the reason this exists. It is measured by
`lathe-bench` and written to `Benchmarks/RESULTS.md`, and a second copy
maintained by hand on a web page is a copy that goes stale and starts
claiming numbers nobody measured. So the page is generated from the same
file, and regenerating it is how the site is updated.

    python3 docs/build.py
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from _shared import head, FOOTER  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"


def read_results():
    """Pull the table, the notes and the versions out of RESULTS.md."""
    path = ROOT / "Benchmarks" / "RESULTS.md"
    if not path.exists():
        return None
    text = path.read_text()

    rows = []
    for line in text.splitlines():
        if not line.startswith("|") or line.startswith("|---") or "| task |" in line:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) == 8:
            rows.append(cells)

    notes = dict()
    for line in text.splitlines():
        match = re.match(r"- \*\*(.+?)\*\* — (.+)", line)
        if match:
            notes[match.group(1)] = match.group(2)

    versions = []
    collecting = False
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
    """Markdown emphasis to HTML, plus the colours the columns mean."""
    cell = cell.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    cell = re.sub(r"\*\*(.+?)\*\*", r'<span class="win">\1</span>', cell)
    cell = re.sub(r"\*(.+?)\*", r"<em>\1</em>", cell)
    cell = re.sub(r"`(.+?)`", r"<code>\1</code>", cell)
    cell = cell.replace("⚠︎", '<span class="warn">⚠︎</span>')
    return cell


def benchmarks_page(data):
    if not data:
        body = '''<div class="empty">
    <h3>No measurements yet</h3>
    <p>This page is generated from <code>Benchmarks/RESULTS.md</code>, which is
    written by the benchmark suite. Until the suite has been run there is
    nothing to show, and inventing a table is exactly what this page exists
    to avoid.</p>
  </div>'''
    else:
        header = ("<tr><th>Task</th><th>Compared with</th><th>Lathe</th><th>Tool</th>"
                  "<th>Speed</th><th>CPU</th><th>Size</th><th>Quality</th></tr>")
        body_rows = []
        for cells in data["rows"]:
            tds = "".join(
                f'<td class="{"num" if index >= 2 else ""}">{markup(cell)}</td>'
                for index, cell in enumerate(cells))
            body_rows.append(f"<tr>{tds}</tr>")
        notes = "".join(
            f"<li><b>{markup(task)}</b> — {markup(note)}</li>"
            for task, note in data["notes"].items())
        versions = "".join(f"<li>{markup(v)}</li>" for v in data["versions"])
        body = f'''<div class="tablewrap">
    <table class="bench">
      <thead>{header}</thead>
      <tbody>{"".join(body_rows)}</tbody>
    </table>
  </div>

  <div class="prose" style="margin-top:26px">
    <p><span class="warn">⚠︎</span> marks a row where the two sides did <b>not</b>
    land at the same quality, so the byte counts are not comparable and no
    percentage is claimed for them. Two encoders&rsquo; &ldquo;q80&rdquo; are not
    the same q80, and a size column that ignores that misleads in whichever
    direction the settings happened to fall.</p>
  </div>

  <div class="sec-head" style="margin-top:52px">
    <div class="label">What each row is showing</div>
  </div>
  <div class="prose"><ul style="padding-left:20px;line-height:1.8">{notes}</ul></div>

  <div class="sec-head" style="margin-top:52px">
    <div class="label">Measured on</div>
  </div>
  <div class="prose"><ul style="padding-left:20px;line-height:1.8">{versions}</ul></div>'''

    return head("Benchmarks — Lathe",
                "Lathe measured against ffmpeg, cwebp, cjpeg, avifenc, lame and "
                "exiftool, with the framing that makes the numbers mean something.",
                "benchmarks.html") + f'''
<header class="pagehead bleed">
  <div class="wrap">
    <div class="label">Measured, not claimed</div>
    <h1>Benchmarks</h1>
    <p class="lede">Every figure here is produced by a suite in this repository and
    regenerated on release. Three claims are being made, and only three:
    <b>in-process beats a process launch</b>, <b>hardware beats software on watts
    and wall-clock</b>, and <b>software encoders still win on bits</b>.</p>
  </div>
  <div class="rule-band"><i></i><i></i><i></i></div>
</header>

<section class="wrap">
  <div class="sec-head">
    <div class="label">01 — How to read this</div>
    <h2>The size column is where the honesty is</h2>
  </div>
  <div class="prose">
    <p>A benchmark table that shows only wall-clock time from a hardware encoder is
    an advertisement. Hardware encoders are faster and they spend more bits;
    both halves are true and a table that shows one is not a measurement.</p>
    <p>So every row carries four columns — <b>time</b>, <b>CPU</b>, <b>size</b> and
    <b>quality</b> — and any row where the two sides did not reach the same
    quality declines to claim a size difference at all.</p>
    <p class="pull">If a row makes Lathe look bad, it is still in the table.</p>
  </div>

  <div style="margin-top:34px">{body}</div>
</section>

<div class="wrap"><div class="hr"></div></div>

<section class="wrap">
  <div class="sec-head">
    <div class="label">02 — On energy</div>
    <h2>The number people actually want, and why it is not here</h2>
  </div>
  <div class="prose">
    <p>The interesting claim about hardware encoding is <b>watts</b>, not seconds.
    It is not in the table, and not for want of trying: <code>powermetrics</code>
    needs root, and a measurement taken on a machine that was not idle is worse
    than no measurement.</p>
    <p>The CPU column is the closest honest proxy and it is <b>not</b> energy. It
    understates what hardware costs, because a fixed-function encoder does its
    work in a block that never appears as CPU time at all. A row showing Lathe
    using a fraction of the CPU is showing where the work <em>moved</em>, not
    that the work became free.</p>
  </div>
</section>

{FOOTER}'''


def main():
    data = read_results()
    (DOCS / "benchmarks.html").write_text(benchmarks_page(data))
    print(f"wrote docs/benchmarks.html ({len(data['rows']) if data else 0} rows)")


if __name__ == "__main__":
    main()
