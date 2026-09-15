"""Fragments every page shares, so the chrome cannot drift between them."""

def head(title, description, page):
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700;800&family=JetBrains+Mono:wght@400;500;700&family=Public+Sans:wght@400;500;600&display=swap">
<link rel="stylesheet" href="lathe.css">
</head>
<body>
{nav(page)}
'''


def nav(page):
    items = [("index.html", "Overview"), ("documentation.html", "Documentation"),
             ("benchmarks.html", "Benchmarks"), ("mac.html", "Mac app"),
             ("sami.html", "Sami")]
    links = "".join(
        f'<li><a href="{href}"{" aria-current=\"page\"" if href == page else ""}>{label}</a></li>'
        for href, label in items)
    return f'''<nav class="nav bleed">
  <div class="wrap">
    <a class="brand" href="index.html">L<em>a</em>the</a>
    <ul>{links}</ul>
    <span class="spacer"></span>
    <a href="https://github.com/blaineam/Lathe">GitHub</a>
  </div>
</nav>'''


FOOTER = '''<footer class="bleed">
  <div class="wrap">
    Apache-2.0 &middot; <a href="https://github.com/blaineam/Lathe">github.com/blaineam/Lathe</a><br>
    Requires iOS 17 / macOS 14. No third-party runtime dependencies.<br>
    Powering <a href="sami.html">Sami</a>.
  </div>
</footer>
</body>
</html>
'''
