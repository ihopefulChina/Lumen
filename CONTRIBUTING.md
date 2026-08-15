# Contributing to Lumen

感谢你愿意改进 Lumen。先为行为变化创建 Issue，说明用户场景、预期结果和安全边界；小型修复可以直接提交 Pull Request。

## Local setup

需要 Apple Silicon Mac、macOS 15 或更高版本，以及当前稳定版 Xcode。依赖由仓库中的 `Package.resolved` 固定。

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd Lumen
xcodebuild -resolvePackageDependencies \
  -project Lumen.xcodeproj \
  -scheme Lumen \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates
```

## Before opening a pull request

```bash
REAL_OSS_SMOKE=0 xcodebuild \
  -project Lumen.xcodeproj \
  -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  test

scripts/validate-website.sh
bash -n scripts/*.sh
zsh -n scripts/*.sh
plutil -lint Info.plist Lumen/PrivacyInfo.xcprivacy
```

不要把真实 OSS 凭证交给测试或 CI。只有显式设置 `REAL_OSS_SMOKE=1` 时，真实 OSS 冒烟测试才会运行；公开 CI 永远不设置该值。

## Change guidelines

- Bug 修复和新行为先写能失败的测试，再实现最小改动。
- 账号、Bucket、对象键、本地路径、URL、请求 ID 与凭证都属于敏感上下文；日志、截图、Fixture 和诊断信息必须使用虚拟数据。
- 文件操作必须保留冲突检查、路径越界防护和不完整列表保护。
- 保持原生 macOS 交互、键盘可达性、清晰焦点和 Reduce Motion 支持。
- 不修改 `Package.resolved`，除非 Pull Request 的目的就是升级依赖。

## Releases

版本号、构建号、发布说明、README、网站、DMG 与 appcast 必须保持一致。发布产物只由维护者通过仓库脚本生成；Pull Request 不应提交私钥、凭证或临时构建产物。
