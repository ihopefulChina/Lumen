# Lumen 官网实施计划

> 本计划在 Lumen 0.0.6 已公开发布并完成公网包校验后执行。

**目标：** 构建并部署 `https://ihopefulchina.github.io/Lumen/`，用真实产品素材呈现 Lumen，并把官网入口回写到仓库。

**架构：** `website/` 保存无构建依赖的静态站点；`.github/workflows/pages.yml` 通过 GitHub Pages 官方 Actions 上传并部署该目录。页面只使用仓库内真实图标和截图，所有 URL 兼容 `/Lumen/` 子路径。

**技术栈：** HTML5、CSS、GitHub Actions、GitHub Pages；验证使用 Python 标准库、HTML 检查脚本、curl 与 GitHub CLI。

---

### 任务 1：建立网站验证基线

**文件：**
- 新建：`scripts/validate-website.sh`

1. 先编写校验：要求核心页面、资源、元数据、下载链接、可访问性标记和相对 URL 存在。
2. 在尚无 `website/` 时运行并确认失败。
3. 校验脚本使用严格 shell 选项，并拒绝外部字体、第三方脚本、占位文案和根路径资源。

### 任务 2：实现静态官网

**文件：**
- 新建：`website/index.html`
- 新建：`website/styles.css`
- 新建：`website/site.webmanifest`
- 新建：`website/robots.txt`
- 新建：`website/.nojekyll`
- 新建：`website/assets/lumen-icon.png`
- 新建：`website/assets/lumen-favicon.png`
- 新建：`website/assets/browser.png`
- 新建：`website/assets/account.png`

1. 复制经过确认的真实产品素材，不改变应用图标资产。
2. 按设计规范实现语义化页面、相对链接、响应式布局、焦点态和 reduced-motion。
3. 不增加运行时 JavaScript；交互使用锚点与原生 `details`。
4. 运行网站校验直到通过。

### 任务 3：建立 GitHub Pages 工作流

**文件：**
- 新建：`.github/workflows/pages.yml`

1. 使用 `actions/checkout`、`actions/configure-pages`、`actions/upload-pages-artifact`、`actions/deploy-pages`。
2. 只上传 `website/`，配置 `pages: write` 与 `id-token: write`，使用 `github-pages` environment。
3. 在部署前运行 `scripts/validate-website.sh`。
4. 用本地 YAML/文本检查确认权限、依赖关系和 artifact 路径。

### 任务 4：本地视觉与质量验收

1. 启动本地静态服务器。
2. 在桌面与窄屏尺寸检查首屏、真实截图、深色安全区、FAQ、焦点态和无横向滚动。
3. 检查所有站内资源返回 200、外部下载链接指向 0.0.6 最新公开包。
4. 检查 HTML 结构、资源尺寸、Git diff 和工作区状态。

### 任务 5：部署并回写仓库入口

**文件：**
- 修改：`README.md`
- 修改：`Lumen/Support/AppLinks.swift`（仅当现有链接结构适合增加官网入口）

1. 提交网站与工作流，推送 main。
2. 将 Pages source 配置为 GitHub Actions，监控部署到成功。
3. 公网验证官网 HTML、CSS、图片、favicon、manifest 和下载链接。
4. 在 README 顶部加入官网入口并提交推送；再次等待 Pages 更新。
5. 最终确认 GitHub Pages URL、Release URL、main 同步状态及无未提交修改。
