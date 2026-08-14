<p align="center">
  <img src="Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v6-256.png" width="112" alt="Lumen 图标">
</p>

<h1 align="center">Lumen</h1>

<p align="center">
  为 Apple Silicon Mac 打造的阿里云 OSS 客户端。<br>
  用熟悉的访达式界面浏览、上传和分享对象。
</p>

<p align="center">
  <a href="https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.3.dmg"><strong>下载 Lumen 0.0.3</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ihopefulChina/Lumen/releases">版本记录</a>
  &nbsp;·&nbsp;
  macOS 15+ / Apple Silicon
</p>

<p align="center">
  <img src="docs/browser.png" alt="Lumen 的对象浏览窗口" width="920">
</p>

## 像整理本地文件一样整理 OSS

Lumen 把账号、Bucket、对象和详情放进一个原生 macOS 窗口。单击选择，双击进入文件夹，按住 `⌘` 或 `⇧` 多选；网格、列表、快速查看和检查器都遵循熟悉的 Mac 操作方式。

### 浏览很熟悉

在网格与原生列表之间切换，用方向键移动选择，按空格快速查看文件。切换账号、Bucket 或路径时，较慢的旧请求不会覆盖当前页面。

### 上传与分享更直接

把文件或整个文件夹拖进窗口，也可以使用文件选择器、剪贴板或 Dock 图标。目录结构会被保留，大文件自动分片；链接可以复制为纯文本、Markdown 或 HTML。

### 关键操作更稳妥

上传前集中显示重名冲突，下载与重命名不会静默覆盖已有文件。失败任务可沿原路径重试；当对象列表没有完整加载时，Lumen 会拒绝整文件夹下载或删除。

## 三步开始

1. [下载 DMG](https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.3.dmg)，把 Lumen 拖进「应用程序」。
2. 添加一个阿里云 OSS 账号，填写 AccessKey 和地域。
3. 双击进入 Bucket，然后拖入文件，或按 `⌘O` 上传。

<p align="center">
  <img src="docs/account.png" alt="在 Lumen 中添加 OSS 账号" width="520">
</p>

账号还可以配置 STS Token、传输加速、自定义 Endpoint、CDN 域名、默认 ACL 和上传路径模板。路径模板只在 Bucket 根目录生效，例如：

```text
assets/{yyyy}/{MM}/{dd}/
```

可用占位符：`{yyyy}`、`{MM}`、`{dd}`、`{HH}`、`{mm}`、`{ss}`、`{name}`、`{ext}`、`{filename}`。

## 常用操作

- 拖入文件夹时保留原目录结构
- 超过 8 MB 的文件自动使用分片上传
- 批量下载文件与完整文件夹
- 批量删除对象
- 复制原始链接、Markdown 或 HTML
- 私有对象生成 1 小时有效的签名 URL
- 使用 OSS 图片处理生成缩略图，避免下载原图
- 从 GitHub Releases 检查更新

默认开启「只显示和上传素材」，支持常见图片格式以及 GIF、WebP、SVG；可在设置中关闭，浏览和上传其他文件。

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
| 打开文件夹或文件 | `Return` |
| 取消选择 / 删除 | `Esc` / `Delete` |

## 安装说明

公开 DMG 使用 ad-hoc 签名，尚未使用 Apple Developer ID 签名或完成 Apple 公证。如果 macOS 阻止首次打开，请在「系统设置 → 隐私与安全性」中确认打开。

Lumen 0.0.3 支持 Apple Silicon Mac 与 macOS 15 或更高版本。

## 账号与安全

- 建议为 Lumen 创建权限最小化的 RAM 子用户，不要使用阿里云主账号的 AccessKey。
- AccessKey Secret 与 STS Token 只保存在本机 Lumen 沙盒的 Application Support 目录中；`secrets.json` 文件权限为 `600`。它们属于明文敏感数据，请妥善保护 Mac 账号与备份。
- 新账号的默认 ACL 是「公共读」。保存账号前，Lumen 会明确提示公开访问风险；不需要公开访问时请改为「私有」。
- 私有对象复制为 1 小时签名 URL；配置 CDN 域名后，复制操作会优先生成 CDN 地址。

## 范围与限制

- Lumen 专注对象浏览与传输，不创建 Bucket，也不管理分片碎片等控制台资源。
- OSS 没有真正的文件夹；`⌘⇧N` 创建的是一个空目录占位对象。
- 单个目录最多读取约 30 页、通常约 3 万条对象。达到上限时会显示未完整加载提示，并阻止可能不完整的整文件夹下载或删除。
- 删除直接作用于 OSS，没有本地回收站；执行前会显示确认信息。
- 图片缩略图依赖 Bucket 已开通 OSS 图片处理。

## 从源码构建

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd Lumen
open Lumen.xcodeproj
```

在 Xcode 中选择 `Lumen` scheme 与 `My Mac` 运行。也可以使用命令行：

```bash
xcodebuild -project Lumen.xcodeproj \
  -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build
```

对外分发自己的构建前，请使用 Apple Developer 账号完成 Developer ID 签名与公证。
