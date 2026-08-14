<p align="center">
  <img src="Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v5-256.png" width="96" alt="Lumen">
</p>

<h1 align="center">Lumen</h1>

<p align="center">
  Apple Silicon 上的阿里云 OSS 客户端<br>
  <a href="https://github.com/ihopefulChina/Lumen/releases/latest">下载</a>
  ·
  macOS 15+
  ·
  仅 arm64
</p>

<p align="center">
  <img src="docs/browser.png" alt="浏览窗口" width="920">
</p>

左边账号和 Bucket，中间网格或列表，右边检查器。把图片、JSON、TXT 传上去，再把链接拷出来。

不是 [oss-browser](https://github.com/aliyun/oss-browser) 的套壳，也不做控制台里那些事。建 Bucket、清碎片还是去阿里云网页。

## 安装

[下载 Lumen-0.0.3.dmg](https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.3.dmg)，把 App 拖进「应用程序」。

公开下载包使用 ad-hoc 签名，没有 Apple Developer ID 公证。如果 macOS 阻止首次打开，可到「系统设置 → 隐私与安全性」确认打开。

应用里的「检查更新」看的也是 [Releases](https://github.com/ihopefulChina/Lumen/releases)。

## 使用

启动后加账号：AccessKey、地域。可选传输加速、默认 ACL、路径模板、STS、自定义 Endpoint、CDN。

<p align="center">
  <img src="docs/account.png" alt="添加账号" width="520">
</p>

点进 Bucket，把文件拖进去，或 `⌘O`。也可以从剪贴板贴（`⌘⇧V`），或丢给 Dock 图标。像访达一样，单击选择、双击打开文件夹；按住 `⌘` 或 `⇧` 多选，点空白处取消选择。

拖到哪个文件夹就传到哪，文件名用原名。拖整个文件夹会按原来的目录结构上传。重名时一次列出冲突。

路径模板默认是空的，只在 Bucket 根目录生效。按日期归档可以写成：

```text
assets/{yyyy}/{MM}/{dd}/
```

占位符还有 `{HH}` `{mm}` `{ss}` `{name}` `{ext}` `{filename}`。

默认 ACL 是公共读。私有对象复制出来的是 1 小时签名 URL。挂了 CDN 域名就复制 CDN 地址。

建议用 RAM 子用户，别拿主账号日常传文件。

## 功能

- 访达式网格 / 原生列表，单击选择、双击打开、空格快速查看
- `⌘` / `⇧` 多选、全选、方向键移动和取消选择
- 批量下载（文件夹整棵拉下来）
- 批量删除
- 下载和重命名不会静默覆盖同名项目
- 复制链接、Markdown、HTML
- 大于 8 MB 自动分片
- 失败的上传和下载可原路径重试
- 缩略图走 OSS 图片处理，不拉原图（Bucket 要开通图片处理）
- GitHub Releases 检查更新

一个目录大约列到 3 万条。再多会提示没列完，并拒绝整文件夹下载或删除，避免误以为处理完整。OSS 没有真文件夹，`⌘⇧N` 是传一个空占位对象。删除没有回收站。

## 快捷键

| | |
| --- | --- |
| 上传 | `⌘O` |
| 剪贴板上传 | `⌘⇧V` |
| 添加账号 | `⌘N` |
| 新建文件夹 | `⌘⇧N` |
| 复制链接 | `⌘⇧C` |
| 全选 / 取消选择 | `⌘A` / `⌘⇧A` |
| 刷新 | `⌘R` |
| 后退 / 前进 | `⌘[` `⌘]` |
| 网格 / 列表 | `⌘1` `⌘2` |
| 快速查看 | 空格 |
| 打开文件夹 / 快速查看文件 | `Return` |
| 取消选择 | `Esc` |
| 删除 | `⌫` |

## 从源码构建

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd Lumen
open Lumen.xcodeproj
```

Xcode 选 scheme Lumen，目标 My Mac。第一次自己签的话，Signing 里勾上 Team。

```bash
xcodebuild -scheme Lumen -destination 'platform=macOS,arch=arm64' -configuration Debug build
```

密钥存在 `~/Library/Application Support/studio.lumen.oss/secrets.json`（权限 `600`），不会进 git。换电脑要重新加账号。

面向不认识的用户分发前，建议使用自己的 Apple Developer 账号 Archive，并完成 Developer ID 签名和公证。GitHub Release 里的公开 DMG 是 ad-hoc 签名，未公证。
