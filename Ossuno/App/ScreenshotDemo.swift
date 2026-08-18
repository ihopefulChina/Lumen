#if DEBUG
import AppKit
import Foundation

@MainActor
enum ScreenshotDemo {
    enum Mode: Equatable {
        case browser
        case account
    }

    static var currentMode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ossuno-screenshot-browser") { return .browser }
        if arguments.contains("--ossuno-screenshot-account") { return .account }
        return nil
    }

    static var forcedAppearance: NSAppearance? {
        guard currentMode != nil else { return nil }
        return NSAppearance(
            named: ProcessInfo.processInfo.arguments.contains("--ossuno-screenshot-dark") ? .darkAqua : .aqua
        )
    }

    static func applyAppearance() {
        guard let forcedAppearance else { return }
        NSApp.appearance = forcedAppearance
    }

    static let accountDraft = AccountDraft(
        id: UUID(uuidString: "6A7ED12A-73B6-4C18-A6DE-3BD395520001")!,
        name: "Ossuno 演示工作室",
        accessKeyId: "LTAI5tDEMO0000000000",
        secret: "demo-secret-never-used",
        token: "",
        regionID: "cn-hangzhou",
        endpointOverride: "",
        cdnDomain: "media.example.com",
        defaultACL: .default,
        prefixTemplate: "assets/{yyyy}/{MM}/{dd}/",
        useTransferAccelerate: true,
        createdAt: Date(timeIntervalSince1970: 1_765_756_800)
    )

    static func makeModel(for mode: Mode) -> AppModel {
        let accountID = UUID(uuidString: "6A7ED12A-73B6-4C18-A6DE-3BD395520001")!
        let account = OSSAccount(
            id: accountID,
            name: "Ossuno 演示工作室",
            accessKeyId: "LTAI5tDEMO0000000000",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "media.example.com",
            defaultACL: .default,
            prefixTemplate: "assets/{yyyy}/{MM}/{dd}/",
            useTransferAccelerate: true,
            createdAt: Date(timeIntervalSince1970: 1_765_756_800)
        )
        let defaults = UserDefaults(suiteName: "Ossuno.ScreenshotDemo.\(UUID().uuidString)")!
        let services = AppServices(
            accounts: [account],
            settings: AppSettings(defaults: defaults),
            favorites: FavoriteStore(defaults: defaults)
        )
        let model = AppModel(services: services)
        model.browser = BrowserModel(defaults: defaults)
        model.selectedAccountID = accountID
        model.buckets = buckets
        model.selectedBucketName = "ossuno-studio-assets"
        model.browser.prefix = "campaigns/2026-autumn/"
        model.browser.viewMode = .list
        model.browser.imagesOnly = false
        model.searchScope = .folder
        model.searchFilter = .all
        model.browser.folders = folders
        model.browser.objects = objects
        model.browser.backStack = ["", "campaigns/"]
        model.browser.replaceSelection(["campaigns/2026-autumn/发布素材/"])
        model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "ossuno-studio-assets",
            prefix: "brand/",
            name: "品牌素材"
        ))
        model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "ossuno-studio-assets",
            prefix: "campaigns/2026-autumn/发布素材/",
            name: "待发布"
        ))
        if mode == .browser {
            model.transfers.jobs = [
                TransferJob(
                    id: UUID(),
                    kind: .download,
                    status: .running,
                    title: "交付清单.pdf",
                    objectKey: "campaigns/2026-autumn/交付清单.pdf",
                    localURL: nil,
                    transferred: 589_660,
                    total: 842_371,
                    errorMessage: nil,
                    publicURL: nil,
                    finishedAt: nil
                ),
                TransferJob(
                    id: UUID(),
                    kind: .upload,
                    status: .paused,
                    title: "片头动画.mov",
                    objectKey: "campaigns/2026-autumn/片头动画.mov",
                    localURL: nil,
                    transferred: 94_371_840,
                    total: 186_422_901,
                    errorMessage: nil,
                    publicURL: nil,
                    finishedAt: nil
                )
            ]
        }
        model.showAccountSheet = mode == .account
        return model
    }

    static func prepareWindow() {
        applyAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
            applyAppearance()
            window.appearance = NSApp.appearance
            let size = NSSize(width: 1240, height: 800)
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: size)
            window.setFrame(
                NSRect(
                    origin: CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2),
                    size: size
                ),
                display: true
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static let buckets = [
        OSSBucket(
            name: "ossuno-studio-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        ),
        OSSBucket(
            name: "ossuno-product-archive",
            regionID: "cn-shanghai",
            location: "oss-cn-shanghai",
            extranetEndpoint: "oss-cn-shanghai.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_672_531_200)
        ),
        OSSBucket(
            name: "ossuno-team-uploads",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
    ]

    private static let folders = [
        OSSFolder(prefix: "campaigns/2026-autumn/品牌规范/"),
        OSSFolder(prefix: "campaigns/2026-autumn/产品图/"),
        OSSFolder(prefix: "campaigns/2026-autumn/发布素材/"),
        OSSFolder(prefix: "campaigns/2026-autumn/归档/")
    ]

    private static let objects = [
        object("交付清单.pdf", size: 842_371, modified: 1_786_579_200),
        object("发布说明.md", size: 18_426, modified: 1_786_406_400),
        object("视觉规范-v3.sketch", size: 28_934_228, modified: 1_785_974_400),
        object("官网文案.txt", size: 9_842, modified: 1_785_628_800),
        object("素材索引.json", size: 124_908, modified: 1_785_369_600),
        object("片头动画.mov", size: 186_422_901, modified: 1_784_851_200),
        object("封面视觉.psd", size: 74_208_552, modified: 1_783_209_600)
    ]

    private static func object(_ name: String, size: Int64, modified: TimeInterval) -> OSSObject {
        OSSObject(
            key: "campaigns/2026-autumn/\(name)",
            size: size,
            etag: "DEMO-\(size)",
            lastModified: Date(timeIntervalSince1970: modified),
            storageClass: "Standard"
        )
    }
}
#endif
