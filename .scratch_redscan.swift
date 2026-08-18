import AppKit

// Scan for red-ish pixels (system red border) in the bottom band of a screenshot.
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ossuno_border.png"
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else { print("no image"); exit(1) }
let w = rep.pixelsWide, h = rep.pixelsHigh
var redRows: [Int: Int] = [:]
for y in max(0, h - 260)..<h {
    for x in stride(from: 0, to: w, by: 2) {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        if r > 0.65, g < 0.35, b < 0.35 {
            redRows[y, default: 0] += 1
        }
    }
}
if redRows.isEmpty {
    print("NO RED PIXELS in bottom \(260)px")
} else {
    let sorted = redRows.sorted { $0.key < $1.key }
    print("red pixel rows (px from top, count):")
    for (y, n) in sorted { print("  y=\(y) (\(Int(Double(y)/Double(h)*800))pt) count=\(n)") }
}
