#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
site_root="$repo_root/website"
index="$site_root/index.html"

required_files=(
  "$index"
  "$site_root/styles.css"
  "$site_root/site.webmanifest"
  "$site_root/sitemap.xml"
  "$site_root/robots.txt"
  "$site_root/.nojekyll"
  "$site_root/assets/lumen-icon.png"
  "$site_root/assets/lumen-favicon.png"
  "$site_root/assets/browser.png"
  "$site_root/assets/account.png"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing website file: ${file#"$repo_root/"}" >&2
    exit 1
  fi
done

required_html=(
  'lang="zh-CN"'
  '<meta name="description"'
  '<link rel="canonical" href="https://ihopefulchina.github.io/Lumen/"'
  '<meta property="og:title"'
  '<link rel="manifest" href="site.webmanifest"'
  '<a class="skip-link" href="#main">'
  '<main id="main">'
  'aria-label="主导航"'
  'id="features"'
  'id="security"'
  'id="start"'
  'id="faq"'
  '<details>'
  'alt="Lumen 的对象浏览窗口"'
  'alt="在 Lumen 中添加 OSS 账号"'
  'https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.6.dmg'
  'macOS 15'
  'Apple Silicon'
  'MIT License'
)

for pattern in "${required_html[@]}"; do
  if ! grep -Fq -- "$pattern" "$index"; then
    echo "Missing required HTML marker: $pattern" >&2
    exit 1
  fi
done

if grep -Eiq '(ad.?hoc|notari[sz]|Gatekeeper|Developer ID)' "$index"; then
  echo "Website contains obsolete distribution copy." >&2
  exit 1
fi

if grep -En '(fonts\.(googleapis|gstatic)\.com|TODO|Lorem ipsum|href="/|src="/)' "$site_root"/*.html "$site_root"/*.css; then
  echo "Website contains a forbidden dependency, placeholder, or root-relative URL." >&2
  exit 1
fi

if ! grep -Fq -- '@media (prefers-reduced-motion: reduce)' "$site_root/styles.css"; then
  echo "Missing reduced-motion support." >&2
  exit 1
fi

python3 - "$index" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.errors = []
        self.ids = set()
        self.links = []
        self.images = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            if values["id"] in self.ids:
                self.errors.append(f"duplicate id: {values['id']}")
            self.ids.add(values["id"])
        if tag == "a" and "href" in values:
            self.links.append(values["href"])
        if tag == "script" and values.get("type") != "application/ld+json":
            self.errors.append("runtime JavaScript is not allowed")
        if tag == "img":
            self.images.append(values)
            for required in ("src", "alt", "width", "height"):
                if required not in values:
                    self.errors.append(f"img missing {required}: {values.get('src', '<unknown>')}")


index = Path(sys.argv[1])
parser = SiteParser()
parser.feed(index.read_text(encoding="utf-8"))

for href in parser.links:
    if href.startswith("#") and href[1:] not in parser.ids:
        parser.errors.append(f"broken anchor: {href}")

for image in parser.images:
    source = image["src"]
    if source.startswith(("http://", "https://", "data:")):
        parser.errors.append(f"image must be local: {source}")
    elif not (index.parent / source).is_file():
        parser.errors.append(f"missing image target: {source}")

if parser.errors:
    raise SystemExit("\n".join(parser.errors))

print(f"Validated {len(parser.links)} links, {len(parser.images)} images, and {len(parser.ids)} unique IDs.")
PY

echo "Website validation passed."
