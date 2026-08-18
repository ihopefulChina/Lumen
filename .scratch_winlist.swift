import CoreGraphics
import Foundation

let onScreenOnly = CommandLine.arguments.contains("--onscreen")
var opts: CGWindowListOption = [.excludeDesktopElements]
if onScreenOnly { opts.insert(.optionOnScreenOnly) }
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no windows"); exit(1)
}
for w in list {
    let owner = w["kCGWindowOwnerName"] as? String ?? "?"
    if owner == "Ossuno" {
        let num = w["kCGWindowNumber"] as? Int ?? -1
        let bounds = w["kCGWindowBounds"] as? [String: Any] ?? [:]
        let name = w["kCGWindowName"] as? String ?? ""
        let layer = w["kCGWindowLayer"] as? Int ?? 0
        print("id=\(num) layer=\(layer) bounds=\(bounds) name=\(name)")
    }
}
