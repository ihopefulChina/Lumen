# lumen-mcp

[Lumen](https://ihopefulchina.github.io/Lumen/)（macOS 阿里云 OSS 客户端）附带的 MCP 服务器。配置到 Codex、Claude Desktop、Claude Code、Cursor、Trae 等 AI 客户端后，AI 可以用自然语言浏览 Bucket、上传下载文件、生成带签名的临时下载链接。

## 快速开始

```bash
# 1. 配置 OSS 凭证（保存在 macOS 钥匙串）
npx lumen-mcp auth

# 2. 一键注册到本机已安装的 AI 客户端
npx lumen-mcp install
```

重启 AI 客户端后直接对话：「列出我的 OSS Bucket」。

## 说明

- 本包是启动器，真正的服务器为 Swift 预编译二进制（arm64 / x64 由 npm 按平台自动安装）。
- 需要 macOS 与 Node ≥ 18；无 Node 时可从 [GitHub Releases](https://github.com/ihopefulChina/Lumen) 获取独立二进制。
- 支持的客户端、安全边界与故障排查见[完整文档](https://github.com/ihopefulChina/Lumen/blob/main/docs/mcp.md)。
