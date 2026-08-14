import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SystemIcons {
    static let folder: NSImage = {
        let image = NSWorkspace.shared.icon(for: UTType.folder).copy() as! NSImage
        image.size = NSSize(width: 128, height: 128)
        return image
    }()

    static let folderSmall: NSImage = {
        let image = NSWorkspace.shared.icon(for: UTType.folder).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    static func fileIcon(for key: String, size: CGFloat = 128) -> NSImage {
        let ext = (key as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type).copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        return image
    }
}

struct FinderFileIcon: View {
    let key: String
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: SystemIcons.fileIcon(for: key, size: size > 32 ? 128 : 16))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

struct FinderFolderIcon: View {
    var size: CGFloat = 72

    var body: some View {
        Image(nsImage: size > 32 ? SystemIcons.folder : SystemIcons.folderSmall)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
    }
}
