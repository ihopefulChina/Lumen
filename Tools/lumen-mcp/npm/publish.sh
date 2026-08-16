#!/bin/bash
# 发布 lumen-mcp 到 npm（三个包：两个平台二进制 + 主包）。
# 用法：在 Terminal.app 中运行  ./npm/publish.sh <version>
# 前置：已 npm login；Xcode 命令行工具可用。
set -euo pipefail

VERSION="${1:?用法：publish.sh <version>，例如 publish.sh 1.0.1}"
cd "$(dirname "$0")"
NPM_DIR="$PWD"
SWIFT_DIR="$(cd .. && pwd)"

if ! command -v npm >/dev/null; then
  echo "错误：未找到 npm。" >&2; exit 1
fi
if [ "$(npm whoami 2>/dev/null || true)" = "" ]; then
  echo "错误：未登录 npm，请先运行 npm login。" >&2; exit 1
fi

echo "==> 构建 arm64..."
cd "$SWIFT_DIR"
swift build --disable-sandbox -c release
mkdir -p "$NPM_DIR/lumen-mcp-darwin-arm64/bin"
cp .build/release/lumen-mcp "$NPM_DIR/lumen-mcp-darwin-arm64/bin/lumen-mcp"

echo "==> 交叉编译 x86_64..."
swift build --disable-sandbox -c release --arch x86_64
mkdir -p "$NPM_DIR/lumen-mcp-darwin-x64/bin"
cp .build/x86_64-apple-macosx/release/lumen-mcp "$NPM_DIR/lumen-mcp-darwin-x64/bin/lumen-mcp"

echo "==> 同步版本号到 $VERSION ..."
cd "$NPM_DIR"
node -e '
const fs = require("fs");
const version = process.argv[1];
for (const name of ["lumen-mcp-darwin-arm64", "lumen-mcp-darwin-x64"]) {
  const file = `${name}/package.json`;
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  json.version = version;
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
}
const main = JSON.parse(fs.readFileSync("lumen-mcp/package.json", "utf8"));
main.version = version;
for (const key of Object.keys(main.optionalDependencies)) {
  main.optionalDependencies[key] = version;
}
fs.writeFileSync("lumen-mcp/package.json", JSON.stringify(main, null, 2) + "\n");
' "$VERSION"

echo "==> 发布平台包（arm64 / x64）..."
(cd lumen-mcp-darwin-arm64 && npm publish --access public)
(cd lumen-mcp-darwin-x64 && npm publish --access public)

echo "==> 发布主包 lumen-mcp..."
(cd lumen-mcp && npm publish --access public)

echo
echo "完成：lumen-mcp@$VERSION 已发布。"
echo "提醒：同步提交 npm/ 下 package.json 的版本号变更并推送仓库。"
