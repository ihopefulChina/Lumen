import AppKit
import Vision
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/lumen_user_window.png"
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let cg = NSBitmapImageRep(data: tiff)?.cgImage else {
    print("cannot load image"); exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([request])

let results = request.results ?? []
struct Box { let text: String; let y: CGFloat; let x: CGFloat }
var boxes: [Box] = []
for obs in results {
    guard let candidate = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox // normalized, origin bottom-left
    boxes.append(Box(text: candidate.string, y: b.origin.y, x: b.origin.x))
}
boxes.sort { $0.y > $1.y }
print("imageHeightPx=\(cg.height) imageWidthPx=\(cg.width)")
for b in boxes {
    // yFromTop in normalized (0=top), and approximate pt coords (logical 1240x800)
    let yTop = 1 - b.y
    let yPt = Int(yTop * 800)
    let xPt = Int(b.x * 1240)
    print("y=\(yPt)pt x=\(xPt)pt | \(b.text)")
}
