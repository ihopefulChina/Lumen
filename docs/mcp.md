# lumen-mcp — 让 AI 直接操作你的阿里云 OSS

`lumen-mcp` 是 Lumen 附带的 MCP（Model Context Protocol）服务器。把它配置到 Claude Desktop、Claude Code、Cursor、Trae 等支持 MCP 的 AI 客户端里，AI 就能通过自然语言完成常见的 OSS 操作：

- 「看看我有哪些 Bucket」
- 「把这个截图上传到 lumen-assets 的 2026/08 文件夹」
- 「给最新的发布包生成一个 24 小时有效的下载链接」

服务器通过 stdio 与 AI 客户端通信，OSS 凭证保存在 macOS 钥匙串中，与 Lumen App 的账号相互独立。

## 前置要求

- macOS 13 或更高版本（与 Lumen App 本体一致）
- Xcode 命令行工具（`xcode-select --install`）
- 一个阿里云 RAM 子账号 AccessKey（建议只授予目标 Bucket 的必要权限）

## 第一步：构建

```bash
git clone https://github.com/ihopefulChina/Lumen.git
cd Lumen/Tools/lumen-mcp
swift build -c release
```

构建产物在 `.build/release/lumen-mcp`。可以验证：

```bash
.build/release/lumen-mcp --version
```

> 提示：记下这个二进制的绝对路径，下一步配置 AI 客户端时要用。也可以把它复制到 `$PATH` 里的目录（如 `/usr/local/bin`）方便日常调用。

## 第二步：配置凭证

```bash
.build/release/lumen-mcp auth
```

按提示填写地域、AccessKey ID / Secret（STS Token 可选）。凭证保存在当前用户的钥匙串，不会写入磁盘明文文件。

支持多个配置档案（比如公司账号和个人账号）：

| 命令 | 作用 |
| --- | --- |
| `lumen-mcp auth` | 交互式添加/更新配置档案 |
| `lumen-mcp auth --list` | 列出所有配置档案（`●` 标记活动档案） |
| `lumen-mcp auth --use <名称>` | 切换活动配置档案 |
| `lumen-mcp auth --remove <名称>` | 删除配置档案 |
| `lumen-mcp auth --test` | 验证当前凭证（调用 ListBuckets） |

## 第三步：接入 AI 客户端

### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "lumen": {
      "command": "/absolute/path/to/Lumen/Tools/lumen-mcp/.build/release/lumen-mcp"
    }
  }
}
```

重启 Claude Desktop 后，工具列表里会出现 Lumen 的 5 个工具。

### Claude Code

```bash
claude mcp add lumen -- /absolute/path/to/Lumen/Tools/lumen-mcp/.build/release/lumen-mcp
```

### Cursor / 其他兼容客户端

编辑 `~/.cursor/mcp.json`（或对应客户端的 MCP 配置文件），格式与 Claude Desktop 相同。

## 提供的工具

| 工具 | 说明 |
| --- | --- |
| `list_buckets` | 列出账号下所有 Bucket（名称、地域、创建时间） |
| `list_objects` | 浏览 Bucket 内的对象和子文件夹；默认按文件夹层级，传空 `delimiter` 可递归 |
| `upload_file` | 上传本机文件到 OSS，返回对象 URL；Content-Type 按扩展名推断 |
| `download_file` | 下载对象到本机指定路径；本地已有同名文件时不覆盖，会报错提示换路径 |
| `presign_url` | 为私有 Bucket 的对象生成带签名的临时下载链接（默认 1 小时） |

典型对话示例：

> 我：把桌面上的 hero.png 上传到 lumen-assets 的 assets/2026/ 目录，然后给我一个明天的临时链接
>
> AI：（调用 `upload_file`）已上传。（调用 `presign_url`，`expires_seconds=86400`）临时链接：https://…

## 安全说明

- AccessKey Secret 与 STS Token 只保存在 macOS 钥匙串，AI 客户端接触不到凭证本身。
- 建议使用权限最小化的 RAM 子账号，只授予需要的 Bucket 和动作。
- `lumen-mcp` 的凭证与 Lumen App 的账号完全独立，删除一边不影响另一边。
- AI 只能执行上面 5 个工具覆盖的操作；创建 Bucket、改权限策略等控制台操作不在范围内。
- 大文件（GB 级）建议仍用 Lumen App，分片上传与断点续传更完整。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| AI 提示「找不到配置档案」 | 先运行 `lumen-mcp auth` 完成配置 |
| AI 提示连接失败 | 检查客户端配置里的二进制路径是否为绝对路径、文件是否有执行权限 |
| 上传报签名错误 | 运行 `lumen-mcp auth --test` 验证凭证与地域是否匹配 |
| 想换账号 | `lumen-mcp auth --use <名称>` 切换活动档案后重启 AI 客户端 |
| 重新编译后 AI 调用时弹钥匙串授权窗 | 二进制重新构建后签名发生变化，属正常现象，点一次「始终允许」即可 |
| 下载报「本地已存在同名文件」 | 这是不覆盖保护。让 AI 换一个保存路径，或先手动删除该文件 |

更多问题请到 [GitHub Issues](https://github.com/ihopefulChina/Lumen/issues) 反馈。
