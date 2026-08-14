import Foundation

enum FileSafety {
    enum Error: LocalizedError, Equatable {
        case emptyPath
        case absolutePath
        case invalidComponent(String)
        case invalidName
        case outsideRoot

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                "文件路径不能为空"
            case .absolutePath:
                "文件路径必须是相对路径"
            case .invalidComponent(let component):
                "文件路径包含无效部分“\(component)”"
            case .invalidName:
                "名称不能为空，也不能包含斜杠或路径符号"
            case .outsideRoot:
                "目标路径超出了所选文件夹"
            }
        }
    }

    static func relativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty else { throw Error.emptyPath }
        guard !relativePath.hasPrefix("/"), !(relativePath as NSString).isAbsolutePath else {
            throw Error.absolutePath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { throw Error.emptyPath }
        for component in components {
            let containsControl = component.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains(":"),
                  !containsControl
            else {
                throw Error.invalidComponent(component)
            }
        }
        return components
    }

    static func destination(root: URL, relativePath: String) throws -> URL {
        let components = try relativeComponents(relativePath)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = resolvedRoot

        for component in components {
            candidate.append(path: component)
            let checked = FileManager.default.fileExists(atPath: candidate.path)
                ? candidate.resolvingSymlinksInPath()
                : candidate.standardizedFileURL
            guard isInside(checked, resolvedRoot: resolvedRoot) else {
                throw Error.outsideRoot
            }
        }
        return candidate
    }

    static func validate(destination: URL, root: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(resolvedParent, resolvedRoot: resolvedRoot) else {
            throw Error.outsideRoot
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard isInside(destination.resolvingSymlinksInPath(), resolvedRoot: resolvedRoot) else {
                throw Error.outsideRoot
            }
        }
    }

    private static func isInside(_ url: URL, resolvedRoot: URL) -> Bool {
        let rootPath = resolvedRoot.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

enum ObjectNameValidator {
    static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsControl = name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains(":"),
              !containsControl
        else {
            throw FileSafety.Error.invalidName
        }
        return name
    }
}
