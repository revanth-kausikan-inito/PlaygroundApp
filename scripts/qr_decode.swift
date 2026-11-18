// Decodes the QR payload of each image listed (one absolute path per line) in the file given as
// argument 1, and writes {"path": payload-or-"NONE"} JSON to argument 2. Used on the Mac to pick
// one image per distinct QR code; payload text is all that matters here, not the corners.
import Foundation
import ImageIO
import Vision

let paths = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .split(separator: "\n").map(String.init)
var out: [String: String] = [:]
for path in paths {
    var payload = "NONE"
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        payload = request.results?.first?.payloadStringValue ?? "NONE"
    }
    out[path] = payload
}
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("decoded \(out.count)")
