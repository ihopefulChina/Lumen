<p align="center">
  <img src="Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v6-256.png" width="112" alt="Lumen 图标">
</p>

<h1 align="center">Lumen</h1>

<p align="center">
  一款为 Mac 打造的阿里云 OSS 客户端。<br>
  用访达熟悉的方式浏览、整理、上传和分享对象。
</p>

<p align="center">
  <a href="https://ihopefulchina.github.io/Lumen/"><strong>访问官网</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.7.dmg">下载 Lumen 0.0.7</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ihopefulChina/Lumen/releases">版本记录</a>
  &nbsp;·&nbsp;
  <a href="https://ihopefulchina.github.io/Lumen/support.html">使用支持</a>
  &nbsp;·&nbsp;
  <a href="https://ihopefulchina.github.io/Lumen/privacy.html">隐私说明</a>
</p>

<p align="center">
  macOS 15+ · Apple Silicon
</p>

<p align="center">
  <img src="docs/browser.png" alt="Lumen 的对象浏览窗口" width="920">
</p>

<p align="center"><sub>截图使用完全虚拟的演示账号、Bucket 与对象数据。</sub></p>

## OSS，也可以像访达一样自然

Lumen 把账号、Bucket、文件和对象信息放进一个原生 macOS 窗口。单击选择、双击打开，使用 `⌘` 或 `⇧` 多选；按 Return 原地重命名，按 `⌘↓` 打开。网格、列表、路径栏、侧边栏收藏、快速查看和拖放整理都遵循熟悉的 Mac 操作。

### 找到内容

- 在网格和列表之间切换，按名称、日期、大小或类型排序。
- 收藏经常访问的 OSS 文件夹，从侧边栏一步抵达。
- 搜索只作用于当前文件夹；过滤结果时会同步清理隐藏选择，避免误操作看不见的对象。
- 使用方向键移动选择，按空格快速查看，打开检查器查看对象信息。
- 切换账号、Bucket 或路径时，过期的网络响应不会覆盖当前页面。

### 整理内容

- 在同一 Bucket 内复制、移动或拖放文件与文件夹。
- 像访达一样在网格或列表中原地重命名；文件默认只选中主名，扩展名保持不动。
- 重命名或移动完成后可点顶部提示中的「撤销」，也可按 `⌘Z` 恢复到原位置；开启版本控制的 Bucket 还能撤销刚刚完成的删除。
- 重命名文件夹时保留完整子目录结构。
- 所有目标会先做冲突检查；Lumen 不会静默覆盖已有对象。
- 云端移动会在复制全部成功后才删除源对象，失败时尽量回滚新建目标。

### 上传、下载与分享

- 拖入文件或整个文件夹，保留原目录结构；大文件自动分片上传。
- 从文件选择器、剪贴板或 Dock 图标接收素材。
- 批量下载文件和完整文件夹；短暂网络错误自动退避重试，失败任务可沿原路径重新开始。
- 重开应用后仍保留传输结果；未完成任务会明确标记为中断，不会误称为字节级续传。
- 复制原始链接、Markdown、HTML，或为私有对象生成临时签名 URL。
- 使用 OSS 图片处理加载缩略图，减少不必要的原图下载。

### 默认把安全放在前面

- AccessKey Secret 和 STS Token 保存在 macOS 钥匙串，不写入项目文件或偏好设置。
- 新账号默认使用私有 ACL；切换到公共权限前必须明确确认。
- 账号配置采用原子写入并保留上一份有效备份，损坏时优先恢复而不是静默清空。
- 上传与下载会核对 OSS 返回的 CRC64；下载通过校验后才写入最终位置。
- 不完整的目录列表会阻止整文件夹移动、复制、下载或删除。
- 软件更新使用 Ed25519 签名，并在解压前验证安装包。

## 开始使用

1. [下载 Lumen 0.0.7](https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.7.dmg)。
2. 打开 DMG，把 Lumen 拖到「应用程序」。
3. 添加阿里云 OSS 账号，选择地域，然后双击进入 Bucket。
4. 把文件拖进窗口，或按 `⌘O` 开始上传。

<p align="center">
  <img src="docs/account.png" alt="在 Lumen 中添加 OSS 账号" width="520">
</p>

<p align="center"><sub>示例 AccessKey 带有 DEMO 标记，不对应任何真实账号。</sub></p>

