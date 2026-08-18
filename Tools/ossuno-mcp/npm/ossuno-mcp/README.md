# ossuno-mcp

[Ossuno](https://ihopefulchina.github.io/Ossuno/)（macOS 阿里云 OSS 客户端）附带的 MCP 服务器。注册到 Codex、Claude Desktop、Claude Code、Cursor 等 AI 客户端后，AI 可以用自然语言浏览 Bucket、上传下载文件、生成带签名的临时下载链接。

```bash
npx ossuno-mcp auth     # 1. 配置 OSS 凭证（保存在 macOS 钥匙串）
npx ossuno-mcp install  # 2. 一键注册到本机已安装的 AI 客户端
```

重启 AI 客户端，直接说「列出我的 OSS Bucket」「把桌面的 hero.png 上传到 assets/2026/，给我一个 24 小时的链接」。

## 环境要求

- macOS（Apple Silicon 或 Intel；二进制按架构自动安装）
- Node ≥ 18（`node -v` 检查；没有的话 `brew install node`）
- 没有 Node？可从[源码构建](https://github.com/ihopefulChina/Ossuno/blob/main/docs/mcp.md)，或使用 [GitHub Releases](https://github.com/ihopefulChina/Ossuno/releases) 的独立二进制

## 提供的能力

| 工具 | 说明 |
| --- | --- |
| `list_buckets` | 列出账号下所有 Bucket |
| `list_objects` | 按文件夹层级浏览对象，也可用 continuation token 连续翻页 |
| `upload_file` | 上传本机文件，默认拒绝覆盖远端同名对象 |
| `download_file` | 下载对象；本地同名文件不覆盖 |
| `presign_url` | 为私有 Bucket 生成带签名的临时下载链接 |

另有 2 个内置提示词（`ossuno-oss-expert` OSS 专家模式、`oss-batch-upload` 批量上传工作流），可在客户端 Prompts 面板一键使用。

## 支持的客户端

`install` 自动检测并注册：Codex、Claude Desktop、Claude Code、Cursor、Trae、Windsurf。其他 stdio 客户端（VS Code Copilot、Cline、Qoder 等）手动配置：

```json
{
  "mcpServers": {
    "ossuno": { "command": "npx", "args": ["-y", "ossuno-mcp"] }
  }
}
```

### 默认 Bucket（可选）

在服务条目加 `env`，AI 不传 `bucket` 时自动使用默认桶，桶名会直接出现在工具描述中：

```json
{
  "mcpServers": {
    "ossuno": {
      "command": "npx",
      "args": ["-y", "ossuno-mcp"],
      "env": { "OSSUNO_MCP_DEFAULT_BUCKET": "my-bucket" }
    }
  }
}
```

### 本地文件允许目录

为避免 AI 意外读取凭证或写入任意位置，上传、下载只允许访问指定目录，且拒绝符号链接。默认允许桌面、文稿、下载和系统临时目录。可在服务条目的 `env` 中覆盖，使用冒号分隔绝对路径：

```json
{
  "mcpServers": {
    "ossuno": {
      "command": "npx",
      "args": ["-y", "ossuno-mcp"],
      "env": {
        "OSSUNO_MCP_ALLOWED_ROOTS": "/Users/me/projects:/Users/me/Downloads"
      }
    }
  }
}
```

`upload_file` 默认先调用 GetBucketVersioning，再做远端存在性检查并发送 OSS 禁止覆盖请求头。只有版本控制未配置（响应不含 Status）时才继续执行保护流程；Enabled 与 Suspended 状态下 OSS 都会忽略禁止覆盖请求头，因此工具会安全拒绝上传。版本状态查询失败同样拒绝，不会降级成不安全上传。只有用户明确确认覆盖后，Agent 才应传 `overwrite=true`；此时会跳过版本状态与存在性预检，直接执行授权覆盖。

最小权限策略除 `oss:PutObject` 外，默认安全上传还需要 `oss:GetBucketVersioning` 与用于 HEAD 存在性检查的 `oss:GetObject`。若账号缺少这些读取权限，`overwrite=false` 会 fail-closed；请补充权限，不要让 Agent 自动改用 `overwrite=true` 绕过保护。

## 安全

AccessKey Secret 只存 macOS 钥匙串，AI 客户端接触不到凭证；建议使用最小权限 RAM 子账号；本地路径受允许目录约束，上传默认不覆盖远端对象，下载不覆盖本地同名文件。签名请求也不会自动跟随重定向。详见[安全边界](https://ihopefulchina.github.io/Ossuno/mcp.html)。

## 常见问题

- **AI 提示找不到配置档案** — 先运行 `npx ossuno-mcp auth`
- **上传报签名错误** — 运行 `npx ossuno-mcp auth --test` 验证凭证与地域
- **移除注册** — `npx ossuno-mcp uninstall`

完整文档（客户端配置位置、多账号、故障排查）见 [docs/mcp.md](https://github.com/ihopefulChina/Ossuno/blob/main/docs/mcp.md)。问题反馈到 [GitHub Issues](https://github.com/ihopefulChina/Ossuno/issues)。

## License

MIT
