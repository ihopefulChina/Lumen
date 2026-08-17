import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: crop <in> <out> <yTopPt> <heightPt>"); exit(1) }
let inPath = args[1], outPath = args[2]
let yTop = CGFloat(Int(args[3])!), h = CGFloat(Int(args[4])!)
guard let image = NSImage(contentsOfFile: inPath) else { print("no image"); exit(1) }
let scale = image.representations.first?.pixelsWide ?? Int(image.size.width)
let pxScale = CGFloat(scale) / image.size.width
let xLeft = args.count > 5 ? CGFloat(Int(args[5])!) : 0
let wPts = args.count > 5 ? CGFloat(Int(args[6])!) : 1240
guard let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("no cg"); exit(1) }
let pxPerPt = CGFloat(full.height) / 800.0
let rect = NSRect(x: xLeft, y: yTop, width: wPts, height: h)
guard let cg = full.cropping(to: NSRect(
    x: rect.origin.x * pxPerPt, y: rect.origin.y * pxPerPt,
    width: rect.size.width * pxPerPt, height: rect.size.height * pxPerPt
)) else { print("crop failed"); exit(1) }
let scaled = NSImage(size: NSSize(width: cg.width, height: cg.height))
scaled.addRepresentation(NSBitmapImageRep(cgImage: cg))
// upscale 3x for OCR
let big = NSImage(size: NSSize(width: CGFloat(cg.width) * 3, height: CGFloat(cg.height) * 3))
big.lockFocus()
scaled.draw(in: NSRect(origin: .zero, size: big.size))
big.unlockFocus()
if let tiff = big.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
}
print("wrote \(outPath)")
