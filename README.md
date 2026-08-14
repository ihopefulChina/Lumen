# Lumen

原生 macOS 应用，用来把素材图片、JSON 和文本上传到阿里云 OSS。界面按访达 / 照片的习惯来：侧边栏、网格、检查器、底部路径条。

只支持 Apple Silicon，最低 macOS 15。

## 打开

```bash
git clone git@github.com:ihopefulChina/lumen.git
cd lumen
open Lumen.xcodeproj
```

Xcode 里选 Lumen scheme 运行。或：

```bash
xcodebuild -scheme Lumen -destination 'platform=macOS,arch=arm64' -configuration Debug build
```

## 第一次用

1. 添加账号：AccessKey ID、Secret、地域。
2. 选一个存储空间。
3. 把文件拖进窗口，或 `⌘O` 选取。
4. 选中后 `⌘⇧C` 复制链接。空格键快速查看原图。

默认路径模板是 `assets/{yyyy}/{MM}/{dd}/`，只在 Bucket 根目录生效。默认 ACL 是公共读；需要私有就在账号里改。

密钥存在本机沙盒：`~/Library/Application Support/studio.lumen.oss/secrets.json`，不要提交到仓库。

列表缩略图走 OSS 图片处理（`x-oss-process`），Bucket 需开通 IMG。点开预览仍是原图。

## 发布

不要把 Debug 包直接发给别人。在 Xcode 填好 Team，把 Bundle ID 改成你自己的，Archive 后用 Developer ID 公证再分发。
