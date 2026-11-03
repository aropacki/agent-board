import Foundation

let popupLogURL = boardDir.appendingPathComponent("popup.log")

/// One line per popup transition, so a popup that stops opening can be traced from the file afterwards.
/// Past 256 KB the file rolls over to `popup.log.1`.
func popupLog(_ line: @autoclosure () -> String) {
    guard !isBench else { return }
    let text = "\(Date().formatted(.iso8601)) \(line())\n"
    let fm = FileManager.default
    if let size = (try? fm.attributesOfItem(atPath: popupLogURL.path))?[.size] as? Int, size > 256_000 {
        let old = popupLogURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: popupLogURL, to: old)
    }
    guard let handle = try? FileHandle(forWritingTo: popupLogURL) else {
        try? text.write(to: popupLogURL, atomically: false, encoding: .utf8)
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(text.utf8))
}
