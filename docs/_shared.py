"""Fragments every page shares, so the chrome cannot drift between them."""

import html

SITE = "https://wemiller.com/apps/lathe/"
FONTS = ("https://fonts.googleapis.com/css2?"
         "family=Bodoni+Moda:ital,opsz,wght@0,6..96,500;0,6..96,700;0,6..96,800;0,6..96,900;1,6..96,500"
         "&family=Hanken+Grotesk:wght@400;500;600;700"
         "&family=JetBrains+Mono:wght@400;500;600&display=swap")

PAGES = [
    ("index.html", "The Issue"),
    ("documentation.html", "Documentation"),
    ("benchmarks.html", "Benchmarks"),
    ("mac.html", "Mac app"),
    ("sami.html", "Sami"),
]


def head(title, description, page, facts):
    canonical = SITE + ("" if page == "index.html" else page)
    esc = html.escape
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(description)}">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(description)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{SITE}media/icon.png">
<meta name="twitter:card" content="summary">
<meta name="theme-color" content="#16192b">
<link rel="icon" type="image/png" href="media/icon-180.png">
<link rel="apple-touch-icon" href="media/icon-180.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{FONTS}">
<link rel="stylesheet" href="lathe.css">
</head>
<body>
{masthead(page, facts)}
'''


def masthead(page, facts):
    links = "".join(
        f'<li><a href="{href}"{" aria-current=\"page\"" if href == page else ""}>{label}</a></li>'
        for href, label in PAGES)
    return f'''<header class="masthead">
  <div class="wrap">
    <div class="issue-line">
      <span>Vol. {facts["version"]} &middot; {facts["month"]}</span>
      <span>Swift 6 &middot; iOS 17 &middot; macOS 14 &middot; Apache-2.0</span>
      <span>Measured, not claimed</span>
    </div>
    <div class="mast-row">
      <a class="wordmark" href="index.html"><img src="media/icon-180.png" alt="" width="38" height="38">Lathe</a>
      <nav aria-label="Pages"><ul class="contents-nav">{links}<li><a href="https://github.com/blaineam/Lathe">GitHub</a></li></ul></nav>
    </div>
  </div>
</header>
'''


def footer(facts):
    return f'''<footer class="colophon">
  <div class="wrap">
    <div>
      <h4>Colophon</h4>
      <p>Lathe {facts["version"]}, an on-device media engine for Apple platforms, free under the Apache&nbsp;2.0 licence.</p>
      <p>Set in Bodoni Moda, Hanken Grotesk and JetBrains Mono. Every page is generated from the repository by <code>docs/build.py</code>; every number on it was measured, and every code sample compiles.</p>
    </div>
    <div>
      <h4>Lathe</h4>
      <p><a href="documentation.html">Documentation</a></p>
      <p><a href="benchmarks.html">Benchmarks</a></p>
      <p><a href="mac.html">The Mac app</a></p>
      <p><a href="https://github.com/blaineam/Lathe">Source on GitHub</a></p>
    </div>
    <div>
      <h4>Elsewhere</h4>
      <p><a href="https://wemiller.com/apps/sami/">Sami, the app it powers</a></p>
      <p><a href="https://wemiller.com/apps/">More apps by Blaine Miller</a></p>
      <p><a href="https://wemiller.com/support/">Support the free apps</a></p>
    </div>
  </div>
</footer>
</body>
</html>
'''
