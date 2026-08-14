# Lumen

原生 macOS 客户端，用来把素材上传到[阿里云对象存储 OSS](https://www.aliyun.com/product/oss)。

它不是 [oss-browser](https://github.com/aliyun/oss-browser) 的 Electron 移植。界面按访达和照片来：侧边栏管账号和 Bucket，中间是网格 / 列表，右边是检查器（默认收起），底下是路径条。目标很窄：把图片、JSON、文本送到 OSS，再把链接复制出去。

当前版本：**0.0.1**（首个公开源码版本）

- 仓库：<https://github.com/ihopefulChina/lumen>
- Release：<https://github.com/ihopefulChina/lumen/releases>
- 只支持 **Apple Silicon**（`arm64`），不考虑 Intel
- 最低系统 **macOS 15 Sequoia**
- 语言：Swift 6 + SwiftUI，Xcode 16 / 26 可编译
- Bundle ID：`studio.lumen.oss`
- 请求签名：阿里云 OSS **Signature V4**（`OSS4-HMAC-SHA256`，payload = `UNSIGNED-PAYLOAD`）
- 界面语言：简体中文

---

## 目录

- [能做什么](#能做什么)
- [明确不做的事](#明确不做的事)
- [和 oss-browser 的差别](#和-oss-browser-的差别)
- [窗口怎么排](#窗口怎么排)
- [环境要求](#环境要求)
- [从源码运行](#从源码运行)
- [从 Release 安装](#从-release-安装)
- [第一次使用](#第一次使用)
- [账号与权限](#账号与权限)
- [支持的地域](#支持的地域)
- [路径模板](#路径模板)
- [浏览](#浏览)
- [上传](#上传)
- [下载、重命名、删除](#下载重命名删除)
- [图片预览与 OSS 处理](#图片预览与-oss-处理)
- [路径条](#路径条)
- [检查器](#检查器)
- [传输队列](#传输队列)
- [快捷键与菜单](#快捷键与菜单)
- [设置](#设置)
- [App 快捷指令](#app-快捷指令)
- [数据存在哪](#数据存在哪)
- [网络与签名](#网络与签名)
- [工程结构](#工程结构)
- [自己打正式包](#自己打正式包)
- [常见问题](#常见问题)
- [安全说明](#安全说明)
- [开发与测试](#开发与测试)
- [版本与发布说明](#版本与发布说明)
- [License](#license)

---

## 能做什么

- 用 AccessKey（或 STS Token）登录，密钥只存在本机沙盒
- 列出账号下的 Bucket，按 Bucket 自己的地域选 Endpoint 和签名 Region
- 按前缀浏览文件夹和对象（`ListObjectsV2`，`delimiter=/`）
- 网格 / 列表切换，单击选中、双击进入文件夹
- 上传图片（jpg / png / gif / webp / heic 等）、`.json`、`.txt`
- 拖放、访达选取、照片选取、剪贴板粘贴、从访达「打开方式」丢给 App
- 大于 8 MB 自动分片上传（每片 8 MB），失败会 Abort Multipart
- 下载、重命名（服务端复制 + 删除）、删除文件或整个文件夹前缀
- 复制链接、Markdown、HTML；私有对象复制 1 小时签名链接
- 列表缩略图走 OSS `x-oss-process`（缩放 + 中心裁剪），点开看原图
- 底部路径条：跳转、右键复制路径 / 链接、上传到此处、新建文件夹
- 传输队列：进度、取消、完成后复制链接
- 传输中 Dock 角标；可选菜单栏图标
- 退出时若还有传输会提示
- 无障碍：尊重「减少动态效果」

## 明确不做的事

Lumen 刻意不做完整控制台。下面这些请继续用阿里云控制台或 [oss-browser](https://github.com/aliyun/oss-browser)：

- 创建 / 删除 Bucket
- 改 Bucket ACL、生命周期、跨域、防盗链、镜像回源
- 碎片（Multipart Upload 残留）管理台
- 对象完整 ACL 编辑、版本控制、WORM
- 跨 Bucket / 跨账号复制、同步盘
- 全库检索（当前搜索只过滤**已列出的当前文件夹**）
- Intel Mac、Windows、Linux
- 未公证的二进制分发给陌生人（Gatekeeper 会拦）

---

## 和 oss-browser 的差别

| | Lumen | oss-browser |
| --- | --- | --- |
| 形态 | 原生 SwiftUI Mac 应用 | Electron，跨 Windows / Linux / Mac |
| 芯片 | 仅 Apple Silicon | 含 Intel |
| 最低系统 | macOS 15 | 更老的系统也能跑 |
| 定位 | 素材上传和取链 | 通用对象管理 |
| 登录 | AccessKey / STS，密钥在沙盒文件 | 多种登录 |
| 图片 | 列表用 IMG 处理参数，点开看原图 | 通用预览 |
| 路径 | 根目录可套日期模板 | 自己拼前缀 |
| 沙盒 | App Sandbox 开着 | 视打包方式 |

---

## 窗口怎么排

```text
┌────────────┬──────────────────────────────┬────────────┐
│  账号      │  工具栏：上传 / 视图 / 信息     │            │
│  Bucket    │──────────────────────────────│  检查器    │
│            │                              │  （默认关） │
│  侧边栏    │   网格 或 列表                 │            │
│  默认开    │   文件夹 / 图片 / JSON / TXT   │            │
│            │                              │            │
├────────────┴──────────────────────────────┴────────────┤
│              底部路径条（访达式面包屑）                   │
└────────────────────────────────────────────────────────┘
           底下还可展开传输托盘
```

- 默认窗口约 `1240 × 800`，最小约 `880 × 560`
- 左边栏宽约 `200–300`
- 检查器宽约 `260–380`，用工具栏「信息」打开，**默认不显示**
- 没有账号时先走欢迎页，点「添加账号…」

---

## 环境要求

运行：

- Mac（Apple Silicon）
- macOS 15 或更高
- 一个阿里云账号，以及对该 Bucket 有读写权限的 AccessKey

编译：

- Xcode 16 或 Xcode 26（工程按 Xcode 26 建的）
- 命令行工具：`xcodebuild`

阿里云侧建议：

- 账号里填的地域尽量和常用 Bucket 一致；打开某个 Bucket 后，签名 Region 会改成 **Bucket 自己的地域**
- 若要用列表缩略图，Bucket 开通 **图片处理 IMG**
- 若对象要公网直链，ACL 用「公共读」，或自己挂 CDN

---

## 从源码运行

```bash
git clone git@github.com:ihopefulChina/lumen.git
cd lumen
open Lumen.xcodeproj
```

HTTPS 克隆：

```bash
git clone https://github.com/ihopefulChina/lumen.git
```

Xcode 中选 scheme **Lumen**，目标 **My Mac**，Run。

命令行：

```bash
xcodebuild -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug \
  build
```

产物一般在：

```text
~/Library/Developer/Xcode/DerivedData/Lumen-*/Build/Products/Debug/Lumen.app
```

第一次用自己的证书时，到 Target → **Signing & Capabilities** 勾选 Automatically manage signing，选 Team。工程里 Debug 默认是临时签名（`CODE_SIGN_IDENTITY = -`），只适合本机自己跑。

不要把这个 Debug `.app` 拷给别人当安装包。

---

## 从 Release 安装

1. 打开 [Releases](https://github.com/ihopefulChina/lumen/releases)
2. 下载对应 tag 的源码包（GitHub 会自动挂 `Source code (zip)` / `tar.gz`）
3. 若该版本另外附了已公证的 `.app` / `.dmg`，解压后拖到「应用程序」即可

当前 **0.0.1** 以**源码 Release** 为主。未公证的 `.app` 发到别人电脑上会被 Gatekeeper 拦截（「无法验证开发者」）。

没有公证包时，请按上一节从源码编译。自己打公证包见 [自己打正式包](#自己打正式包)。

---

## 第一次使用

1. 启动后点 **添加账号…**（欢迎页按钮、侧边栏工具栏的 `+`，或快捷键 `⌘N`）
2. 填写：
   - **名称**（可选，方便区分工作室 / 主账号）
   - **AccessKey ID**
   - **AccessKey Secret**（眼睛按钮可显示明文）
   - **地域**（如华东 1 杭州 `cn-hangzhou`）
3. 可选：
   - 传输加速
   - 默认 ACL（出厂是**公共读**）
   - 路径模板
   - 高级：STS Token、自定义 Endpoint、CDN 域名
4. 点 **存储并连接**。应用会发一次 `ListBuckets` 验证密钥
5. 左侧选 Bucket，中间即可浏览
6. 把文件拖进窗口，或 `⌘O` 选取

根目录上传会套路径模板，默认：

```text
assets/{yyyy}/{MM}/{dd}/
```

已经进入某个文件夹后再拖文件，只传到当前文件夹，不再套一层日期。

---

## 账号与权限

### AccessKey

建议用 **RAM 子用户**，只授需要的 OSS 权限。不要用主账号永久密钥做日常上传。

日常上传 / 浏览 / 删除，大致需要：

| Action | 用途 |
| --- | --- |
| `oss:ListBuckets` | 登录时拉 Bucket 列表 |
| `oss:ListObjects` / `oss:ListObjectsV2` | 浏览文件夹 |
| `oss:GetObject` | 预览、下载、快速查看 |
| `oss:PutObject` | 上传、新建文件夹占位、重命名时的复制 |
| `oss:DeleteObject` | 删除、重命名时清掉旧对象 |
| `oss:AbortMultipartUpload` | 分片失败时清理 |
| `oss:InitiateMultipartUpload` / `oss:UploadPart` / `oss:CompleteMultipartUpload` | 大于 8 MB 的文件 |

示例 RAM 策略（请把 `YOUR-BUCKET` 换成真实名字，按需删掉 Delete）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["oss:ListBuckets"],
      "Resource": ["acs:oss:*:*:*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "oss:ListObjects",
        "oss:ListObjectsV2",
        "oss:GetObject",
        "oss:PutObject",
        "oss:DeleteObject",
        "oss:AbortMultipartUpload",
        "oss:InitiateMultipartUpload",
        "oss:UploadPart",
        "oss:CompleteMultipartUpload"
      ],
      "Resource": [
        "acs:oss:*:*:YOUR-BUCKET",
        "acs:oss:*:*:YOUR-BUCKET/*"
      ]
    }
  ]
}
```

### 默认 ACL

上传时写到对象头 `x-oss-object-acl`。

| 选项 | 含义 | 复制链接时 |
| --- | --- | --- |
| 继承存储空间 | 跟 Bucket 默认权限 | 按账号是否「看起来像私有」决定 |
| 私有 | 只有密钥能访问 | **1 小时**签名 URL |
| 公共读 | 链接可直接打开，适合对外素材 | 普通 `https://bucket.oss-….aliyuncs.com/key` |
| 公共读写 | 几乎不该用 | 同公共读 |

出厂默认是 **公共读**。内部文件请改成私有。挂了 CDN 域名后，复制的是 CDN 链接，不再自动签 OSS URL。

### 传输加速

打开后 API Host 用 `oss-accelerate.aliyuncs.com`。签名 Region 仍用 Bucket 真实地域。Bucket 需要先在控制台开通传输加速。

### 自定义 Endpoint / CDN

- Endpoint 填 `oss-cn-hangzhou.aliyuncs.com` 这种地域域名（不要带 `https://`）
- 若不小心填成 `bucket.oss-cn-hangzhou.aliyuncs.com`，应用会去掉前面的 Bucket 名
- 自定义域名（CNAME）不会再拼成 `bucket.你的域名.com`
- CDN 域名只用于**展示和复制链接**，请求 API 仍走 OSS Endpoint

### STS

高级里可填 STS Token。请求会带 `x-oss-security-token`。Token 过期后重新编辑账号填新的即可。

---

## 支持的地域

下拉列表里内置这些 Region（也可在高级 Endpoint 里填官方未列出的）：

| ID | 名称 |
| --- | --- |
| `cn-hangzhou` | 华东1（杭州） |
| `cn-shanghai` | 华东2（上海） |
| `cn-nanjing` | 华东5（南京） |
| `cn-fuzhou` | 华东6（福州） |
| `cn-wuhan` | 华中1（武汉） |
| `cn-qingdao` | 华北1（青岛） |
| `cn-beijing` | 华北2（北京） |
| `cn-zhangjiakou` | 华北3（张家口） |
| `cn-huhehaote` | 华北5（呼和浩特） |
| `cn-wulanchabu` | 华北6（乌兰察布） |
| `cn-shenzhen` | 华南1（深圳） |
| `cn-heyuan` | 华南2（河源） |
| `cn-guangzhou` | 华南3（广州） |
| `cn-chengdu` | 西南1（成都） |
| `cn-hongkong` | 中国香港 |
| `ap-southeast-1` | 新加坡 |
| `ap-southeast-3` | 吉隆坡 |
| `ap-southeast-5` | 雅加达 |
| `ap-southeast-7` | 曼谷 |
| `ap-northeast-1` | 东京 |
| `ap-northeast-2` | 首尔 |
| `ap-south-1` | 孟买 |
| `us-west-1` | 硅谷 |
| `us-east-1` | 弗吉尼亚 |
| `eu-central-1` | 法兰克福 |
| `eu-west-1` | 伦敦 |
| `me-east-1` | 迪拜 |

默认公共 Host 形如 `oss-<id>.aliyuncs.com`。对象请求用虚拟主机：`bucket.oss-<id>.aliyuncs.com`。

---

## 路径模板

只在**当前前缀为空（Bucket 根）**且模板非空时生效。进入任意文件夹后再上传，模板不参与。

可用占位符（按本地日历展开）：

| 占位符 | 含义 | 例 |
| --- | --- | --- |
| `{yyyy}` | 四位年 | `2026` |
| `{MM}` | 两位月 | `08` |
| `{dd}` | 两位日 | `14` |
| `{HH}` | 两位时 | `09` |
| `{mm}` | 两位分 | `05` |
| `{ss}` | 两位秒 | `07` |
| `{filename}` | 完整文件名 | `hero.png` |
| `{name}` | 不含扩展名 | `hero` |
| `{ext}` | 扩展名 | `png` |

出厂模板：`assets/{yyyy}/{MM}/{dd}/`  
上传 `hero.png` 会变成：`assets/2026/08/14/hero.png`

连续斜杠会被收成单斜杠，首尾 `/` 会去掉后再和当前前缀拼接。

---

## 浏览

- 侧边栏：账号、该账号下的 Bucket
- 中间：网格（`⌘1`）或列表（`⌘2`）
- 单击选中；文件夹**双击**进入
- 文件夹选中：图标后有淡强调色，名字蓝底白字（访达图标视图）
- 后退 / 前进：`⌘[` / `⌘]`
- 刷新：`⌘R`
- 搜索：工具栏搜索框只过滤**当前已列出**的名称，不是全库检索
- 列表接口：`ListObjectsV2`，`delimiter=/`，每页最多 1000 条
- 大目录最多拉 **30 页 × 1000 条**。还有下一页时会提示目录未列完
- 名为当前前缀本身的占位对象（`application/x-directory`）不会显示成文件

「只显示和上传素材」打开时，网格 / 列表只留图片和 JSON / TXT；关掉后能看见 Bucket 里其它类型。

---

## 上传

### 从哪进文件

- 拖到窗口（文件或文件夹；文件夹会递归展开）
- `⌘O` / 菜单「上传图片…」（系统选取面板，可多选）
- 从照片 App 拖入
- `⌘⇧V` 从剪贴板上传（图片或文件 URL）
- 访达里把文件「打开方式」指定给 Lumen（声明了 `public.image` / `public.json` / `public.text`）

沙盒只允许访问你选中或拖入的文件，以及下载目录。

### 支持的扩展名

默认「只显示和上传素材」时：

**图片**

`jpg` `jpeg` `png` `gif` `webp` `heic` `heif` `tif` `tiff` `bmp` `svg` `avif` `jxl` `ico` `jp2`

**文本**

`json` `txt` `text`

关闭该开关后，上传过滤放开，其它类型按扩展名猜 `Content-Type`（未识别则为 `application/octet-stream`）。

### 上传规则

- 对象 Key = 当前文件夹前缀 +（仅根目录时）路径模板 + 文件名
- `Content-Type` 按扩展名写
- ACL 用账号的默认权限
- **小于等于 8 MB**：一次 `PUT`
- **大于 8 MB**：Multipart，每片 8 MB；失败调用 `AbortMultipartUpload`
- 单个请求超时 30 分钟
- HEIC 可在设置里先转成 JPEG 再传（会改文件名扩展名和 `image/jpeg`）
- 同时进行的上传路数：设置里 1–6，默认 3
- 拖入文件夹时，不符合过滤器的文件会被跳过并计数提示

### 新建文件夹

`⌘⇧N` 或路径条右键「在此处新建文件夹…」。实现是上传一个空对象：

```text
当前前缀/文件夹名/
Content-Type: application/x-directory
ACL: 继承存储空间
```

OSS 没有真正的文件夹，这只是前缀约定。

---

## 下载、重命名、删除

- **下载**：选中对象 → 选本机文件夹。文件名用对象的 `name`（最后一段）
- **重命名**：复制到新 Key 再删旧对象（不是服务端 Rename API）
- **删除文件**：红色按钮或 `⌫`，先确认
- **删除文件夹**：选中文件夹再删，会删该前缀下**已经列出**的对象。若目录超过 30 页，未列出的对象不会被这次删除扫到
- 删除不可撤销，没有回收站

---

## 图片预览与 OSS 处理

列表和检查器**不拉原图**，走 [GetObject + `x-oss-process`](https://www.alibabacloud.com/help/zh/oss/user-guide/custom-crop)。Bucket 需要开通 **图片处理 IMG**。

| 位置 | 参数 | 说明 |
| --- | --- | --- |
| 网格缩略图 | `image/resize,w_200/crop,w_128,h_128,g_center` | 先缩到宽 200，再中心裁 128×128 |
| 检查器 | `image/resize,m_lfit,w_640,h_640,limit_1` | 等比放入 640，不放大 |
| 空格 / 双击快速查看 | **无处理参数** | 下载原图到临时目录再 Quick Look |

不强制 `format,jpg`，尽量保留原格式。

处理失败且文件小于 **256 KB** 时，缩略图才退回拉原文件。Bucket 未开通 IMG 时，大图缩略图可能空白，点开仍可看原图。

私有 Bucket 的缩略图请求同样走带签名的 GET。

---

## 路径条

窗口底部，类似访达路径栏。面包屑第一级是 Bucket 名，后面每一级是前缀。

左键点某一级：跳到该前缀。  
右键某一级或栏空白处：

| 菜单 | 作用 |
| --- | --- |
| 复制路径 | 例如 `assets/2026/08/` |
| 复制完整路径 | 例如 `bucket/assets/2026/08/` |
| 复制链接 | 该前缀对应的 HTTPS 地址 |
| 转到此处 | 与左键相同 |
| 上传到此处… | 打开选取面板，目标前缀用这一级 |
| 在此处新建文件夹… | 在这一级下建前缀 |

---

## 检查器

默认收起。工具栏「信息」打开。

选中对象后会 `HEAD` 一次，展示：

- 文件名、种类、大小
- `Content-Type`、ETag、存储类型、ACL（若响应里有）
- 最后修改时间
- 公共 / 签名链接
- 图片：处理后的预览
- JSON / 文本：拉正文预览，**不超过 512 KB**

底部删除是红色，会再确认。

---

## 传输队列

窗口底部托盘（有任务时出现）：

- 排队 / 进行中 / 完成 / 失败
- 进度条、已传字节
- 取消进行中的任务
- 上传完成后可直接复制该对象链接
- 完成时可播放系统提示音（设置里关）
- Dock 图标角标 = 进行中的任务数
- 设置打开时，传输期间菜单栏会多一个 Lumen 图标，点开看队列
- 退出时若 `activeCount > 0`，对话框：「退出」或「继续传输」

---

## 快捷键与菜单

### 文件

| 操作 | 快捷键 |
| --- | --- |
| 上传 / 选取文件 | `⌘O` |
| 从剪贴板上传 | `⌘⇧V` |
| 添加账号 | `⌘N` |
| 新建文件夹 | `⌘⇧N` |

### 编辑

| 操作 | 快捷键 |
| --- | --- |
| 复制链接 | `⌘⇧C` |
| 复制 Markdown | 菜单「编辑」 |
| 复制 HTML | 菜单「编辑」 |
| 删除 | `⌫`（先确认） |

Markdown 形如 `![name](url)`，HTML 形如 `<img src="url" alt="name" />`。一次可复制多条，换行分隔。

### 浏览

| 操作 | 快捷键 |
| --- | --- |
| 后退 / 前进 | `⌘[` / `⌘]` |
| 刷新 | `⌘R` |
| 网格 / 列表 | `⌘1` / `⌘2` |
| 快速查看 | 空格 |

系统设置在 **Lumen → 设置…**。

---

## 设置

**Lumen → 设置…**，两个标签。

### 通用

| 项 | 默认 | 说明 |
| --- | --- | --- |
| 同时上传 1–6 路 | 3 | 写入 `settings.concurrentUploads` |
| 将 HEIC 转为 JPEG | 关 | 上传前用系统解码再压 JPEG |
| 只显示和上传素材 | 开 | 图片 + JSON + 文本 |
| 完成时播放提示音 | 关 | `NSSound` |
| 传输时显示菜单栏图标 | 开 | 仅传输期间插入 `MenuBarExtra` |

### 账号

列出已保存账号（只显示名称、地域、AccessKey ID），可点编辑。Secret 不会出现在这个列表里。

关于栏显示版本 **0.0.1**。

---

## App 快捷指令

提供一条 App Intent：**打开 Lumen**（把窗口带到前面）。

Siri / 快捷指令示例短语：

- 「打开 Lumen」
- 「用 Lumen 上传素材」

当前不会自动选文件或开上传面板，只是把 App 激活。

---

## 数据存在哪

都在本机用户目录，**不进 git**（`.gitignore` 已忽略 `secrets.json`、`.env`、`xcuserdata`、DerivedData）。

| 内容 | 路径 |
| --- | --- |
| 账号列表（不含 Secret） | `~/Library/Application Support/studio.lumen.oss/accounts.json` |
| AccessKey Secret / STS | `~/Library/Application Support/studio.lumen.oss/secrets.json`（权限 `600`） |
| 界面偏好 | UserDefaults（并发数、HEIC、过滤器、菜单栏等） |
| 上次账号 / Bucket | UserDefaults |
| 快速查看缓存 | 系统临时目录，文件名带 ETag |

换电脑或重装后需要重新加账号。不要把 `secrets.json` 发到聊天或打进安装包。

0.0.1 之前试过把密钥放进钥匙串。Debug 临时签名（`CODE_SIGN_IDENTITY = -`）会让钥匙串 ACL 反复弹窗，而且条目容易绑死。现在写入沙盒文件；若旧钥匙串里还能读到，启动时会**迁移**到 `secrets.json`，不会先清空再写。

---

## 网络与签名

- 仅 HTTPS
- 虚拟主机：`bucket.oss-<region>.aliyuncs.com`
- 账号级操作（ListBuckets）打在地域 Host 上，不带 Bucket
- 签名算法：[OSS Signature Version 4](https://help.aliyun.com/zh/oss/developer-reference/recommend-to-use-signature-version-4)
  - `x-oss-content-sha256: UNSIGNED-PAYLOAD`
  - Canonical Request 含空的 additional headers 行（官方要求）
  - 查询参数、对象 Key 按官方规则 URI Encode（斜杠是否编码分开处理）
- 预签名 URL 默认 **3600 秒**
- 图片处理把 `x-oss-process` 放在查询串里再签名
- STS 请求额外带 `x-oss-security-token`

应用开了 App Sandbox，权限只有：

- `com.apple.security.network.client`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.downloads.read-write`

隐私清单 `PrivacyInfo.xcprivacy`：不追踪；UserDefaults 访问原因为 `CA92.1`。

---

## 工程结构

```text
lumen/
  Lumen.xcodeproj
  Lumen/
    LumenApp.swift          入口、菜单、Dock 打开文件、退出确认
    App/
      AppModel.swift        账号、当前 Bucket、复制链接、删除、检查器
      AccountStore.swift    accounts.json
      AppSettings.swift     UserDefaults
    OSS/
      OSSSigner.swift       V4 Canonical Request / 预签名查询
      OSSClient.swift       REST：列举、上传、分片、下载、HEAD
      OSSXML.swift          ListBuckets / ListObjects 解析
      OSSTypes.swift        地域、账号、ACL、对象模型
      OSSImageProcess.swift 缩略图 / 检查器处理参数
    Browser/
      BrowserModel.swift    前缀、选择、前进后退、网格过滤
    Transfer/
      TransferEngine.swift  队列、HEIC、安全作用域、Dock 角标
      TransferJob.swift
    Views/
      RootView.swift        欢迎页 / 三栏工作区
      SidebarView.swift
      BrowserView.swift     网格、列表、文件夹高亮
      InspectorView.swift
      TransferTray.swift
      AccountSheet.swift
      SettingsView.swift
      ThumbnailView.swift
      WelcomeView.swift
    Support/
      SecretStore.swift     secrets.json + 旧钥匙串迁移
      KeychainStore.swift   只读恢复，不再作为主存储
      PathTemplate.swift    日期模板、面包屑
      Formatters.swift      体积、种类、Content-Type
      SystemIcons.swift     访达文件夹图标
      Glass.swift / Haptics.swift
    Intents/LumenShortcuts.swift
    PrivacyInfo.xcprivacy
    Lumen.entitlements
    Assets.xcassets         App Icon（按 macOS 图标网格留白）
  LumenTests/               路径模板、签名规范化、地域 Host、处理参数
  Info.plist                可打开的文档类型（图片 / JSON / 文本）
  README.md
```

营销版本号 `MARKETING_VERSION = 0.0.1`，构建号 `CURRENT_PROJECT_VERSION = 1`。

---

## 自己打正式包

1. 用自己的 [Apple Developer](https://developer.apple.com) 账号
2. Xcode → Signing & Capabilities → 选 Team
3. Bundle ID 改成你的（现在是 `studio.lumen.oss`，别人没法用你的 Team 签这个 ID）
4. 版权、显示名按需要改
5. Product → **Archive**（目标仍是 My Mac / Any Mac Apple Silicon）
6. Distribute App → **Developer ID** → Upload / Notarize
7. 公证通过后再分发 `.app` 或自己做的 `.dmg`

没有 Developer ID 和公证，不要把本地 Debug 包当正式安装程序发给别人。

本仓库 **0.0.1** 的 GitHub Release **不附带**已公证二进制。需要安装包请按上面自己 Archive。

---

## 常见问题

**连接失败 / 提示没有密钥**  
编辑账号，重新填写 AccessKey Secret 并保存。0.0.1 起密钥在 `secrets.json`。若你用过更早的本地构建，启动时会尝试从旧钥匙串迁一次。

**ListBuckets 成功但某个 Bucket 列不出来**  
RAM 策略可能只授了部分 Bucket；或地域 / Endpoint 填错。打开 Bucket 后签名用的是 Bucket 的 `Location`。

**缩略图是空的**  
确认 Bucket 已开通图片处理；HEIC / 部分格式可能不被 IMG 支持，点开仍可看原图。

**图标和系统 App 不一样大**  
应用图标已按 macOS 图标网格留白。若 Dock 仍显示旧图，退出应用，从 Dock 移走后再运行，或重启一次。

**每次编译都要输钥匙串密码**  
用现在的版本即可，密钥不再写入会绑定代码签名的文件钥匙串。

**上传到了奇怪的多层日期目录**  
路径模板只在根目录生效。先点进目标文件夹再拖文件。

**发给同事打不开**  
未公证。按「自己打正式包」做完再发，或让对方从源码编译。

**搜索找不到别的文件夹里的图**  
搜索不是 OSS 全库检索，只过滤当前页已经拉下来的名字。

**删除文件夹后还有文件**  
该前缀超过 3 万个对象时，一次列表列不完，删除也只作用于已列出的部分。分批删，或用控制台 / ossutil。

**私有对象的链接过一会儿失效**  
签名 URL 默认 1 小时。需要长期外链请改公共读或走 CDN。

---

## 安全说明

- 默认公共读意味着对象 URL 可被任何人下载，链接不要当机密
- AccessKey 权限尽量收窄到单个 Bucket；日常账号不要随便授 `oss:DeleteBucket`
- `secrets.json` 仅当前用户可读（`0600`），但仍是本机明文；丢失电脑等于丢失密钥
- 应用开了沙盒，只能访问你选中或拖入的文件，以及下载目录
- 仓库不含密钥、`.env`、用户数据。Review PR 时不要把真实 AccessKey 贴进 Issue
- 本项目不会替你把包公证；你从未知 fork 下的二进制请自行判断

---

## 开发与测试

```bash
xcodebuild -scheme Lumen \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug \
  test
```

当前单测（Swift Testing）覆盖：

- 路径拼接、去重斜杠、面包屑、日期占位符
- URI 编码、Canonical Request 形状（含空 additional headers）
- 地域 Host、Endpoint 规范化
- 图片 / 文本种类和 `Content-Type`
- 图片处理参数字符串

不替代真实 OSS 联调。上线前请至少：加自己的账号 → 列 Bucket → 上传一张小图和一张 >8 MB 的图 → 看缩略图 → 复制链接在浏览器打开 → 删掉测试对象。

欢迎 Issue / PR。改签名或 XML 解析时请补测试。

---

## 版本与发布说明

遵循[语义化版本](https://semver.org/lang/zh-CN/)。`MARKETING_VERSION` 是用户看见的版本，`CURRENT_PROJECT_VERSION` 是构建号。

发布记录见 [Releases](https://github.com/ihopefulChina/lumen/releases)。

### 0.0.1 — 2026-08-14

首个公开源码版本。功能可用，默认 ACL、密钥存放、公证流程仍按「内部工具」来。

- 原生 SwiftUI 三栏浏览（侧边栏 + 网格/列表 + 默认收起的检查器）
- OSS Signature V4，虚拟主机访问
- AccessKey / STS，密钥写入 `secrets.json`（`600`），兼容从旧钥匙串迁移
- 素材上传：图片、JSON、TXT；拖放 / 选取 / 剪贴板
- 大于 8 MB 分片上传
- 根目录日期路径模板
- 列表缩略图走 `x-oss-process`，快速查看下原图
- 路径条右键：复制路径 / 链接、上传到此处、新建文件夹
- 复制普通链接或 1 小时签名链接，以及 Markdown / HTML
- 传输队列、Dock 角标、可选菜单栏
- 仅 Apple Silicon / macOS 15+
- **不含**已公证的安装包

---

## License

源码按仓库内声明使用；当前尚未附加 SPDX 许可证文件。阿里云 OSS、oss-browser 名称归各自权利人所有。应用图标来自 OSS Browser 的公开 iOS 图标素材，仅作识别，不表示与阿里云官方有从属关系。
