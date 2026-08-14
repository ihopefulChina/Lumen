import Foundation

enum OSSImageProcess {
    case grid
    case inspector

    var query: String {
        switch self {
        case .grid:
            "image/resize,w_200/crop,w_128,h_128,g_center"
        case .inspector:
            "image/resize,m_lfit,w_640,h_640,limit_1"
        }
    }

    var cacheKey: String {
        switch self {
        case .grid: "g2"
        case .inspector: "i2"
        }
    }
}
