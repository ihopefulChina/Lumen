# lumen-mcp

[Lumen](https://ihopefulchina.github.io/Lumen/)（macOS 阿里云 OSS 客户端）附带的 MCP 服务器。注册到 Codex、Claude Desktop、Claude Code、Cursor 等 AI 客户端后，AI 可以用自然语言浏览 Bucket、上传下载文件、生成带签名的临时下载链接。

```bash
npx lumen-mcp auth     # 1. 配置 OSS 凭证（保存在 macOS 钥匙串）
npx lumen-mcp install  # 2. 一键注册到本机已安装的 AI 客户端
```

重启 AI 客户端，直接说「列出我的 OSS Bucket」「把桌面的 hero.png 上传到 assets/2026/，给我一个 24 小时的链接」。

## 环境要求

- macOS（Apple Silicon 或 Intel；二进制按架构自动安装）
- Node ≥ 18（`node -v` 检查；没有的话 `brew install node`）
- 没有 Node？可从[源码构建](https://github.com/ihopefulChina/Lumen/blob/main/docs/mcp.md)，或使用 [GitHub Releases](https://github.com/ihopefulChina/Lumen/releases) 的独立二进制

## 提供的能力

| 工具 | 说明 |
| --- | --- |
| `list_buckets` | 列出账号下所有 Bucket |
| `list_objects` | 按文件夹层级浏览对象，也可递归列举 |
| `upload_file` | 上传本机文件，返回对象 URL |
| `download_file` | 下载对象；本地同名文件不覆盖 |
| `presign_url` | 为私有 Bucket 生成带签名的临时下载链接 |

另有 2 个内置提示词（`lumen-oss-expert` OSS 专家模式、`oss-batch-upload` 批量上传工作流），可在客户端 Prompts 面板一键使用。

## 支持的客户端

`install` 自动检测并注册：Codex、Claude Desktop、Claude Code、Cursor、Windsurf。其他 stdio 客户端（VS Code Copilot、Cline、Qoder 等）手动配置：

```json
{
  "mcpServers": {
    "lumen": { "command": "npx", "args": ["-y", "lumen-mcp"] }
  }
}
```

### 默认 Bucket（可选）

在服务条目加 `env`，AI 不传 `bucket` 时自动使用默认桶，桶名会直接出现在工具描述中：

```json
{
  "mcpServers": {
    "lumen": {
      "command": "npx",
      "args": ["-y", "lumen-mcp"],
      "env": { "LUMEN_MCP_DEFAULT_BUCKET": "my-bucket" }
    }
  }
}
```

## 安全

AccessKey Secret 只存 macOS 钥匙串，AI 客户端接触不到凭证；建议使用最小权限 RAM 子账号；下载不覆盖本地同名文件。详见[安全边界](https://ihopefulchina.github.io/Lumen/mcp.html)。

## 常见问题

- **AI 提示找不到配置档案** — 先运行 `npx lumen-mcp auth`
- **上传报签名错误** — 运行 `npx lumen-mcp auth --test` 验证凭证与地域
- **移除注册** — `npx lumen-mcp uninstall`

完整文档（客户端配置位置、多账号、故障排查）见 [docs/mcp.md](https://github.com/ihopefulChina/Lumen/blob/main/docs/mcp.md)。问题反馈到 [GitHub Issues](https://github.com/ihopefulChina/Lumen/issues)。

## License

MIT
