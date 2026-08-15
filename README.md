<p align="center">
  <img src="Lumen/Assets.xcassets/AppIcon.appiconset/Icon-v6-256.png" width="112" alt="Lumen 图标">
</p>

<h1 align="center">Lumen</h1>

<p align="center">
  在 Mac 上，像使用访达一样使用阿里云 OSS。
</p>

<p align="center">
  <a href="https://ihopefulchina.github.io/Lumen/"><strong>官网</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.9.dmg"><strong>下载 Lumen 0.0.9</strong></a>
  &nbsp;·&nbsp;
  <a href="https://ihopefulchina.github.io/Lumen/support.html">使用支持</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ihopefulChina/Lumen/releases">版本记录</a>
</p>

<p align="center">Apple Silicon · macOS 15 或更高版本</p>

<p align="center">
  <img src="docs/browser.png" width="920" alt="Lumen 的对象浏览窗口">
</p>

<p align="center"><sub>截图中的账号、Bucket、路径与文件均为虚拟演示数据。</sub></p>

Lumen 是一款专注对象工作的原生 macOS OSS 客户端。它不试图把控制台搬进桌面，而是把最常做的事——查找、预览、整理、传输和恢复——放进一个安静、熟悉的 Mac 窗口。

## 从找到文件开始

当前文件夹搜索即时完成；切换到「当前 Bucket」后，Lumen 会分页扫描整个 Bucket，并显示进度。结果可按类型、大小与修改日期筛选，双击即可回到所在文件夹，空格直接快速查看。

侧边栏提供最近修改、大文件、已删除对象和失败传输。常用 OSS 文件夹可以收藏；多个窗口可以合并为 macOS 标签页，新窗口会继承当前账号、Bucket 和路径，但保留独立选择。

## 像访达一样整理

- 单击、Command 多选、Shift 连选，Return 原地重命名。
- 网格与列表、路径栏、方向键、空格快速查看和 `⌘I` 信息窗口遵循常见 Mac 操作。
- 在 Bucket 内拖放、复制或移动文件夹；目标冲突可询问、替换、跳过或「保留两者」。
- 把对象或整个文件夹直接拖到访达。多选时会生成一个「Lumen 下载」文件夹，并保留云端目录结构。
- 复制后切换 Bucket 再粘贴即可跨 Bucket 整理。同账号同地域使用云端复制，其他情况会先明确提示，再经由这台 Mac 中转。

移动始终先完成全部复制，再删除来源。失败不会让尚未安全复制的源对象消失。

## 传输可以停下来，再继续

大文件上传会持久保存 multipart upload ID 与已完成分片；下载按固定字节范围写入隐藏临时文件。暂停、退出或短暂断网后，可以从最近检查点继续。完成时会在 OSS 提供校验值的情况下核对 CRC64，再原子发布下载文件。

传输中心提供上传/下载独立并发数、暂停与继续、失败重试、队列置顶、速度、剩余时间、方向限速和完成通知。下载从不静默覆盖本地同名文件。

## 版本、恢复与对象属性

在已启用版本控制的 Bucket 中，「版本历史」会列出当前版本、历史版本和 delete marker。恢复历史版本会创建新的当前版本；「已删除」位置只移除所选的精确 delete marker，不永久删除历史数据。

「对象属性」可以编辑 Content-Type、Cache-Control、Content-Disposition、用户元数据和最多十个 OSS 标签。重复键、空键和换行注入会在提交前被拦截；只修改标签时不会重写元数据。

## 安全边界

- AccessKey Secret 与 STS Token 保存在 macOS 钥匙串。
- 新账号默认继承 Bucket 权限；明确选择公共权限前会解释影响并再次确认。
- 账号配置原子写入，并保留上一份可恢复副本。
- 路径穿越、符号链接逃逸、不完整分页和目标冲突都会中止相关批量操作。
- 诊断摘要不包含账号名、AccessKey ID、Bucket、对象键、本地路径、URL、请求 ID、Secret 或 Token。
- 软件内更新通过 Sparkle 校验更新包；安装完成后会自动退出并重新打开 Lumen。

## 安装

1. [下载 Lumen 0.0.9](https://github.com/ihopefulChina/Lumen/releases/latest/download/Lumen-0.0.9.dmg)。
2. 打开 DMG，把 Lumen 拖入「应用程序」。
3. 添加权限最小化的 RAM 子账号，选择地域，然后打开 Bucket。

已安装带自动更新功能的版本，可在「Lumen → 检查更新…」直接升级。设置中也可以开启自动检查。

<p align="center">
  <img src="docs/account.png" width="520" alt="在 Lumen 中添加 OSS 账号">
</p>

账号可使用 STS Token、传输加速、自定义 Endpoint、CDN 域名和上传路径模板。模板支持 `{yyyy}`、`{MM}`、`{dd}`、`{HH}`、`{mm}`、`{ss}`、`{name}`、`{ext}` 与 `{filename}`。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建窗口 / 添加账号 | `⌘N` / `⇧⌘A` |
| 上传 / 从剪贴板上传 | `⌘O` / `⇧⌘V` |
| 新建文件夹 | `⇧⌘N` |
| 打开传输中心 | `⌥⌘L` |
| 网格 / 列表 | `⌘1` / `⌘2` |
| 后退 / 前进 | `⌘[` / `⌘]` |
| 快速查看 / 显示信息 | `Space` / `⌘I` |
| 重命名 / 撤销 | `Return` / `⌘Z` |

## 范围

Lumen 专注对象浏览和传输，不创建 Bucket，也不管理 RAM、生命周期、CORS、跨区域复制策略或未完成分片等控制台资源。OSS 的「文件夹」是对象前缀；空文件夹通过占位对象表示。

单次聚合最多读取 30 页，通常约 3 万个对象。达到边界时界面会明确标记结果不完整，并阻止可能遗漏对象的文件夹级危险操作。删除能否恢复取决于 Bucket 是否已经启用版本控制。

## 从源码运行

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd Lumen
open Lumen.xcodeproj
```

或使用命令行：

```bash
xcodebuild -project Lumen.xcodeproj \
  -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build
```

项目使用 Swift 6、SwiftUI、AppKit、Swift Testing 与固定版本的 Sparkle，不增加其他运行时依赖。

## 参与与支持

问题和建议请提交到 [GitHub Issues](https://github.com/ihopefulChina/Lumen/issues/new/choose)。提交前可从「帮助 → 复制诊断信息」取得脱敏摘要；截图请使用虚拟数据或遮盖标识。安全问题请通过 [Security Policy](SECURITY.md) 中的私密入口报告。

更多说明见 [Lumen 官网](https://ihopefulchina.github.io/Lumen/)、[支持页面](https://ihopefulchina.github.io/Lumen/support.html) 与 [隐私说明](https://ihopefulchina.github.io/Lumen/privacy.html)。

## License

Lumen 采用 [MIT License](LICENSE) 开源。
