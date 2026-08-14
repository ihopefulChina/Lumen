# Lumen 0.0.4 Finder、可信传输与自动更新实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 发布 Lumen 0.0.4，交付 Keychain 凭证、CRC64 校验、同 Bucket 云端整理、排序、收藏夹和安装后自动重启的 Sparkle 更新。

**Architecture:** 敏感凭证、校验、云端操作、浏览器状态和更新器分别放在独立组件中，由 `AppModel` 组合，避免继续扩大单个视图或模型职责。所有数据破坏性流程先完成预检和目标写入，再删除源；更新只接受固定 GitHub Feed 与 EdDSA 签名归档。

**Tech Stack:** Swift 6、SwiftUI、Observation、Foundation Security、URLSession、Swift Testing、Sparkle 2.9.2、GitHub Releases。

## Global Constraints

- 支持 Apple Silicon 与 macOS 15 或更高版本。
- 版本号 `0.0.4`，构建号 `4`。
- 不静默覆盖 OSS 对象或本地文件。
- 不完整分页必须阻断文件夹移动、复制、重命名和删除。
- Sparkle 归档必须通过 EdDSA 校验；私钥只保存在本机登录 Keychain。
- 每项生产行为先写失败测试并确认 RED，再写最小实现。

---

### Task 1: Keychain 凭证与明文迁移

**Files:**
- Modify: `Lumen/Support/KeychainStore.swift`
- Modify: `Lumen/Support/SecretStore.swift`
- Modify: `Lumen/App/AccountStore.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `LumenTests/SafetyAndVersionTests.swift`

**Interfaces:**
- Produces: `SecureSecretBackend`, `KeychainSecretBackend`, `SecretMigration.migrate(legacy:backend:)`, `SecretStore.migrateLegacySecrets()`。
- Consumes: `AccountStore.secretAccount(_:)` 与 `AccountStore.tokenAccount(_:)` 的稳定账号键。

- [ ] **Step 1: 写迁移事务失败测试**

```swift
@Test func keychainMigrationKeepsLegacyValueUntilWriteAndReadBackSucceed() throws {
    let backend = MemorySecretBackend(failingAccounts: ["broken"])
    let result = SecretMigration.migrate(legacy: ["ok": "one", "broken": "two"], backend: backend)
    #expect(result.remainingLegacy == ["broken": "two"])
    #expect(backend.value(for: "ok") == "one")
}

@Test func newSecretsAreReadFromSecureBackendInsteadOfLegacyJSON() throws {
    let backend = MemorySecretBackend()
    try backend.set("secret", for: "account")
    #expect(try backend.get("account") == "secret")
}
```

- [ ] **Step 2: 运行测试并确认因迁移 API 不存在而失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/SafetyAndVersionTests`

- [ ] **Step 3: 实现 Keychain CRUD 和迁移核心**

```swift
protocol SecureSecretBackend {
    func get(_ account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

struct SecretMigrationResult {
    var remainingLegacy: [String: String]
    var migratedAccounts: Set<String>
}
```

`KeychainSecretBackend.set` 使用 `SecItemUpdate`，找不到项目时使用 `SecItemAdd`；迁移逐项写入、回读相等后才从 `remainingLegacy` 删除。`SecretStore.set/get/delete` 只操作 Keychain，新启动时调用一次 `migrateLegacySecrets()`，空明文文件删除。

- [ ] **Step 4: 运行定向测试和完整测试**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test`

- [ ] **Step 5: 提交**

```bash
git add Lumen/Support/KeychainStore.swift Lumen/Support/SecretStore.swift Lumen/App/AccountStore.swift Lumen/LumenApp.swift LumenTests/SafetyAndVersionTests.swift
git commit -m "security: move account secrets into Keychain"
```

### Task 2: CRC64/XZ 上传下载校验

**Files:**
- Create: `Lumen/Support/CRC64XZ.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/Transfer/TransferJob.swift`
- Modify: `Lumen/Transfer/TransferEngine.swift`
- Modify: `Lumen/Views/TransferTray.swift`
- Modify: `LumenTests/OSSClientTests.swift`
- Modify: `LumenTests/TransferEngineTests.swift`

**Interfaces:**
- Produces: `CRC64XZ.update(_:)`, `CRC64XZ.checksum(fileURL:)`, `OSSIntegrityError`, `TransferJob.integrityVerified`。
- Consumes: `OSSHTTPResult.headers` 与大小写不敏感的 Header 查找。

- [ ] **Step 1: 写已知向量、上传匹配和下载不匹配测试**

```swift
@Test func crc64XZMatchesTheStandardCheckVector() {
    #expect(CRC64XZ.checksum(Data("123456789".utf8)) == 0x995D_C9BB_DF19_39FA)
}

