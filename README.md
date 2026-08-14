# Lumen

Apple Silicon 上用的阿里云 OSS 客户端。界面按访达来：左边账号和 Bucket，中间网格或列表，右边检查器默认收着，底下一条路径。

主要就干两件事：把图片、JSON、TXT 传上去，再把链接拷出来。不是 [oss-browser](https://github.com/aliyun/oss-browser) 的套壳，也不打算做成控制台——建 Bucket、清碎片这些还是去阿里云网页。

![浏览窗口](docs/browser.png)

当前 **0.0.1**。只要 arm64，系统 macOS 15+。签名走 OSS V4（`OSS4-HMAC-SHA256`）。

仓库：<https://github.com/ihopefulChina/Lumen>

## 安装

[Releases](https://github.com/ihopefulChina/Lumen/releases) 里下 `Lumen-0.0.1.dmg`，把 App 拖进「应用程序」。

这个包是临时签名，没做公证。第一次打开会提示无法验证开发者，**右键 App → 打开** 一次就行。别从不明 fork 下别人编好的包。

从源码跑：

```bash
git clone git@github.com:ihopefulChina/Lumen.git
cd lumen
open Lumen.xcodeproj
```

Xcode 选 scheme Lumen，目标 My Mac。第一次自己签的话，Signing 里勾上 Team。

```bash
xcodebuild -scheme Lumen -destination 'platform=macOS,arch=arm64' -configuration Debug build
```

## 怎么用

启动后加账号：AccessKey ID、Secret、地域。可选的有传输加速、默认 ACL、路径模板、STS、自定义 Endpoint、CDN。点「存储并连接」，会打一次 ListBuckets 验密钥。

![添加账号](docs/account.png)

左边点 Bucket，文件拖进去，或者 `⌘O`。也可以从剪贴板贴（`⌘⇧V`），或把文件丢给 Dock 图标。

在 Bucket 根目录上传，会套路径模板，默认：

```text
assets/{yyyy}/{MM}/{dd}/文件名
```

进了某个文件夹再拖，就传到当前目录，不会再套一层日期。占位符还有 `{HH}` `{mm}` `{ss}` `{name}` `{ext}` `{filename}`。

默认 ACL 是**公共读**，链接能直接打开，适合对外素材。内部文件改成私有，复制出来的是 1 小时签名 URL。挂了 CDN 域名就复制 CDN 地址，不再签 OSS。

建议用 RAM 子用户，别拿主账号密钥日常传文件。读写大概需要 `ListBuckets`、`ListObjects` / `ListObjectsV2`、`GetObject`、`PutObject`、`DeleteObject`，大于 8 MB 的文件还要分片那几个权限。

## 浏览和上传

单击选中，文件夹双击进去。`⌘1` 网格，`⌘2` 列表。搜索只过滤当前已经列出来的名字，不是全库检索。

一个目录最多拉 30 页 × 1000 条，再多会提示没列完。删文件夹也只删已经列到的对象。

默认只显示和上传这些：

- 图片：`jpg jpeg png gif webp heic heif tif tiff bmp svg avif jxl ico jp2`
- 文本：`json txt text`

设置里可以关掉这个过滤。超过 8 MB 自动分片（每片 8 MB），失败会 Abort。HEIC 能先转成 JPEG 再传。

OSS 没有真文件夹，`⌘⇧N` 是传一个 `application/x-directory` 的空对象当占位。

重命名是复制到新 Key 再删旧的。删除没有回收站。

## 预览

列表和检查器不拉原图，走 Bucket 的图片处理：

| 哪里 | 参数 |
| --- | --- |
| 网格 | `image/resize,w_200/crop,w_128,h_128,g_center` |
| 检查器 | `image/resize,m_lfit,w_640,h_640,limit_1` |
| 空格 / 快速查看 | 原图 |

不强制转 jpg。Bucket 没开通 IMG 的话，大图缩略图可能是空的，点开还是能看。处理失败且文件小于 256 KB 时，缩略图才退回拉原文件。

检查器里 JSON / 文本会预览正文，上限 512 KB。

## 路径条

窗口底部，跟访达那条差不多。左键跳转。右键可以复制路径、复制带 Bucket 的完整路径、复制链接、上传到这一级、在这里新建文件夹。

## 快捷键

| | |
| --- | --- |
| 上传 | `⌘O` |
| 剪贴板上传 | `⌘⇧V` |
| 添加账号 | `⌘N` |
| 新建文件夹 | `⌘⇧N` |
| 复制链接 | `⌘⇧C` |
| 刷新 | `⌘R` |
| 后退 / 前进 | `⌘[` `⌘]` |
| 网格 / 列表 | `⌘1` `⌘2` |
| 快速查看 | 空格 |
| 删除 | `⌫`（会确认） |

菜单里还能复制 Markdown 和 HTML。一次选多个就换行拼在一起。

## 设置

Lumen → 设置。同时上传 1–6 路（默认 3），HEIC 转 JPEG，是否只看素材，完成提示音，传输时要不要菜单栏图标。

账号页能改已保存的账号，Secret 不会列出来。

Siri / 快捷指令里有一条「打开 Lumen」，只是把窗口叫到前面。

## 数据放哪

| | |
| --- | --- |
| 账号列表（不含密钥） | `~/Library/Application Support/studio.lumen.oss/accounts.json` |
| AccessKey Secret / STS | 同目录 `secrets.json`，权限 `600` |
| 界面偏好、上次打开的 Bucket | UserDefaults |

换电脑要重新加账号。`secrets.json` 别发到聊天里，也别打进安装包。仓库的 `.gitignore` 已经忽略它。

更早的本地构建试过钥匙串。Debug 临时签名会让钥匙串反复弹窗，所以改成沙盒文件了；旧钥匙串里要是还能读到，启动时会迁过来。

## 实现上几句

请求打 HTTPS，虚拟主机 `bucket.oss-<region>.aliyuncs.com`。签名按[官方 V4](https://help.aliyun.com/zh/oss/developer-reference/recommend-to-use-signature-version-4)，payload 是 `UNSIGNED-PAYLOAD`。预签名默认 3600 秒。

沙盒只开了网络客户端、用户选中的文件、下载目录。

```text
Lumen/          App、OSS、Browser、Transfer、Views
LumenTests/     路径模板、签名形状、地域 Host、处理参数
Info.plist      能打开图片 / JSON / 文本
```

版本号在 Xcode 的 `MARKETING_VERSION`（现在 0.0.1），构建号 `CURRENT_PROJECT_VERSION`（1）。设置里的关于读的是包里的 `CFBundleShortVersionString`。

```bash
xcodebuild -scheme Lumen -destination 'platform=macOS,arch=arm64' test
```

单测不替代真机连 OSS。自己改完至少走一遍：加账号 → 列 Bucket → 传一张小图和一张超过 8 MB 的 → 看缩略图 → 复制链接在浏览器打开 → 删掉测试文件。

## 自己公证

要发给不认识的人，用自己的 Apple Developer 账号：Signing 选 Team，Bundle ID 换成你的（现在是 `studio.lumen.oss`），Archive → Developer ID → Notarize。

Release 里的 dmg 没走这套流程。

## 常见问题

**提示没有密钥**  
编辑账号，把 Secret 再存一次。

**缩略图是空的**  
Bucket 开通图片处理。HEIC 等格式 IMG 可能不认，点开看原图。

**传到一串日期目录里了**  
路径模板只在根目录生效，先点进目标文件夹再拖。

**同事打不开**  
没公证。让对方右键打开，或自己 Archive 后再发。

**搜索找不到别的文件夹里的图**  
只过滤当前列出来的名字。

**删了文件夹还有文件**  
超过大约 3 万个对象一次列不完，删除也只作用于已列出的。分批删，或用 ossutil。

**私有对象的链接过一会失效**  
签名 URL 默认 1 小时。要长期外链就公共读，或走 CDN。

## 安全

默认公共读的 URL 谁都能下，别把内部图当机密链发出去。AccessKey 尽量收到单个 Bucket。`secrets.json` 是本机明文，电脑丢了等于密钥丢了。

## License

还没附许可证文件。阿里云 OSS、oss-browser 的名字归各自权利人。图标来自 OSS Browser 的公开 iOS 素材，不表示跟阿里云官方有关系。
