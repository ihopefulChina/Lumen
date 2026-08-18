#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
site_root="$repo_root/website"
readme="$repo_root/README.md"
index="$site_root/index.html"
privacy="$site_root/privacy.html"
support="$site_root/support.html"
mcp="$site_root/mcp.html"
version_info="$("$repo_root/scripts/project-version.sh")"
version="${version_info%% *}"
download_url="https://github.com/ihopefulChina/Ossuno/releases/latest/download/Ossuno-$version.dmg"

required_files=(
  "$index"
  "$privacy"
  "$support"
  "$mcp"
  "$site_root/styles.css"
  "$site_root/site.webmanifest"
  "$site_root/sitemap.xml"
  "$site_root/robots.txt"
  "$site_root/.nojekyll"
  "$site_root/appcast.xml"
  "$site_root/assets/ossuno-icon.png"
  "$site_root/assets/ossuno-favicon.png"
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

python3 - "$site_root/appcast.xml" "$site_root/sitemap.xml" <<'PY'
from pathlib import Path
from xml.etree import ElementTree
import sys


for value in sys.argv[1:]:
    path = Path(value)
    try:
        ElementTree.parse(path)
    except ElementTree.ParseError as error:
        raise SystemExit(f"Invalid XML in {path}: {error}") from error
PY
python3 -m json.tool "$site_root/site.webmanifest" >/dev/null
if ! cmp -s "$repo_root/appcast.xml" "$site_root/appcast.xml"; then
  echo "Root and website appcasts differ." >&2
  exit 1
fi

required_html=(
  'lang="zh-CN"'
  '<meta name="description"'
  '<link rel="canonical" href="https://ihopefulchina.github.io/Ossuno/"'
  '<meta property="og:title"'
  '<link rel="manifest" href="site.webmanifest"'
  '<a class="skip-link" href="#main">'
  '<main id="main">'
  'aria-label="主导航"'
  'id="mcp"'
  'id="features"'
  'id="security"'
  'id="start"'
  'id="faq"'
  '<details>'
  'alt="在 Ossuno 中浏览阿里云 OSS"'
  'alt="在 Ossuno 中添加阿里云 OSS 账号"'
  "$download_url"
  'href="privacy.html"'
  'href="support.html"'
  'href="mcp.html"'
  'npx ossuno-mcp install'
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
  "$privacy|https://ihopefulchina.github.io/Ossuno/privacy.html" \
  "$support|https://ihopefulchina.github.io/Ossuno/support.html" \
  "$mcp|https://ihopefulchina.github.io/Ossuno/mcp.html"; do
  page="${page_and_canonical%%|*}"
  canonical="${page_and_canonical#*|}"
  for pattern in \
    "<link rel=\"canonical\" href=\"$canonical\"" \
    '<a class="skip-link" href="#main">' \
    '<main id="main"' \
    'href="index.html"' \
    'href="mcp.html"' \
    'href="privacy.html"' \
    'href="support.html"'; do
    if ! grep -Fq -- "$pattern" "$page"; then
      echo "Missing policy page marker in ${page#"$repo_root/"}: $pattern" >&2
      exit 1
    fi
  done
done

for page in "$index" "$privacy" "$support" "$mcp"; do
  if ! grep -Fq -- '>ossuno-mcp</a>' "$page"; then
    echo "Missing prominent ossuno-mcp navigation label in ${page#"$repo_root/"}." >&2
    exit 1
  fi
done

if grep -Eini -- \
  'npm.{0,24}(尚未发布|未发布)|发布后.{0,24}(可用|可运行)|计划.{0,24}发布到 npm|正式发布前|not yet published|coming soon' \
  "$readme" "$repo_root/docs/mcp.md" "$site_root"/*.html; then
  echo "MCP documentation still contains pre-release transition copy." >&2
  exit 1
fi

previous_brand="$(printf '\154\165\155\145\156')"
if grep -RIni --include='*.html' -- "$previous_brand" "$site_root"; then
  echo "Website still contains the previous brand." >&2
  exit 1
fi

unexpected_versions="$(grep -RhoE --include='*.html' 'Ossuno [0-9]+\.[0-9]+\.[0-9]+' "$site_root" | grep -Fvx -- "Ossuno $version" || true)"
if [[ -n "$unexpected_versions" ]]; then
  echo "Website contains mismatched release versions:" >&2
  echo "$unexpected_versions" >&2
  exit 1
fi

if ! grep -Fq -- "$download_url" "$readme"; then
  echo "README download URL does not match website version $version." >&2
  exit 1
fi

unexpected_downloads="$(grep -RhoE --include='*.html' 'https://github\.com/ihopefulChina/Ossuno/releases/latest/download/Ossuno-[0-9.]+\.dmg' "$site_root" | grep -Fvx -- "$download_url" || true)"
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

python3 - "$index" "$privacy" "$support" "$mcp" <<'PY'
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
    source = page.read_text(encoding="utf-8")
    parser.feed(source)

    if page.name == "index.html" and source.find('id="mcp"') > source.find('id="features"'):
        parser.errors.append("ossuno-mcp must appear before the App feature chapters")

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