@Test func uploadRejectsAMismatchedServerCRC64() async throws {
    let transport = StubTransport(headers: ["x-oss-hash-crc64ecma": "1"])
    await #expect(throws: OSSIntegrityError.self) {
        try await makeClient(transport).putData(key: "a", data: Data("abc".utf8), contentType: "text/plain", acl: .private)
    }
}

@Test func mismatchedDownloadNeverReachesTheDestination() async throws {
    let destination = temporaryDirectory.appending(path: "a.bin")
    await #expect(throws: OSSIntegrityError.self) {
        try await makeDownloadClient(serverCRC: "1").download(key: "a", to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
```

- [ ] **Step 2: 运行测试并确认 CRC 类型缺失导致失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/OSSClientTests`

- [ ] **Step 3: 实现流式 CRC 与响应比较**

使用 CRC64/XZ 反射多项式 `0xC96C5795D7870F42`、初值与最终异或 `UInt64.max`。上传前流式计算本地文件；普通 PUT、CompleteMultipartUpload 和完整 GET 返回校验头时调用：

```swift
static func verify(local: UInt64, headers: [String: String]) throws -> Bool
```

下载在临时文件校验成功后再移动到最终路径；没有校验头时返回 `false` 但不失败。

- [ ] **Step 4: 把校验结果显示到传输任务**

`TransferJob` 增加 `integrityVerified: Bool`；完成文案在 true 时显示“完成 · 已校验”。失败使用“完整性校验失败，本地文件未保存”。

- [ ] **Step 5: 运行定向和完整测试后提交**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test
git add Lumen/Support/CRC64XZ.swift Lumen/OSS/OSSClient.swift Lumen/Transfer Lumen/Views/TransferTray.swift LumenTests
git commit -m "feat: verify OSS transfers with CRC64"
```

### Task 3: 排序与收藏夹

**Files:**
- Create: `Lumen/Browser/FavoriteLocation.swift`
- Modify: `Lumen/Browser/BrowserModel.swift`
- Modify: `Lumen/App/AppSettings.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/SidebarView.swift`
- Modify: `LumenTests/BrowserModelTests.swift`
- Modify: `LumenTests/SafetyAndVersionTests.swift`

**Interfaces:**
- Produces: `BrowserSortField`, `BrowserSortDirection`, `BrowserModel.sortField`, `BrowserModel.sortDirection`, `FavoriteLocation`, `FavoriteLocationStore`。

- [ ] **Step 1: 写排序稳定性与收藏序列化测试**

```swift
@Test func browserSortsBySizeDescendingWhileKeepingFoldersFirst() {
    let model = populatedBrowser()
    model.sortField = .size
    model.sortDirection = .descending
    #expect(model.orderedVisibleKeys == ["folder/", "large.bin", "small.bin"])
}

@Test func favoriteStoreRoundTripsAccountBucketAndPrefix() throws {
    let favorite = FavoriteLocation(accountID: accountID, bucketName: "assets", prefix: "images/", displayName: "图片")
    let data = try JSONEncoder().encode([favorite])
    #expect(try JSONDecoder().decode([FavoriteLocation].self, from: data) == [favorite])
}
```

- [ ] **Step 2: 运行并确认缺少排序/收藏类型导致失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/BrowserModelTests`

- [ ] **Step 3: 实现排序模型与持久化收藏**

`visibleFolders`、`visibleObjects` 在过滤后统一按字段和方向排序；同值使用名称自然排序保证稳定。收藏存入 `UserDefaults` JSON，去重键为 `accountID + bucketName + prefix`。

- [ ] **Step 4: 接入 Finder 式 UI**

工具栏增加排序菜单；列表表头点击更新排序。路径菜单增加“添加到个人收藏”，侧边栏增加“个人收藏”区及移除菜单；点击时异步切换账号、Bucket 和 prefix。

- [ ] **Step 5: 运行完整测试后提交**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test
git add Lumen/Browser Lumen/App Lumen/Views/BrowserView.swift Lumen/Views/SidebarView.swift LumenTests
git commit -m "feat: add Finder sorting and favorites"
```

### Task 4: 同 Bucket 移动、复制和文件夹重命名

**Files:**
- Create: `Lumen/OSS/CloudObjectOperation.swift`
- Modify: `Lumen/OSS/OSSClient.swift`
- Modify: `Lumen/App/AppModel.swift`
- Modify: `Lumen/Views/BrowserView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `LumenTests/OSSClientTests.swift`
- Modify: `LumenTests/BrowserModelTests.swift`
- Modify: `LumenTests/RealOSSSmokeTests.swift`

**Interfaces:**
- Produces: `CloudOperationMode.copy/move`, `CloudObjectOperation.planPrefix`, `OSSClient.copyPrefix`, `OSSClient.movePrefix`, `AppModel.renameFolder(_:to:)`, `AppModel.moveSelection(to:)`。

- [ ] **Step 1: 写前缀映射、内部目标拒绝和失败不删源测试**

```swift
@Test func prefixPlanPreservesRelativePaths() throws {
    let plan = try CloudObjectOperation.planPrefix(source: "old/", destination: "new/", keys: ["old/", "old/a.jpg", "old/sub/b.jpg"])
    #expect(plan.map(\.destinationKey) == ["new/", "new/a.jpg", "new/sub/b.jpg"])
}

@Test func prefixCannotMoveInsideItself() {
    #expect(throws: CloudObjectOperationError.self) {
        try CloudObjectOperation.planPrefix(source: "old/", destination: "old/sub/", keys: ["old/a"])
    }
}

@Test func failedCopyLeavesEverySourceObjectUntouched() async throws {
    let transport = CopyFailureTransport(failAt: 2)
    await #expect(throws: Error.self) { try await makeClient(transport).movePrefix(from: "old/", to: "new/") }
    #expect(transport.deletedSourceKeys.isEmpty)
}
```

- [ ] **Step 2: 运行并确认规划 API 缺失导致失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/OSSClientTests`

- [ ] **Step 3: 实现安全的前缀操作**

完整列举包含占位对象；不完整则失败。先对所有目标执行 HEAD 冲突预检，再逐项无覆盖复制。复制失败时反向删除本次目标；移动模式全部复制成功后再反向删除源。

- [ ] **Step 4: 接入文件夹重命名、快捷菜单和拖放**

文件夹菜单增加“重命名…”；对象和文件夹成为应用内部拖动源，文件夹/路径栏成为目标，默认移动。复制入口保留在快捷菜单，以明确避免 Option 键状态丢失造成误操作。

- [ ] **Step 5: 扩展真实 OSS 冒烟测试并运行完整测试**

真实测试只使用 `lumen-v004-smoke/`，验证上传、复制、移动、前缀重命名、下载和清理。

- [ ] **Step 6: 提交**

```bash
git add Lumen/OSS Lumen/App/AppModel.swift Lumen/Views/BrowserView.swift Lumen/Views/RootView.swift LumenTests
git commit -m "feat: organize OSS objects like Finder"
```

### Task 5: Sparkle 安装更新并自动重启

**Files:**
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Create: `Lumen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `Lumen/App/AppUpdater.swift`
- Modify: `Lumen/App/AppServices.swift`
- Delete: `Lumen/App/UpdateService.swift`
- Delete: `Lumen/Views/UpdateSheet.swift`
- Modify: `Lumen/LumenApp.swift`
- Modify: `Lumen/Views/SettingsView.swift`
- Modify: `Lumen/Views/RootView.swift`
- Modify: `Info.plist`
- Modify: `Lumen/Lumen.entitlements`
- Replace: `LumenTests/UpdateServiceTests.swift`

**Interfaces:**
- Produces: `AppUpdater.checkForUpdates()`, `AppUpdater.automaticallyChecksForUpdates`，内部持有 `SPUStandardUpdaterController`。

- [ ] **Step 1: 写固定 Feed、安全配置和设置桥接测试**

```swift
@Test func updateFeedIsPinnedToTheLatestLumenReleaseAsset() {
    #expect(AppUpdater.feedURL.absoluteString == "https://github.com/ihopefulChina/Lumen/releases/latest/download/appcast.xml")
}

@Test func automaticCheckPreferenceIsForwardedToTheUpdaterDriver() {
    let driver = RecordingUpdaterDriver()
    let updater = AppUpdater(driver: driver)
    updater.automaticallyChecksForUpdates = false
    #expect(driver.automaticallyChecksForUpdates == false)
}
```

- [ ] **Step 2: 运行测试并确认新更新器 API 缺失导致失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/UpdateServiceTests`

- [ ] **Step 3: 固定 Sparkle 2.9.2 并实现更新器封装**

项目加入 `https://github.com/sparkle-project/Sparkle` 精确版本 `2.9.2` 和 `Sparkle` 产品。`AppUpdater` 使用 `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`；菜单和设置按钮调用 `checkForUpdates(nil)`。

- [ ] **Step 4: 配置沙盒、安全键和 Feed**

`Info.plist` 增加 `SUFeedURL`、`SUPublicEDKey`、`SUEnableInstallerLauncherService=true`、`SUVerifyUpdateBeforeExtraction=true`；entitlements 增加 `studio.lumen.oss-spks` 与 `studio.lumen.oss-spki` Mach lookup 例外。

- [ ] **Step 5: 解析依赖、构建、运行测试并提交**

```bash
xcodebuild -resolvePackageDependencies -project Lumen.xcodeproj -scheme Lumen
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test
git add Lumen.xcodeproj Lumen Info.plist LumenTests/UpdateServiceTests.swift
git commit -m "feat: install updates and relaunch with Sparkle"
```

### Task 6: 版本、发布脚本、README 和更新 Feed

**Files:**
- Modify: `Lumen.xcodeproj/project.pbxproj`
- Modify: `scripts/package-dmg.sh`
- Create: `scripts/generate-appcast.sh`
- Create: `appcast.xml`
- Modify: `README.md`
- Create: `docs/releases/v0.0.4.md`
- Create: `docs/superpowers/checklists/2026-08-14-lumen-v0.0.4-release.md`

**Interfaces:**
- Produces: `dist/Lumen-0.0.4.dmg`、`dist/appcast.xml`。

- [ ] **Step 1: 写版本和发布资产测试**

更新 `SafetyAndVersionTests`，断言 `AppVersion.current == "0.0.4"` 的构建配置由 Info.plist 提供，并增加脚本静态检查：版本 `0.0.4`、构建号 `4`、Feed enclosure 固定到 `/releases/download/v0.0.4/Lumen-0.0.4.dmg`。

- [ ] **Step 2: 确认旧版本配置使测试失败**

Run: `xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-tdd test -only-testing:LumenTests/SafetyAndVersionTests`

- [ ] **Step 3: 更新版本和打包脚本**

把应用与测试目标设为 `MARKETING_VERSION=0.0.4`、`CURRENT_PROJECT_VERSION=4`。打包脚本新建 DMG 后运行 Sparkle `generate_appcast`，使用 Keychain 中 EdDSA 私钥生成签名 enclosure，并把 Feed 输出到 `dist/appcast.xml`。

- [ ] **Step 4: 重写产品文档相关部分**

README 增加“整理云端文件”“传输可信度”“自动更新”，删除明文凭证说明；发布说明列出安全迁移、CRC64、排序、收藏和同 Bucket 限制。

- [ ] **Step 5: 运行测试、打包并提交**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lumen-v004-release-gate test
scripts/package-dmg.sh
git add Lumen.xcodeproj scripts README.md appcast.xml docs LumenTests
git commit -m "chore: prepare Lumen 0.0.4"
```

### Task 7: 发布门禁与 GitHub 上线

**Files:**
- Modify: `docs/superpowers/checklists/2026-08-14-lumen-v0.0.4-release.md`

- [ ] **Step 1: 执行最终自动化门禁**

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/lumen-v004-final clean test
xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath /tmp/lumen-v004-final clean analyze
codesign --verify --deep --strict --verbose=2 .build/release-v004/Build/Products/Release/Lumen.app
hdiutil verify dist/Lumen-0.0.4.dmg
```

- [ ] **Step 2: 验证 Sparkle 资产**

使用 Sparkle `sign_update` 验证生成的 EdDSA 签名来源，`xmllint --noout dist/appcast.xml`，并断言 enclosure 的版本、长度、URL 与本地 DMG 一致。

- [ ] **Step 3: 运行真实 OSS 冒烟测试**

启用既有真实测试环境变量，确认 `lumen-v004-smoke/` 只包含测试键且结束为空。

- [ ] **Step 4: 合并到 main、推送并创建标签**

在主工作区 fast-forward 合并 `codex/lumen-v004`，推送 `main`，创建并推送 annotated tag `v0.0.4`。

- [ ] **Step 5: 创建公开 GitHub Release**

```bash
gh release create v0.0.4 dist/Lumen-0.0.4.dmg dist/appcast.xml --repo ihopefulChina/Lumen --title "Lumen 0.0.4" --notes-file docs/releases/v0.0.4.md --latest
```

- [ ] **Step 6: 从公开 Release 回验**

下载 DMG 与 appcast 到新临时目录，比较 SHA-256 与字节内容；确认 Release 非草稿、非预发布、Latest，远端 `main` 与 `v0.0.4^{}` 指向最终提交。

