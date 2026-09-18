import Foundation

/// Tiny append-only log so shortcut issues can be diagnosed from a file
/// (~/Library/Logs/Imager/imager.log) instead of a console the user never sees.
enum ImagerLog {
    private static let directory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Imager", isDirectory: true)
    private static let file = directory.appendingPathComponent("imager.log")

    static func log(_ message: String) {
        let line = "[\(Date().formatted())] \(message)\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}