账号还可配置 STS Token、传输加速、自定义 Endpoint、CDN 域名、默认 ACL 和上传路径模板。路径模板只在 Bucket 根目录生效，例如：

```text
assets/{yyyy}/{MM}/{dd}/
```

支持 `{yyyy}`、`{MM}`、`{dd}`、`{HH}`、`{mm}`、`{ss}`、`{name}`、`{ext}` 和 `{filename}`。

默认开启「只显示和上传素材」，支持常见图片格式及 GIF、WebP、SVG；关闭后也可浏览和上传其他文件。

## 自动更新

在菜单栏选择「Lumen → 检查更新…」，或在「设置 → 通用」开启自动检查。发现新版本后，点击安装即可完成下载与签名验证；安装结束后 Lumen 会自动退出并重新打开。

已安装 0.0.4 或更高版本的用户可以直接在软件内升级到 0.0.7。0.0.3 及更早版本尚未内置更新器，需要先手动安装一次当前版本。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 上传文件 | `⌘O` |
| 从剪贴板上传 | `⌘⇧V` |
| 添加账号 / 新建文件夹 | `⌘N` / `⌘⇧N` |
| 复制链接 | `⌘⇧C` |
| 全选 / 取消全选 | `⌘A` / `⌘⇧A` |
| 后退 / 前进 | `⌘[` / `⌘]` |
| 刷新 | `⌘R` |
| 网格 / 列表 | `⌘1` / `⌘2` |
| 快速查看 | `Space` |
| 重命名 | `Return` |
| 撤销最近一次可恢复的云端操作 | `⌘Z` |
| 打开选中项 | `⌘↓` 或双击 |
| 取消重命名或选择 / 删除 | `Esc` / `Delete` |

## 安装与系统要求

Lumen 0.0.7 支持 Apple Silicon Mac 和 macOS 15 或更高版本。

## 账号与权限

- 建议创建权限最小化的 RAM 子用户，不要使用阿里云主账号 AccessKey。
- 从旧版本升级时，Lumen 会先把旧凭证写入钥匙串并回读确认，成功后才移除原明文记录。
- 新账号默认 ACL 为「私有」。改为公共读或公共读写前，Lumen 会说明影响并要求确认。
- 私有对象默认生成 1 小时有效的签名 URL；配置 CDN 域名后，公开链接会优先使用 CDN 地址。

## 范围与限制

- Lumen 专注对象浏览与传输，不创建 Bucket，也不管理未完成的分片等控制台资源。
- OSS 没有真正的文件夹；新建文件夹实际创建空目录占位对象。
- 单个目录最多读取 30 页，通常约 3 万条对象。达到上限时会显示未完整加载，并阻止可能遗漏内容的批量操作。
- 删除直接作用于 OSS，执行前会要求确认。只有 Bucket 开启版本控制且 OSS 返回精确 delete marker 时，Lumen 才会提供撤销；其他删除是永久的。
- 撤销只保留当前会话内最近一次成功且可恢复的云端操作，不提供重做；复制、上传与新建文件夹不能撤销。
- 如果原位置已被其他客户端创建同名对象，Lumen 会拒绝撤销，绝不会覆盖该对象。
- 云端复制与移动目前限定在同一 Bucket 内。
- 图片缩略图依赖 Bucket 已开通 OSS 图片处理。

## 从源码构建

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd Lumen
open Lumen.xcodeproj
```

在 Xcode 中选择 `Lumen` scheme 与 `My Mac` 运行，或使用命令行：

```bash
xcodebuild -project Lumen.xcodeproj \
  -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build
```

项目会通过 Swift Package Manager 获取固定版本的 Sparkle。对外分发自己的构建前，请配置独立的 Sparkle Ed25519 密钥。

## 参与项目

欢迎提交 [Issue](https://github.com/ihopefulChina/Lumen/issues/new/choose) 或 Pull Request。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；报告问题时，可从「帮助 → 复制诊断信息」取得已脱敏摘要，并确保截图只含虚拟数据。

使用说明与常见问题见 [支持页面](https://ihopefulchina.github.io/Lumen/support.html)，本地数据与网络边界见 [隐私说明](https://ihopefulchina.github.io/Lumen/privacy.html)。尚未公开的漏洞请按 [Security Policy](SECURITY.md) 私密报告。

## License

Lumen 采用 [MIT License](LICENSE) 开源。
