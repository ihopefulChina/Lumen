import Foundation

enum OSSImageProcess {
    case grid
    case row
    case inspector

    var query: String {
        switch self {
        case .grid:
            "image/resize,m_fill,w_128,h_128,limit_1"
        case .row:
            "image/resize,m_lfit,w_40,h_40,limit_1"
        case .inspector:
            "image/resize,m_lfit,w_640,h_640,limit_1"
        }
    }

    var cacheKey: String {
        switch self {
        case .grid: "g4"
        case .row: "r2"
        case .inspector: "i3"
        }
    }

    func queries(for key: String) -> [String] {
        var items = [query]
        if ImageKind.needsJPEGPreview(key: key) {
            items.append(query + "/format,jpg")
            items.append("image/resize,m_lfit,w_160,h_160,limit_1/format,jpg")
        } else {
            items.append("image/resize,m_lfit,w_160,limit_1")
        }
        return items
    }

    var maxPixel: CGFloat {
        switch self {
        case .grid: 128
        case .row: 40
        case .inspector: 640
        }
    }
}
