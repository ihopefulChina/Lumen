#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
site_root="$repo_root/website"
readme="$repo_root/README.md"
index="$site_root/index.html"
privacy="$site_root/privacy.html"
support="$site_root/support.html"
version="1.0.1"
download_url="https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-$version.dmg"

required_files=(
  "$index"
  "$privacy"
  "$support"
  "$site_root/styles.css"
  "$site_root/site.webmanifest"
  "$site_root/sitemap.xml"
  "$site_root/robots.txt"
  "$site_root/.nojekyll"
  "$site_root/appcast.xml"
  "$site_root/assets/lumen-icon.png"
  "$site_root/assets/lumen-favicon.png"
  "$site_root/assets/browser.png"
  "$site_root/assets/browser-dark.png"
  "$site_root/assets/account.png"
  "$site_root/assets/account-dark.png"
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
  'alt="在 Lumen 中浏览阿里云 OSS"'
  'alt="在 Lumen 中添加阿里云 OSS 账号"'
  "$download_url"
  'href="privacy.html"'
  'href="support.html"'
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

for page_and_canonical in \
  "$privacy|https://ihopefulchina.github.io/Lumen/privacy.html" \
  "$support|https://ihopefulchina.github.io/Lumen/support.html"; do
  page="${page_and_canonical%%|*}"
  canonical="${page_and_canonical#*|}"
  for pattern in \
    "<link rel=\"canonical\" href=\"$canonical\"" \
    '<a class="skip-link" href="#main">' \
    '<main id="main"' \
    'href="index.html"' \
    'href="privacy.html"' \
    'href="support.html"'; do
    if ! grep -Fq -- "$pattern" "$page"; then
      echo "Missing policy page marker in ${page#"$repo_root/"}: $pattern" >&2
      exit 1
    fi
  done
done

if grep -RFn --include='*.html' -- '0.0.8' "$site_root"; then
  echo "Website still contains the previous version." >&2
  exit 1
fi

if ! grep -Fq -- "$download_url" "$readme"; then
  echo "README download URL does not match website version $version." >&2
  exit 1
fi

unexpected_downloads="$(grep -RhoE --include='*.html' 'https://github\.com/ihopefulChina/Lumen/releases/latest/download/Lumen-[0-9.]+\.dmg' "$site_root" | grep -Fvx -- "$download_url" || true)"
if [[ -n "$unexpected_downloads" ]]; then
  echo "Website contains mismatched download URLs:" >&2
  echo "$unexpected_downloads" >&2
  exit 1
fi

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

python3 - "$index" "$privacy" "$support" <<'PY'
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


totals = [0, 0, 0]
for raw_path in sys.argv[1:]:
    page = Path(raw_path)
    parser = SiteParser()
    parser.feed(page.read_text(encoding="utf-8"))

    for href in parser.links:
        if href.startswith("#") and href[1:] not in parser.ids:
            parser.errors.append(f"broken anchor: {href}")

    for image in parser.images:
        source = image["src"]
        if source.startswith(("http://", "https://", "data:")):
            parser.errors.append(f"image must be local: {source}")
        elif not (page.parent / source).is_file():
            parser.errors.append(f"missing image target: {source}")

    if parser.errors:
        raise SystemExit(f"{page.name}:\n" + "\n".join(parser.errors))
    totals[0] += len(parser.links)
    totals[1] += len(parser.images)
    totals[2] += len(parser.ids)

print(f"Validated {totals[0]} links, {totals[1]} images, and {totals[2]} unique IDs across {len(sys.argv) - 1} pages.")
PY

echo "Website validation passed."
