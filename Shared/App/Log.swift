import Foundation
import os

/// Logs to the unified log (Console.app, subsystem com.mjcocat.Cocut) and to
/// ~/Library/Logs/Cocut/Cocut.log so problems can be shared easily.
enum Log {
    private static let logger = Logger(subsystem: "com.mjcocat.Cocut", category: "app")
    private static let queue = DispatchQueue(label: "com.mjcocat.Cocut.log")

    static let fileURL: URL = {
        let dir = Platform.logsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Cocut.log")
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            append("INFO  Log created")
        }
        queue.sync {}
        Platform.reveal([fileURL])
    }

    private static func append(_ line: String) {
        let stamp = Date().formatted(.iso8601)
        queue.async {
            let data = Data("\(stamp) \(line)\n".utf8)
            let path = fileURL.path(percentEncoded: false)
            // Keep the file from growing without bound.
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
