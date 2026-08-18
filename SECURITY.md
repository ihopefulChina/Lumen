# Security Policy

## Supported versions

安全修复只进入当前最新版本。请先升级到 [Releases](https://github.com/ihopefulChina/Ossuno/releases/latest) 中的最新版，再验证问题是否仍然存在。

## Privately report a vulnerability

请通过 GitHub 的 [Private vulnerability reporting](https://github.com/ihopefulChina/Ossuno/security/advisories/new) 提交尚未公开的安全问题，不要创建公开 Issue。

报告中请说明：

- 受影响版本与 macOS 版本；
- 最小复现步骤和影响；
- 只使用虚拟账号、Bucket、对象名与 URL 的截图或样例；
- 如有可行的缓解方式，请一并说明。

不要发送 AccessKey ID、AccessKey Secret、STS Token、签名 URL、真实 Bucket、对象键、本地路径或请求 ID。维护者确认问题后会在私密 advisory 中协调修复、披露时间和致谢。

## Product security boundaries

Ossuno 将 Secret 与 Token 保存在 macOS 钥匙串；本地账号偏好和传输历史不应包含凭证。应用内“复制诊断信息”生成的摘要经过字段白名单过滤。若发现这些边界被破坏，请按安全漏洞私密报告。
